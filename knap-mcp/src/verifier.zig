//! The verifier slot (SPEC layer 4): `none | heuristic | decision`.
//!
//! A loop gate, advisory only. It is never on the render path, and its
//! scores are not conformance metrics: never show them next to fixture
//! counts. Two entry points:
//!
//! - `checkCitation` labels a claim against evidence quotes
//!   (entails | neutral | contradicts | unknown). The heuristic is string
//!   matching plus content-word overlap. It is NOT natural-language
//!   inference: only a verbatim quote earns `entails`.
//! - `judgeStep` is the accept / keep_iterating / escalate gate for the
//!   repair, voice and ratchet loops.
//!
//! Heuristic constants are pinned below; docs/tracks/M2.md explains them.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const backend = @import("backend.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { none, heuristic, decision };

pub fn parseKind(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

pub const Label = enum { entails, neutral, contradicts, unknown };

pub const Citation = struct {
    label: Label,
    /// 0..1. Heuristic: 1.0 for a verbatim quote, otherwise the claim's
    /// content-word overlap with the best evidence item (capped at
    /// `overlap_cap`). Decision: the model's own score. Not a probability.
    score: f32,
    reason: []const u8,
    /// The evidence item the label rests on, when there is one.
    matched: ?[]const u8 = null,
};

/// Share of the claim's content words that must appear in one evidence
/// item before the heuristic calls it `neutral` or `contradicts`.
pub const high_overlap: f32 = 0.6;
/// Non-verbatim scores stop here, so 1.0 always means a verbatim quote.
pub const overlap_cap: f32 = 0.95;
/// Minimum density gain (density/1 points) for `judgeStep` to accept.
pub const epsilon: f64 = 1.0;

// --- checkCitation ---------------------------------------------------------

/// Label `claim` against `evidence`. Never fails the caller: a disabled or
/// unavailable verifier answers `unknown` or falls back to the heuristic,
/// and says so in `reason`. The only error is running out of memory.
/// Everything is allocated in `ctx.arena`.
pub fn checkCitation(ctx: *Ctx, kind: Kind, claim: []const u8, evidence: []const []const u8) Allocator.Error!Citation {
    return switch (kind) {
        .none => .{ .label = .unknown, .score = 0, .reason = "verifier disabled" },
        .heuristic => heuristic(ctx.arena, claim, evidence),
        .decision => decide(ctx, claim, evidence),
    };
}

/// The heuristic verifier on its own; needs no Ctx (the eval gate uses it).
pub fn heuristic(arena: Allocator, claim: []const u8, evidence: []const []const u8) Allocator.Error!Citation {
    const nclaim = trimClaim(try normalize(arena, claim));
    const ct = try tokenize(arena, nclaim);
    if (ct.content.len == 0)
        return .{ .label = .unknown, .score = 0, .reason = "claim has no content words" };
    if (evidence.len == 0)
        return .{ .label = .unknown, .score = 0, .reason = "no evidence" };

    for (evidence, 0..) |ev, i| {
        if (containsWords(try normalize(arena, ev), nclaim))
            return .{
                .label = .entails,
                .score = 1.0,
                .reason = try std.fmt.allocPrint(arena, "verbatim quote of evidence[{d}]", .{i}),
                .matched = ev,
            };
    }

    var best: usize = 0;
    var best_overlap: f32 = -1;
    var best_tokens: Tokens = undefined;
    for (evidence, 0..) |ev, i| {
        const et = try tokenize(arena, try normalize(arena, ev));
        const o = overlap(ct.content, et.content);
        if (o > best_overlap) {
            best, best_overlap, best_tokens = .{ i, o, et };
        }
    }

    const score = @min(best_overlap, overlap_cap);
    if (best_overlap < high_overlap)
        return .{
            .label = .unknown,
            .score = score,
            .reason = try std.fmt.allocPrint(arena, "low overlap {d:.2} (best evidence[{d}])", .{ best_overlap, best }),
        };

    const neg = ct.negated != best_tokens.negated;
    const num = numberMismatch(ct.content, best_tokens.content);
    const label: Label = if (neg or num) .contradicts else .neutral;
    return .{
        .label = label,
        .score = score,
        .reason = try std.fmt.allocPrint(arena, "overlap {d:.2} with evidence[{d}]{s}{s}{s}", .{
            best_overlap,
            best,
            if (neg) "; negation mismatch" else "",
            if (num) "; number mismatch" else "",
            if (label == .neutral) "; not verbatim" else "",
        }),
        .matched = evidence[best],
    };
}

const decision_system =
    "You are a citation verifier. You decide; you never write. Given a claim " ++
    "and numbered evidence quotes, label the claim: \"entails\" if the evidence " ++
    "states it, \"contradicts\" if the evidence states the opposite, " ++
    "\"neutral\" if the evidence is on the same topic but neither confirms nor " ++
    "refutes it, \"unknown\" if the evidence does not bear on it. Reply with " ++
    "ONLY a JSON object: {\"label\":\"entails|neutral|contradicts|unknown\"," ++
    "\"score\":<confidence 0..1>}. No prose, no fences.";

fn decide(ctx: *Ctx, claim: []const u8, evidence: []const []const u8) Allocator.Error!Citation {
    const why: []const u8 = why: {
        const bk = ctx.backend_kind;
        if (bk == .mock) break :why "backend mock has no live completion";
        if (backend.needsKey(bk) and ctx.environ.get("MODEL_API_KEY") == null) break :why "no MODEL_API_KEY";

        var user: std.Io.Writer.Allocating = .init(ctx.arena);
        writePrompt(&user.writer, claim, evidence) catch return error.OutOfMemory;
        const saved = ctx.err_msg;
        const reply = backend.complete(ctx, bk, .verify, decision_system, user.written()) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            const msg = if (ctx.err_msg.len > 0) ctx.err_msg else @errorName(e);
            ctx.err_msg = saved;
            break :why try std.fmt.allocPrint(ctx.arena, "backend error: {s}", .{msg});
        };
        const d = parseDecision(ctx.arena, reply) orelse break :why "unparseable decision reply";
        return .{
            .label = d.label,
            .score = d.score,
            .reason = try std.fmt.allocPrint(ctx.arena, "decision model ({s})", .{@tagName(bk)}),
        };
    };
    var h = try heuristic(ctx.arena, claim, evidence);
    h.reason = try std.fmt.allocPrint(ctx.arena, "decision verifier unavailable ({s}); heuristic: {s}", .{ why, h.reason });
    return h;
}

