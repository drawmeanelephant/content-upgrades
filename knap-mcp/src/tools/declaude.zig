//! knap_declaude: strip invisible marks, fold space variants, flag
//! homoglyphs/controls/slop in generated text (src/declaude.zig).
//! No model call.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const declaude = @import("../declaude.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_declaude",
    .description = "Mechanical cleanup of character-level marks in generated text. Strips invisible format chars (ZWSP/ZWNJ, word joiner, soft hyphen, mid-text BOM, bidi controls, tag chars, supplementary variation selectors), folds Unicode space variants to ASCII space, drops trailing whitespace per line. 'normalize':true also folds dashes/curly quotes/minus/ellipsis to ASCII (lossy, opt-in). Always reports homoglyph confusables in Latin words, C0/C1 controls, U+2028/9 and slop phrases — flagged, never rewritten. 'report':true detects without rewriting. Honest limit: a statistical (token-level) watermark survives any mechanical strip; only paraphrase removes it. Input: 'text' string, or a 'data' object whose string values are cleaned in place.",
    .input_schema =
    \\{"type":"object","properties":{"text":{"type":"string"},"data":{"type":"object"},"normalize":{"type":"boolean"},"report":{"type":"boolean"}}}
    ,
    .run = run,
};

fn getBool(args: ?ObjectMap, key: []const u8) bool {
    const a = args orelse return false;
    return switch (a.get(key) orelse return false) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const a = args orelse return ctx.fail("missing arguments", .{});
    const opts: declaude.Options = .{
        .normalize = getBool(a, "normalize"),
        .report = getBool(a, "report"),
    };
    if (common.getStr(a, "text")) |text| {
        try declaude.writeJson(try declaude.run(ctx.arena, text, opts), &out.writer);
        return;
    }
    const dv = a.get("data") orelse
        return ctx.fail("missing required argument 'text' (or a 'data' object)", .{});
    if (dv != .object) return ctx.fail("data must be a JSON object", .{});
    var agg: Agg = .{};
    var changed = false;
    const cleaned = try cleanValue(ctx, dv, opts, &agg, &changed);
    var buf: std.Io.Writer.Allocating = .init(ctx.arena);
    try declaude.writeJson(.{
        .text = "",
        .stripped = agg.stripped.items,
        .normalized = agg.normalized.items,
        .flagged = agg.flagged.items,
        .changed = changed,
        .normalize = opts.normalize,
        .report = opts.report,
        .data = cleaned,
    }, &buf.writer);
    try out.writer.writeAll(buf.written());
}

const Agg = struct {
    stripped: std.ArrayList(declaude.Entry) = .empty,
    normalized: std.ArrayList(declaude.Entry) = .empty,
    flagged: std.ArrayList(declaude.Entry) = .empty,
};

/// Every string in a data record is cleaned in place; tallies aggregate
/// across all of them. In report mode values come back byte-identical.
fn cleanValue(ctx: *Ctx, v: std.json.Value, opts: declaude.Options, agg: *Agg, changed: *bool) tools.Error!std.json.Value {
    switch (v) {
        .string => |s| {
            const r = try declaude.run(ctx.arena, s, opts);
            try declaude.mergeEntries(&agg.stripped, ctx.arena, r.stripped);
            try declaude.mergeEntries(&agg.normalized, ctx.arena, r.normalized);
            try declaude.mergeEntries(&agg.flagged, ctx.arena, r.flagged);
            changed.* = changed.* or r.changed;
            return .{ .string = r.text };
        },
        .array => |arr| {
            var items: std.json.Array = .init(ctx.arena);
            try items.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| items.appendAssumeCapacity(try cleanValue(ctx, item, opts, agg, changed));
            return .{ .array = items };
        },
        .object => |obj| {
            var m: ObjectMap = .empty;
            try m.ensureTotalCapacity(ctx.arena, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| {
                m.putAssumeCapacity(e.key_ptr.*, try cleanValue(ctx, e.value_ptr.*, opts, agg, changed));
            }
            return .{ .object = m };
        },
        else => return v,
    }
}

/// `knap-mcp declaude <doc_id|file|-> [--normalize] [--report]` — text
/// comes from a file, a stored doc, or stdin. Exit 0 with the JSON
/// report on stdout; the report's `text` carries the cleaned bytes.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var normalize = false;
    var report = false;
    var pos: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--normalize")) {
            normalize = true;
        } else if (std.mem.eql(u8, a, "--report")) {
            report = true;
        } else if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            std.debug.print("knap-mcp: declaude: unknown option '{s}'\nusage: knap-mcp declaude <doc_id|file|-> [--normalize] [--report]\n", .{a});
            return 1;
        } else if (pos != null) {
            std.debug.print("knap-mcp: declaude: unexpected argument '{s}'\nusage: knap-mcp declaude <doc_id|file|-> [--normalize] [--report]\n", .{a});
            return 1;
        } else pos = a;
    }
    const arg = pos orelse {
        std.debug.print("knap-mcp: declaude needs exactly one doc_id, file or -\nusage: knap-mcp declaude <doc_id|file|-> [--normalize] [--report]\n", .{});
        return 1;
    };
    const bytes = if (std.mem.eql(u8, arg, "-")) blk: {
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().readerStreaming(ctx.io, &rbuf);
        break :blk r.interface.allocRemaining(ctx.arena, .limited(common.max_doc_bytes)) catch {
            std.debug.print("knap-mcp: cannot read stdin\n", .{});
            return 1;
        };
    } else (common.resolveDoc(ctx, arg) orelse {
        std.debug.print("knap-mcp: no such doc or file '{s}'\n", .{arg});
        return 1;
    }).bytes;

    var a: ObjectMap = .empty;
    try a.put(ctx.arena, "text", .{ .string = bytes });
    try a.put(ctx.arena, "normalize", .{ .bool = normalize });
    try a.put(ctx.arena, "report", .{ .bool = report });
    var out: Allocating = .init(ctx.arena);
    tools.dispatch(ctx, tool.name, a, &out) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "declaude failed"});
        return 1;
    };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    try w.interface.writeAll(out.written());
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return 0;
}
