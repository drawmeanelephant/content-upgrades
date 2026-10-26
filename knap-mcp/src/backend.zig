//! Model backends. The server is a context broker: every call carries the
//! smallest slice that can do the job — for repair, that's the diagnostic
//! plus the template region around it, never the whole template.
//!
//! `mock` returns canned patches so the whole loop is testable with zero
//! API access. `spark`/`wonder`/`baseten` hit OpenAI-compatible endpoints
//! via curl (CLI contracts only, no HTTP client dependency).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");

pub const Kind = enum { mock, spark, wonder, baseten };

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

pub fn parseKind(name: []const u8) ?Kind {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, 0..) |fname, i| {
        if (std.mem.eql(u8, name, fname)) return @enumFromInt(info.field_values[i]);
    }
    return null;
}

const repair_prefix =
    "You are a surgical patch engine for knap templates. " ++
    "Given a diagnostic and the template region around it, return ONLY " ++
    "the corrected region text — same line count where possible, no " ++
    "explanation, no fences. knap syntax: {{ expr }} output, " ++
    "{% if/elseif/else/endif %}, {% for x in xs %}{% endfor %}, " ++
    "filters via | name or | name:arg.";

/// Returns the replacement region, or null when the backend proposes no
/// change (which the repair loop treats as a non-convergence signal).
pub fn repairPatch(ctx: *Ctx, kind: Kind, region: []const u8, diag: engine.Diag) Error!?[]const u8 {
    return switch (kind) {
        .mock => mockPatch(ctx, region, diag),
        .spark, .wonder, .baseten => remotePatch(ctx, kind, region, diag),
    };
}

// --- mock ------------------------------------------------------------------

/// Canned patch table keyed on diagnostic detail — enough to prove the
/// loop converges end-to-end with zero API access. Diagnostics outside the
/// canned set return null so non-convergence stays exercise-able.
fn mockPatch(ctx: *Ctx, region: []const u8, diag: engine.Diag) !?[]const u8 {
    const d = diag.detail;
    if (std.mem.indexOf(u8, d, "unclosed if block") != null)
        return try std.fmt.allocPrint(ctx.arena, "{s}{{% endif %}}\n", .{region});
    if (std.mem.indexOf(u8, d, "unclosed for block") != null)
        return try std.fmt.allocPrint(ctx.arena, "{s}{{% endfor %}}\n", .{region});
    if (std.mem.indexOf(u8, d, "no filter named") != null or
        std.mem.indexOf(u8, diag.kind, "unknown filter") != null)
        return stripUnknownFilter(ctx, region, d);
    if (std.mem.indexOf(u8, d, "expected a filter name") != null)
        return trimDanglingFilter(ctx, region);
    if (std.mem.indexOf(u8, d, "output tag") != null)
        return closeOutputTag(ctx, region);
    return null;
}

/// Find the first region line with an unbalanced "{{" and append " }}".
fn closeOutputTag(ctx: *Ctx, region: []const u8) !?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    var lines = std.mem.splitScalar(u8, region, '\n');
    var fixed = false;
    while (lines.next()) |line| {
        const opens = std.mem.count(u8, line, "{{");
        const closes = std.mem.count(u8, line, "}}");
        if (!fixed and opens > closes) {
            try aw.writer.print("{s} }}}}\n", .{line});
            fixed = true;
        } else {
            try aw.writer.print("{s}\n", .{line});
        }
    }
    return if (fixed) aw.written() else null;
}

/// `no filter named "head2"` → drop `| head2` from the region. The
/// conservative mock fix is removing the bad filter, not inventing one.
fn stripUnknownFilter(ctx: *Ctx, region: []const u8, detail: []const u8) !?[]const u8 {
    const q1 = std.mem.indexOfScalar(u8, detail, '"') orelse return null;
    const rest = detail[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..q2];
    const needle = try std.fmt.allocPrint(ctx.arena, "| {s}", .{name});
    const at = std.mem.indexOf(u8, region, needle) orelse return null;
    return try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ region[0..at], region[at + needle.len ..] });
}

