//! `knap-mcp audit <dir>` — batch density/format-check over a content
//! tree (FILED-AUDIT, #253). Read-only: no model calls, no artifact
//! writes, no subprocesses. The scorer is in-process — density.score
//! already folds formatcheck warnings into each row — so the whole
//! corpus is one pass per file through a reused scorer. Matched files
//! are path-sorted before scoring, so two runs over the same tree are
//! byte-identical regardless of walk order.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const density = @import("../density.zig");
const policy = @import("../policy.zig");

const max_doc_bytes = 64 * 1024 * 1024;
pub const default_glob = "**/*.md";

/// A `--per-glob` pair: files matching `pattern` roll up under `name`.
pub const Group = struct {
    name: []const u8,
    pattern: []const u8,
};

pub const Opts = struct {
    dir: []const u8,
    glob: []const u8 = default_glob,
    /// Group by containing directory instead of first path segment.
    per_dir: bool = false,
    /// Named glob groups; first match wins, unmatched files keep the
    /// default first-segment grouping.
    per_glob: []const Group = &.{},
    /// After the table, list docs whose total is under this score. With
    /// a policy, a collection's `score.min` replaces it for its docs.
    below: ?f64 = null,
    /// `--below band`: list only docs under their collection's band.
    below_band: bool = false,
    /// JSONL destination; null streams rows to stdout before the table.
    jsonl: ?[]const u8 = null,
    /// Per-collection policy: groups by collection, judges every row.
    policy: ?*const policy.Policy = null,
};

/// One scored doc: path relative to the audit root ('/'-separated), its
/// resolved rollup group, and the density score. Under a policy, `coll`
/// is the matching collection (null = unpoliced) and `verdict` its
/// judgement.
pub const Row = struct {
    rel: []const u8,
    group: []const u8,
    sc: density.Score,
    coll: ?*const policy.Collection = null,
    verdict: ?policy.Verdict = null,

    /// The number bands and `--below` compare: the policy score for a
    /// policed doc, else the raw total.
    fn score(r: Row) f64 {
        return if (r.verdict) |v| v.score else r.sc.total;
    }
};

/// `knap-mcp audit <dir> [--glob <p>] [--per-dir|--per-glob <map>]
/// [--below <score|band>] [--jsonl <file>] [--policy <file>|--no-policy]`
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var o: Opts = .{ .dir = "" };
    var dir: ?[]const u8 = null;
    var groups: std.ArrayList(Group) = .empty;
    var policy_path: ?[]const u8 = null;
    var no_policy = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (optVal(args, &i, "--glob") catch return usage("missing value for --glob")) |v| {
            o.glob = v;
        } else if (std.mem.eql(u8, a, "--per-dir")) {
            o.per_dir = true;
        } else if (optVal(args, &i, "--per-glob") catch return usage("missing value for --per-glob")) |v| {
            parseGroupMap(ctx, v, &groups) catch return fail(ctx);
        } else if (optVal(args, &i, "--below") catch return usage("missing value for --below")) |v| {
            if (std.mem.eql(u8, v, "band")) {
                o.below_band = true;
            } else o.below = std.fmt.parseFloat(f64, v) catch
                return usage("--below needs a number or 'band'");
        } else if (optVal(args, &i, "--jsonl") catch return usage("missing value for --jsonl")) |v| {
            o.jsonl = v;
        } else if (optVal(args, &i, "--policy") catch return usage("missing value for --policy")) |v| {
            policy_path = v;
        } else if (std.mem.eql(u8, a, "--no-policy")) {
            no_policy = true;
        } else if (a.len > 1 and a[0] == '-') {
            return usage(try std.fmt.allocPrint(ctx.arena, "unknown option '{s}'", .{a}));
        } else {
            if (dir != null) return usage("audit takes exactly one directory");
            dir = a;
        }
    }
    o.dir = std.mem.trimEnd(u8, dir orelse return usage("audit needs a directory"), "/");
    if (o.dir.len == 0) o.dir = ".";
    o.per_glob = groups.items;
    if (o.per_dir and o.per_glob.len > 0)
        return usage("--per-dir and --per-glob are mutually exclusive");
    if (no_policy and policy_path != null)
        return usage("--policy and --no-policy are mutually exclusive");
    if (!no_policy and policy_path == null)
        policy_path = policy.discover(ctx, o.dir) catch return fail(ctx);
    var pol: policy.Policy = undefined;
    if (policy_path) |pp| {
        pol = policy.load(ctx, pp) catch return fail(ctx);
        o.policy = &pol;
    }
    if (o.below_band and o.policy == null)
        return usage("--below band needs a policy (--policy <file>)");

    const rows = auditTree(ctx, o) catch return fail(ctx);
    if (rows.len == 0)
        std.debug.print("knap-mcp: audit: no files match '{s}' under '{s}'\n", .{ o.glob, o.dir });

    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(ctx.io, &out_buf);
    defer out.interface.flush() catch {};
    // Name the policy up front: a discovered file changes the report, so
    // the report must say which one it was.
    if (o.policy) |p|
        std.debug.print("knap-mcp: audit: policy {s} ({s}, {d} collection{s})\n", .{ p.path, policy.schema, p.collections.len, if (p.collections.len == 1) "" else "s" });

    // Per-doc JSONL rows: --jsonl file, else stdout ahead of the table.
    if (o.jsonl) |path| {
        var jbuf: [8192]u8 = undefined;
        const jf = std.Io.Dir.createFile(.cwd(), ctx.io, path, .{}) catch
            return failf(ctx, "cannot create --jsonl file '{s}'", .{path});
        defer jf.close(ctx.io);
        var jw = jf.writer(ctx.io, &jbuf);
        for (rows) |row| writeRow(&jw.interface, row, o.policy != null) catch
            return failf(ctx, "cannot write --jsonl file '{s}'", .{path});
        jw.interface.flush() catch
            return failf(ctx, "cannot write --jsonl file '{s}'", .{path});
    } else {
        for (rows) |row| writeRow(&out.interface, row, o.policy != null) catch return 1;
    }

    writeRollup(ctx, &out.interface, rows, o.policy != null) catch return fail(ctx);
    if (o.policy != null) writeOutOfPolicy(ctx, &out.interface, rows) catch return fail(ctx);
    if (o.below != null or o.below_band)
        writeBelow(ctx, &out.interface, rows, if (o.below_band) null else o.below, o.policy != null) catch return fail(ctx);
    return 0;
}

