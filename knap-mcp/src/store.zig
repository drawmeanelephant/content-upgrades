//! Artifact handles. Rendered documents and eval reports land in
//! <store_dir>/artifacts and are addressable as `doc_id` handles so tool
//! responses carry references, not payloads (context economy rule 4).

const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig").Ctx;

var counter: usize = 0;

fn stamp(ctx: *Ctx) u64 {
    const ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    return @intCast(@max(0, ns));
}

/// Pid without a libc dependency (the linux build is freestanding).
fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

pub const Error = error{ ToolFailed, OutOfMemory };

const Permissions = std.Io.File.Permissions;

/// Everything under the store is owner-only: scratch files carry staged
/// data and full request bodies, artifacts carry rendered documents —
/// none of it should be readable by other users on a shared box. Same
/// flags backend.zig gives the curl request body.
const private_file: std.Io.Dir.CreateFileOptions = .{
    .permissions = if (@hasDecl(Permissions, "fromMode")) Permissions.fromMode(0o600) else .default_file,
};
const private_dir: Permissions = if (@hasDecl(Permissions, "fromMode")) Permissions.fromMode(0o700) else .default_dir;

/// writeFile at owner-only 0600 — the one path every store write takes,
/// so no call site can land a world-readable file by default.
pub fn writePrivate(ctx: *Ctx, sub_path: []const u8, data: []const u8) std.Io.Dir.WriteFileError!void {
    return std.Io.Dir.writeFile(.cwd(), ctx.io, .{
        .sub_path = sub_path,
        .data = data,
        .flags = private_file,
    });
}

/// createDirPath at owner-only 0700 — <store>, tmp/, artifacts/ all
/// inherit it (pre-existing dirs keep their mode; mkdir never chmods).
fn ensurePrivateDir(ctx: *Ctx, sub_path: []const u8) std.Io.Dir.CreateDirPathError!void {
    _ = try std.Io.Dir.createDirPathStatus(.cwd(), ctx.io, sub_path, private_dir);
}

/// Store `bytes` under a fresh handle. Returns the doc_id.
pub fn put(ctx: *Ctx, extension: []const u8, bytes: []const u8) Error![]const u8 {
    ensurePrivateDir(ctx, artifactsPath(ctx)) catch
        return ctx.fail("cannot create artifacts dir", .{});
    counter += 1;
    const doc_id = try std.fmt.allocPrint(
        ctx.arena,
        "doc-{d}-{d}-{d}",
        .{ stamp(ctx), processId(), counter },
    );
    const rel = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.{s}", .{ artifactsPath(ctx), doc_id, extension });
    writePrivate(ctx, rel, bytes) catch
        return ctx.fail("artifact store write failed", .{});
    prune(ctx);
    return doc_id;
}

/// Resolve a doc_id to its artifact path (relative to cwd).
pub fn path(ctx: *Ctx, doc_id: []const u8, extension: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}/{s}.{s}", .{ artifactsPath(ctx), doc_id, extension });
}

/// Read an artifact back by doc_id. Caller picks the extension by
/// trying known ones — artifacts record their extension at put() time,
/// and we scan the dir for `doc_id.*` rather than guessing.
pub fn read(ctx: *Ctx, doc_id: []const u8) !?[]const u8 {
    const dir_path = artifactsPath(ctx);
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch return null;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, doc_id)) continue;
        if (entry.name.len <= doc_id.len or entry.name[doc_id.len] != '.') continue;
        const rel = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir_path, entry.name });
        return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, rel, ctx.arena, .limited(64 * 1024 * 1024)) catch null;
    }
    return null;
}

pub const Entry = struct {
    doc_id: []const u8,
    extension: []const u8,
};

/// All artifacts currently in the store.
pub fn list(ctx: *Ctx) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    const dir_path = artifactsPath(ctx);
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch return out.items;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const dot = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        // entry.name aliases the iterator's buffer — dupe before retaining.
        const name = try ctx.arena.dupe(u8, entry.name);
        try out.append(ctx.arena, .{
            .doc_id = name[0..dot],
            .extension = name[dot + 1 ..],
        });
    }
    return out.items;
}

