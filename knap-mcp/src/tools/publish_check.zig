//! knap_publish_check: stage a rendered markdown doc into a throwaway copy
//! of the frozen boris site and report every wiki-link that does not
//! resolve (src/boris.zig). The CLI row exits 1 when the doc is not ok.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const store = @import("../store.zig");
const boris = @import("../boris.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_publish_check",
    .description = "Stage a rendered markdown doc (doc_id from knap_render or knap_repair) into a copy of the frozen boris site and run boris validate. Every wiki-link and embed must resolve to a page; ok is false on any error diagnostic. Line and column refer to the rendered doc.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"}},"required":["doc_id"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const entries = store.list(ctx) catch return ctx.fail("cannot list the artifact store", .{});
    const ext = for (entries) |e| {
        if (std.mem.eql(u8, e.doc_id, doc_id)) break e.extension;
    } else return ctx.fail("no such doc '{s}'", .{doc_id});
    if (!std.mem.eql(u8, ext, "md"))
        return ctx.fail("knap_publish_check needs a markdown doc; '{s}' is .{s} (render it with target markdown)", .{ doc_id, ext });
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});

    const r = try boris.check(ctx, doc, doc_id);
    try writeReport(out, doc_id, r);
}

fn writeReport(out: *Allocating, doc_id: []const u8, r: boris.Report) !void {
    const w = &out.writer;
    try w.writeAll("{\"doc_id\":");
    try std.json.Stringify.value(doc_id, .{}, w);
    try w.print(",\"ok\":{},\"staged_as\":", .{r.ok});
    try std.json.Stringify.value(r.staged_as, .{}, w);
    try w.print(",\"pages\":{d},\"links\":{d},\"diagnostics\":", .{ r.pages, r.links });
    try std.json.Stringify.value(r.diagnostics, .{}, w);
    try w.print(",\"elapsed_ms\":{d:.1}}}", .{r.elapsed_ms});
}

/// `knap-mcp publish-check <doc_id>`: the tool through the dispatcher, JSON
/// on stdout; exit 0 when ok, 1 when not ok or the check could not run.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    if (args.len != 1 or (args[0].len > 1 and args[0][0] == '-')) {
        std.debug.print("knap-mcp: publish-check needs exactly one doc_id\nusage: knap-mcp <command> [options]  (see --help)\n", .{});
        return 1;
    }
    var a: ObjectMap = .empty;
    try a.put(ctx.arena, "doc_id", .{ .string = args[0] });
    var out: Allocating = .init(ctx.arena);
    tools.dispatch(ctx, tool.name, a, &out) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "publish-check failed"});
        return 1;
    };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    try w.interface.writeAll(out.written());
    try w.interface.writeAll("\n");
    try w.flush();
    const res = try std.json.parseFromSliceLeaky(struct { ok: bool }, ctx.arena, out.written(), .{ .ignore_unknown_fields = true });
    return @intFromBool(!res.ok);
}

test "writeReport emits the documented shape" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var out: Allocating = .init(a.allocator());
    var diags = [_]boris.Diagnostic{.{
        .code = "EREFERENCEMISSING",
        .severity = "error",
        .line = 44,
        .column = 3,
        .detail = "wiki-link target \"x\" not found in the page graph",
        .link = "[[X]]",
        .target = "x",
    }};
    try writeReport(&out, "doc-1-1", .{ .ok = false, .staged_as = "staged/doc-1-1", .pages = 22, .links = 3, .diagnostics = &diags, .elapsed_ms = 7.25 });
    try std.testing.expectEqualStrings(
        \\{"doc_id":"doc-1-1","ok":false,"staged_as":"staged/doc-1-1","pages":22,"links":3,"diagnostics":[{"code":"EREFERENCEMISSING","severity":"error","line":44,"column":3,"detail":"wiki-link target \"x\" not found in the page graph","link":"[[X]]","target":"x"}],"elapsed_ms":7.3}
    , out.written());
}