fn writePrompt(w: *std.Io.Writer, claim: []const u8, evidence: []const []const u8) std.Io.Writer.Error!void {
    try w.print("claim: {s}\n\nevidence:\n", .{claim});
    for (evidence, 1..) |ev, i| try w.print("[{d}] {s}\n", .{ i, ev });
}

pub const Decision = struct { label: Label, score: f32 };

/// Strict parse of a decision-model reply: exactly one JSON object with a
/// `label` (one of the four names) and a numeric `score` in 0..1, and no
/// other keys. Surrounding whitespace is the only slack; fences or prose
/// are a parse failure (null).
pub fn parseDecision(arena: Allocator, reply: []const u8) ?Decision {
    const text = std.mem.trim(u8, reply, " \t\r\n");
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (v != .object or v.object.count() != 2) return null;
    const label = switch (v.object.get("label") orelse return null) {
        .string => |s| std.meta.stringToEnum(Label, s) orelse return null,
        else => return null,
    };
    const score: f64 = switch (v.object.get("score") orelse return null) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return null,
    };
    if (!(score >= 0 and score <= 1)) return null;
    return .{ .label = label, .score = @floatCast(score) };
}

// --- text normalization ----------------------------------------------------

/// Lowercase ASCII, map curly quotes to straight ones and `…` to `...`,
/// and collapse whitespace runs (including NBSP) to one space, trimmed.
pub fn normalize(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var space = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        var rep: []const u8 = &.{c};
        var n: usize = 1;
        if (c == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80) {
            switch (s[i + 2]) {
                0x98, 0x99 => rep = "'",
                0x9C, 0x9D => rep = "\"",
                0xA6 => rep = "...",
                else => {},
            }
            if (rep.len != 1 or rep[0] != c) n = 3;
        } else if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0xA0) {
            rep = " ";
            n = 2;
        }
        i += n;
        if (rep.len == 1 and std.ascii.isWhitespace(rep[0])) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        for (rep) |r| try out.append(arena, std.ascii.toLower(r));
    }
    return out.items;
}