/// Walk `o.dir`, keep files matching `o.glob`, path-sort them, score
/// each in order. Unreadable files are reported on stderr and skipped —
/// the row count always equals the number of scored files.
pub fn auditTree(ctx: *Ctx, o: Opts) ![]Row {
    var files: std.ArrayList([]const u8) = .empty;
    try walkTree(ctx, o.dir, "", &files);

    var matched: std.ArrayList([]const u8) = .empty;
    for (files.items) |rel| {
        if (globMatch(o.glob, rel)) try matched.append(ctx.arena, rel);
    }
    std.mem.sort([]const u8, matched.items, {}, strLess);

    var rows: std.ArrayList(Row) = .empty;
    var skipped: usize = 0;
    for (matched.items) |rel| {
        const full = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ o.dir, rel });
        const doc = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, full, ctx.arena, .limited(max_doc_bytes)) catch {
            std.debug.print("knap-mcp: audit: cannot read '{s}' — skipped\n", .{full});
            skipped += 1;
            continue;
        };
        const sc = try density.score(ctx.arena, doc);
        var row: Row = .{ .rel = rel, .group = groupName(rel, o), .sc = sc };
        if (o.policy) |p| {
            row.coll = p.match(rel);
            if (row.coll) |c| {
                row.group = c.name;
                row.verdict = try policy.judge(ctx.arena, c, sc);
            } else {
                // Unpoliced docs never share a bucket with a policed
                // collection of the same name.
                row.group = try std.fmt.allocPrint(ctx.arena, "unpoliced:{s}", .{row.group});
            }
        }
        try rows.append(ctx.arena, row);
    }
    if (skipped > 0)
        std.debug.print("knap-mcp: audit: {d} file(s) unreadable, skipped\n", .{skipped});
    return rows.items;
}

/// Depth-first walk of `root`; appends '/'-joined paths relative to
/// `root`. Hidden entries (dotfiles, .git, .knap-mcp) and non-regular
/// entries (symlinks, sockets) are skipped — the corpus under audit is
/// plain markdown files.
fn walkTree(ctx: *Ctx, root: []const u8, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    const dir_path = if (rel.len == 0)
        root
    else
        try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ root, rel });
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, dir_path, .{ .iterate = true }) catch
        return ctx.fail("cannot open directory '{s}'", .{dir_path});
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        // entry.name aliases the iterator's buffer; build the retained
        // relative path before the next next() call.
        const child = if (rel.len == 0)
            try ctx.arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => try walkTree(ctx, root, child, out),
            .file => try out.append(ctx.arena, child),
            else => {},
        }
    }
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The rollup group for a file: a `--per-glob` match first, then
/// `--per-dir`, else the first path segment — a root-level file is its
/// own collection, named by its stem (`index.md` → `index`).
fn groupName(rel: []const u8, o: Opts) []const u8 {
    for (o.per_glob) |g| {
        if (globMatch(g.pattern, rel)) return g.name;
    }
    if (o.per_dir) {
        return if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[0..i] else ".";
    }
    if (std.mem.indexOfScalar(u8, rel, '/')) |i| return rel[0..i];
    const stem = std.fs.path.stem(rel);
    return if (stem.len > 0) stem else rel;
}