pub fn scratchDir(ctx: *Ctx) Error![]const u8 {
    const rel = try std.fmt.allocPrint(ctx.arena, "{s}/tmp", .{ctx.store_dir});
    ensurePrivateDir(ctx, rel) catch
        return ctx.fail("cannot create scratch dir", .{});
    return rel;
}

/// A unique scratch file path inside <store>/tmp. The pid keeps two
/// processes sharing a KNAP_MCP_HOME from colliding when their real-clock
/// stamps and per-process counters line up.
pub fn scratchFile(ctx: *Ctx, ext: []const u8) Error![]const u8 {
    counter += 1;
    return std.fmt.allocPrint(ctx.arena, "{s}/scratch-{d}-{d}-{d}.{s}", .{
        try scratchDir(ctx), processId(), stamp(ctx), counter, ext,
    });
}

/// Delete this process's leftover scratch files. Scratch content is
/// request-scoped, so the server sweeps after each dispatch; foreign-pid
/// files (a crashed run, a concurrent CLI) are left alone.
pub fn sweepScratch(ctx: *Ctx) void {
    const dir_path = std.fmt.allocPrint(ctx.arena, "{s}/tmp", .{ctx.store_dir}) catch return;
    const prefix = std.fmt.allocPrint(ctx.arena, "scratch-{d}-", .{processId()}) catch return;
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const rel = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        std.Io.Dir.deleteFile(.cwd(), ctx.io, rel) catch {};
    }
}

/// The pid segment of a `scratch-<pid>-<ns>-<counter>.<ext>` name; null
/// when it doesn't parse, which sends the caller back to the age-only
/// rule.
fn scratchPid(name: []const u8) ?i32 {
    const rest = name["scratch-".len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    return std.fmt.parseInt(i32, rest[0..dash], 10) catch null;
}

/// True while `pid` belongs to a live process. kill(pid, 0) reports ESRCH
/// only when nothing owns the pid — EPERM still means alive. Windows has
/// no kill(2); an OpenProcess handle is the equivalent check.
fn pidAlive(pid: i32) bool {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.errno(std.os.linux.kill(pid, @fromBackingInt(@intCast(0)))) != .SRCH,
        .windows => blk: {
            const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, @intCast(pid)) orelse
                break :blk false;
            std.os.windows.CloseHandle(h);
            break :blk true;
        },
        else => std.c.errno(std.c.kill(pid, @fromBackingInt(@intCast(0)))) != .SRCH,
    };
}

const PROCESS_QUERY_LIMITED_INFORMATION: std.os.windows.DWORD = 0x1000;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

/// Delete any process's `scratch-*` files older than an hour. main calls
/// this once at startup so leftovers of a SIGKILLed or crashed run —
/// request bodies holding full prompts, staged data, working templates —
/// don't linger forever; everything in tmp/ is written 0600 owner-only
/// via writePrivate. sweepScratch still handles the live pid's files per
/// request. A `scratch-<pid>-…` file whose pid is still alive is skipped:
/// a long-lived server or CLI can hold a scratch file past the cutoff.
/// Names that don't parse to a pid get the age-only rule. Non-`scratch-`
/// names are never touched.
pub fn sweepStale(ctx: *Ctx) void {
    const dir_path = std.fmt.allocPrint(ctx.arena, "{s}/tmp", .{ctx.store_dir}) catch return;
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(ctx.io);
    const cutoff = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - std.time.ns_per_hour;
    var it = d.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "scratch-")) continue;
        // A live pid may still be staging the file — its age means
        // nothing while the process is up.
        if (scratchPid(entry.name)) |pid| {
            if (pidAlive(pid)) continue;
        }
        const stat = d.statFile(ctx.io, entry.name, .{}) catch continue;
        if (stat.mtime.nanoseconds >= cutoff) continue;
        const rel = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        std.Io.Dir.deleteFile(.cwd(), ctx.io, rel) catch {};
    }
}

