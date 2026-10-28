//! knap_ingest: copy existing markdown files into the artifact store
//! under fresh doc_ids, so every doc_id tool and the knap://docs
//! resources work on docs that never went through knap_render. Ingest
//! is byte-preserving: no normalization, no frontmatter rewriting.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_ingest",
    .description = "Copy existing markdown files into the artifact store under fresh doc_id handles, so doc tools (format_check, publish_check, density, structure_hash) and knap://docs resources work on docs that never went through knap_render. Byte-preserving: no normalization, no frontmatter rewriting. Non-markdown extensions are rejected unless force is true. Paths must be relative and name a file under a content/ dir; pass anywhere to ingest outside the content tree.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"force":{"type":"boolean"},"anywhere":{"type":"boolean"}}}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const force = if (args) |a| blk: {
        const v = a.get("force") orelse break :blk false;
        break :blk switch (v) {
            .bool => |b| b,
            else => return ctx.fail("force must be a boolean", .{}),
        };
    } else false;

    const anywhere = if (args) |a| blk: {
        const v = a.get("anywhere") orelse break :blk false;
        break :blk switch (v) {
            .bool => |b| b,
            else => return ctx.fail("anywhere must be a boolean", .{}),
        };
    } else false;

    var paths: std.ArrayList([]const u8) = .empty;
    if (common.getStr(args, "path")) |p| try paths.append(ctx.arena, p);
    if (args) |a| {
        if (a.get("paths")) |v| switch (v) {
            .array => |items| for (items.items) |item| switch (item) {
                .string => |s| try paths.append(ctx.arena, s),
                else => return ctx.fail("paths must be an array of strings", .{}),
            },
            else => return ctx.fail("paths must be an array of strings", .{}),
        };
    }
    if (paths.items.len == 0)
        return ctx.fail("missing required argument 'path' or 'paths'", .{});
    if (!anywhere)
        for (paths.items) |p| try confinedPath(ctx, p);

    try out.writer.writeAll("{\"ok\":true,\"ingested\":[");
    for (paths.items, 0..) |p, i| {
        const doc_id = try ingestFile(ctx, p, force);
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"path\":");
        try std.json.Stringify.value(p, .{}, &out.writer);
        try out.writer.writeAll(",\"doc_id\":");
        try std.json.Stringify.value(doc_id, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
}

/// Absolute in any supported syntax — POSIX root, drive letter, or UNC —
/// so the confinement check means the same thing on Windows.
fn isAbsolutePath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return true;
    return p.len > 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
}

/// Ingest reads inside a `content/` tree — the same source root the
/// doc_voice `as` and `--out` guards assume. Absolute paths, `..`
/// components, and paths with no `content` dir are refused unless the
/// caller opts out with `anywhere` / `--anywhere` (#330): an MCP caller
/// (including a prompt-injected model) is otherwise one `path` away
/// from reading any file the server can reach.
fn confinedPath(ctx: *Ctx, path: []const u8) tools.Error!void {
    if (isAbsolutePath(path))
        return ctx.fail("refusing '{s}': absolute paths are outside the content/ tree (pass anywhere/--anywhere to read anyway)", .{path});
    var in_content = false;
    var names_file = false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, ".."))
            return ctx.fail("refusing '{s}': '..' escapes the content/ tree (pass anywhere/--anywhere to read anyway)", .{path});
        if (!in_content) {
            if (std.mem.eql(u8, c, "content")) in_content = true;
            continue;
        }
        names_file = true;
    }
    if (!in_content)
        return ctx.fail("refusing '{s}': path is outside a content/ tree (pass anywhere/--anywhere to read anyway)", .{path});
    if (!names_file)
        return ctx.fail("refusing '{s}': path must name a file under a content/ dir", .{path});
}

/// Read `path` and store its bytes verbatim under a fresh doc_id.
/// Non-markdown extensions need `force`; the stored extension stays
/// honest so md-only tools still refuse a forced .html.
/// Confinement lives at the run/cli boundary; callers get raw bytes here.
pub fn ingestFile(ctx: *Ctx, path: []const u8, force: bool) tools.Error![]const u8 {
    const ext = common.docExtForPath(path);
    if (!force and !std.mem.eql(u8, ext, "md"))
        return ctx.fail("'{s}' is not a markdown file (.md/.markdown); pass --force to ingest it anyway", .{path});
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(common.max_doc_bytes)) catch
        return ctx.fail("cannot read '{s}'", .{path});
    return store.put(ctx, ext, bytes);
}

/// `knap-mcp ingest <file>... [--force]`: one {"ok":true,"doc_id":...}
/// line per file; exit 1 on the first failure.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var force = false;
    var anywhere = false;
    var paths: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--anywhere")) {
            anywhere = true;
        } else if (a.len > 1 and a[0] == '-') {
            return usage(try std.fmt.allocPrint(ctx.arena, "ingest: unknown option '{s}'", .{a}));
        } else try paths.append(ctx.arena, a);
    }
    if (paths.items.len == 0) return usage("ingest needs at least one file");
    if (!anywhere)
        for (paths.items) |p| confinedPath(ctx, p) catch {
            std.debug.print("knap-mcp: {s}\n", .{ctx.err_msg});
            return 1;
        };

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    for (paths.items) |p| {
        const doc_id = ingestFile(ctx, p, force) catch {
            w.flush() catch {};
            std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "ingest failed"});
            return 1;
        };
        try w.interface.writeAll("{\"ok\":true,\"doc_id\":");
        try std.json.Stringify.value(doc_id, .{}, &w.interface);
        try w.interface.writeAll("}\n");
    }
    try w.flush();
    return 0;
}

