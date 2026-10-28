//! Per-collection scoring policy (FILED-POL, #255): `knap-policy.json`.
//!
//! A corpus is not one genre. A haiku is three lines, so a haiku that
//! scores 6 is correct and a haiku with a table is damage. The policy
//! names collections by glob and says, per collection, which density
//! signals are scored, exempt, capped or forbidden, what score band a doc
//! is expected to sit in, the collection-mean floor below which the
//! collection has regressed, and where (if anywhere) a voice pass may
//! touch it.
//!
//! Policy only judges. It never edits a doc and never changes the raw
//! density total (`density/3` stays the scorer contract): it adds a
//! policy score next to it, plus violations as data. Unknown keys,
//! unknown signals, unknown tones and unknown regions are load errors,
//! with the JSON path in the message — a typo must not silently widen a
//! policy. Full schema: docs/policy.md.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const density = @import("density.zig");
const Tone = @import("voice.zig").Tone;

pub const schema = "knap-policy/1";
/// Discovered in the audit root or its parent (a site keeps
/// `knap-policy.json` next to `content/`).
pub const file_name = "knap-policy.json";
pub const env_var = "KNAP_POLICY";

const max_policy_bytes = 1 << 20;

/// Per-glob `**` segment limit, enforced at load: a real collection
/// glob uses one or two (`docs/**`, `**/*.md`), and even with the
/// polynomial matcher a policy file can carry thousands — an absurd
/// count only ever comes from a planted file, so it fails loudly.
const max_globstar_segments = 64;

/// What a signal is to a collection.
pub const Mode = enum {
    /// Counts toward the policy score as it does toward the raw total.
    score,
    /// Not scored: its contribution is dropped and the score is
    /// re-normalized over the remaining weight, so its absence doesn't
    /// drag the collection down and its presence earns nothing (an
    /// upgrade loop gains no score by adding it). Not a violation.
    exempt,
    /// Must be absent: any occurrence is a violation and earns no
    /// credit. Not re-normalized — absence is the norm the collection's
    /// band is set against, so the policy score stays on the raw scale.
    forbid,
};

pub const SignalRule = struct {
    mode: Mode = .score,
    /// Per-doc ceiling on the signal's raw count; above it is a
    /// violation. Scoring is unchanged.
    cap: ?usize = null,
};

/// Doc regions a voice pass may rewrite. Policy declares; the voice
/// walker (FILED-VOICE) classifies.
pub const Region = enum {
    /// Prose paragraphs.
    paragraphs,
    /// Hard-broken line groups: stanzas, haiku, limerick lines.
    verse,
    list_items,
    headings,
};

pub const Voice = struct {
    tones: []const Tone = &.{},
    regions: []const Region = &.{},
};

pub const ScoreRule = struct {
    /// Per-doc band on the policy score. Under `min` is an upgrade
    /// candidate (`--below`); over `max` is a violation — an over-upgraded
    /// doc is how genre gets sanded off.
    min: ?f64 = null,
    max: ?f64 = null,
    /// Collection floor: a collection mean under this has regressed.
    mean_min: ?f64 = null,
};

pub const Collection = struct {
    name: []const u8,
    /// Audit-root-relative globs (audit.globMatch syntax); any match.
    globs: []const []const u8,
    note: []const u8 = "",
    signals: std.EnumArray(density.Id, SignalRule) = .initFill(.{}),
    score: ScoreRule = .{},
    /// Null = undeclared, which denies every voice pass.
    voice: ?Voice = null,
};

pub const Policy = struct {
    /// Where it was loaded from, for reports.
    path: []const u8,
    note: []const u8 = "",
    collections: []const Collection,

    /// First collection with a matching glob, in file order.
    pub fn match(p: *const Policy, rel: []const u8) ?*const Collection {
        for (p.collections) |*c| {
            for (c.globs) |g| if (globMatch(g, rel)) return c;
        }
        return null;
    }
};

const globMatch = @import("tools/audit.zig").globMatch;

/// True only when the doc's collection declares voice with this tone
/// and this region. No collection, or no voice block, is a no.
pub fn voiceAllowed(c: ?*const Collection, tone: Tone, region: Region) bool {
    const v = (c orelse return false).voice orelse return false;
    return std.mem.indexOfScalar(Tone, v.tones, tone) != null and
        std.mem.indexOfScalar(Region, v.regions, region) != null;
}