/// The artifacts FIFO cap: `KNAP_STORE_MAX_ARTIFACTS`, default 256, 0
/// disables pruning.
fn maxArtifacts(ctx: *Ctx) usize {
    const s = ctx.environ.get("KNAP_STORE_MAX_ARTIFACTS") orelse return 256;
    return std.fmt.parseInt(usize, s, 10) catch 256;
}

/// Keep the newest `maxArtifacts` `doc-*` files: the server's store lives
/// as long as the process, so put() cannot grow without bound. Only
/// put()-named files count toward the cap — foreign files in the dir are
/// never evicted. Best-effort: any failure leaves the store unpruned.
fn prune(ctx: *Ctx) void {
    const cap = maxArtifacts(ctx);
    if (cap == 0) return;
    const dir_path = artifactsPath(ctx);
    const Victim = struct {
        name: []const u8,
        key: Key,
    };
    var docs: std.ArrayList(Victim) = .empty;
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "doc-")) continue;
        const name = ctx.arena.dupe(u8, entry.name) catch return;
        docs.append(ctx.arena, .{ .name = name, .key = artifactKey(name) }) catch return;
    }
    if (docs.items.len <= cap) return;
    std.mem.sort(Victim, docs.items, {}, struct {
        fn less(_: void, a: Victim, b: Victim) bool {
            if (a.key.ns != b.key.ns) return a.key.ns < b.key.ns;
            if (a.key.pid != b.key.pid) return a.key.pid < b.key.pid;
            return a.key.counter < b.key.counter;
        }
    }.less);
    for (docs.items[0 .. docs.items.len - cap]) |v| {
        const rel = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir_path, v.name }) catch continue;
        std.Io.Dir.deleteFile(.cwd(), ctx.io, rel) catch {};
    }
}

const Key = struct { ns: u64, pid: u64, counter: u64 };

/// Sort key parsed from `doc-<ns>-<pid>-<counter>.<ext>` and legacy
/// `doc-<ns>-<counter>.<ext>` ids (pid 0, so old stores still prune
/// oldest-first); unparseable names sort oldest-first.
fn artifactKey(name: []const u8) Key {
    var rest = name["doc-".len..];
    rest = rest[0 .. std.mem.lastIndexOfScalar(u8, rest, '.') orelse rest.len];
    var parts = std.mem.splitScalar(u8, rest, '-');
    const ns = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch 0;
    const second = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch 0;
    return if (parts.next()) |third| .{
        .ns = ns,
        .pid = second,
        .counter = std.fmt.parseInt(u64, third, 10) catch 0,
    } else .{
        .ns = ns,
        .pid = 0,
        .counter = second,
    };
}

fn artifactsPath(ctx: *Ctx) []const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}/artifacts", .{ctx.store_dir}) catch ".knap-mcp/artifacts";
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
        .store_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]}),
        .project_root = ".",
    };
}

test "scratchFile names carry the pid; put prunes to the newest N" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("KNAP_STORE_MAX_ARTIFACTS", "3");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const scratch = try scratchFile(&ctx, "json");
    const prefix = try std.fmt.allocPrint(a, "scratch-{d}-", .{processId()});
    try std.testing.expect(std.mem.indexOf(u8, scratch, prefix) != null);
    try std.testing.expect(std.mem.endsWith(u8, scratch, ".json"));

    // Foreign files are never counted or evicted.
    var ids: [5][]const u8 = undefined;
    ids[0] = try put(&ctx, "md", "x"); // creates the artifacts dir
    const foreign = try std.fmt.allocPrint(a, "{s}/frozen-report.json", .{artifactsPath(&ctx)});
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = foreign, .data = "{}" });
    for (ids[1..]) |*id| id.* = try put(&ctx, "md", "x");
    for (ids[0..2]) |id| try std.testing.expect((try read(&ctx, id)) == null);
    for (ids[2..]) |id| try std.testing.expect((try read(&ctx, id)) != null);
    const entries = try list(&ctx);
    try std.testing.expectEqual(@as(usize, 4), entries.len); // 3 doc-* + frozen
}