fn parseGroupMap(ctx: *Ctx, spec: []const u8, groups: *std.ArrayList(Group)) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse
            return ctx.fail("--per-glob entries need name=glob, got '{s}'", .{pair});
        if (eq == 0 or eq + 1 == pair.len)
            return ctx.fail("--per-glob entries need name=glob, got '{s}'", .{pair});
        try groups.append(ctx.arena, .{ .name = pair[0..eq], .pattern = pair[eq + 1 ..] });
    }
}

/// `--opt <v>` / `--opt=<v>`; null when args[i] is a different option.
fn optVal(args: [][]const u8, i: *usize, comptime opt: []const u8) !?[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, opt)) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingValue;
        return args[i.*];
    }
    if (std.mem.startsWith(u8, a, opt ++ "=")) return a[opt.len + 1 ..];
    return null;
}

// --- Glob --------------------------------------------------------------------
//
// `*` and `?` match within a path segment; `**` as a whole segment
// matches zero or more segments, so the default `**/*.md` covers both
// `a.md` and `deep/nested/b.md`.

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return matchSegs(pattern, path);
}

fn firstSeg(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '/')) |i| s[0..i] else s;
}

fn restSegs(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else "";
}

fn matchSegs(pat: []const u8, path: []const u8) bool {
    if (pat.len == 0) return path.len == 0;
    const p = firstSeg(pat);
    const prest = restSegs(pat);
    if (std.mem.eql(u8, p, "**")) {
        var rest = path;
        while (true) {
            if (matchSegs(prest, rest)) return true;
            if (rest.len == 0) return false;
            rest = restSegs(rest);
        }
    }
    if (path.len == 0) return false;
    if (!segMatch(p, firstSeg(path))) return false;
    return matchSegs(prest, restSegs(path));
}

/// Single-segment wildcard match with `*` and `?` (backtracking).
fn segMatch(pat: []const u8, seg: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star_p: usize = 0;
    var star_s: usize = 0;
    var have_star = false;
    while (s < seg.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == seg[s])) {
            p += 1;
            s += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star_p = p;
            star_s = s;
            have_star = true;
            p += 1;
        } else if (have_star) {
            p = star_p + 1;
            star_s += 1;
            s = star_s;
        } else {
            return false;
        }
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

// --- Output ------------------------------------------------------------------

/// `{"file":..,"total":..,"words":..,"signals":{"top":[..],"penalties":
/// [..]},"warnings":[..]}` — one line. Top is the three signals earning
/// the most; penalties are negative contributors, worst first. Under a
/// policy the row gains `"policy":{"collection","score","band",
/// "violations":[{rule,signal,value,limit}]}` (`{"collection":null}` when
/// no collection matches); without one the row is unchanged.
fn writeRow(w: *std.Io.Writer, row: Row, with_policy: bool) !void {
    try w.writeAll("{\"file\":");
    try std.json.Stringify.value(row.rel, .{}, w);
    try w.print(",\"total\":{d:.2},\"words\":{d},\"signals\":{{\"top\":[", .{ row.sc.total, row.sc.words });
    const top = topSignals(row.sc);
    var n: usize = 0;
    for (top) |name| {
        if (name == null) break;
        if (n > 0) try w.writeAll(",");
        try std.json.Stringify.value(name.?, .{}, w);
        n += 1;
    }
    try w.writeAll("],\"penalties\":[");
    var pen_buf: [64]density.Signal = undefined;
    for (penaltySignals(row.sc, &pen_buf), 0..) |sig, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(sig.name, .{}, w);
    }
    try w.writeAll("]},\"warnings\":[");
    for (row.sc.warnings, 0..) |warn, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"rule\":");
        try std.json.Stringify.value(warn.rule, .{}, w);
        try w.print(",\"line\":{d},\"detail\":", .{warn.line});
        try std.json.Stringify.value(warn.detail, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (with_policy) try writePolicyField(w, row);
    try w.writeAll("}\n");
}

