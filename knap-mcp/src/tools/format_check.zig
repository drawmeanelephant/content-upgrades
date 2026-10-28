//! knap_format_check: advisory structure lint over a stored doc.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const store = @import("../store.zig");
const formatcheck = @import("../formatcheck.zig");
const boris = @import("../boris.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_format_check",
    .description = "Advisory structure lint over a rendered markdown or oliver doc (doc_id handle): headings, footnotes, callouts, raw URLs, fences. Warnings only, never blocks. html docs are refused.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"}},"required":["doc_id"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});
    // The rules read markdown syntax. Oliver docs are markdown (`md`);
    // html would only produce false positives, so refuse it outright.
    const ext = extensionOf(ctx, doc_id);
    if (!std.mem.eql(u8, ext, "md"))
        return ctx.fail("format_check is markdown only: doc '{s}' is .{s}; render with target markdown or oliver", .{ doc_id, ext });
    // FILED-BORIS: a knap-site.json profile opts the doc into the boris
    // rule pack; frozen (or no profile) resolves to plain check().
    const warnings = try formatcheck.checkSite(ctx.arena, doc, try boris.siteRules(ctx));
    try out.writer.writeAll("{\"ok\":true,\"warnings\":[");
    for (warnings, 0..) |w, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"rule\":");
        try std.json.Stringify.value(w.rule, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"detail\":", .{w.line});
        try std.json.Stringify.value(w.detail, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
}

fn extensionOf(ctx: *Ctx, doc_id: []const u8) []const u8 {
    const artifacts = store.list(ctx) catch return "?";
    for (artifacts) |a| if (std.mem.eql(u8, a.doc_id, doc_id)) return a.extension;
    return "?";
}

/// `knap-mcp format-check <doc_id|file>`: a readable file path is staged
/// into the artifact store byte-for-byte first; anything else is a doc_id.
/// Exit 0 with the JSON warnings on stdout, 1 when the check can't run.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    if (args.len != 1 or (args[0].len > 1 and args[0][0] == '-')) {
        std.debug.print("knap-mcp: format-check needs exactly one doc_id or file\nusage: knap-mcp <command> [options]  (see --help)\n", .{});
        return 1;
    }
    const doc_id = common.docIdOrStage(ctx, args[0]) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "format-check failed"});
        return 1;
    };
    var a: ObjectMap = .empty;
    try a.put(ctx.arena, "doc_id", .{ .string = doc_id });
    var out: Allocating = .init(ctx.arena);
    tools.dispatch(ctx, tool.name, a, &out) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "format-check failed"});
        return 1;
    };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    try w.interface.writeAll(out.written());
    try w.interface.writeAll("\n");
    try w.flush();
    return 0;
}
