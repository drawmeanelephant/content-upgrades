//! knap_publish_check: stage a rendered markdown doc into a throwaway copy
//! of a boris site and report every wiki-link that does not resolve
//! (src/boris.zig). The site picks the staging profile — `frozen` slug-
//! rewrites into staged/, `raw` passes canonical-id records through at
//! their source path (`as`). The CLI row exits 1 when the doc is not ok.

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
    .description = "Stage a rendered markdown doc (doc_id from knap_render or knap_repair) into a copy of the boris site and run boris validate. The staging profile comes from KNAP_BORIS_STAGING or <site>/knap-site.json: frozen (default) slug-rewrites links into staged/<name>.md; raw passes frontmatter and canonical-id link targets through at the doc's source path (the 'as' argument). Every wiki-link and embed must resolve to a page; ok is false on any error diagnostic. Line and column refer to the rendered doc.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"},"as":{"type":"string"}},"required":["doc_id"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const as = common.getStr(args, "as");
    const entries = store.list(ctx) catch return ctx.fail("cannot list the artifact store", .{});
    const ext = for (entries) |e| {
        if (std.mem.eql(u8, e.doc_id, doc_id)) break e.extension;
    } else return ctx.fail("no such doc '{s}'", .{doc_id});
    if (!std.mem.eql(u8, ext, "md"))
        return ctx.fail("knap_publish_check needs a markdown doc; '{s}' is .{s} (render it with target markdown)", .{ doc_id, ext });
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});

    const r = try boris.check(ctx, doc, doc_id, as);
    try writeReport(out, doc_id, r);
}

fn writeReport(out: *Allocating, doc_id: []const u8, r: boris.Report) !void {
    const w = &out.writer;
    try w.writeAll("{\"doc_id\":");
    try std.json.Stringify.value(doc_id, .{}, w);
    try w.print(",\"ok\":{},\"profile\":\"{s}\",\"staged_as\":", .{ r.ok, @tagName(r.profile) });
    try std.json.Stringify.value(r.staged_as, .{}, w);
    try w.print(",\"pages\":{d},\"links\":{d},\"diagnostics\":", .{ r.pages, r.links });
    try std.json.Stringify.value(r.diagnostics, .{}, w);
    try w.print(",\"elapsed_ms\":{d:.1}}}", .{r.elapsed_ms});
}

/// `knap-mcp publish-check <doc_id|file> [--as <path>]`: a readable file
/// path is staged into the artifact store byte-for-byte first; anything
/// else is a doc_id. --as is the raw-profile source path. The tool runs
/// through the dispatcher, JSON on stdout; exit 0 when ok, 1 when not ok
/// or the check could not run.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var as: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var bad = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--as")) {
            i += 1;
            if (i < args.len) as = args[i] else bad = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            bad = true;
        } else if (target == null) {
            target = arg;
        } else bad = true;
    }
    if (bad or target == null) {
        std.debug.print("knap-mcp: publish-check needs exactly one doc_id or file\nusage: knap-mcp <command> [options]  (see --help)\n", .{});
        return 1;
    }
    const doc_id = common.docIdOrStage(ctx, target.?) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "publish-check failed"});
        return 1;
    };
    var a: ObjectMap = .empty;
    try a.put(ctx.arena, "doc_id", .{ .string = doc_id });
    if (as) |v| try a.put(ctx.arena, "as", .{ .string = v });
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
    try writeReport(&out, "doc-1-1", .{ .ok = false, .profile = .frozen, .staged_as = "staged/doc-1-1", .pages = 22, .links = 3, .diagnostics = &diags, .elapsed_ms = 7.25 });
    try std.testing.expectEqualStrings(
        \\{"doc_id":"doc-1-1","ok":false,"profile":"frozen","staged_as":"staged/doc-1-1","pages":22,"links":3,"diagnostics":[{"code":"EREFERENCEMISSING","severity":"error","line":44,"column":3,"detail":"wiki-link target \"x\" not found in the page graph","link":"[[X]]","target":"x"}],"elapsed_ms":7.3}
    , out.written());
}