// --- Judging -----------------------------------------------------------------

pub const Band = enum { in, below, above, unbanded };

pub const Rule = enum {
    forbid,
    cap,
    @"above-band",
};

pub const Violation = struct {
    rule: Rule,
    /// Signal name for forbid/cap; null for a band breach.
    signal: ?[]const u8 = null,
    /// Raw count (forbid/cap) or policy score (band).
    value: f64,
    /// 0 for forbid, the cap, or the band max.
    limit: f64,
};

pub const Verdict = struct {
    score: f64,
    band: Band,
    violations: []const Violation,
};

/// Policy score: density contributions with exempt and forbidden
/// signals dropped, the positive part re-normalized over the weight
/// left after exemptions, then clamped like the raw total. With nothing
/// exempt or forbidden-and-present it equals `sc.total`.
pub fn policyScore(c: *const Collection, sc: density.Score) f64 {
    var pos: f64 = 0;
    var neg: f64 = 0;
    var dropped: f64 = 0;
    for (sc.signals, 0..) |sig, i| {
        const mode = if (i < density.specs.len) c.signals.get(density.specs[i].id).mode else .score;
        if (mode != .score) {
            if (mode == .exempt and sig.weight > 0) dropped += sig.weight;
            continue;
        }
        if (sig.contribution >= 0) pos += sig.contribution else neg += sig.contribution;
    }
    const kept = 100 - dropped;
    const scaled = if (kept > 0) pos * 100 / kept else 0;
    return std.math.clamp(scaled + neg, 0, 100);
}

pub fn judge(arena: std.mem.Allocator, c: *const Collection, sc: density.Score) !Verdict {
    var out: std.ArrayList(Violation) = .empty;
    for (density.specs, sc.signals[0..density.specs.len]) |sp, sig| {
        const r = c.signals.get(sp.id);
        const raw: f64 = @floatFromInt(sig.raw);
        if (r.mode == .forbid and sig.raw > 0)
            try out.append(arena, .{ .rule = .forbid, .signal = sig.name, .value = raw, .limit = 0 });
        if (r.cap) |cap| if (sig.raw > cap)
            try out.append(arena, .{ .rule = .cap, .signal = sig.name, .value = raw, .limit = @floatFromInt(cap) });
    }
    const s = policyScore(c, sc);
    var band: Band = .unbanded;
    if (c.score.min != null or c.score.max != null) band = .in;
    if (c.score.min) |m| if (s < m) {
        band = .below;
    };
    if (c.score.max) |m| if (s > m) {
        band = .above;
        try out.append(arena, .{ .rule = .@"above-band", .value = s, .limit = m });
    };
    return .{ .score = s, .band = band, .violations = out.items };
}

// --- Loading -----------------------------------------------------------------

/// `--policy` wins, then $KNAP_POLICY, then `<dir>/knap-policy.json`,
/// then `<dir>/../knap-policy.json`. Null when none exists.
pub fn discover(ctx: *Ctx, dir: []const u8) !?[]const u8 {
    if (ctx.environ.get(env_var)) |p| if (p.len > 0) return p;
    const here = try std.fmt.allocPrint(ctx.arena, "{s}/" ++ file_name, .{dir});
    const up = try std.fmt.allocPrint(ctx.arena, "{s}/../" ++ file_name, .{dir});
    for ([_][]const u8{ here, up }) |p| {
        std.Io.Dir.access(.cwd(), ctx.io, p, .{}) catch continue;
        return p;
    }
    return null;
}

pub fn load(ctx: *Ctx, path: []const u8) !Policy {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(max_policy_bytes)) catch
        return ctx.fail("policy {s}: cannot read", .{path});
    return parse(ctx, path, bytes);
}

pub fn parse(ctx: *Ctx, path: []const u8, bytes: []const u8) !Policy {
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, bytes, .{}) catch |e|
        return ctx.fail("policy {s}: invalid JSON ({s})", .{ path, @errorName(e) });
    var p: Parser = .{ .ctx = ctx, .path = path };
    return p.policy(v);
}