/// `expected a filter name after '|'` → find the `{{` line ending in a
/// bare `|`, drop the `|`, and close the tag.
fn trimDanglingFilter(ctx: *Ctx, region: []const u8) !?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    var lines = std.mem.splitScalar(u8, region, '\n');
    var fixed = false;
    while (lines.next()) |line| {
        const t = std.mem.trimEnd(u8, line, " \r\t");
        if (!fixed and t.len > 0 and t[t.len - 1] == '|' and
            std.mem.indexOf(u8, t, "{{") != null)
        {
            try aw.writer.print("{s} }}}}\n", .{t[0 .. t.len - 1]});
            fixed = true;
        } else {
            try aw.writer.print("{s}\n", .{line});
        }
    }
    return if (fixed) aw.written() else null;
}

// --- remote (OpenAI-compatible, via curl) -----------------------------------

fn remotePatch(ctx: *Ctx, kind: Kind, region: []const u8, diag: engine.Diag) Error!?[]const u8 {
    const key = ctx.environ.get("MODEL_API_KEY") orelse
        return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    const url = switch (kind) {
        .baseten => ctx.environ.get("KNAP_BASETEN_URL") orelse
            "https://api.baseten.co/v1/chat/completions",
        else => "https://api.meta.ai/v1/chat/completions",
    };
    const model: []const u8 = switch (kind) {
        .spark => "muse-spark-1.3",
        .wonder => "muse-wonder-1.0",
        .baseten => "meta-models/muse-spark-open-1026",
        .mock => unreachable,
    };

    var user: std.Io.Writer.Allocating = .init(ctx.arena);
    try user.writer.print(
        "diagnostic: {s} at line {d}, column {d}: {s}\n\nregion:\n{s}\n",
        .{ diag.kind, diag.line, diag.col, diag.detail, region },
    );

    const body = try chatCompletion(ctx, url, key, model, repair_prefix, user.written());
    return if (body.len == 0) null else body;
}

/// POST an OpenAI-compatible chat completion through curl; return the
/// first choice's message content. Errors in the transport or a missing
/// choices field both surface as ToolFailed with the raw reply attached.
fn chatCompletion(
    ctx: *Ctx,
    url: []const u8,
    key: []const u8,
    model: []const u8,
    system: []const u8,
    user_msg: []const u8,
) Error![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(ctx.arena);
    try payload.writer.print("{{\"model\":", .{});
    try std.json.Stringify.value(model, .{}, &payload.writer);
    try payload.writer.print(",\"messages\":[{{\"role\":\"system\",\"content\":", .{});
    try std.json.Stringify.value(system, .{}, &payload.writer);
    try payload.writer.print("}},{{\"role\":\"user\",\"content\":", .{});
    try std.json.Stringify.value(user_msg, .{}, &payload.writer);
    try payload.writer.print("}}],\"temperature\":0}}", .{});

    const auth = try std.fmt.allocPrint(ctx.arena, "Authorization: Bearer {s}", .{key});
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{
            "curl", "-sS", "-f", "-X", "POST", url,
            "-H",       auth,
            "-H",       "Content-Type: application/json",
            "--data",   payload.written(),
        },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |e| return ctx.fail("curl failed: {s}", .{@errorName(e)});

    switch (result.term) {
        .exited => |code| if (code != 0)
            return ctx.fail("backend http {d}: {s}", .{ code, result.stderr }),
        else => return ctx.fail("curl terminated abnormally", .{}),
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{}) catch
        return ctx.fail("backend returned non-JSON", .{});
    const choices = getPath(parsed, &.{ "choices" }) orelse
        return ctx.fail("backend reply has no choices", .{});
    switch (choices) {
        .array => |arr| {
            if (arr.items.len == 0) return ctx.fail("backend reply has empty choices", .{});
            const content = getPath(arr.items[0], &.{ "message", "content" }) orelse
                return ctx.fail("backend reply has no message.content", .{});
            switch (content) {
                .string => |s| return s,
                else => return ctx.fail("backend message.content is not a string", .{}),
            }
        },
        else => return ctx.fail("backend choices is not an array", .{}),
    }
}

fn getPath(v: std.json.Value, comptime keys: []const []const u8) ?std.json.Value {
    var cur = v;
    for (keys) |k| {
        switch (cur) {
            .object => |o| cur = o.get(k) orelse return null,
            else => return null,
        }
    }
    return cur;
}
