//! `knap-mcp ask --system <file> --user <file> [--backend k] [--task t]`:
//! one raw `backend.completeReply` with prompts read from files, printed
//! as JSON. It exists so a one-off live take (a flat doc, drafted data) has
//! an exact, rerunnable command for its provenance instead of a throwaway
//! harness. The JSON carries the model as resolved before the call: the
//! endpoint's id for HTTP kinds, the agent's report for acp.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const backend = @import("backend.zig");
const acp = @import("acp.zig");

const max_prompt = 4 * 1024 * 1024;

pub fn cmd(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var kind = ctx.backend_kind;
    var task: backend.Task = .judge;
    var system_path: ?[]const u8 = null;
    var user_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const a = args[i];
        if (i + 1 >= args.len) return usage("missing value for an option");
        const v = args[i + 1];
        if (std.mem.eql(u8, a, "--backend")) {
            kind = backend.parseKind(v) orelse return usage("unknown backend");
        } else if (std.mem.eql(u8, a, "--task")) {
            task = std.meta.stringToEnum(backend.Task, v) orelse return usage("task must be repair|voice|verify|judge|enrich");
        } else if (std.mem.eql(u8, a, "--system")) {
            system_path = v;
        } else if (std.mem.eql(u8, a, "--user")) {
            user_path = v;
        } else return usage("unknown option");
    }
    const sp = system_path orelse return usage("--system is required");
    const up = user_path orelse return usage("--user is required");
    const system = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, sp, ctx.arena, .limited(max_prompt)) catch return usage("cannot read --system file");
    const user = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, up, ctx.arena, .limited(max_prompt)) catch return usage("cannot read --user file");

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    run(ctx, kind, task, system, user, &out.writer) catch |e| {
        if (e != error.ToolFailed) return e;
        std.debug.print("knap-mcp: ask: {s}\n", .{ctx.err_msg});
        return 1;
    };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    try w.interface.writeAll(out.written());
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return 0;
}

fn usage(msg: []const u8) u8 {
    std.debug.print("knap-mcp: {s}\nusage: knap-mcp ask --system <file> --user <file> [--backend <b>] [--task <t>]\n", .{msg});
    return 1;
}

/// The call and its JSON record. `mock` has no live completion and fails.
pub fn run(ctx: *Ctx, kind: backend.Kind, task: backend.Task, system: []const u8, user: []const u8, w: *std.Io.Writer) !void {
    var model: ?[]const u8 = null;
    var effort: ?[]const u8 = null;
    switch (kind) {
        .mock => return ctx.fail("backend 'mock' has no live completion; pick a live backend", .{}),
        .acp => {
            const sel = acp.probe(ctx) catch |e| return if (e == error.OutOfMemory) e else error.ToolFailed;
            model = sel.model;
            effort = sel.effort;
        },
        else => model = (try backend.endpoint(ctx, kind)).model,
    }
    const r = try backend.completeReply(ctx, kind, task, system, user);
    const s: std.json.Stringify.Options = .{ .emit_null_optional_fields = true };
    try w.writeAll("{\"backend\":");
    try std.json.Stringify.value(@tagName(kind), s, w);
    try w.writeAll(",\"model\":");
    try std.json.Stringify.value(model, s, w);
    try w.writeAll(",\"effort\":");
    try std.json.Stringify.value(effort, s, w);
    try w.writeAll(",\"task\":");
    try std.json.Stringify.value(@tagName(task), s, w);
    try w.writeAll(",\"finish_reason\":");
    try std.json.Stringify.value(r.finish_reason, s, w);
    try w.writeAll(",\"usage\":");
    try std.json.Stringify.value(r.usage, s, w);
    try w.writeAll(",\"reasoning\":");
    try std.json.Stringify.value(r.reasoning, s, w);
    try w.writeAll(",\"content\":");
    try std.json.Stringify.value(r.content, s, w);
    try w.writeAll("}");
}

const testing = std.testing;

test "ask records model, usage and content from one acp turn" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("echo");
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try run(&ctx, .acp, .judge, "sys", "say knap-smoke-judge", &out.writer);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), out.written(), .{});
    try testing.expectEqualStrings("fake-model-1", v.object.get("model").?.string);
    try testing.expectEqualStrings("low", v.object.get("effort").?.string);
    try testing.expectEqualStrings("knap-smoke-judge", v.object.get("content").?.string);
    try testing.expectEqual(@as(i64, 22), v.object.get("usage").?.object.get("total_tokens").?.integer);
    try testing.expectError(error.ToolFailed, run(&ctx, .mock, .judge, "s", "u", &out.writer));
}