const Parser = struct {
    ctx: *Ctx,
    path: []const u8,

    fn err(p: *Parser, comptime fmt: []const u8, args: anytype) error{ToolFailed} {
        const msg = std.fmt.allocPrint(p.ctx.arena, fmt, args) catch "out of memory";
        return p.ctx.fail("policy {s}: {s}", .{ p.path, msg });
    }

    fn object(p: *Parser, v: std.json.Value, at: []const u8, comptime keys: []const []const u8) !std.json.ObjectMap {
        if (v != .object) return p.err("{s}: expected an object", .{at});
        var it = v.object.iterator();
        outer: while (it.next()) |e| {
            inline for (keys) |k| if (std.mem.eql(u8, e.key_ptr.*, k)) continue :outer;
            return p.err("{s}: unknown key '{s}' (allowed: {s})", .{ at, e.key_ptr.*, comptime joinNames(keys) });
        }
        return v.object;
    }

    fn string(p: *Parser, v: std.json.Value, at: []const u8) ![]const u8 {
        if (v != .string) return p.err("{s}: expected a string", .{at});
        return v.string;
    }

    fn number(p: *Parser, v: std.json.Value, at: []const u8) !f64 {
        const n: f64 = switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return p.err("{s}: expected a number", .{at}),
        };
        if (n < 0 or n > 100) return p.err("{s}: {d} is outside the 0..100 score range", .{ at, n });
        return n;
    }

    fn array(p: *Parser, v: std.json.Value, at: []const u8) ![]const std.json.Value {
        if (v != .array) return p.err("{s}: expected an array", .{at});
        return v.array.items;
    }

    fn fmtPath(p: *Parser, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(p.ctx.arena, fmt, args);
    }

    fn policy(p: *Parser, v: std.json.Value) !Policy {
        const o = try p.object(v, "top level", &.{ "schema", "note", "collections" });
        const sv = try p.string(o.get("schema") orelse return p.err("top level: missing \"schema\"", .{}), "schema");
        if (!std.mem.eql(u8, sv, schema))
            return p.err("schema: '{s}' is not supported (want '{s}')", .{ sv, schema });
        const note = if (o.get("note")) |n| try p.string(n, "note") else "";
        const items = try p.array(o.get("collections") orelse return p.err("top level: missing \"collections\"", .{}), "collections");
        if (items.len == 0) return p.err("collections: empty", .{});
        const out = try p.ctx.arena.alloc(Collection, items.len);
        for (items, out, 0..) |item, *c, i| {
            c.* = try p.collection(item, try p.fmtPath("collections[{d}]", .{i}));
            for (out[0..i]) |prev| if (std.mem.eql(u8, prev.name, c.name))
                return p.err("collections[{d}]: duplicate name '{s}'", .{ i, c.name });
        }
        return .{ .path = p.path, .note = note, .collections = out };
    }

    fn collection(p: *Parser, v: std.json.Value, where: []const u8) !Collection {
        const o = try p.object(v, where, &.{ "name", "glob", "note", "signals", "score", "voice" });
        const name = try p.string(o.get("name") orelse return p.err("{s}: missing \"name\"", .{where}), try p.fmtPath("{s}.name", .{where}));
        if (name.len == 0) return p.err("{s}.name: empty", .{where});
        var c: Collection = .{ .name = name, .globs = try p.globs(o.get("glob") orelse
            return p.err("{s}: missing \"glob\"", .{where}), try p.fmtPath("{s}.glob", .{where})) };
        if (o.get("note")) |n| c.note = try p.string(n, try p.fmtPath("{s}.note", .{where}));
        if (o.get("signals")) |s| try p.signals(s, try p.fmtPath("{s}.signals", .{where}), &c.signals);
        if (o.get("score")) |s| c.score = try p.scoreRule(s, try p.fmtPath("{s}.score", .{where}));
        if (o.get("voice")) |s| c.voice = try p.voice(s, try p.fmtPath("{s}.voice", .{where}));
        return c;
    }

    fn globs(p: *Parser, v: std.json.Value, where: []const u8) ![]const []const u8 {
        if (v == .string) {
            const one = try p.ctx.arena.alloc([]const u8, 1);
            one[0] = try p.glob(v.string, where);
            return one;
        }
        const items = p.array(v, where) catch return p.err("{s}: expected a glob string or an array of them", .{where});
        if (items.len == 0) return p.err("{s}: empty glob list", .{where});
        const out = try p.ctx.arena.alloc([]const u8, items.len);
        for (items, out, 0..) |item, *g, i| {
            g.* = try p.glob(try p.string(item, try p.fmtPath("{s}[{d}]", .{ where, i })), try p.fmtPath("{s}[{d}]", .{ where, i }));
        }
        return out;
    }

    /// One validated glob string: non-empty, and under the `**` segment
    /// cap — whole-segment `**` is what the matcher expands, so e.g.
    /// `a/**b` doesn't count.
    fn glob(p: *Parser, g: []const u8, where: []const u8) ![]const u8 {
        if (g.len == 0) return p.err("{s}: empty glob", .{where});
        var stars: usize = 0;
        var it = std.mem.splitScalar(u8, g, '/');
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, "**")) stars += 1;
        }
        if (stars > max_globstar_segments)
            return p.err("{s}: too many '**' segments ({d}; limit {d})", .{ where, stars, max_globstar_segments });
        return g;
    }

    fn signals(p: *Parser, v: std.json.Value, where: []const u8, out: *std.EnumArray(density.Id, SignalRule)) !void {
        if (v != .object) return p.err("{s}: expected an object", .{where});
        var it = v.object.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const id = std.meta.stringToEnum(density.Id, name) orelse .overload;
            if (id == .overload)
                return p.err("{s}: unknown signal '{s}' (known: {s})", .{ where, name, comptime signalNames() });
            out.set(id, try p.signalRule(e.value_ptr.*, try p.fmtPath("{s}.{s}", .{ where, name })));
        }
    }

    fn signalRule(p: *Parser, v: std.json.Value, where: []const u8) !SignalRule {
        if (v == .string) {
            const m = std.meta.stringToEnum(Mode, v.string) orelse
                return p.err("{s}: unknown mode '{s}' (allowed: score, exempt, forbid, or {{\"cap\": n}})", .{ where, v.string });
            return .{ .mode = m };
        }
        const o = p.object(v, where, &.{"cap"}) catch |e| {
            if (v != .object) return p.err("{s}: expected \"score\", \"exempt\", \"forbid\" or {{\"cap\": n}}", .{where});
            return e;
        };
        const cv = o.get("cap") orelse return p.err("{s}: missing \"cap\"", .{where});
        if (cv != .integer or cv.integer < 0) return p.err("{s}.cap: expected a non-negative integer", .{where});
        return .{ .cap = @intCast(cv.integer) };
    }

    fn scoreRule(p: *Parser, v: std.json.Value, where: []const u8) !ScoreRule {
        const o = try p.object(v, where, &.{ "min", "max", "mean_min" });
        var r: ScoreRule = .{};
        if (o.get("min")) |n| r.min = try p.number(n, try p.fmtPath("{s}.min", .{where}));
        if (o.get("max")) |n| r.max = try p.number(n, try p.fmtPath("{s}.max", .{where}));
        if (o.get("mean_min")) |n| r.mean_min = try p.number(n, try p.fmtPath("{s}.mean_min", .{where}));
        if (r.min != null and r.max != null and r.min.? > r.max.?)
            return p.err("{s}: min {d} is above max {d}", .{ where, r.min.?, r.max.? });
        return r;
    }

    fn voice(p: *Parser, v: std.json.Value, where: []const u8) !Voice {
        const o = try p.object(v, where, &.{ "tones", "regions" });
        return .{
            .tones = try p.enumList(Tone, o.get("tones") orelse return p.err("{s}: missing \"tones\" ([] denies voice)", .{where}), try p.fmtPath("{s}.tones", .{where})),
            .regions = try p.enumList(Region, o.get("regions") orelse return p.err("{s}: missing \"regions\" ([] denies voice)", .{where}), try p.fmtPath("{s}.regions", .{where})),
        };
    }

    fn enumList(p: *Parser, comptime E: type, v: std.json.Value, where: []const u8) ![]const E {
        const items = try p.array(v, where);
        const out = try p.ctx.arena.alloc(E, items.len);
        for (items, out, 0..) |item, *e, i| {
            const s = try p.string(item, try p.fmtPath("{s}[{d}]", .{ where, i }));
            e.* = std.meta.stringToEnum(E, s) orelse
                return p.err("{s}[{d}]: unknown value '{s}' (allowed: {s})", .{ where, i, s, comptime joinNames(std.meta.fieldNames(E)) });
            if (std.mem.indexOfScalar(E, out[0..i], e.*) != null)
                return p.err("{s}[{d}]: duplicate '{s}'", .{ where, i, s });
        }
        return out;
    }
};

