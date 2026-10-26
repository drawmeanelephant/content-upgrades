//! knap_density: the deterministic formatting-density score of a stored
//! markdown doc (src/density.zig). No model call.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const density = @import("../density.zig");
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_density",
    .description = "Deterministic formatting-density score (density/1, 0-100) of a rendered markdown doc (doc_id handle): per-signal breakdown plus format_check penalties. Markdown renders only.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"}},"required":["doc_id"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const entries = store.list(ctx) catch return ctx.fail("artifact store not readable", .{});
    const ext = for (entries) |e| {
        if (std.mem.eql(u8, e.doc_id, doc_id)) break e.extension;
    } else return ctx.fail("no such doc '{s}'", .{doc_id});
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});
    if (!std.mem.eql(u8, ext, "md") or looksLikeHtml(doc))
        return ctx.fail("doc '{s}' is not markdown ({s}); density scores markdown renders only: render with target=markdown", .{ doc_id, ext });
    try scoreInto(ctx, doc, &out.writer);
}

fn scoreInto(ctx: *Ctx, doc: []const u8, w: *std.Io.Writer) tools.Error!void {
    try density.writeJson(try density.score(ctx.arena, doc), w);
}

fn looksLikeHtml(doc: []const u8) bool {
    const t = std.mem.trimStart(u8, doc, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(t, "<!doctype") or std.ascii.startsWithIgnoreCase(t, "<html");
}

/// `knap-mcp density <doc_id|file>`: a readable file path is scored
/// directly; anything else is a doc_id run through the tool.
pub fn cmd(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    if (args.len != 1 or (args[0].len > 1 and args[0][0] == '-')) {
        std.debug.print("knap-mcp: density needs exactly one doc_id or file\nusage: knap-mcp <command> [options]  (see --help)\n", .{});
        return 1;
    }
    var out: Allocating = .init(ctx.arena);
    if (std.Io.Dir.readFileAlloc(.cwd(), ctx.io, args[0], ctx.arena, .limited(64 * 1024 * 1024))) |doc| {
        try scoreInto(ctx, doc, &out.writer);
    } else |_| {
        var a: ObjectMap = .empty;
        try a.put(ctx.arena, "doc_id", .{ .string = args[0] });
        tools.dispatch(ctx, tool.name, a, &out) catch {
            std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "density failed"});
            return 1;
        };
    }
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    try w.interface.writeAll(out.written());
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return 0;
}