fn writePolicyField(w: *std.Io.Writer, row: Row) !void {
    const c = row.coll orelse return w.writeAll(",\"policy\":{\"collection\":null}");
    const v = row.verdict.?;
    try w.writeAll(",\"policy\":{\"collection\":");
    try std.json.Stringify.value(c.name, .{}, w);
    try w.print(",\"score\":{d:.2},\"band\":\"{s}\",\"violations\":[", .{ v.score, @tagName(v.band) });
    for (v.violations, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"rule\":\"{s}\"", .{@tagName(vi.rule)});
        if (vi.signal) |s| {
            try w.writeAll(",\"signal\":");
            try std.json.Stringify.value(s, .{}, w);
        }
        try w.print(",\"value\":{d:.2},\"limit\":{d:.2}}}", .{ vi.value, vi.limit });
    }
    try w.writeAll("]}");
}

/// Up to three signal names with the highest positive contribution;
/// ties keep spec order.
fn topSignals(sc: density.Score) [3]?[]const u8 {
    var best: [3]?[]const u8 = @splat(null);
    var vals: [3]f64 = @splat(0);
    for (sc.signals) |sig| {
        if (sig.contribution <= 0) continue;
        for (0..3) |j| {
            if (best[j] == null or sig.contribution > vals[j]) {
                var k: usize = 3;
                while (k > j + 1) : (k -= 1) {
                    best[k - 1] = best[k - 2];
                    vals[k - 1] = vals[k - 2];
                }
                best[j] = sig.name;
                vals[j] = sig.contribution;
                break;
            }
        }
    }
    return best;
}

/// Signals whose contribution is negative, most-penalizing first;
/// writes into caller's `buf` (signal count is bounded by density's
/// spec+penalty tables, far under 64).
fn penaltySignals(sc: density.Score, buf: []density.Signal) []const density.Signal {
    var len: usize = 0;
    for (sc.signals) |sig| {
        if (sig.contribution >= 0) continue;
        // Insertion by contribution ascending; `<=` keeps spec order on
        // ties so the result is deterministic.
        var j: usize = 0;
        while (j < len and buf[j].contribution <= sig.contribution) j += 1;
        if (len == buf.len) break;
        var k: usize = len;
        while (k > j) : (k -= 1) buf[k] = buf[k - 1];
        buf[j] = sig;
        len += 1;
    }
    return buf[0..len];
}

pub const Stats = struct {
    name: []const u8,
    n: usize,
    mean: f64,
    min: f64,
    max: f64,
    p25: f64,
    p75: f64,
    // Policy columns; zero/null without a policy.
    raw_mean: f64 = 0,
    coll: ?*const policy.Collection = null,
    in_band: usize = 0,
    below: usize = 0,
    above: usize = 0,
    /// Docs with at least one violation.
    oop: usize = 0,
};

/// Stats over a sorted-by-path row set for the rows of one group (or
/// all of them). Deterministic: the totals are sorted in place.
fn statsOf(name: []const u8, totals: []f64) Stats {
    if (totals.len == 0) return .{ .name = name, .n = 0, .mean = 0, .min = 0, .max = 0, .p25 = 0, .p75 = 0 };
    std.mem.sort(f64, totals, {}, f64Less);
    var sum: f64 = 0;
    for (totals) |t| sum += t;
    const n: f64 = @floatFromInt(totals.len);
    return .{
        .name = name,
        .n = totals.len,
        .mean = sum / n,
        .min = totals[0],
        .max = totals[totals.len - 1],
        .p25 = percentile(totals, 25),
        .p75 = percentile(totals, 75),
    };
}

fn f64Less(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// Linear interpolation between order statistics (numpy's default):
/// p% of the way through the sorted values.
pub fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const pos = p / 100 * @as(f64, @floatFromInt(sorted.len - 1));
    const lo = @floor(pos);
    const li: usize = @intFromFloat(lo);
    const hi: usize = @min(li + 1, sorted.len - 1);
    return sorted[li] + (sorted[hi] - sorted[li]) * (pos - lo);
}

