//! `knap-mcp smoke [--backend k]`: the live-backend checklist (#89) as one
//! command, so a new provider is tested by pointing at it, not by hand.
//!
//! Before any call it resolves the model: the endpoint's model id for
//! HTTP kinds (and whether `GET /models` serves it), or the agent's own
//! report from a free ACP handshake. Then one `completeReply` per
//! `backend.Task` asks for a fixed token, and one real `repairPatch` runs
//! the repair prompt and sanitizer on an unclosed `{% if %}`. Each row
//! records latency, finish reason, answer and reasoning bytes, metered
//! usage, and whether the reply had the right shape. Exits 1 when any row
//! fails, so a runner can stop before a long eval.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const backend = @import("backend.zig");
const acp = @import("acp.zig");
const engine = @import("engine.zig");

const Writer = std.Io.Writer;

/// How a reply matched what the row asked for.
const Shape = enum {
    /// The answer is exactly the token (task rows) or a patch that closes
    /// the block (repair row).
    exact,
    /// The token is in the answer, with extra text around it.
    loose,
    wrong,
    /// No answer to judge: the call failed, or the patch was rejected.
    none,

    fn passes(s: Shape) bool {
        return s == .exact or s == .loose;
    }
};

const Row = struct {
    name: []const u8,
    ms: u64 = 0,
    finish: ?[]const u8 = null,
    content_bytes: ?usize = null,
    reasoning_bytes: ?usize = null,
    usage: backend.Usage = .{},
    shape: Shape = .none,
    err: ?[]const u8 = null,

    fn ok(r: Row) bool {
        return r.err == null and r.shape.passes();
    }
};

/// The model a run will hit, as far as it can be known before a call.
const Model = struct {
    id: []const u8,
    effort: ?[]const u8 = null,
    /// `GET /models` lists `id` (HTTP kinds only).
    served: []const u8 = "n/a",
};

const repair_region = "{% if items %}\n- {{ items | first }}\n";
const repair_diag: engine.Diag = .{ .kind = "syntax error", .line = 1, .col = 1, .detail = "unclosed if block" };

pub fn cmd(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var kind = ctx.backend_kind;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const name = if (std.mem.eql(u8, a, "--backend")) blk: {
            i += 1;
            if (i >= args.len) return usage("missing value for --backend");
            break :blk args[i];
        } else if (std.mem.startsWith(u8, a, "--backend="))
            a["--backend=".len..]
        else
            return usage("smoke takes only --backend <b>");
        kind = backend.parseKind(name) orelse return usage("unknown backend");
    }

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    const code = run(ctx, kind, &w.interface) catch |e| {
        w.interface.flush() catch {};
        if (e != error.ToolFailed) return e;
        std.debug.print("knap-mcp: smoke: {s}\n", .{ctx.err_msg});
        return 1;
    };
    try w.interface.flush();
    return code;
}

fn usage(msg: []const u8) u8 {
    std.debug.print("knap-mcp: {s}\nusage: knap-mcp smoke [--backend <b>]\n", .{msg});
    return 1;
}