fn usage(msg: ?[]const u8) u8 {
    if (msg) |m| std.debug.print("knap-mcp: {s}\n", .{m});
    std.debug.print("usage: knap-mcp ingest <file>... [--force] [--anywhere]\n", .{});
    return 1;
}

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map, tmp: *std.testing.TmpDir) !Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/store", .{tmp.sub_path[0..]}),
        .project_root = ".",
    };
}

test "ingestFile stores bytes verbatim; non-markdown needs force" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const body = "---\ntitle: Keep Me Verbatim\nslug:  Raw--Slug \n---\n# T\n\nsome  odd   spacing\tand\nCRLF-free bytes\n";
    const src = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/003.blamey-mctypoface.md", .{tmp.sub_path[0..]});
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = src, .data = body });

    const doc_id = try ingestFile(&ctx, src, false);
    const back = (try store.read(&ctx, doc_id)).?;
    var want: [32]u8 = undefined;
    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &want, .{});
    std.crypto.hash.sha2.Sha256.hash(back, &got, .{});
    try std.testing.expectEqualSlices(u8, &want, &got);
    for (try store.list(&ctx)) |e| {
        if (std.mem.eql(u8, e.doc_id, doc_id))
            try std.testing.expectEqualStrings("md", e.extension);
    }

    const txt = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/notes.txt", .{tmp.sub_path[0..]});
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = txt, .data = "x" });
    try std.testing.expectError(error.ToolFailed, ingestFile(&ctx, txt, false));
    try std.testing.expectEqualStrings("x", (try store.read(&ctx, try ingestFile(&ctx, txt, true))).?);

    try std.testing.expectError(error.ToolFailed, ingestFile(&ctx, "no/such/file.md", false));
}

test "run takes path, paths, and force; rejects a non-markdown path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const f1 = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/a.md", .{tmp.sub_path[0..]});
    const f2 = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/b.markdown", .{tmp.sub_path[0..]});
    const f3 = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/c.txt", .{tmp.sub_path[0..]});
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = f1, .data = "# a\n" });
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = f2, .data = "# b\n" });
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = f3, .data = "c" });

    const args = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a,
        \\{{"path":"{s}","paths":["{s}","{s}"],"anywhere":true}}
    , .{ f1, f2, f3 }), .{});
    var out: Allocating = .init(a);
    // c.txt without force fails the whole call.
    try std.testing.expectError(error.ToolFailed, run(&ctx, args.object, &out));

    const forced = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a,
        \\{{"paths":["{s}","{s}","{s}"],"force":true,"anywhere":true}}
    , .{ f1, f2, f3 }), .{});
    out = .init(a);
    try run(&ctx, forced.object, &out);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try std.testing.expect(v.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 3), v.object.get("ingested").?.array.items.len);

    const none = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"force":true}
    , .{});
    try std.testing.expectError(error.ToolFailed, run(&ctx, none.object, &out));
}

test "run confines paths to a content/ tree unless anywhere is set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const inside = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/site/content/mascots/x.md", .{tmp.sub_path[0..]});
    const outside = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/outside.md", .{tmp.sub_path[0..]});
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/site/content/mascots", .{tmp.sub_path[0..]}));
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = inside, .data = "# x\n" });
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = outside, .data = "# outside\n" });

    var out: Allocating = .init(a);
    // Absolute, escaping, and content-less paths are refused.
    for ([_][]const u8{ "/tmp/x.md", "C:/site/content/x.md", "../x.md", "content/../x.md", "plain.md", outside, "content/", "x/content" }) |bad| {
        const args = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a,
            \\{{"path":"{s}"}}
        , .{bad}), .{});
        try std.testing.expectError(error.ToolFailed, run(&ctx, args.object, &out));
        out = .init(a);
    }
    // A relative path under a content/ dir is admitted; the flag admits the rest.
    const good = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a,
        \\{{"path":"{s}"}}
    , .{inside}), .{});
    try run(&ctx, good.object, &out);
    out = .init(a);
    const free = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a,
        \\{{"path":"{s}","anywhere":true}}
    , .{outside}), .{});
    try run(&ctx, free.object, &out);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try std.testing.expect(v.object.get("ok").?.bool);

    // The CLI refuses the same way; --anywhere opts back out.
    try std.testing.expectEqual(@as(u8, 1), try cli(&ctx, try a.dupe([]const u8, &.{outside})));
    try std.testing.expectEqual(@as(u8, 0), try cli(&ctx, try a.dupe([]const u8, &.{ outside, "--anywhere" })));
    try std.testing.expectEqual(@as(u8, 0), try cli(&ctx, try a.dupe([]const u8, &.{inside})));
}

test "isAbsolutePath covers posix, drive, and UNC forms" {
    try std.testing.expect(isAbsolutePath("/tmp/x.md"));
    try std.testing.expect(isAbsolutePath("\\srv\\x.md"));
    try std.testing.expect(isAbsolutePath("\\x.md"));
    try std.testing.expect(isAbsolutePath("C:\\x.md"));
    try std.testing.expect(isAbsolutePath("c:/x.md"));
    try std.testing.expect(!isAbsolutePath("content/x.md"));
    try std.testing.expect(!isAbsolutePath("c.md"));
    try std.testing.expect(!isAbsolutePath(""));
}