const Bucket = struct {
    scores: std.ArrayList(f64) = .empty,
    raw_sum: f64 = 0,
    coll: ?*const policy.Collection = null,
    in_band: usize = 0,
    below: usize = 0,
    above: usize = 0,
    oop: usize = 0,

    fn add(b: *Bucket, a: std.mem.Allocator, row: Row) !void {
        try b.scores.append(a, row.score());
        b.raw_sum += row.sc.total;
        if (row.coll) |c| b.coll = c;
        if (row.verdict) |v| {
            switch (v.band) {
                .in => b.in_band += 1,
                .below => b.below += 1,
                .above => b.above += 1,
                .unbanded => {},
            }
            if (v.violations.len > 0) b.oop += 1;
        }
    }

    fn stats(b: *Bucket, name: []const u8) Stats {
        var s = statsOf(name, b.scores.items);
        if (s.n > 0) s.raw_mean = b.raw_sum / @as(f64, @floatFromInt(s.n));
        s.coll = b.coll;
        s.in_band = b.in_band;
        s.below = b.below;
        s.above = b.above;
        s.oop = b.oop;
        return s;
    }
};

/// Group scores per collection, sort groups by mean desc (name asc on
/// ties), then append `overall`. Scores are raw totals without a
/// policy and policy scores for policed docs with one.
fn collectStats(ctx: *Ctx, rows: []const Row) ![]Stats {
    var by_group: std.StringHashMap(Bucket) = .init(ctx.arena);
    var all: Bucket = .{};
    for (rows) |row| {
        const g = try by_group.getOrPut(row.group);
        if (!g.found_existing) g.value_ptr.* = .{};
        try g.value_ptr.add(ctx.arena, row);
        try all.add(ctx.arena, row);
    }
    var out: std.ArrayList(Stats) = .empty;
    var it = by_group.iterator();
    while (it.next()) |e|
        try out.append(ctx.arena, e.value_ptr.stats(e.key_ptr.*));
    std.mem.sort(Stats, out.items, {}, struct {
        fn less(_: void, a: Stats, b: Stats) bool {
            if (a.mean != b.mean) return a.mean > b.mean;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var overall = all.stats("overall");
    overall.coll = null;
    try out.append(ctx.arena, overall);
    return out.items;
}

/// The sorted table: header, one row per group (mean desc), `overall`.
/// Under a policy the stats columns are policy scores, and each row adds
/// the raw mean, the per-doc band, in/below/above-band counts, docs out
/// of policy, and `state`: `drift` when the mean is under the
/// collection's `mean_min` floor, `ok` otherwise, `-` when unpoliced.
fn writeRollup(ctx: *Ctx, w: *std.Io.Writer, rows: []const Row, with_policy: bool) !void {
    const stats = try collectStats(ctx, rows);
    var width: usize = "collection".len;
    for (stats) |s| width = @max(width, s.name.len);

    try padRight(w, "collection", width);
    try w.writeAll("       n    mean     min     max     p25     p75");
    try w.writeAll(if (with_policy) "     raw       band     in  below  above    oop  state\n" else "\n");
    var buf: [32]u8 = undefined;
    for (stats) |s| {
        try padRight(w, s.name, width);
        try w.writeAll("  ");
        try cell(w, &buf, "{d}", .{s.n});
        try cell(w, &buf, "{d:.1}", .{s.mean});
        try cell(w, &buf, "{d:.1}", .{s.min});
        try cell(w, &buf, "{d:.1}", .{s.max});
        try cell(w, &buf, "{d:.1}", .{s.p25});
        try cell(w, &buf, "{d:.1}", .{s.p75});
        if (with_policy) {
            try cell(w, &buf, "{d:.1}", .{s.raw_mean});
            const band = try bandText(&buf, if (s.coll) |c| c.score else .{});
            try w.splatByteAll(' ', 11 -| band.len);
            try w.writeAll(band);
            try cell(w, &buf, "{d}", .{s.in_band});
            try cell(w, &buf, "{d}", .{s.below});
            try cell(w, &buf, "{d}", .{s.above});
            try cell(w, &buf, "{d}", .{s.oop});
            const state = if (s.coll) |c|
                (if (c.score.mean_min) |m| (if (s.mean < m) "drift" else "ok") else "ok")
            else
                "-";
            try w.print("  {s}", .{state});
        }
        try w.writeAll("\n");
    }
}

/// `min-max`, `min-`, `-max`, or `-` when unbanded.
fn bandText(buf: []u8, r: policy.ScoreRule) ![]const u8 {
    if (r.min == null and r.max == null) return "-";
    var w: std.Io.Writer = .fixed(buf);
    if (r.min) |m| try w.print("{d:.1}", .{m});
    try w.writeAll("-");
    if (r.max) |m| try w.print("{d:.1}", .{m});
    return w.buffered();
}

/// Every policed doc with a violation, collection then path order, one
/// line each: `collection  path  rule[:signal value>limit] ...`. Always
/// printed under a policy — a zero count is the all-clear.
fn writeOutOfPolicy(ctx: *Ctx, w: *std.Io.Writer, rows: []const Row) !void {
    var hits: std.ArrayList(Row) = .empty;
    for (rows) |row| {
        if (row.verdict) |v| if (v.violations.len > 0) try hits.append(ctx.arena, row);
    }
    std.mem.sort(Row, hits.items, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            const o = std.mem.order(u8, a.group, b.group);
            if (o != .eq) return o == .lt;
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.less);
    try w.print("\nout of policy ({d} doc{s}):\n", .{ hits.items.len, if (hits.items.len == 1) "" else "s" });
    for (hits.items) |row| {
        try w.print("  {s}  {s} ", .{ row.group, row.rel });
        for (row.verdict.?.violations) |vi| {
            try w.print(" {s}", .{@tagName(vi.rule)});
            if (vi.signal) |s| try w.print(":{s}", .{s});
            switch (vi.rule) {
                .forbid => try w.print("={d:.0}", .{vi.value}),
                .cap => try w.print("={d:.0}>{d:.0}", .{ vi.value, vi.limit }),
                .@"above-band" => try w.print("={d:.2}>{d:.1}", .{ vi.value, vi.limit }),
            }
        }
        try w.writeAll("\n");
    }
}

/// Right-aligned value in a 7-wide column (matches the header).
fn cell(w: *std.Io.Writer, buf: []u8, comptime fmt: []const u8, v: anytype) !void {
    const s = try std.fmt.bufPrint(buf, fmt, v);
    if (s.len < 7) try w.splatByteAll(' ', 7 - s.len);
    try w.writeAll(s);
}

fn padRight(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}

/// The doc's `--below` limit: its collection's `score.min` when the
/// policy sets one (genre beats the global number), else `global`;
/// null = not listed.
fn belowLimit(row: Row, global: ?f64) ?f64 {
    if (row.coll) |c| if (c.score.min) |m| return m;
    return global;
}

/// The `--below` hit list: every doc whose score is under its limit
/// (raw total under `limit` without a policy; see `belowLimit` with
/// one), worst first (path order on ties — the comparator is a total
/// order). Under a policy each line also shows the limit it missed.
fn writeBelow(ctx: *Ctx, w: *std.Io.Writer, rows: []const Row, limit: ?f64, with_policy: bool) !void {
    var hits: std.ArrayList(Row) = .empty;
    for (rows) |row| {
        const l = belowLimit(row, limit) orelse continue;
        if (row.score() < l) try hits.append(ctx.arena, row);
    }
    std.mem.sort(Row, hits.items, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            if (a.score() != b.score()) return a.score() < b.score();
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.less);
    const plural = if (hits.items.len == 1) "" else "s";
    if (!with_policy) {
        try w.print("\nbelow {d:.1} ({d} doc{s}):\n", .{ limit.?, hits.items.len, plural });
    } else if (limit) |l| {
        try w.print("\nbelow band, else {d:.1} ({d} doc{s}):\n", .{ l, hits.items.len, plural });
    } else {
        try w.print("\nbelow band ({d} doc{s}):\n", .{ hits.items.len, plural });
    }
    var buf: [32]u8 = undefined;
    for (hits.items) |row| {
        const s = try std.fmt.bufPrint(&buf, "{d:.2}", .{row.score()});
        try w.writeAll("  ");
        if (s.len < 7) try w.splatByteAll(' ', 7 - s.len);
        try w.writeAll(s);
        if (with_policy) try w.print(" < {d:.1}", .{belowLimit(row, limit).?});
        try w.print("  {s}\n", .{row.rel});
    }
}

fn usage(msg: ?[]const u8) u8 {
    if (msg) |m| std.debug.print("knap-mcp: {s}\n", .{m});
    std.debug.print("usage: knap-mcp audit <dir> [--glob <p>] [--per-dir | --per-glob <name=glob,...>] [--below <score|band>] [--jsonl <file>] [--policy <file> | --no-policy]\n", .{});
    return 1;
}

fn fail(ctx: *Ctx) u8 {
    std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "audit failed"});
    return 1;
}

fn failf(ctx: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
    ctx.err_msg = std.fmt.allocPrint(ctx.arena, fmt, args) catch "out of memory";
    return fail(ctx);
}

// --- Tests -------------------------------------------------------------------

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map, store_dir: []const u8) Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = store_dir,
        .project_root = ".",
    };
}

