//! knap_format_check: advisory structure lint over a stored doc.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const store = @import("../store.zig");
const formatcheck = @import("../formatcheck.zig");
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
    const warnings = try formatcheck.check(ctx.arena, doc);
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
