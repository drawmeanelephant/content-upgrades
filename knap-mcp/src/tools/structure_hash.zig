//! knap_structure_hash: the layout skeleton hash of a stored doc, plus the
//! `knap-mcp structhash` CLI command (prints `<16 hex>  <name>` like
//! sha256sum). Logic lives in structhash.zig.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const store = @import("../store.zig");
const structhash = @import("../structhash.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_structure_hash",
    .description = "Layout skeleton hash of a rendered doc (doc_id handle): block and inline kinds with all text dropped. Equal hashes mean the same layout. strict also keeps link targets and footnote labels.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"},"target":{"type":"string","enum":["markdown","html"]},"strict":{"type":"boolean"}},"required":["doc_id"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});
    const format = if (common.getStr(args, "target")) |t|
        structhash.formatFromName(t) orelse return ctx.fail("target must be markdown|html", .{})
    else
        try docFormat(ctx, doc_id, doc);
    const strict = if (args) |a| if (a.get("strict")) |v| v == .bool and v.bool else false else false;
    const tokens = try structhash.skeletonOpts(ctx.arena, doc, format, .{ .strict = strict });

    try out.writer.writeAll("{\"ok\":true,\"doc_id\":");
    try std.json.Stringify.value(doc_id, .{}, &out.writer);
    try out.writer.print(",\"format\":\"{s}\",\"strict\":{},\"hash\":\"{x:0>16}\",\"tokens\":[", .{
        @tagName(format), strict, structhash.hashTokens(tokens),
    });
    for (tokens, 0..) |t, i| {
        if (i > 0) try out.writer.writeAll(",");
        try std.json.Stringify.value(t.kind, .{}, &out.writer);
    }
    try out.writer.writeAll("]}");
}

/// A stored doc's format from its artifact extension, else by sniffing.
fn docFormat(ctx: *Ctx, doc_id: []const u8, doc: []const u8) tools.Error!structhash.Format {
    const entries = store.list(ctx) catch return structhash.sniff(doc);
    for (entries) |e| {
        if (!std.mem.eql(u8, e.doc_id, doc_id)) continue;
        if (std.mem.eql(u8, e.extension, "md")) return .markdown;
        if (std.mem.eql(u8, e.extension, "html")) return .html;
        return ctx.fail("doc '{s}' is .{s}; structure hash reads markdown or html", .{ doc_id, e.extension });
    }
    return structhash.sniff(doc);
}

fn pathFormat(path: []const u8, doc: []const u8) structhash.Format {
    const ext = std.fs.path.extension(path);
    if (ext.len > 1) {
        if (structhash.formatFromName(ext[1..])) |f| return f;
        if (std.mem.eql(u8, ext, ".markdown")) return .markdown;
    }
    return structhash.sniff(doc);
}

/// `knap-mcp structhash <doc_id|file>... [--target markdown|html] [--explain] [--strict]`
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var target: ?structhash.Format = null;
    var explain = false;
    var strict = false;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--explain")) {
            explain = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, a, "--target") or std.mem.startsWith(u8, a, "--target=")) {
            const v = if (std.mem.indexOfScalar(u8, a, '=')) |eq| a[eq + 1 ..] else blk: {
                i += 1;
                if (i >= args.len) return usage("missing value for --target");
                break :blk args[i];
            };
            target = structhash.formatFromName(v) orelse return usage("--target must be markdown|html");
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("knap-mcp: unknown option '{s}'\n", .{a});
            return usage(null);
        } else try names.append(ctx.arena, a);
    }
    if (names.items.len == 0) return usage("structhash needs a doc_id or file");

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    defer w.flush() catch {};
    for (names.items) |name| {
        var format = target;
        const doc = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, name, ctx.arena, .limited(64 * 1024 * 1024)) catch
            (store.read(ctx, name) catch null) orelse {
            w.flush() catch {};
            std.debug.print("knap-mcp: no such file or doc '{s}'\n", .{name});
            return 1;
        };
        if (format == null) format = if (std.Io.Dir.access(.cwd(), ctx.io, name, .{})) |_|
            pathFormat(name, doc)
        else |_|
            docFormat(ctx, name, doc) catch {
                w.flush() catch {};
                std.debug.print("knap-mcp: {s}\n", .{ctx.err_msg});
                return 1;
            };
        const tokens = try structhash.skeletonOpts(ctx.arena, doc, format.?, .{ .strict = strict });
        if (explain) {
            for (tokens) |t| {
                try w.interface.splatByteAll(' ', 2 * @as(usize, t.depth));
                try w.interface.print("{s}\n", .{t.kind});
            }
        }
        try w.interface.print("{x:0>16}  {s}\n", .{ structhash.hashTokens(tokens), name });
    }
    return 0;
}

fn usage(msg: ?[]const u8) u8 {
    if (msg) |m| std.debug.print("knap-mcp: {s}\n", .{m});
    std.debug.print("usage: knap-mcp structhash <doc_id|file>... [--target markdown|html] [--explain] [--strict]\n", .{});
    return 1;
}