test "globMatch: ** crosses segments, * and ? stay inside one" {
    try std.testing.expect(globMatch("**/*.md", "a.md"));
    try std.testing.expect(globMatch("**/*.md", "x/y/a.md"));
    try std.testing.expect(!globMatch("**/*.md", "x/y/a.txt"));
    try std.testing.expect(!globMatch("*.md", "x/a.md"));
    try std.testing.expect(globMatch("mascots/**", "mascots/003.md"));
    try std.testing.expect(globMatch("mascots/**", "mascots/a/b.md"));
    try std.testing.expect(!globMatch("mascots/**", "lorelog/1.md"));
    try std.testing.expect(globMatch("posts/??.md", "posts/ab.md"));
    try std.testing.expect(!globMatch("posts/??.md", "posts/abc.md"));
    try std.testing.expect(globMatch("a/*/c.md", "a/b/c.md"));
    try std.testing.expect(!globMatch("a/*/c.md", "a/b/d/c.md"));
    try std.testing.expect(globMatch("a/**/c.md", "a/b/d/c.md"));
    try std.testing.expect(globMatch("**", "anything/at/all.md"));
}

test "percentile interpolates between order statistics" {
    var vals = [_]f64{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(f64, 17.5), percentile(&vals, 25));
    try std.testing.expectEqual(@as(f64, 32.5), percentile(&vals, 75));
    try std.testing.expectEqual(@as(f64, 10), percentile(&vals, 0));
    try std.testing.expectEqual(@as(f64, 40), percentile(&vals, 100));
    var one = [_]f64{7};
    try std.testing.expectEqual(@as(f64, 7), percentile(&one, 50));
}

