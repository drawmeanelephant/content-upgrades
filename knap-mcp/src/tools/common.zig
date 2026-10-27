//! Helpers shared by tool handlers: argument access, data staging,
//! shipped-template lookup, and the diagnostics JSON shape.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const store = @import("../store.zig");
const Error = @import("../tools.zig").Error;

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub fn getStr(args: ?ObjectMap, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    return switch (a.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn requireStr(ctx: *Ctx, args: ?ObjectMap, key: []const u8) Error![]const u8 {
    return getStr(args, key) orelse ctx.fail("missing required argument '{s}'", .{key});
}

/// Re-serialize the `data` argument for `--data <file>` staging. Every
/// schema declares `"data":{"type":"object"}` — anything else is a client
/// bug, not an engine diagnostic. Numbers keep their request-text form:
/// the MCP layer parses with .parse_numbers = false, so .number_string
/// values here stringify verbatim (1.50 stays 1.50).
pub fn requireData(ctx: *Ctx, args: ?ObjectMap) Error![]const u8 {
    const a = args orelse return ctx.fail("missing arguments", .{});
    const v = a.get("data") orelse return ctx.fail("missing required argument 'data'", .{});
    if (v != .object) return ctx.fail("data must be a JSON object", .{});
    return std.json.Stringify.valueAlloc(ctx.arena, v, .{}) catch return error.OutOfMemory;
}

/// Shipped template path from its id (template_id never crosses the
/// server boundary as text — callers can only name shipped templates).
pub fn templatePath(ctx: *Ctx, template_id: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, template_id, "/\\") != null or
        std.mem.indexOf(u8, template_id, "..") != null)
        return ctx.fail("invalid template_id '{s}'", .{template_id});
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.knap", .{ ctx.templates_dir, template_id });
    std.Io.Dir.access(.cwd(), ctx.io, path, .{}) catch
        return ctx.fail("unknown template '{s}'", .{template_id});
    return path;
}

pub fn templateText(ctx: *Ctx, template_id: []const u8) Error![]const u8 {
    const path = try templatePath(ctx, template_id);
    return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(4 * 1024 * 1024)) catch
        return ctx.fail("cannot read template '{s}'", .{template_id});
}

/// Write `data` JSON to a scratch file; engines take --data <file>.
pub fn stageData(ctx: *Ctx, data_json: []const u8) Error![]const u8 {
    const path = try store.scratchFile(ctx, "json");
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = data_json }) catch
        return ctx.fail("cannot stage data file", .{});
    return path;
}

pub fn writeDiags(out: *Allocating, diags: []engine.Diag) !void {
    try out.writer.writeAll("\"diagnostics\":[");
    for (diags, 0..) |d, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"kind\":", .{});
        try std.json.Stringify.value(d.kind, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"column\":{d},\"detail\":", .{ d.line, d.col });
        try std.json.Stringify.value(d.detail, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");
}

test "getStr ignores missing and non-string values" {
    var m: ObjectMap = .empty;
    defer m.deinit(std.testing.allocator);
    try m.put(std.testing.allocator, "s", .{ .string = "x" });
    try m.put(std.testing.allocator, "n", .{ .integer = 1 });
    try std.testing.expectEqualStrings("x", getStr(m, "s").?);
    try std.testing.expect(getStr(m, "n") == null);
    try std.testing.expect(getStr(m, "missing") == null);
    try std.testing.expect(getStr(null, "s") == null);
}

test "requireData rejects non-objects and keeps number_string verbatim" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();
    ctx.err_msg = "";

    const args = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena,
        \\{"data":{"year":1.50,"n":2}}
    , .{ .parse_numbers = false });
    try std.testing.expectEqualStrings(
        \\{"year":1.50,"n":2}
    , try requireData(&ctx, args.object));

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena,
        \\{"data":"x"}
    , .{});
    try std.testing.expectError(error.ToolFailed, requireData(&ctx, bad.object));
    try std.testing.expectEqualStrings("data must be a JSON object", ctx.err_msg);
}