/// Drop quotes wrapped around a claim and its final punctuation, so a
/// quoted or full-stopped claim still matches mid-sentence evidence.
fn trimClaim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \"'.,;:!?");
}

/// `needle` occurs in `hay` starting and ending on word boundaries.
fn containsWords(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var from: usize = 0;
    while (std.mem.findPos(u8, hay, from, needle)) |at| : (from = at + 1) {
        const end = at + needle.len;
        const left_ok = at == 0 or !isWordByte(hay[at - 1]) or !isWordByte(needle[0]);
        const right_ok = end == hay.len or !isWordByte(hay[end]) or !isWordByte(needle[needle.len - 1]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

// --- tokens ----------------------------------------------------------------

const Tokens = struct {
    /// Deduplicated, stemmed content words; numbers are digit strings.
    content: []const []const u8,
    negated: bool,
};

const stopwords = [_][]const u8{
    "a",     "an",    "the",   "and",   "or",    "but",   "of",    "to",    "in",
    "on",    "at",    "for",   "by",    "with",  "from",  "as",    "is",    "are",
    "was",   "were",  "be",    "been",  "being", "it",    "its",   "this",  "that",
    "these", "those", "has",   "have",  "had",   "do",    "does",  "did",   "will",
    "would", "can",   "could", "should", "may",  "might", "must",  "so",    "than",
    "then",  "there", "their", "they",  "them",  "we",    "our",   "you",   "your",
    "he",    "she",   "his",   "her",   "i",     "me",    "my",    "if",    "into",
    "about", "just",  "also",  "any",   "some",  "each",  "very",  "too",   "which",
    "who",   "whom",  "what",  "when",  "where", "how",   "why",   "s",     "t",
};

/// The brief's list (no, not, never, without, n't) plus close kin.
const negations = [_][]const u8{
    "no", "not", "never", "without", "cannot", "none", "nobody", "nothing", "neither", "nor",
};

const number_words = [_][]const u8{
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
};

fn inList(list: []const []const u8, w: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

/// Split normalized text into words. A word is a run of ASCII letters
/// (with inner apostrophes) or a run of digits; a letter/digit switch
/// splits, so `2ms` is `2` + `ms` and `p99` is `p` + `99`.
fn tokenize(arena: Allocator, s: []const u8) Allocator.Error!Tokens {
    var content: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var negated = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (!std.ascii.isAlphanumeric(c)) {
            i += 1;
            continue;
        }
        const start = i;
        const digits = std.ascii.isDigit(c);
        while (i < s.len) : (i += 1) {
            const d = s[i];
            if (digits and std.ascii.isDigit(d)) continue;
            if (!digits and std.ascii.isAlphabetic(d)) continue;
            if (!digits and d == '\'' and i + 1 < s.len and std.ascii.isAlphabetic(s[i + 1])) continue;
            break;
        }
        var w = s[start..i];
        if (!digits) {
            if (std.mem.endsWith(u8, w, "n't")) {
                negated = true;
                continue;
            }
            if (std.mem.endsWith(u8, w, "'s")) w = w[0 .. w.len - 2];
            if (std.mem.indexOfScalar(u8, w, '\'') != null) continue;
            if (inList(&negations, w)) {
                negated = true;
                continue;
            }
            if (inList(&stopwords, w)) continue;
            w = for (number_words, 0..) |nw, n| {
                if (std.mem.eql(u8, nw, w)) break try std.fmt.allocPrint(arena, "{d}", .{n});
            } else stem(w);
            if (w.len < 2 and !std.ascii.isDigit(w[0])) continue;
        }
        const gop = try seen.getOrPut(arena, w);
        if (!gop.found_existing) try content.append(arena, w);
    }
    return .{ .content = content.items, .negated = negated };
}

/// Crude suffix stripping so light inflection still overlaps:
/// snapshots/snapshot, acknowledged/acknowledges/acknowledging.
fn stem(w: []const u8) []const u8 {
    var s = w;
    if (s.len > 3 and s[s.len - 1] == 's' and s[s.len - 2] != 's') s = s[0 .. s.len - 1];
    if (s.len > 4 and s[s.len - 1] == 'e') s = s[0 .. s.len - 1];
    if (s.len > 5 and std.mem.endsWith(u8, s, "ing")) s = s[0 .. s.len - 3];
    if (s.len > 5 and std.mem.endsWith(u8, s, "ed")) s = s[0 .. s.len - 2];
    return s;
}

/// Share of `claim` words that occur in `ev`.
fn overlap(claim: []const []const u8, ev: []const []const u8) f32 {
    if (claim.len == 0) return 0;
    var hit: usize = 0;
    for (claim) |w| {
        if (inList(ev, w)) hit += 1;
    }
    return @as(f32, @floatFromInt(hit)) / @as(f32, @floatFromInt(claim.len));
}

/// The claim names a number the evidence lacks, and the evidence names a
/// number the claim lacks: "9 seconds" against "19 seconds".
fn numberMismatch(claim: []const []const u8, ev: []const []const u8) bool {
    return extraNumber(claim, ev) and extraNumber(ev, claim);
}

fn extraNumber(a: []const []const u8, b: []const []const u8) bool {
    for (a) |w| {
        if (std.ascii.isDigit(w[0]) and !inList(b, w)) return true;
    }
    return false;
}

// --- judgeStep -------------------------------------------------------------

/// One loop state, measured on the rendered doc.
pub const Step = struct {
    /// density/1 total.
    density: f64,
    /// format_check rule ids (duplicates are fine).
    warnings: []const []const u8 = &.{},
    /// Residual engine diagnostics.
    diagnostics: usize = 0,
    /// Read from `after` only: the caller has no iterations left, so a
    /// step that is not accepted escalates instead of iterating.
    budget_spent: bool = false,
};

pub const StepDecision = enum { accept, keep_iterating, escalate };

pub const StepVerdict = struct {
    decision: StepDecision,
    reason: []const u8,
    /// after.density - before.density.
    gain: f64 = 0,
    /// A warning rule present after but not before, if any.
    new_warning: ?[]const u8 = null,
};

/// The loop gate. Heuristic table, first match wins:
///   1. diagnostics after                         -> keep_iterating
///   2. a warning rule new since before           -> keep_iterating
///   3. diagnostics before, none after            -> accept (a repair landed)
///   4. density gain >= epsilon                   -> accept
///   5. otherwise                                 -> keep_iterating
/// Any keep_iterating becomes escalate when `after.budget_spent`.
/// `none` accepts every step. `decision` has no Ctx here, so it uses the
/// heuristic and says so in the reason.
pub fn judgeStep(kind: Kind, before: Step, after: Step) StepVerdict {
    const gain = after.density - before.density;
    if (kind == .none) return .{ .decision = .accept, .reason = "verifier disabled", .gain = gain };

    var new_warning: ?[]const u8 = null;
    for (after.warnings) |w| {
        if (!inList(before.warnings, w)) {
            new_warning = w;
            break;
        }
    }
    const r: Reason = if (after.diagnostics > 0)
        .diagnostics
    else if (new_warning != null)
        .new_warning
    else if (before.diagnostics > 0)
        .repaired
    else if (gain >= epsilon)
        .gain
    else
        .no_gain;

    const accepted = r == .repaired or r == .gain;
    const decision: StepDecision = if (accepted) .accept else if (after.budget_spent) .escalate else .keep_iterating;
    const fallback = @intFromBool(kind == .decision);
    return .{
        .decision = decision,
        .reason = reason_text[fallback][@intFromBool(decision == .escalate)][@intFromEnum(r)],
        .gain = gain,
        .new_warning = new_warning,
    };
}

const Reason = enum { diagnostics, new_warning, repaired, gain, no_gain };

/// [decision fallback][escalated][reason], built at comptime so verdicts
/// need no allocator.
const reason_text = blk: {
    const base = [_][]const u8{
        "residual diagnostics",
        "new format_check warning rule",
        "diagnostics cleared, no new warning rule",
        "density gain >= epsilon, no new warning rule",
        "density gain below epsilon",
    };
    var t: [2][2][base.len][]const u8 = undefined;
    for (0..2) |f| for (0..2) |e| for (base, 0..) |b, i| {
        t[f][e][i] = (if (f == 1) "decision judge unavailable; heuristic: " else "") ++ b ++
            (if (e == 1) "; iteration budget spent" else "");
    };
    break :blk t;
};

// --- eval gate (eval/verifier/cases.json) ----------------------------------

pub const Case = struct {
    id: []const u8,
    class: []const u8,
    source: []const u8 = "",
    claim: []const u8,
    evidence: []const []const u8,
    expected: Label,
};

pub const Miss = struct { case: Case, got: Citation };

pub const ClassTally = struct { name: []const u8, pass: usize = 0, total: usize = 0 };

pub const GateResult = struct {
    total: usize,
    /// [expected][got], indexed by `Label`.
    confusion: [4][4]usize,
    classes: []const ClassTally,
    misses: []const Miss,
    /// Ids of verbatim cases not labeled `entails` and unrelated cases not
    /// labeled `unknown`. The gate fails on any.
    hard_failures: []const []const u8,
};

/// Run the heuristic over a cases file (`{"cases":[Case...]}`).
pub fn runGate(arena: Allocator, json: []const u8) !GateResult {
    const File = struct { note: []const u8 = "", cases: []const Case };
    const file = try std.json.parseFromSliceLeaky(File, arena, json, .{});
    var confusion: [4][4]usize = @splat(@splat(0));
    var classes: std.ArrayList(ClassTally) = .empty;
    var misses: std.ArrayList(Miss) = .empty;
    var hard: std.ArrayList([]const u8) = .empty;
    for (file.cases) |c| {
        const got = try heuristic(arena, c.claim, c.evidence);
        confusion[@intFromEnum(c.expected)][@intFromEnum(got.label)] += 1;
        const pass = got.label == c.expected;
        const t = for (classes.items) |*t| {
            if (std.mem.eql(u8, t.name, c.class)) break t;
        } else blk: {
            try classes.append(arena, .{ .name = c.class });
            break :blk &classes.items[classes.items.len - 1];
        };
        t.total += 1;
        if (pass) t.pass += 1 else try misses.append(arena, .{ .case = c, .got = got });
        const must: ?Label = if (std.mem.eql(u8, c.class, "verbatim"))
            .entails
        else if (std.mem.eql(u8, c.class, "unrelated"))
            .unknown
        else
            null;
        if (must) |m| if (got.label != m) try hard.append(arena, c.id);
    }
    return .{
        .total = file.cases.len,
        .confusion = confusion,
        .classes = classes.items,
        .misses = misses.items,
        .hard_failures = hard.items,
    };
}

/// Markdown confusion table, per-class pass counts, and every miss.
pub fn writeGate(g: GateResult, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const labels = std.meta.fieldNames(Label);
    try w.print("verifier gate: heuristic (string overlap, not NLI), {d} cases\n\n", .{g.total});
    try w.writeAll("| expected \\ heuristic |");
    for (labels) |l| try w.print(" {s} |", .{l});
    try w.writeAll("\n|---|");
    for (labels) |_| try w.writeAll("--:|");
    try w.writeAll("\n");
    for (labels, g.confusion) |l, row| {
        try w.print("| **{s}** |", .{l});
        for (row) |n| try w.print(" {d} |", .{n});
        try w.writeAll("\n");
    }
    var agree: usize = 0;
    for (0..4) |i| agree += g.confusion[i][i];
    try w.print("\nagreement {d}/{d}; by class:", .{ agree, g.total });
    for (g.classes) |c| try w.print(" {s} {d}/{d}", .{ c.name, c.pass, c.total });
    try w.writeAll("\n");
    if (g.misses.len > 0) try w.writeAll("\nmisses:\n");
    for (g.misses) |m| try w.print("- {s} ({s}): expected {s}, got {s} — {s}\n", .{
        m.case.id, m.case.class, @tagName(m.case.expected), @tagName(m.got.label), m.got.reason,
    });
    try w.print("\nhard gate (every verbatim = entails, every unrelated = unknown): {s}\n", .{
        if (g.hard_failures.len == 0) "PASS" else "FAIL",
    });
    for (g.hard_failures) |id| try w.print("  failed: {s}\n", .{id});
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testCtx(arena: Allocator, env: *std.process.Environ.Map, kind: backend.Kind) Ctx {
    return .{
        .arena = arena,
        .gpa = arena,
        .io = testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = kind,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
}

fn expectLabel(want: Label, claim: []const u8, evidence: []const []const u8) !Citation {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try heuristic(arena.allocator(), claim, evidence);
    if (c.label != want) {
        std.debug.print("claim {s}: want {s}, got {s} ({s})\n", .{ claim, @tagName(want), @tagName(c.label), c.reason });
        return error.TestUnexpectedResult;
    }
    return .{ .label = c.label, .score = c.score, .reason = "", .matched = c.matched };
}

test "parseKind takes the three slot names only" {
    try testing.expectEqual(Kind.none, parseKind("none").?);
    try testing.expectEqual(Kind.heuristic, parseKind("heuristic").?);
    try testing.expectEqual(Kind.decision, parseKind("decision").?);
    try testing.expect(parseKind("nli") == null);
    try testing.expect(parseKind("") == null);
}

test "normalize folds case, curly quotes, ellipsis and whitespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "it's \"fine\"... really",
        try normalize(a, "  It\u{2019}s \u{201C}Fine\u{201D}\u{2026}\n\t REALLY\u{00A0} "),
    );
    try testing.expectEqualStrings("a 'b' c", try normalize(a, "A \u{2018}b\u{2019}\r\nc"));
    try testing.expectEqualStrings("", try normalize(a, " \n "));
    try testing.expectEqualStrings("em\u{2014}dash", try normalize(a, "Em\u{2014}dash"));
}

test "verbatim quote entails with score 1 across normalizations" {
    const ev = [_][]const u8{ "Other text.", "Every write is appended to the write-ahead\n  log and fsynced before it is acknowledged." };
    const c = try expectLabel(.entails, "EVERY write is appended to the write-ahead log", &ev);
    try testing.expectEqual(@as(f32, 1.0), c.score);
    try testing.expectEqualStrings(ev[1], c.matched.?);
    _ = try expectLabel(.entails, "\u{201C}Beware of first-hand ideas!\u{201D}", &.{"Beware of first-hand ideas!"});
    _ = try expectLabel(.entails, "lists snapshots as \u{2018}coming soon\u{2019}.", &.{"docs page lists snapshots as 'coming soon'"});
}

test "verbatim needs word boundaries" {
    // "nap" sits inside "snapshots" but is not a quote of it.
    _ = try expectLabel(.unknown, "nap", &.{"snapshots are coming soon"});
    _ = try expectLabel(.entails, "snapshots", &.{"snapshots are coming soon"});
}

test "high overlap without negation is neutral and scores below 1" {
    const c = try expectLabel(.neutral, "Cold starts on a 500 GB database dropped from 4 minutes to 9 seconds.", &.{"Cold start on a 500 GB database fell from 4 minutes to 9 seconds."});
    try testing.expect(c.score >= high_overlap and c.score <= overlap_cap);
}

test "negation mismatch is contradicts, both ways and with n't" {
    _ = try expectLabel(.contradicts, "Cross-region replication is not on the roadmap.", &.{"Cross-region replication is on the roadmap."});
    _ = try expectLabel(.contradicts, "AcmeDB shards its keyspace across nodes.", &.{"AcmeDB does not shard. One node owns the whole keyspace."});
    _ = try expectLabel(.contradicts, "The snapshot feature doesn\u{2019}t ship in 2.0.", &.{"The snapshot feature ships in 2.0."});
    _ = try expectLabel(.contradicts, "Restores work without a support ticket.", &.{"Restores work through a support ticket."});
    // Negation on both sides agrees.
    _ = try expectLabel(.neutral, "Multi-region replication is never planned for this year.", &.{"Multi-region is not planned for this year, replication included."});
}

test "number mismatch is contradicts; number words count as numbers" {
    _ = try expectLabel(.contradicts, "Cold start fell from 4 minutes to 19 seconds.", &.{"Cold start fell from 4 minutes to 9 seconds."});
    _ = try expectLabel(.contradicts, "restorable to any point in the last 14 days", &.{"restorable to any point in the last seven days"});
    _ = try expectLabel(.neutral, "restorable to any point in the last 7 days", &.{"restorable to any point in the past seven days"});
}

test "low overlap, empty claim and no evidence are unknown" {
    const c = try expectLabel(.unknown, "Forster wrote this before radio broadcasting existed.", &.{"Point-in-time snapshots are coming soon."});
    try testing.expect(c.matched == null);
    _ = try expectLabel(.unknown, "", &.{"anything"});
    _ = try expectLabel(.unknown, "it is the", &.{"it is the"});
    _ = try expectLabel(.unknown, "Snapshots are coming soon.", &.{});
}

test "picks the best evidence item" {
    const ev = [_][]const u8{ "AcmeDB is a durable key-value store.", "Point-in-time snapshots are coming soon." };
    const c = try expectLabel(.neutral, "Point-in-time snapshots are coming very soon now.", &ev);
    try testing.expectEqualStrings(ev[1], c.matched.?);
}

test "checkCitation: none is disabled, heuristic passes through" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env, .mock);
    const n = try checkCitation(&ctx, .none, "snapshots ship", &.{"snapshots ship"});
    try testing.expectEqual(Label.unknown, n.label);
    try testing.expectEqualStrings("verifier disabled", n.reason);
    const h = try checkCitation(&ctx, .heuristic, "snapshots ship", &.{"snapshots ship"});
    try testing.expectEqual(Label.entails, h.label);
}

test "checkCitation: decision falls back to heuristic and says why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ev = [_][]const u8{"Point-in-time snapshots are coming soon."};

    var mock = testCtx(a, &env, .mock);
    const m = try checkCitation(&mock, .decision, "Point-in-time snapshots are coming soon.", &ev);
    try testing.expectEqual(Label.entails, m.label);
    try testing.expect(std.mem.startsWith(u8, m.reason, "decision verifier unavailable (backend mock has no live completion); heuristic: verbatim"));

    var spark = testCtx(a, &env, .spark);
    const s = try checkCitation(&spark, .decision, "Snapshots are never coming.", &ev);
    try testing.expectEqual(Label.contradicts, s.label);
    try testing.expect(std.mem.startsWith(u8, s.reason, "decision verifier unavailable (no MODEL_API_KEY); heuristic: overlap"));
    try testing.expectEqualStrings("", spark.err_msg);
}