fn joinNames(comptime names: []const []const u8) []const u8 {
    comptime var s: []const u8 = "";
    inline for (names, 0..) |n, i| s = s ++ (if (i > 0) ", " else "") ++ n;
    return s;
}

/// Every density spec id except `overload`, which is a meta-penalty over
/// the others and not a thing a doc contains.
fn signalNames() []const u8 {
    comptime var s: []const u8 = "";
    inline for (density.specs, 0..) |sp, i| {
        if (sp.id == .overload) continue;
        s = s ++ (if (i > 0) ", " else "") ++ @tagName(sp.id);
    }
    return s;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map) Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = "unused",
        .project_root = ".",
    };
}

const verse_policy =
    \\{"schema":"knap-policy/1","collections":[
    \\ {"name":"haikus","glob":["haikus/**"],
    \\  "signals":{"tables":"forbid","callouts":"forbid","footnotes":{"cap":0},"wikilinks":"exempt"},
    \\  "score":{"min":0,"max":20,"mean_min":3},
    \\  "voice":{"tones":[],"regions":[]}},
    \\ {"name":"mascots","glob":"mascots/**","score":{"min":15},
    \\  "voice":{"tones":["mild","feral"],"regions":["paragraphs","list_items"]}}
    \\]}
;

fn expectRejects(src: []const u8, needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    try testing.expectError(error.ToolFailed, parse(&ctx, "p.json", src));
    if (std.mem.indexOf(u8, ctx.err_msg, needle) == null) {
        std.debug.print("error '{s}' lacks '{s}'\n", .{ ctx.err_msg, needle });
        return error.TestUnexpectedResult;
    }
}

