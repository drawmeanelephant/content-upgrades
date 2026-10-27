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

/// KNAP_TEMPLATES_DIR wins; then ./templates; then the dir two levels up
/// from the executable (covers zig-out/bin/knap-mcp -> <root>/templates).
fn resolveTemplatesDir(p: std.process.Init) ![]const u8 {
    const arena = p.arena.allocator();
    if (p.environ_map.get("KNAP_TEMPLATES_DIR")) |dir| return dir;

    if (dirExists(p.io, "templates")) return "templates";

    const exe_dir = std.process.executableDirPathAlloc(p.io, arena) catch return "templates";
    const candidate = try std.fmt.allocPrint(arena, "{s}/../../templates", .{exe_dir});
    if (dirExists(p.io, candidate)) return candidate;
    return "templates";
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.openDir(.cwd(), io, path, .{}) catch return false;
    d.close(io);
    return true;
}