test "groupName: first segment, stem for root files, --per-dir, --per-glob" {
    const plain: Opts = .{ .dir = "d" };
    try std.testing.expectEqualStrings("mascots", groupName("mascots/003.md", plain));
    try std.testing.expectEqualStrings("index", groupName("index.md", plain));
    const per_dir: Opts = .{ .dir = "d", .per_dir = true };
    try std.testing.expectEqualStrings("a/b", groupName("a/b/c.md", per_dir));
    try std.testing.expectEqualStrings(".", groupName("top.md", per_dir));
    const groups = [_]Group{.{ .name = "verse", .pattern = "haikus/**" }};
    const per_glob: Opts = .{ .dir = "d", .per_glob = &groups };
    try std.testing.expectEqualStrings("verse", groupName("haikus/HA-1.md", per_glob));
    try std.testing.expectEqualStrings("posts", groupName("posts/p.md", per_glob));
}

test "auditTree: path-sorted rows, groups, warnings folded in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/tree", .{tmp.sub_path});
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, try std.fmt.allocPrint(a, "{s}/beta", .{root}));
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, try std.fmt.allocPrint(a, "{s}/alpha", .{root}));
    const rich =
        \\---
        \\title: Rich
        \\id: alpha-1
        \\---
        \\
        \\# Heading
        \\
        \\A paragraph with a [[wikilink]] and a [link](https://example.com) and
        \\enough prose to matter for the word count of this small test document.
        \\
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\> [!note] Callout
        \\> body
        \\
    ;
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/beta/b.md", .{root}),
        .data = "just a stub\n",
    });
    // Written second but sorts first; also carries an unclosed fence so a
    // format_check warning rides along in the row.
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/alpha/a.md", .{root}),
        .data = rich ++ "```\n",
    });
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/alpha/skip.txt", .{root}),
        .data = "not markdown by name\n",
    });
    var ctx = testCtx(a, &env, root);
    const rows = try auditTree(&ctx, .{ .dir = root });
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("alpha/a.md", rows[0].rel);
    try std.testing.expectEqualStrings("alpha", rows[0].group);
    try std.testing.expectEqualStrings("beta/b.md", rows[1].rel);
    try std.testing.expect(rows[1].sc.total < rows[0].sc.total);
    var found_unclosed = false;
    for (rows[0].sc.warnings) |w| {
        if (std.mem.eql(u8, w.rule, "unclosed-fence")) found_unclosed = true;
    }
    try std.testing.expect(found_unclosed);
}

