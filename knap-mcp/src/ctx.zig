//! Shared runtime context: allocator handles, resolved engine paths,
//! backend selection, and the on-disk locations for templates and the
//! artifact store. One Ctx per process; CLI subcommands and the MCP
//! server both build one.

const std = @import("std");
const engine = @import("engine.zig");
const backend = @import("backend.zig");

pub const Ctx = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    engines: engine.Config,
    backend_kind: backend.Kind,
    templates_dir: []const u8,
    store_dir: []const u8,
    project_root: []const u8,
    /// Set by tool handlers before returning an error so the MCP layer can
    /// surface a real message instead of a bare error name.
    err_msg: []const u8 = "",
    /// One-shot latch for the "scratch files inside the project tree"
    /// warning — a repair loop must not repeat it on every call.
    store_warned: bool = false,

    /// Slice-economy counters for the numbers card ("disseminate, don't
    /// stuff"). `backend.complete` counts live calls; the mock paths count
    /// the slice they would have sent, via `countCall`.
    calls: usize = 0,
    slice_bytes_total: usize = 0,
    slice_bytes_max: usize = 0,
    /// The cache-stable system prefix: recorded, not summed.
    prefix_bytes: usize = 0,

    /// Token counters summed from `completeReply(...).usage`, alongside
    /// the byte counters. Fields a provider omits contribute nothing, so
    /// they stay 0 on unmetered backends like mock — never estimated.
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,

    /// One model call carrying `slice` bytes under a `prefix`-byte system
    /// prompt. Mock paths pass the slice they would have sent so eval
    /// numbers measure the real context economy.
    pub fn countCall(ctx: *Ctx, prefix: []const u8, slice: []const u8) void {
        ctx.calls += 1;
        ctx.slice_bytes_total += slice.len;
        ctx.slice_bytes_max = @max(ctx.slice_bytes_max, slice.len);
        ctx.prefix_bytes = prefix.len;
    }

    /// One reply's metered tokens; null fields are skipped, matching
    /// `backend.Usage`.
    pub fn countUsage(ctx: *Ctx, u: backend.Usage) void {
        if (u.prompt_tokens) |t| ctx.prompt_tokens += t;
        if (u.completion_tokens) |t| ctx.completion_tokens += t;
        if (u.total_tokens) |t| ctx.total_tokens += t;
        if (u.reasoning_tokens) |t| ctx.reasoning_tokens += t;
    }

    /// Mean slice bytes per counted call; 0 before the first.
    pub fn meanSlice(ctx: *const Ctx) usize {
        return if (ctx.calls == 0) 0 else ctx.slice_bytes_total / ctx.calls;
    }

    /// The token segment of the numbers card, in the `calls:` line's style.
    pub fn writeTokens(ctx: *const Ctx, w: *std.Io.Writer) !void {
        try w.print("tokens: prompt {d}  completion {d}  total {d}  reasoning {d}\n", .{
            ctx.prompt_tokens, ctx.completion_tokens, ctx.total_tokens, ctx.reasoning_tokens,
        });
    }

    pub fn init(p: std.process.Init) !Ctx {
        const arena = p.arena.allocator();
        const env = p.environ_map;

        const templates_dir = try resolveTemplatesDir(p);
        const project_root = std.fs.path.dirname(templates_dir) orelse ".";

        return .{
            .arena = arena,
            .gpa = p.gpa,
            .io = p.io,
            .environ = env,
            .engines = .{
                .k4o = env.get("KNAP_K4O_PATH") orelse "k4o",
                .dogbed = env.get("KNAP_DOGBED_PATH") orelse "dogbed",
            },
            .backend_kind = backend.parseKind(env.get("KNAP_BACKEND") orelse "mock") orelse .mock,
            .templates_dir = templates_dir,
            .store_dir = env.get("KNAP_MCP_HOME") orelse ".knap-mcp",
            .project_root = project_root,
        };
    }

    pub fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{ToolFailed} {
        ctx.err_msg = std.fmt.allocPrint(ctx.arena, fmt, args) catch "out of memory";
        return error.ToolFailed;
    }

    /// Seconds-valued env var, or `default` when unset or unparseable.
    pub fn envSecs(ctx: *Ctx, name: []const u8, default: u64) u64 {
        const s = ctx.environ.get(name) orelse return default;
        return std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t"), 10) catch default;
    }

    /// `.none` for 0, else a hard deadline `secs` from now on the awake
    /// clock — a cap on the whole child process, not per-I/O idle time.
    pub fn deadline(ctx: *Ctx, secs: u64) std.Io.Timeout {
        if (secs == 0) return .none;
        return .{ .deadline = .fromNow(ctx.io, .{
            .raw = .fromSeconds(@intCast(secs)),
            .clock = .awake,
        }) };
    }
};