test "parseDecision is strict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = parseDecision(a, " {\"label\":\"contradicts\",\"score\":0.75}\n").?;
    try testing.expectEqual(Label.contradicts, d.label);
    try testing.expectApproxEqAbs(@as(f32, 0.75), d.score, 1e-6);
    try testing.expectEqual(Label.entails, parseDecision(a, "{\"score\":1,\"label\":\"entails\"}").?.label);
    const bad = [_][]const u8{
        "",
        "entails",
        "```json\n{\"label\":\"entails\",\"score\":1}\n```",
        "{\"label\":\"entails\"}",
        "{\"label\":\"yes\",\"score\":1}",
        "{\"label\":\"entails\",\"score\":1.5}",
        "{\"label\":\"entails\",\"score\":-0.1}",
        "{\"label\":\"entails\",\"score\":\"1\"}",
        "{\"label\":\"entails\",\"score\":1,\"why\":\"x\"}",
        "[\"entails\",1]",
        "Sure! {\"label\":\"entails\",\"score\":1}",
    };
    for (bad) |b| try testing.expect(parseDecision(a, b) == null);
}

test "judgeStep heuristic table" {
    const S = Step;
    const Row = struct { before: S, after: S, want: StepDecision, reason: []const u8 };
    const rows = [_]Row{
        .{ .before = .{ .density = 20 }, .after = .{ .density = 30, .diagnostics = 1 }, .want = .keep_iterating, .reason = "residual diagnostics" },
        .{ .before = .{ .density = 20 }, .after = .{ .density = 30, .diagnostics = 1, .budget_spent = true }, .want = .escalate, .reason = "residual diagnostics; iteration budget spent" },
        .{ .before = .{ .density = 20 }, .after = .{ .density = 21 }, .want = .accept, .reason = "density gain >= epsilon, no new warning rule" },
        .{ .before = .{ .density = 20 }, .after = .{ .density = 20.99 }, .want = .keep_iterating, .reason = "density gain below epsilon" },
        .{ .before = .{ .density = 20 }, .after = .{ .density = 15 }, .want = .keep_iterating, .reason = "density gain below epsilon" },
        .{ .before = .{ .density = 20 }, .after = .{ .density = 15, .budget_spent = true }, .want = .escalate, .reason = "density gain below epsilon; iteration budget spent" },
        .{ .before = .{ .density = 20, .warnings = &.{"raw-url-count"} }, .after = .{ .density = 40, .warnings = &.{ "raw-url-count", "empty-callout" } }, .want = .keep_iterating, .reason = "new format_check warning rule" },
        .{ .before = .{ .density = 20, .warnings = &.{"raw-url-count"} }, .after = .{ .density = 30, .warnings = &.{ "raw-url-count", "raw-url-count" } }, .want = .accept, .reason = "density gain >= epsilon, no new warning rule" },
        .{ .before = .{ .density = 20, .warnings = &.{"wall-of-text"} }, .after = .{ .density = 25 }, .want = .accept, .reason = "density gain >= epsilon, no new warning rule" },
        .{ .before = .{ .density = 0, .diagnostics = 2 }, .after = .{ .density = 0 }, .want = .accept, .reason = "diagnostics cleared, no new warning rule" },
        .{ .before = .{ .density = 0, .diagnostics = 2 }, .after = .{ .density = 0, .warnings = &.{"unclosed-fence"}, .budget_spent = true }, .want = .escalate, .reason = "new format_check warning rule; iteration budget spent" },
        // An accepted step stays accepted on the last iteration.
        .{ .before = .{ .density = 20 }, .after = .{ .density = 22, .budget_spent = true }, .want = .accept, .reason = "density gain >= epsilon, no new warning rule" },
    };
    for (rows, 0..) |r, i| {
        const v = judgeStep(.heuristic, r.before, r.after);
        errdefer std.debug.print("row {d}: got {s} ({s})\n", .{ i, @tagName(v.decision), v.reason });
        try testing.expectEqual(r.want, v.decision);
        try testing.expectEqualStrings(r.reason, v.reason);
        try testing.expectApproxEqAbs(r.after.density - r.before.density, v.gain, 1e-9);
    }
    const nw = judgeStep(.heuristic, rows[6].before, rows[6].after);
    try testing.expectEqualStrings("empty-callout", nw.new_warning.?);
}