test "parse: collections, signal rules, bands, voice; first glob match wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    const p = try parse(&ctx, "p.json", verse_policy);
    try testing.expectEqual(@as(usize, 2), p.collections.len);
    const h = p.match("haikus/hai-003.md").?;
    try testing.expectEqualStrings("haikus", h.name);
    try testing.expectEqual(Mode.forbid, h.signals.get(.tables).mode);
    try testing.expectEqual(Mode.exempt, h.signals.get(.wikilinks).mode);
    try testing.expectEqual(@as(?usize, 0), h.signals.get(.footnotes).cap);
    try testing.expectEqual(Mode.score, h.signals.get(.lists).mode);
    try testing.expectEqual(@as(?f64, 20), h.score.max);
    try testing.expect(p.match("lorelog/x.md") == null);
    const m = p.match("mascots/003.md");
    try testing.expect(voiceAllowed(m, .feral, .paragraphs));
    try testing.expect(!voiceAllowed(m, .spicy, .paragraphs));
    try testing.expect(!voiceAllowed(m, .mild, .verse));
    try testing.expect(!voiceAllowed(h, .mild, .paragraphs));
    try testing.expect(!voiceAllowed(null, .mild, .paragraphs));
}

test "parse rejects unknown keys, signals, modes, tones, regions loudly" {
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[],"extra":1}
    , "top level: unknown key 'extra'");
    try expectRejects(
        \\{"schema":"knap-policy/2","collections":[{"name":"a","glob":"a/**"}]}
    , "not supported");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","bands":{}}]}
    , "collections[0]: unknown key 'bands'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","signals":{"tabels":"forbid"}}]}
    , "collections[0].signals: unknown signal 'tabels'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","signals":{"overload":"exempt"}}]}
    , "unknown signal 'overload'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","signals":{"tables":"ban"}}]}
    , "collections[0].signals.tables: unknown mode 'ban'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","signals":{"tables":{"cap":1,"soft":true}}}]}
    , "signals.tables: unknown key 'soft'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","score":{"min":30,"max":20}}]}
    , "min 30 is above max 20");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","score":{"max":120}}]}
    , "outside the 0..100");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","voice":{"tones":["rude"],"regions":[]}}]}
    , "voice.tones[0]: unknown value 'rude'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","voice":{"tones":[],"regions":["stanzas"]}}]}
    , "voice.regions[0]: unknown value 'stanzas'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**","voice":{"tones":["mild"]}}]}
    , "missing \"regions\"");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a","glob":"a/**"},{"name":"a","glob":"b/**"}]}
    , "duplicate name 'a'");
    try expectRejects(
        \\{"schema":"knap-policy/1","collections":[{"name":"a"}]}
    , "missing \"glob\"");
    try expectRejects("{\"schema\":", "invalid JSON");
}

test "parse: globs over the '**' segment cap are rejected at load" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "{\"schema\":\"knap-policy/1\",\"collections\":[{\"name\":\"a\",\"glob\":\"");
    for (0..max_globstar_segments + 1) |_| try src.appendSlice(a, "**/");
    try src.appendSlice(a, "x\"}]}");
    try expectRejects(src.items, "too many '**' segments");

    // At the cap the glob still loads; the count only applies to whole
    // `**` segments, so `a/**b` is fine.
    var ok: std.ArrayList(u8) = .empty;
    try ok.appendSlice(a, "{\"schema\":\"knap-policy/1\",\"collections\":[{\"name\":\"a\",\"glob\":\"a/**b/");
    for (0..max_globstar_segments) |_| try ok.appendSlice(a, "**/");
    try ok.appendSlice(a, "x\"}]}");
    _ = try parse(&ctx, "p.json", ok.items);
}