test "put ids carry the pid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const id = try put(&ctx, "md", "x");
    const pid_part = try std.fmt.allocPrint(a, "-{d}-", .{processId()});
    try std.testing.expect(std.mem.indexOf(u8, id, pid_part) != null);
}

/// The store's confinement contract on POSIX: 0600 files, 0700 dirs.
/// No-ops where permissions carry no mode (Windows).
fn expectMode(sub_path: []const u8, want: u32) !void {
    if (@hasDecl(Permissions, "toMode")) {
        const st = try std.Io.Dir.statFile(.cwd(), std.testing.io, sub_path, .{});
        try std.testing.expectEqual(want, st.permissions.toMode() & 0o777);
    }
}

test "scratch files and artifacts land 0600 in 0700 dirs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const id = try put(&ctx, "md", "x");
    try expectMode(try path(&ctx, id, "md"), 0o600);
    try expectMode(artifactsPath(&ctx), 0o700);

    const scratch = try scratchFile(&ctx, "json");
    try writePrivate(&ctx, scratch, "{}");
    try expectMode(scratch, 0o600);
    try expectMode(try std.fmt.allocPrint(a, "{s}/tmp", .{ctx.store_dir}), 0o700);
}

test "sweepStale removes only aged scratch files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    const dir = try scratchDir(&ctx);
    // Above every supported OS's max pid (Linux pid_max tops out at
    // 2^22), so guaranteed dead.
    const dead_pid: i32 = 1 << 24;
    const stale = try std.fmt.allocPrint(a, "{s}/scratch-{d}-1-1.json", .{ dir, dead_pid });
    const live = try std.fmt.allocPrint(a, "{s}/scratch-{d}-2-2.json", .{ dir, processId() });
    const unparsed = try std.fmt.allocPrint(a, "{s}/scratch-nopid-3-3.json", .{dir});
    const fresh = try std.fmt.allocPrint(a, "{s}/scratch-{d}-4-4.json", .{ dir, dead_pid });
    const keeper = try std.fmt.allocPrint(a, "{s}/keep.txt", .{dir});
    for ([_][]const u8{ stale, live, unparsed, fresh, keeper }) |p|
        try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = p, .data = "{}" });
    // Two hours old — past the sweep cutoff.
    const old: std.Io.Timestamp = .{
        .nanoseconds = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - 2 * std.time.ns_per_hour,
    };
    for ([_][]const u8{ stale, live, unparsed, keeper }) |p|
        try std.Io.Dir.setTimestamps(.cwd(), std.testing.io, p, .{ .modify_timestamp = .{ .new = old } });

    sweepStale(&ctx);

    // Dead pid or unparseable name: the age-only rule applies.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, stale, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, unparsed, .{}));
    // A scratch file whose pid is still alive is kept despite its age.
    _ = try std.Io.Dir.statFile(.cwd(), std.testing.io, live, .{});
    _ = try std.Io.Dir.statFile(.cwd(), std.testing.io, fresh, .{});
    // Stale files that aren't scratch-* are left alone.
    _ = try std.Io.Dir.statFile(.cwd(), std.testing.io, keeper, .{});
}

test "prune orders mixed legacy and new doc ids by stamp" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("KNAP_STORE_MAX_ARTIFACTS", "3");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);

    _ = try put(&ctx, "md", "x"); // creates the artifacts dir; newest stamp
    const dir = artifactsPath(&ctx);
    // Same stamp, two id shapes: the legacy two-part id (pid 0) sorts
    // older than the three-part one.
    const legacy = try std.fmt.allocPrint(a, "{s}/doc-5-9.md", .{dir});
    const three = try std.fmt.allocPrint(a, "{s}/doc-5-{d}-1.md", .{ dir, processId() });
    for ([_][]const u8{ legacy, three }) |p|
        try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = p, .data = "x" });

    _ = try put(&ctx, "md", "x"); // 4 files over cap 3: evicts the oldest
    try std.testing.expect((try read(&ctx, "doc-5-9")) == null);
    try std.testing.expect((try read(&ctx, try std.fmt.allocPrint(a, "doc-5-{d}-1", .{processId()}))) != null);
}