/// The whole smoke on `kind`, table to `w`. Returns the exit code; a
/// backend that can't be reached at all fails before any row runs.
pub fn run(ctx: *Ctx, kind: backend.Kind, w: *Writer) !u8 {
    if (kind == .mock) return ctx.fail("backend 'mock' has no live completion; pick a live backend", .{});
    const model = try resolveModel(ctx, kind);
    try w.print("backend: {s}   model: {s}   effort: {s}   served: {s}\n\n", .{
        @tagName(kind), model.id, model.effort orelse "-", model.served,
    });

    const tasks = std.meta.tags(backend.Task);
    var rows: [tasks.len + 1]Row = undefined;
    for (tasks, 0..) |task, n| rows[n] = try taskRow(ctx, kind, task);
    rows[tasks.len] = try repairRow(ctx, kind);

    try w.writeAll("| row | ok | ms | finish | answer B | reasoning B | prompt tok | completion tok | total tok | reasoning tok | shape | error |\n");
    try w.writeAll("|---|---|--:|---|--:|--:|--:|--:|--:|--:|---|---|\n");
    var passed: usize = 0;
    var wall: u64 = 0;
    for (rows) |r| {
        passed += @intFromBool(r.ok());
        wall += r.ms;
        try w.print("| {s} | {s} | {d} | {s} | ", .{ r.name, if (r.ok()) "yes" else "NO", r.ms, r.finish orelse "-" });
        try opt(w, r.content_bytes);
        try opt(w, r.reasoning_bytes);
        try opt(w, r.usage.prompt_tokens);
        try opt(w, r.usage.completion_tokens);
        try opt(w, r.usage.total_tokens);
        try opt(w, r.usage.reasoning_tokens);
        try w.print("{s} | {s} |\n", .{ @tagName(r.shape), r.err orelse "" });
    }
    try w.print("\nsmoke: {d}/{d} ok   wall {d} ms   mean {d} ms/call\n", .{ passed, rows.len, wall, wall / rows.len });
    try w.print("calls: {d}  mean slice: {d} B  max: {d} B  prefix: {d} B\n", .{
        ctx.calls, ctx.meanSlice(), ctx.slice_bytes_max, ctx.prefix_bytes,
    });
    try ctx.writeTokens(w);
    return @intFromBool(passed != rows.len);
}

fn opt(w: *Writer, v: anytype) !void {
    if (v) |n| try w.print("{d} | ", .{n}) else try w.writeAll("- | ");
}

fn resolveModel(ctx: *Ctx, kind: backend.Kind) error{ ToolFailed, OutOfMemory }!Model {
    if (kind == .acp) {
        const sel = acp.probe(ctx) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ToolFailed,
        };
        return .{ .id = sel.model orelse "unreported", .effort = sel.effort };
    }
    const ep = try backend.endpoint(ctx, kind);
    if (backend.needsKey(kind) and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    const ids = backend.listModels(ctx, kind) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .id = ep.model, .served = try std.fmt.allocPrint(ctx.arena, "unknown ({s})", .{ctx.err_msg}) },
    };
    for (ids) |id| {
        if (std.mem.eql(u8, id, ep.model)) return .{ .id = ep.model, .served = "yes" };
    }
    return .{ .id = ep.model, .served = try std.fmt.allocPrint(ctx.arena, "NO ({d} other ids; see backends --probe)", .{ids.len}) };
}

fn now(ctx: *Ctx) std.Io.Timestamp {
    return std.Io.Timestamp.now(ctx.io, .awake);
}

fn msSince(ctx: *Ctx, t0: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(t0.durationTo(now(ctx)).toNanoseconds(), std.time.ns_per_ms));
}

/// One `completeReply` for `task` that asks for a fixed token.
fn taskRow(ctx: *Ctx, kind: backend.Kind, task: backend.Task) error{OutOfMemory}!Row {
    const token = try std.fmt.allocPrint(ctx.arena, "knap-smoke-{s}", .{@tagName(task)});
    const system = try std.fmt.allocPrint(ctx.arena, "knap-mcp live smoke, task '{s}'. Answer with exactly what the user asks for: no explanation, no formatting.", .{@tagName(task)});
    const user = try std.fmt.allocPrint(ctx.arena, "Reply with exactly this token and nothing else: {s}", .{token});
    var row: Row = .{ .name = @tagName(task) };
    ctx.err_msg = "";
    const t0 = now(ctx);
    const reply = backend.completeReply(ctx, kind, task, system, user) catch |e| {
        row.ms = msSince(ctx, t0);
        row.err = if (e == error.OutOfMemory) return error.OutOfMemory else if (ctx.err_msg.len > 0) ctx.err_msg else @errorName(e);
        return row;
    };
    row.ms = msSince(ctx, t0);
    row.finish = reply.finish_reason;
    row.content_bytes = reply.content.len;
    row.reasoning_bytes = if (reply.reasoning) |r| r.len else 0;
    row.usage = reply.usage;
    row.shape = tokenShape(reply.content, token);
    if (reply.truncated()) row.err = "truncated at the token cap";
    return row;
}

