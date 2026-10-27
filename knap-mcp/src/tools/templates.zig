//! knap_templates: shipped templates with their JSON shape descriptors.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const tools = @import("../tools.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_templates",
    .description = "List shipped templates with their JSON shape descriptors.",
    .input_schema =
    \\{"type":"object","properties":{}}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    _ = args;
    try out.writer.writeAll("{\"templates\":[");
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, ctx.templates_dir, .{ .iterate = true }) catch
        return ctx.fail("templates dir '{s}' not readable", .{ctx.templates_dir});
    defer d.close(ctx.io);
    var it = d.iterate();
    var i: usize = 0;
    while (it.next(ctx.io) catch return ctx.fail("templates dir iterate failed", .{})) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".knap")) continue;
        // entry.name aliases the iterator's buffer — dupe before use.
        const name = try ctx.arena.dupe(u8, entry.name);
        const id = name[0 .. name.len - ".knap".len];
        if (i > 0) try out.writer.writeAll(",");
        i += 1;
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, &out.writer);
        // Per-template shape doc, fetched on demand per SPEC (slim catalog,
        // shape on request — here we inline it since it's small). Parsed
        // then re-emitted: a malformed shapes/<id>.json must not corrupt
        // the result document.
        const shape_path = try std.fmt.allocPrint(ctx.arena, "{s}/shapes/{s}.json", .{ ctx.templates_dir, id });
        if (std.Io.Dir.readFileAlloc(.cwd(), ctx.io, shape_path, ctx.arena, .limited(1 << 20)) catch null) |shape| {
            if (std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, shape, .{}) catch null) |v| {
                try out.writer.writeAll(",\"shape\":");
                try std.json.Stringify.value(v, .{}, &out.writer);
            }
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
}
