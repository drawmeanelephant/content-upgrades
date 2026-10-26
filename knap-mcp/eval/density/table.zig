//! Prints the density fixture table for docs/tracks/D1.md: one row per
//! file, the total, the top contributors, and the scoring time. With
//! `--json`, prints each file's full `density.writeJson` breakdown instead.
//!
//!     cd knap-mcp
//!     zig run -OReleaseFast --dep density -Mroot=eval/density/table.zig \
//!         -Mdensity=src/density.zig -- [--json] eval/density/*.md

const std = @import("std");
const density = @import("density");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var json = false;
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.next();
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "--json")) json = true;
        if (std.mem.endsWith(u8, p, ".md") and !std.mem.endsWith(u8, p, "README.md")) try paths.append(a, p);
    }

    const docs = try a.alloc([]const u8, paths.items.len);
    for (paths.items, docs) |p, *d| d.* = try std.Io.Dir.readFileAlloc(.cwd(), init.io, p, a, .limited(1 << 20));

    const scores = try a.alloc(density.Score, docs.len);
    const t0 = std.Io.Timestamp.now(init.io, .awake);
    for (docs, scores) |d, *s| s.* = try density.score(a, d);
    const ns = t0.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    if (json) {
        for (paths.items, scores) |p, s| {
            try out.print("{s}\n", .{p});
            try density.writeJson(s, out);
            try out.writeAll("\n");
        }
        return w.flush();
    }
    try out.print("| fixture | words | total | top signals | penalties |\n|---|--:|--:|---|---|\n", .{});
    for (paths.items, scores) |p, s| {
        try out.print("| `{s}` | {d} | **{d:.1}** | ", .{ std.fs.path.basename(p), s.words, s.total });
        var first = true;
        for (s.signals) |sig| {
            if (sig.contribution < 3) continue;
            try out.print("{s}{s} {d:.1}", .{ if (first) "" else ", ", sig.name, sig.contribution });
            first = false;
        }
        try out.writeAll(" | ");
        first = true;
        for (s.signals) |sig| {
            if (sig.contribution >= 0) continue;
            try out.print("{s}{s} {d:.1}", .{ if (first) "" else ", ", sig.name, sig.contribution });
            first = false;
        }
        try out.writeAll(" |\n");
    }
    try out.print("\nscored {d} docs in {d:.3} ms\n", .{ docs.len, @as(f64, @floatFromInt(ns)) / 1e6 });
    try w.flush();
}
