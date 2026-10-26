//! Verifier gate: runs the heuristic over the labeled cases and prints the
//! confusion table (expected label against heuristic label), per-class
//! pass counts, and every miss. Exits 1 if any verbatim case is not
//! `entails` or any unrelated case is not `unknown`.
//!
//!     cd knap-mcp
//!     zig run --dep verifier -Mroot=eval/verifier/gate.zig \
//!         -Mverifier=src/verifier.zig -- [eval/verifier/cases.json]

const std = @import("std");
const verifier = @import("verifier");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.next();
    const path = it.next() orelse "eval/verifier/cases.json";
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), init.io, path, a, .limited(1 << 20));
    const g = try verifier.runGate(a, bytes);

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try verifier.writeGate(g, &w.interface);
    try w.flush();
    return if (g.hard_failures.len == 0) 0 else 1;
}