test "judge: a haiku with a table is out of policy; exempt signals don't drag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);
    const p = try parse(&ctx, "p.json", verse_policy);
    const h = p.match("haikus/x.md").?;

    const haiku = "# H\n\nFault rerouted now  \nto a desk that cannot speak  \nritual is safe\n";
    const clean = try judge(a, h, try density.score(a, haiku));
    try testing.expectEqual(@as(usize, 0), clean.violations.len);
    try testing.expectEqual(Band.in, clean.band);

    const vandal = try judge(a, h, try density.score(a, haiku ++ "\n| a | b |\n|---|---|\n| 1 | 2 |\n"));
    try testing.expectEqual(@as(usize, 1), vandal.violations.len);
    try testing.expectEqual(Rule.forbid, vandal.violations[0].rule);
    try testing.expectEqualStrings("tables", vandal.violations[0].signal.?);

    // Re-normalization: dropping 'tables' etc. never lowers the score.
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "# T\n\n## S\n\n");
    for (0..240) |_| try long.appendSlice(a, "word ");
    try long.appendSlice(a, "with **bold** and *it*.\n\n- one\n- two\n");
    const sc = try density.score(a, long.items);
    const none: Collection = .{ .name = "n", .globs = &.{"**"} };
    try testing.expectApproxEqAbs(sc.total, policyScore(&none, sc), 1e-9);
    try testing.expect(policyScore(h, sc) > sc.total);

    // Band breach from above is a violation; below is a band state only.
    const tight: Collection = .{ .name = "t", .globs = &.{"**"}, .score = .{ .min = 90, .max = 95 } };
    try testing.expectEqual(Band.below, (try judge(a, &tight, sc)).band);
    try testing.expectEqual(@as(usize, 0), (try judge(a, &tight, sc)).violations.len);
    const low: Collection = .{ .name = "l", .globs = &.{"**"}, .score = .{ .max = 1 } };
    const over = try judge(a, &low, sc);
    try testing.expectEqual(Band.above, over.band);
    try testing.expectEqual(Rule.@"above-band", over.violations[0].rule);
}

// Shipped examples sit outside the module root (no @embedFile), and the
// test binary inherits the cwd `zig build test` started from.
test "shipped policy examples parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);
    const bytes = for ([_][]const u8{ "policy/filed.json", "knap-mcp/policy/filed.json" }) |path| {
        if (std.Io.Dir.readFileAlloc(.cwd(), testing.io, path, a, .limited(max_policy_bytes))) |b| break b else |e| if (e != error.FileNotFound) return e;
    } else return error.FileNotFound;
    const p = parse(&ctx, "filed.json", bytes) catch |e| {
        std.debug.print("{s}\n", .{ctx.err_msg});
        return e;
    };
    // The genre rule #250 asks for: verse is never pushed toward block
    // apparatus and never voice-rewritten line by line.
    for ([_][]const u8{ "haikus/hai-1.md", "limericks/LIM-1.md" }) |rel| {
        const c = p.match(rel).?;
        try testing.expectEqual(Mode.forbid, c.signals.get(.tables).mode);
        try testing.expect(!voiceAllowed(c, .mild, .verse));
    }
    try testing.expect(p.match("mascots/003.blamey-mctypoface.md").?.score.min != null);
}