test "writeRollup and writeBelow: group order, below hit list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env, "unused");
    const mk = struct {
        fn row(alloc: std.mem.Allocator, rel: []const u8, group: []const u8, doc: []const u8) Row {
            return .{ .rel = rel, .group = group, .sc = density.score(alloc, doc) catch unreachable };
        }
    }.row;
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "# T\n\n");
    for (0..220) |_| try long.appendSlice(a, "word ");
    try long.appendSlice(a, "\n[^x]: note\n");
    const rows = [_]Row{
        mk(a, "b/1.md", "b", "# T\n\nshort\n"),
        mk(a, "a/1.md", "a", long.items),
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try writeRollup(&ctx, &out.writer, &rows, false);
    const text = out.written();
    // b (low mean) sorts after a (high mean); overall is last.
    const ia = std.mem.indexOf(u8, text, "a ").?;
    const ib = std.mem.indexOf(u8, text, "b ").?;
    const io_ = std.mem.indexOf(u8, text, "overall").?;
    try std.testing.expect(ia < ib and ib < io_);
    // The long doc beats the stub, so --below <stub+1> hits exactly one.
    const stub_total = rows[0].sc.total;
    out = .init(a);
    try writeBelow(&ctx, &out.writer, &rows, stub_total + 1, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b/1.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a/1.md") == null);
}

test "policy: haiku with a table is out of policy, bands drive --below, rows carry verdicts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    for ([_][]const u8{ "haikus", "mascots", "posts" }) |d|
        try std.Io.Dir.createDirPath(.cwd(), std.testing.io, try std.fmt.allocPrint(a, "{s}/{s}", .{ root, d }));
    const haiku = "---\ntitle: H\nid: haikus/HAI-1\n---\n\n# H\n\nFault rerouted now  \nto a desk that cannot speak  \nritual is safe\n";
    const files = [_][2][]const u8{
        .{ "haikus/hai-1.md", haiku },
        .{ "haikus/hai-2.md", haiku ++ "\n| a | b |\n|---|---|\n| 1 | 2 |\n" },
        .{ "mascots/001.md", "# M\n\nshort mascot stub\n" },
        .{ "posts/p.md", "# P\n\nunpoliced\n" },
    };
    for (files) |f| try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f[0] }),
        .data = f[1],
    });
    // Discovered next to the audit root (a site keeps it beside content/).
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/knap-policy.json", .{tmp.sub_path}),
        .data =
        \\{"schema":"knap-policy/1","collections":[
        \\ {"name":"haikus","glob":"haikus/**","signals":{"tables":"forbid"},"score":{"min":0,"max":20}},
        \\ {"name":"mascots","glob":"mascots/**","score":{"min":25}}]}
        ,
    });
    var ctx = testCtx(a, &env, root);
    const found = (try policy.discover(&ctx, root)).?;
    try std.testing.expect(std.mem.endsWith(u8, found, "/../knap-policy.json"));
    const pol = try policy.load(&ctx, found);
    const rows = try auditTree(&ctx, .{ .dir = root, .policy = &pol });
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings("haikus", rows[0].group);
    try std.testing.expectEqual(policy.Band.in, rows[0].verdict.?.band);
    try std.testing.expectEqual(@as(usize, 0), rows[0].verdict.?.violations.len);
    try std.testing.expectEqual(@as(usize, 1), rows[1].verdict.?.violations.len);
    try std.testing.expectEqual(policy.Band.below, rows[2].verdict.?.band);
    try std.testing.expectEqualStrings("unpoliced:posts", rows[3].group);
    try std.testing.expect(rows[3].verdict == null);

    var out: std.Io.Writer.Allocating = .init(a);
    try writeRow(&out.writer, rows[1], true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(),
        \\"policy":{"collection":"haikus",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(),
        \\"violations":[{"rule":"forbid","signal":"tables","value":1.00,"limit":0.00}]}}
    ) != null);
    out = .init(a);
    try writeRow(&out.writer, rows[3], true);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), ",\"policy\":{\"collection\":null}}\n"));
    out = .init(a);
    try writeRow(&out.writer, rows[3], false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "policy") == null);

    out = .init(a);
    try writeOutOfPolicy(&ctx, &out.writer, rows);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "out of policy (1 doc)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "haikus/hai-2.md  forbid:tables=1") != null);

    // --below band: only the mascot (under its 25 floor); haikus sit in
    // their band and posts have none.
    out = .init(a);
    try writeBelow(&ctx, &out.writer, rows, null, true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "below band (1 doc)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "< 25.0  mascots/001.md") != null);
    // A global number still covers unpoliced docs; the band wins for the rest.
    out = .init(a);
    try writeBelow(&ctx, &out.writer, rows, 50, true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "posts/p.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "haikus/") == null);

    out = .init(a);
    try writeRollup(&ctx, &out.writer, rows, true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0.0-20.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "unpoliced:posts") != null);
}
