//! Tool registry. Each handler lives in `tools/<name>.zig` and exports
//! `pub const tool: Tool`; registering it is one line in `all`. Handlers
//! write a JSON result object into `out`; both the MCP `tools/call` path
//! and the CLI subcommands go through `dispatch`. The server is a
//! dispatcher only — no engine logic lives here.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const common = @import("tools/common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

pub const Handler = *const fn (ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    run: Handler,
};

/// One line per tool, in tools/list order.
pub const all = [_]Tool{
    @import("tools/templates.zig").tool,
    @import("tools/validate.zig").tool,
    @import("tools/render.zig").tool,
    @import("tools/repair.zig").tool,
    @import("tools/lint.zig").tool,
    @import("tools/format_check.zig").tool,
};

pub const templatePath = common.templatePath;
pub const templateText = common.templateText;
pub const writeOutcome = @import("tools/repair.zig").writeOutcome;

/// tools/call dispatcher. Result JSON lands in `out`.
pub fn dispatch(ctx: *Ctx, name: []const u8, args: ?ObjectMap, out: *Allocating) Error!void {
    for (&all) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t.run(ctx, args, out);
    }
    return ctx.fail("unknown tool '{s}'", .{name});
}

/// tools/list payload: {"tools":[...]}.
pub fn listJson(w: *Allocating) !void {
    try w.writer.writeAll("{\"tools\":[");
    for (&all, 0..) |*t, i| {
        if (i > 0) try w.writer.writeAll(",");
        try w.writer.print("{{\"name\":", .{});
        try std.json.Stringify.value(t.name, .{}, &w.writer);
        try w.writer.print(",\"description\":", .{});
        try std.json.Stringify.value(t.description, .{}, &w.writer);
        try w.writer.print(",\"inputSchema\":{s}}}", .{t.input_schema});
    }
    try w.writer.writeAll("]}");
}
