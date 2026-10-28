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

/// Cap on doc bytes read straight off disk — same bound store.read uses.
pub const max_doc_bytes = 64 * 1024 * 1024;

/// A `<doc_id|file>` positional resolved to bytes.
pub const DocArg = struct {
    bytes: []const u8,
    /// The argument when it named a readable file; null for a doc_id.
    file_path: ?[]const u8,
};

/// CLI `<doc_id|file>` resolution: a readable file wins over a doc_id
/// spelled the same; the artifact store is the fallback. null when
/// neither resolves.
pub fn resolveDoc(ctx: *Ctx, arg: []const u8) ?DocArg {
    if (std.Io.Dir.readFileAlloc(.cwd(), ctx.io, arg, ctx.arena, .limited(max_doc_bytes))) |bytes| {
        return .{ .bytes = bytes, .file_path = arg };
    } else |_| {}
    const bytes = (store.read(ctx, arg) catch null) orelse return null;
    return .{ .bytes = bytes, .file_path = null };
}

/// Link/image destinations a value for --target html may carry. dogbed
/// does no escaping, so anything without one of these schemes — relative
/// or `#` targets included — can smuggle a live URL into the published
/// page and is rejected outright.
const html_schemes = [_][]const u8{ "http:", "https:", "mailto:" };

fn htmlSchemeOk(dest: []const u8) bool {
    for (html_schemes) |s| {
        if (std.ascii.startsWithIgnoreCase(dest, s)) return true;
    }
    return false;
}

fn htmlString(s: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '<') != null) return "contains '<'";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "](")) |p| {
        var d = p + 2;
        while (d < s.len and std.ascii.isWhitespace(s[d])) d += 1;
        if (!htmlSchemeOk(s[d..])) return "has a link/image target outside http:|https:|mailto:";
        i = p + 2;
    }
    return null;
}

/// The first html-target violation in any string inside `value`, or
/// null. Same recursive walk as ratchet.inertViolation, different
/// contract: markdown emphasis in a value is fine for html, but raw HTML
/// (`<`, which also covers autolinks and `<...>`-wrapped destinations)
/// and off-scheme link/image targets are not. Reject rather than escape.
pub fn htmlDataViolation(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return htmlString(s),
        .array => |a| for (a.items) |v| {
            if (htmlDataViolation(v)) |why| return why;
        },
        .object => |o| for (o.values()) |v| {
            if (htmlDataViolation(v)) |why| return why;
        },
        else => {},
    }
    return null;
}

/// The store extension a file path implies: .md/.markdown → "md", other
/// extensions pass through as-is, none → "txt".
pub fn docExtForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return "txt";
    const e = ext[1..];
    if (std.ascii.eqlIgnoreCase(e, "md") or std.ascii.eqlIgnoreCase(e, "markdown")) return "md";
    return e;
}

/// `arg` → a doc_id for tools that only take handles: a readable file is
/// staged into the artifact store byte-for-byte under its own extension
/// and the fresh doc_id returned; anything else passes through so the
/// tool resolves (or rejects) it as a doc_id.
pub fn docIdOrStage(ctx: *Ctx, arg: []const u8) Error![]const u8 {
    const r = resolveDoc(ctx, arg) orelse return arg;
    if (r.file_path == null) return arg;
    return store.put(ctx, docExtForPath(arg), r.bytes);
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

test "htmlDataViolation rejects raw HTML and off-scheme link targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad = [_][]const u8{
        \\{"title":"X <script>alert(1)</script>","summary":"s","take":"t"}
        ,
        \\{"title":"t","summary":"s <img src=x onerror=alert(1)> [l](javascript:alert(1))","take":"t"}
        ,
        \\{"title":"t","summary":"s","take":"<b>raw</b>"}
        ,
        \\{"nested":{"list":["ok","x ](JaVaScRiPt:alert(1))"]}}
        ,
        \\{"u":"[d](data:text/html,x) [v](\tvbscript:x) [r](/rel) [f](#frag) [e]()"}
        ,
    };
    for (bad) |r| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, r, .{});
        try std.testing.expect(htmlDataViolation(v) != null);
    }

    const good = [_][]const u8{
        \\{"u":"[ok](https://x.y) [m](mailto:a@b) [h](HTTP://x) [s]( http://x )"}
        ,
        \\{"n":3,"b":true,"u":null,"o":{"k":"v"},"a":["x","**emphasis**"]}
        ,
    };
    for (good) |r| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, r, .{});
        try std.testing.expect(htmlDataViolation(v) == null);
    }
}

test "htmlDataViolation passes every shipped data sample" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d = try std.Io.Dir.openDir(.cwd(), std.testing.io, "data", .{ .iterate = true });
    defer d.close(std.testing.io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".sample.json")) continue;
        const text = try std.Io.Dir.readFileAlloc(d, std.testing.io, e.name, a, .limited(1 << 20));
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        try std.testing.expect(htmlDataViolation(v) == null);
        n += 1;
    }
    try std.testing.expect(n > 0);
}