/// KNAP_TEMPLATES_DIR wins; then the dir two levels up from the
/// executable (covers zig-out/bin/knap-mcp -> <root>/templates); then
/// ./templates. The shipped set outranks a stray cwd ./templates, which
/// is only the fallback for a binary moved out of its tree.
fn resolveTemplatesDir(p: std.process.Init) ![]const u8 {
    const arena = p.arena.allocator();
    if (p.environ_map.get("KNAP_TEMPLATES_DIR")) |dir| return dir;
    const exe_dir = std.process.executableDirPathAlloc(p.io, arena) catch null;
    return defaultTemplatesDir(p.io, arena, exe_dir);
}

/// <exe>/../../templates when that dir exists, else ./templates — split
/// from resolveTemplatesDir so tests can pass a fake exe location.
fn defaultTemplatesDir(io: std.Io, arena: std.mem.Allocator, exe_dir: ?[]const u8) ![]const u8 {
    if (exe_dir) |d| {
        const candidate = try std.fmt.allocPrint(arena, "{s}/../../templates", .{d});
        if (dirExists(io, candidate)) return candidate;
    }
    return "templates";
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.openDir(.cwd(), io, path, .{}) catch return false;
    d.close(io);
    return true;
}

test "countCall totals slice bytes, keeps the max, records the prefix once" {
    var ctx: Ctx = undefined;
    ctx.calls = 0;
    ctx.slice_bytes_total = 0;
    ctx.slice_bytes_max = 0;
    ctx.prefix_bytes = 0;
    ctx.countCall("system prompt", "12345");
    ctx.countCall("system prompt", "12");
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
    try std.testing.expectEqual(@as(usize, 7), ctx.slice_bytes_total);
    try std.testing.expectEqual(@as(usize, 5), ctx.slice_bytes_max);
    try std.testing.expectEqual(@as(usize, 3), ctx.meanSlice());
    try std.testing.expectEqual(@as(usize, 13), ctx.prefix_bytes);
}

test "countUsage sums metered fields, leaves unmetered at 0" {
    var ctx: Ctx = undefined;
    ctx.prompt_tokens = 0;
    ctx.completion_tokens = 0;
    ctx.total_tokens = 0;
    ctx.reasoning_tokens = 0;
    ctx.countUsage(.{ .prompt_tokens = 412, .completion_tokens = 9, .total_tokens = 421 });
    ctx.countUsage(.{ .prompt_tokens = 50, .completion_tokens = 256, .reasoning_tokens = 256 });
    ctx.countUsage(.{}); // mock-shaped reply: nothing metered
    try std.testing.expectEqual(@as(u64, 462), ctx.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 265), ctx.completion_tokens);
    try std.testing.expectEqual(@as(u64, 421), ctx.total_tokens);
    try std.testing.expectEqual(@as(u64, 256), ctx.reasoning_tokens);
}

test "KNAP_TEMPLATES_DIR is an explicit override" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("KNAP_TEMPLATES_DIR", "/custom/templates");
    const p: std.process.Init = .{
        .minimal = undefined,
        .arena = &arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &env,
        .preopens = .empty,
    };
    try std.testing.expectEqualStrings("/custom/templates", try resolveTemplatesDir(p));
}

test "a stray ./templates in cwd cannot shadow the exe-relative shipped set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Shipped layout: <pkg>/zig-out/bin/<exe>, templates at <pkg>/templates.
    try tmp.dir.createDirPath(std.testing.io, "pkg/zig-out/bin");
    try tmp.dir.createDirPath(std.testing.io, "pkg/templates");
    const exe_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pkg/zig-out/bin", .{tmp.sub_path});
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{s}/../../templates", .{exe_dir}),
        try defaultTemplatesDir(std.testing.io, a, exe_dir),
    );
    // No shipped set beside the exe (relocated binary): ./templates fallback.
    try std.testing.expectEqualStrings("templates", try defaultTemplatesDir(std.testing.io, a, null));
    try std.testing.expectEqualStrings("templates", try defaultTemplatesDir(std.testing.io, a, "/nonexistent/bin"));
}