fn tokenShape(content: []const u8, token: []const u8) Shape {
    const t = std.mem.trim(u8, content, " \t\r\n`'\".");
    if (std.mem.eql(u8, t, token)) return .exact;
    return if (std.mem.indexOf(u8, content, token) != null) .loose else .wrong;
}

/// The real repair prompt and sanitizer on an unclosed `{% if %}`. Usage
/// comes from the counters `completeReply` feeds, since `repairPatch`
/// returns the patch only.
fn repairRow(ctx: *Ctx, kind: backend.Kind) error{OutOfMemory}!Row {
    var row: Row = .{ .name = "repair-patch" };
    const before = ctx.*;
    ctx.err_msg = "";
    const t0 = now(ctx);
    const patch = backend.repairPatch(ctx, kind, repair_region, 1, repair_diag) catch |e| {
        row.ms = msSince(ctx, t0);
        row.err = if (e == error.OutOfMemory) return error.OutOfMemory else if (ctx.err_msg.len > 0) ctx.err_msg else @errorName(e);
        return row;
    };
    row.ms = msSince(ctx, t0);
    row.usage = .{
        .prompt_tokens = delta(before.prompt_tokens, ctx.prompt_tokens),
        .completion_tokens = delta(before.completion_tokens, ctx.completion_tokens),
        .total_tokens = delta(before.total_tokens, ctx.total_tokens),
        .reasoning_tokens = delta(before.reasoning_tokens, ctx.reasoning_tokens),
    };
    const p = patch orelse {
        row.err = "no patch (empty, fenced, echoed, or truncated reply)";
        return row;
    };
    row.content_bytes = p.len;
    row.shape = if (std.mem.indexOf(u8, p, "endif") != null and std.mem.indexOf(u8, p, "items") != null) .exact else .wrong;
    return row;
}

fn delta(a: u64, b: u64) ?u64 {
    return if (b > a) b - a else null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "tokenShape: exact, loose, wrong" {
    try testing.expectEqual(Shape.exact, tokenShape(" `knap-smoke-voice`.\n", "knap-smoke-voice"));
    try testing.expectEqual(Shape.loose, tokenShape("Sure: knap-smoke-voice", "knap-smoke-voice"));
    try testing.expectEqual(Shape.wrong, tokenShape("knap-smoke-verify", "knap-smoke-voice"));
}

test "smoke on mock fails before any call" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("echo");
    var out: Writer.Allocating = .init(f.arena.allocator());
    try testing.expectError(error.ToolFailed, run(&ctx, .mock, &out.writer));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "smoke on an echo agent: every row passes, model from the handshake" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("echo");
    var out: Writer.Allocating = .init(f.arena.allocator());
    try testing.expectEqual(@as(u8, 0), try run(&ctx, .acp, &out.writer));
    const s = out.written();
    try testing.expect(std.mem.startsWith(u8, s, "backend: acp   model: fake-model-1   effort: low   served: n/a\n"));
    try testing.expect(std.mem.indexOf(u8, s, "| verify | yes | ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "| repair-patch | yes | ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\nsmoke: 6/6 ok ") != null);
    // Six model calls, and the agent's usage reached the token counters.
    try testing.expectEqual(@as(usize, 6), ctx.calls);
    try testing.expectEqual(@as(u64, 6 * 22), ctx.total_tokens);
}

test "smoke flags a reply with the wrong shape" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("ok");
    var out: Writer.Allocating = .init(f.arena.allocator());
    try testing.expectEqual(@as(u8, 1), try run(&ctx, .acp, &out.writer));
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "| repair | NO | ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "| wrong |") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\nsmoke: 0/6 ok ") != null);
}

test "smoke on a sponsor kind without a key fails fast" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("echo");
    var out: Writer.Allocating = .init(f.arena.allocator());
    try testing.expectError(error.ToolFailed, run(&ctx, .spark, &out.writer));
    try testing.expectEqualStrings("backend 'spark' needs MODEL_API_KEY", ctx.err_msg);
    try testing.expectError(error.ToolFailed, run(&ctx, .compat, &out.writer));
    try testing.expectEqualStrings("backend 'compat' needs KNAP_COMPAT_URL", ctx.err_msg);
}
