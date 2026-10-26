//! Artifact handles. Rendered documents and eval reports land in
//! <store_dir>/artifacts and are addressable as `doc_id` handles so tool
//! responses carry references, not payloads (context economy rule 4).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;

var counter: usize = 0;

fn stamp(ctx: *Ctx) u64 {
    const ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    return @intCast(@max(0, ns));
}

pub const Error = error{ ToolFailed, OutOfMemory };

/// Store `bytes` under a fresh handle. Returns the doc_id.
pub fn put(ctx: *Ctx, extension: []const u8, bytes: []const u8) Error![]const u8 {
    std.Io.Dir.createDirPath(.cwd(), ctx.io, artifactsPath(ctx)) catch
        return ctx.fail("cannot create artifacts dir", .{});
    counter += 1;
    const doc_id = try std.fmt.allocPrint(
        ctx.arena,
        "doc-{d}-{d}",
        .{ stamp(ctx), counter },
    );
    const rel = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.{s}", .{ artifactsPath(ctx), doc_id, extension });
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = rel, .data = bytes }) catch
        return ctx.fail("artifact store write failed", .{});
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
    std.Io.Dir.createDirPath(.cwd(), ctx.io, rel) catch
        return ctx.fail("cannot create scratch dir", .{});
    return rel;
}

/// A unique scratch file path inside <store>/tmp.
pub fn scratchFile(ctx: *Ctx, ext: []const u8) Error![]const u8 {
    counter += 1;
    return std.fmt.allocPrint(ctx.arena, "{s}/scratch-{d}-{d}.{s}", .{
        try scratchDir(ctx), stamp(ctx), counter, ext,
    });
}

fn artifactsPath(ctx: *Ctx) []const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}/artifacts", .{ctx.store_dir}) catch ".knap-mcp/artifacts";
}