test "judgeStep none accepts, decision falls back with a reason" {
    const n = judgeStep(.none, .{ .density = 20 }, .{ .density = 10, .diagnostics = 3 });
    try testing.expectEqual(StepDecision.accept, n.decision);
    try testing.expectEqualStrings("verifier disabled", n.reason);
    const d = judgeStep(.decision, .{ .density = 20 }, .{ .density = 22 });
    try testing.expectEqual(StepDecision.accept, d.decision);
    try testing.expectEqualStrings("decision judge unavailable; heuristic: density gain >= epsilon, no new warning rule", d.reason);
    const e = judgeStep(.decision, .{ .density = 20 }, .{ .density = 20, .budget_spent = true });
    try testing.expectEqual(StepDecision.escalate, e.decision);
    try testing.expectEqualStrings("decision judge unavailable; heuristic: density gain below epsilon; iteration budget spent", e.reason);
}

// The labeled cases live outside the module root, so they can't be
// @embedFile'd; the test binary inherits the cwd `zig build test` started in.
const cases_paths = [_][]const u8{ "eval/verifier/cases.json", "knap-mcp/eval/verifier/cases.json" };

test "eval/verifier/cases.json: hard gate holds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = for (cases_paths) |p| {
        if (std.Io.Dir.readFileAlloc(.cwd(), testing.io, p, a, .limited(1 << 20))) |b| break b else |err| {
            if (err != error.FileNotFound) return err;
        }
    } else {
        std.debug.print("verifier: cases.json not found; run zig build test from knap-mcp/ or the repo root\n", .{});
        return error.FileNotFound;
    };
    const g = try runGate(a, bytes);
    try testing.expect(g.total >= 20);
    for (g.hard_failures) |id| std.debug.print("verifier gate: hard failure {s}\n", .{id});
    try testing.expectEqual(@as(usize, 0), g.hard_failures.len);
    for (g.classes) |c| {
        if (std.mem.eql(u8, c.name, "verbatim") or std.mem.eql(u8, c.name, "unrelated"))
            try testing.expect(c.total >= 5);
    }
}
