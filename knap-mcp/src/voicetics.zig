//! `knap-mcp voice-tics`: profile a voice pass for repetitive editorial
//! tics (VOICE-TICS, #382; filed.fyi#1061). Model-free and deterministic.
//!
//! Input is (before, after) pairs. `before` is the source record; `after`
//! is the patched record (.md) or a `doc-voice --report` JSON. Runs are
//! paired with voice.docWalk, so only the text a voice pass may touch is
//! compared. Per label it measures what a per-reply guard can't see: the
//! same few interjections and ironic emphases added across a whole batch.
//!
//! - lexicon: added hedge/interjection phrases (`regrettably`, `it seems`).
//! - emphasis_on_existing: an added `*x*`/`**x**`/`==x==` over 1-3 words
//!   the run already had. emphasis_ironic is the subset over one lowercase
//!   word (`*helpfully*`, `*misplaced*`): the italics-as-irony signpost,
//!   as opposed to stressing a load-bearing term (`*freshness score*`).
//! - reworded: the run's words are no longer a subsequence of the reply's
//!   (reordered or deleted, not just inserted into).
//! - repeats: added terms (content unigrams and bigrams) that recur in at
//!   least `min_runs` runs. repeat_share is the share of added content
//!   words that belong to a recurring unigram; distinct_ratio is distinct
//!   added content words over all of them.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const voice = @import("voice.zig");
const common = @import("tools/common.zig");

const Allocator = std.mem.Allocator;

/// Added-phrase lexicon: the issue's tic set plus the usual wry-narrator
/// hedges. Phrases are lowercase words separated by single spaces.
pub const default_lexicon = [_][]const u8{
    "regrettably",         "unfortunately",           "sadly",              "somewhat",
    "of course",           "it seems",                "it would seem",      "seemingly",
    "apparently",          "perhaps",                 "naturally",          "predictably",
    "inevitably",          "presumably",              "evidently",          "arguably",
    "ostensibly",          "admittedly",              "understandably",     "curiously",
    "notably",             "indeed",                  "rather",             "quite",
    "politely",            "firmly",                  "dutifully",          "helpfully",
    "mercifully",          "thankfully",              "duly",               "characteristically",
    "conveniently",        "after due consideration", "in its purest form", "as expected",
    "as one does",         "needless to say",         "to be fair",         "in fairness",
    "for the record",      "it must be said",         "so to speak",        "as it happens",
    "with great ceremony", "with due ceremony",       "of a sort",          "one might say",
    "quietly",             "merely",                  "it turns out",       "as always",
    "as ever",             "once again",              "simply",             "clearly",
};

const stopwords = [_][]const u8{
    "a",    "an",    "the",   "and",  "or",   "but",  "of",    "to",    "in",    "on",
    "at",   "for",   "by",    "with", "from", "as",   "is",    "are",   "was",   "were",
    "be",   "been",  "being", "it",   "its",  "this", "that",  "these", "those", "has",
    "have", "had",   "do",    "does", "did",  "will", "would", "can",   "could", "should",
    "may",  "might", "must",  "so",   "than", "then", "there", "their", "they",  "them",
    "we",   "our",   "you",   "your", "he",   "she",  "his",   "her",   "i",     "me",
    "my",   "if",    "into",  "not",  "no",   "all",  "which", "who",   "what",  "when",
};

pub const Pair = struct { before: []const u8, after: []const u8 };

pub const Hit = struct { term: []const u8, added: usize, runs: usize };

pub const Options = struct {
    min_runs: usize = 3,
    top: usize = 15,
    lexicon: []const []const u8 = &default_lexicon,
};

pub const Profile = struct {
    label: []const u8 = "",
    pairs: usize = 0,
    pairs_skipped: usize = 0,
    runs: usize = 0,
    changed: usize = 0,
    /// Guard rejections (report input only; a patched .md can't show them).
    rejected: usize = 0,
    /// Of those, runs whose backend call failed: no reply to judge.
    backend_errors: usize = 0,
    insert_only: usize = 0,
    reworded: usize = 0,
    added_words: usize = 0,
    added_content_words: usize = 0,
    lexicon_added: usize = 0,
    emphasis_added: usize = 0,
    emphasis_on_existing: usize = 0,
    emphasis_ironic: usize = 0,
    /// Em/en dashes the reply added (a cross-model tic of its own).
    dashes_added: usize = 0,
    dash_runs: usize = 0,
    /// Changed runs carrying at least one lexicon hit or ironic emphasis.
    tic_runs: usize = 0,
    tic_run_share: f64 = 0,
    lexicon_per_100_changed: f64 = 0,
    repeat_share: f64 = 0,
    distinct_ratio: f64 = 0,
    min_runs: usize = 0,
    lexicon: []const Hit = &.{},
    emphasis: []const Hit = &.{},
    repeats: []const Hit = &.{},
};

fn listed(list: []const []const u8, w: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Byte length of the word character at s[i], or 0 for a separator.
/// Non-ASCII counts as a letter except Latin-1 and general punctuation,
/// so an em dash or a curly quote splits words like a space does.
fn wordCharLen(s: []const u8, i: usize) usize {
    if (s[i] < 0x80) return @intFromBool(std.ascii.isAlphanumeric(s[i]));
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0;
    if (i + n > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return 0;
    const punct = (cp >= 0x80 and cp <= 0xBF) or cp == 0xD7 or cp == 0xF7 or (cp >= 0x2000 and cp <= 0x206F) or (cp >= 0x3000 and cp <= 0x303F);
    return if (punct) 0 else n;
}

/// Lowercased words of `s`; markup bytes are separators, an apostrophe
/// between letters stays inside the word.
pub fn words(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (wordCharLen(s, i) == 0) {
            i += 1;
            continue;
        }
        const p = i;
        while (i < s.len) {
            const n = wordCharLen(s, i);
            if (n > 0) {
                i += n;
            } else if (s[i] == '\'' and i + 1 < s.len and std.ascii.isAlphabetic(s[i + 1])) {
                i += 1;
            } else break;
        }
        try out.append(a, try std.ascii.allocLowerString(a, s[p..i]));
    }
    return out.items;
}

/// Em and en dashes in `s` (U+2014, U+2013, ASCII ` -- `).
fn dashes(s: []const u8) usize {
    return std.mem.count(u8, s, "\u{2014}") + std.mem.count(u8, s, "\u{2013}") + std.mem.count(u8, s, " -- ");
}

const Counts = std.StringHashMapUnmanaged(usize);

fn bump(a: Allocator, m: *Counts, k: []const u8, n: usize) Allocator.Error!void {
    const gop = try m.getOrPut(a, k);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + n else n;
}

fn countOf(m: *const Counts, k: []const u8) usize {
    return m.get(k) orelse 0;
}

/// Occurrences of the word sequence `phrase` in `ws`.
fn phraseCount(ws: []const []const u8, phrase: []const []const u8) usize {
    if (phrase.len == 0 or ws.len < phrase.len) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + phrase.len <= ws.len) : (i += 1) {
        for (phrase, 0..) |p, j| {
            if (!std.mem.eql(u8, ws[i + j], p)) break;
        } else n += 1;
    }
    return n;
}

fn isSubsequence(small: []const []const u8, big: []const []const u8) bool {
    var j: usize = 0;
    for (big) |w| {
        if (j < small.len and std.mem.eql(u8, w, small[j])) j += 1;
    }
    return j == small.len;
}

/// Emphasis spans of `s` as their full source text (`*x*`, `**x**`,
/// `_x_`, `==x==`, `~~x~~`). Crude on purpose: one level, no nesting.
pub fn spans(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (std.mem.indexOfScalar(u8, "*_=~", c) == null) {
            i += 1;
            continue;
        }
        var n: usize = 0;
        while (i + n < s.len and s[i + n] == c) n += 1;
        const ok_len = if (c == '=' or c == '~') n == 2 else n <= 2;
        const left_ok = c != '_' or i == 0 or !isWordByte(s[i - 1]);
        if (!ok_len or !left_ok or i + n >= s.len or s[i + n] == ' ') {
            i += n;
            continue;
        }
        var j = i + n;
        const close: ?usize = while (j < s.len) {
            if (s[j] != c) {
                j += 1;
                continue;
            }
            var m: usize = 0;
            while (j + m < s.len and s[j + m] == c) m += 1;
            const right_ok = c != '_' or j + m == s.len or !isWordByte(s[j + m]);
            if (m == n and s[j - 1] != ' ' and right_ok) break j;
            j += m;
        } else null;
        if (close) |e| {
            try out.append(a, s[i .. e + n]);
            i = e + n;
        } else i += n;
    }
    return out.items;
}

fn spanInner(span: []const u8) []const u8 {
    var n: usize = 0;
    while (n < span.len and span[n] == span[0]) n += 1;
    return span[n .. span.len - n];
}

const Tally = std.StringArrayHashMapUnmanaged(Hit);

fn tallyRun(a: Allocator, t: *Tally, local: *const Counts) Allocator.Error!void {
    var it = local.iterator();
    while (it.next()) |e| {
        const gop = try t.getOrPut(a, e.key_ptr.*);
        if (!gop.found_existing) gop.value_ptr.* = .{ .term = e.key_ptr.*, .added = 0, .runs = 0 };
        gop.value_ptr.added += e.value_ptr.*;
        gop.value_ptr.runs += 1;
    }
}

fn sorted(a: Allocator, t: *const Tally, min_runs: usize, top: usize) Allocator.Error![]const Hit {
    var out: std.ArrayList(Hit) = .empty;
    for (t.values()) |h| if (h.runs >= min_runs) try out.append(a, h);
    std.mem.sort(Hit, out.items, {}, struct {
        fn lt(_: void, x: Hit, y: Hit) bool {
            if (x.runs != y.runs) return x.runs > y.runs;
            if (x.added != y.added) return x.added > y.added;
            return std.mem.lessThan(u8, x.term, y.term);
        }
    }.lt);
    return out.items[0..@min(top, out.items.len)];
}

fn ratio(n: usize, d: usize) f64 {
    if (d == 0) return 0;
    return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

/// Profile every pair. `rejected` and the pair counters are the caller's.
pub fn score(a: Allocator, pairs: []const Pair, o: Options) Allocator.Error!Profile {
    var p: Profile = .{ .min_runs = o.min_runs };
    var lex_words: std.ArrayList([]const []const u8) = .empty;
    for (o.lexicon) |phrase| try lex_words.append(a, try words(a, phrase));
    var lex: Tally = .empty;
    var emph: Tally = .empty;
    var uni: Tally = .empty;
    var terms: Tally = .empty;

    for (pairs) |pair| {
        p.runs += 1;
        if (std.mem.eql(u8, pair.before, pair.after)) continue;
        p.changed += 1;
        const wb = try words(a, pair.before);
        const wa = try words(a, pair.after);
        if (isSubsequence(wb, wa)) p.insert_only += 1 else p.reworded += 1;
        const db, const da = .{ dashes(pair.before), dashes(pair.after) };
        if (da > db) {
            p.dashes_added += da - db;
            p.dash_runs += 1;
        }

        var before_counts: Counts = .empty;
        for (wb) |w| try bump(a, &before_counts, w, 1);
        var added_set: Counts = .empty;
        var local_uni: Counts = .empty;
        var left = try before_counts.clone(a);
        for (wa) |w| {
            const n = countOf(&left, w);
            if (n > 0) {
                left.putAssumeCapacity(w, n - 1);
                continue;
            }
            p.added_words += 1;
            try bump(a, &added_set, w, 1);
            if (listed(&stopwords, w)) continue;
            p.added_content_words += 1;
            try bump(a, &local_uni, w, 1);
        }
        try tallyRun(a, &uni, &local_uni);

        var local_terms = try local_uni.clone(a);
        var before_bi: Counts = .empty;
        if (wb.len > 1) for (wb[0 .. wb.len - 1], wb[1..]) |x, y|
            try bump(a, &before_bi, try std.fmt.allocPrint(a, "{s} {s}", .{ x, y }), 1);
        if (wa.len > 1) for (wa[0 .. wa.len - 1], wa[1..]) |x, y| {
            if (listed(&stopwords, x) and listed(&stopwords, y)) continue;
            if (added_set.get(x) == null and added_set.get(y) == null) continue;
            const bi = try std.fmt.allocPrint(a, "{s} {s}", .{ x, y });
            const n = countOf(&before_bi, bi);
            if (n > 0) {
                before_bi.putAssumeCapacity(bi, n - 1);
                continue;
            }
            try bump(a, &local_terms, bi, 1);
        };
        try tallyRun(a, &terms, &local_terms);

        var tic = false;
        var local_lex: Counts = .empty;
        for (o.lexicon, lex_words.items) |phrase, pw| {
            const nb = phraseCount(wb, pw);
            const na = phraseCount(wa, pw);
            if (na <= nb) continue;
            p.lexicon_added += na - nb;
            try bump(a, &local_lex, phrase, na - nb);
            tic = true;
        }
        try tallyRun(a, &lex, &local_lex);

        var before_spans: Counts = .empty;
        for (try spans(a, pair.before)) |s| try bump(a, &before_spans, s, 1);
        var local_emph: Counts = .empty;
        for (try spans(a, pair.after)) |s| {
            const n = countOf(&before_spans, s);
            if (n > 0) {
                before_spans.putAssumeCapacity(s, n - 1);
                continue;
            }
            p.emphasis_added += 1;
            const inner = try words(a, spanInner(s));
            if (inner.len == 0 or inner.len > 3) continue;
            const existing = for (inner) |w| {
                if (before_counts.get(w) == null) break false;
            } else true;
            if (!existing) continue;
            p.emphasis_on_existing += 1;
            const raw = std.mem.trim(u8, spanInner(s), " ");
            if (inner.len == 1 and raw.len > 0 and std.ascii.isLower(raw[0])) {
                p.emphasis_ironic += 1;
                tic = true;
            }
            try bump(a, &local_emph, try std.mem.join(a, " ", inner), 1);
        }
        try tallyRun(a, &emph, &local_emph);
        if (tic) p.tic_runs += 1;
    }

    var repeated: usize = 0;
    for (uni.values()) |h| {
        if (h.runs >= o.min_runs) repeated += h.added;
    }
    p.repeat_share = ratio(repeated, p.added_content_words);
    p.distinct_ratio = ratio(uni.count(), p.added_content_words);
    p.tic_run_share = ratio(p.tic_runs, p.changed);
    p.lexicon_per_100_changed = 100 * ratio(p.lexicon_added, p.changed);
    p.lexicon = try sorted(a, &lex, 1, o.top);
    p.emphasis = try sorted(a, &emph, 1, o.top);
    p.repeats = try sorted(a, &terms, o.min_runs, o.top);
    return p;
}

pub const PairError = error{ OutOfMemory, Mismatch, BadReport };

/// Run pairs from two versions of one doc. Mismatch when the walks
/// disagree (not the same record, or the layout moved).
pub fn pairsFromDocs(a: Allocator, before: []const u8, after: []const u8) PairError![]const Pair {
    const wb = try voice.docWalk(a, before);
    const wa = try voice.docWalk(a, after);
    if (wb.runs.len != wa.runs.len) return error.Mismatch;
    const out = try a.alloc(Pair, wb.runs.len);
    for (wb.runs, wa.runs, out) |rb, ra, *o| {
        if (rb.kind != ra.kind) return error.Mismatch;
        o.* = .{ .before = before[rb.lo..rb.hi], .after = after[ra.lo..ra.hi] };
    }
    return out;
}

/// Rejected runs in a report; `backend` counts calls that never replied.
pub const Rejections = struct { guard: usize = 0, backend: usize = 0 };

/// Run pairs from the source doc and its `doc-voice` report: `fields[]`
/// carry the readable reply when it differs from the run and a redacted
/// `{bytes,sha256}` otherwise; each field's redacted `before` must match
/// the source run.
pub fn pairsFromReport(a: Allocator, before: []const u8, report: []const u8, rej: *Rejections) PairError![]const Pair {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, report, .{}) catch return error.BadReport;
    if (root != .object) return error.BadReport;
    const fields = root.object.get("fields") orelse return error.BadReport;
    if (fields != .array) return error.BadReport;
    const walk = try voice.docWalk(a, before);
    if (fields.array.items.len != walk.runs.len) return error.Mismatch;
    const out = try a.alloc(Pair, walk.runs.len);
    for (fields.array.items, walk.runs, out) |f, r, *o| {
        if (f != .object) return error.BadReport;
        const text = before[r.lo..r.hi];
        const b = f.object.get("before") orelse return error.BadReport;
        if (b != .object) return error.BadReport;
        const sha = b.object.get("sha256") orelse return error.BadReport;
        if (sha != .string) return error.BadReport;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, sha.string, &hex)) return error.Mismatch;
        if (f.object.get("status")) |s| if (s == .string and std.mem.eql(u8, s.string, "rejected")) {
            rej.guard += 1;
            if (f.object.get("reasons")) |rs| if (rs == .array and rs.array.items.len > 0) {
                const r0 = rs.array.items[0];
                if (r0 == .string and std.mem.startsWith(u8, r0.string, "backend error")) rej.backend += 1;
            };
        };
        const after = f.object.get("after") orelse return error.BadReport;
        o.* = .{ .before = text, .after = if (after == .string) after.string else text };
    }
    return out;
}

/// Lexicon file: one phrase per line; blank lines and `#` comments skipped.
fn parseLexicon(a: Allocator, bytes: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        try out.append(a, try std.mem.join(a, " ", try words(a, t)));
    }
    return out.items;
}

const usage_line = "usage: knap-mcp voice-tics [--label <s>] [--min-runs <n>] [--top <n>] [--lexicon <file>] <before.md> <after.md|report.json> [<before> <after>]...";

fn usage(msg: []const u8) u8 {
    std.debug.print("knap-mcp: {s}\n{s}\n", .{ msg, usage_line });
    return 1;
}

/// `knap-mcp voice-tics ... <before> <after>...`: one JSON profile on
/// stdout. A pair whose runs don't line up is skipped with a warning and
/// counted in `pairs_skipped`; exit 1 only when nothing could be scored.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    const a = ctx.arena;
    var o: Options = .{};
    var label: []const u8 = "";
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const names = [_][]const u8{ "--label", "--min-runs", "--top", "--lexicon" };
        const which = for (names, 0..) |n, k| {
            if (std.mem.eql(u8, arg, n)) break k;
        } else null;
        if (which == null) {
            if (arg.len > 1 and arg[0] == '-') return usage(try std.fmt.allocPrint(a, "voice-tics: unknown option '{s}'", .{arg}));
            try files.append(a, arg);
            continue;
        }
        i += 1;
        if (i >= args.len) return usage(try std.fmt.allocPrint(a, "missing value for {s}", .{arg}));
        const v = args[i];
        switch (which.?) {
            0 => label = v,
            1, 2 => {
                const n = std.fmt.parseInt(usize, v, 10) catch return usage(try std.fmt.allocPrint(a, "{s} needs a number", .{arg}));
                if (which.? == 1) o.min_runs = @max(n, 1) else o.top = n;
            },
            else => {
                const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, v, a, .limited(1 << 20)) catch
                    return usage(try std.fmt.allocPrint(a, "cannot read lexicon '{s}'", .{v}));
                o.lexicon = try parseLexicon(a, bytes);
            },
        }
    }
    if (files.items.len == 0 or files.items.len % 2 != 0) return usage("voice-tics needs <before> <after> pairs");

    var pairs: std.ArrayList(Pair) = .empty;
    var rej: Rejections = .{};
    var skipped: usize = 0;
    var n_pairs: usize = 0;
    var k: usize = 0;
    while (k < files.items.len) : (k += 2) {
        const bp, const ap = .{ files.items[k], files.items[k + 1] };
        const b = common.resolveDoc(ctx, bp) orelse return usage(try std.fmt.allocPrint(a, "no such file or doc '{s}'", .{bp}));
        const af = common.resolveDoc(ctx, ap) orelse return usage(try std.fmt.allocPrint(a, "no such file or doc '{s}'", .{ap}));
        const got = if (std.mem.endsWith(u8, ap, ".json"))
            pairsFromReport(a, b.bytes, af.bytes, &rej)
        else
            pairsFromDocs(a, b.bytes, af.bytes);
        const ps = got catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.debug.print("knap-mcp: voice-tics: skipping {s} / {s}: {s}\n", .{ bp, ap, @errorName(e) });
                skipped += 1;
                continue;
            },
        };
        n_pairs += 1;
        try pairs.appendSlice(a, ps);
    }
    var p = try score(a, pairs.items, o);
    p.label = label;
    p.pairs = n_pairs;
    p.pairs_skipped = skipped;
    p.rejected = rej.guard;
    p.backend_errors = rej.backend;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    try std.json.Stringify.value(p, .{}, &w.interface);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return @intFromBool(n_pairs == 0);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testRoot() []const u8 {
    std.Io.Dir.access(.cwd(), testing.io, "eval/voice-tics/fixture.before.md", .{}) catch return "knap-mcp/";
    return "";
}

fn readFixture(a: Allocator, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}eval/voice-tics/{s}", .{ testRoot(), rel });
    return std.Io.Dir.readFileAlloc(.cwd(), testing.io, path, a, .limited(1 << 20));
}

fn hitFor(hits: []const Hit, term: []const u8) ?Hit {
    for (hits) |h| if (std.mem.eql(u8, h.term, term)) return h;
    return null;
}

test "fixture: the issue's representative diffs score as tics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pairs = try pairsFromDocs(a, try readFixture(a, "fixture.before.md"), try readFixture(a, "fixture.after.md"));
    const p = try score(a, pairs, .{});
    try testing.expectEqual(@as(usize, 10), p.runs);
    try testing.expectEqual(@as(usize, 8), p.changed);
    try testing.expectEqual(@as(usize, 1), p.reworded);
    try testing.expectEqual(@as(usize, 7), p.insert_only);
    try testing.expectEqual(@as(usize, 8), p.lexicon_added);
    try testing.expectEqual(@as(usize, 2), p.emphasis_on_existing);
    try testing.expectEqual(@as(usize, 2), p.emphasis_ironic);
    try testing.expectEqual(@as(usize, 8), p.tic_runs);
    try testing.expectEqual(@as(usize, 9), p.added_content_words);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 9.0), p.repeat_share, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.0 / 9.0), p.distinct_ratio, 1e-9);
    const reg = hitFor(p.lexicon, "regrettably").?;
    try testing.expectEqual(@as(usize, 3), reg.runs);
    inline for (.{ "it seems", "in its purest form", "after due consideration", "politely", "firmly" }) |t|
        try testing.expectEqual(@as(usize, 1), hitFor(p.lexicon, t).?.added);
    try testing.expect(hitFor(p.emphasis, "kerning") != null);
    try testing.expect(hitFor(p.emphasis, "misplaced") != null);
    try testing.expectEqual(@as(usize, 1), p.repeats.len);
    try testing.expectEqualStrings("regrettably", p.repeats[0].term);
}

test "a flat pass-through scores zero" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try readFixture(a, "fixture.before.md");
    const p = try score(a, try pairsFromDocs(a, before, before), .{});
    try testing.expectEqual(@as(usize, 10), p.runs);
    inline for (.{ "changed", "lexicon_added", "emphasis_added", "tic_runs", "added_words", "reworded" }) |f|
        try testing.expectEqual(@as(usize, 0), @field(p, f));
    try testing.expectEqual(@as(usize, 0), p.repeats.len);
}

test "a lexicon hit already in the input is not added; layout moves are a mismatch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try score(a, &.{.{ .before = "Regrettably, the form was lost.", .after = "Regrettably, the form was *lost*." }}, .{});
    try testing.expectEqual(@as(usize, 0), p.lexicon_added);
    try testing.expectEqual(@as(usize, 1), p.emphasis_on_existing);
    try testing.expectEqual(@as(usize, 1), p.tic_runs);
    const key = try score(a, &.{.{ .before = "The freshness score was nine weeks old.", .after = "The *freshness score* was nine weeks old." }}, .{});
    try testing.expectEqual(@as(usize, 1), key.emphasis_on_existing);
    try testing.expectEqual(@as(usize, 0), key.emphasis_ironic);
    try testing.expectEqual(@as(usize, 0), key.tic_runs);
    const d = try score(a, &.{.{ .before = "The form was lost.", .after = "The form — of course — was lost." }}, .{});
    try testing.expectEqual(@as(usize, 2), d.dashes_added);
    try testing.expectEqual(@as(usize, 2), d.added_words);
    try testing.expectError(error.Mismatch, pairsFromDocs(a, "One.\n\nTwo.\n", "One.\n"));
}

test "spans: one level of *, **, _, ==, ~~; intraword _ and lone * are not spans" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try spans(a, "a *b* **c d** snake_case_name _e_ ==f== ~~g~~ 2 * 3 ~h~");
    const want = [_][]const u8{ "*b*", "**c d**", "_e_", "==f==", "~~g~~" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
}

test "report input: readable replies pair with the source, redacted ones stay unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "# T\n\nThe form was lost.\n\nNobody came.\n";
    var hex: [2][64]u8 = undefined;
    for ([_][]const u8{ "The form was lost.", "Nobody came." }, 0..) |s, n| {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(s, &d, .{});
        hex[n] = std.fmt.bytesToHex(d, .lower);
    }
    const report = try std.fmt.allocPrint(a,
        \\{{"fields":[{{"para":1,"status":"rewritten","before":{{"bytes":18,"sha256":"{s}"}},"after":"The form was, regrettably, lost."}},{{"para":2,"status":"rejected","before":{{"bytes":12,"sha256":"{s}"}},"after":{{"bytes":12,"sha256":"{s}"}},"reasons":["backend error: timeout"]}}]}}
    , .{ hex[0], hex[1], hex[1] });
    var rej: Rejections = .{};
    const pairs = try pairsFromReport(a, doc, report, &rej);
    try testing.expectEqual(@as(usize, 1), rej.guard);
    try testing.expectEqual(@as(usize, 1), rej.backend);
    const p = try score(a, pairs, .{});
    try testing.expectEqual(@as(usize, 2), p.runs);
    try testing.expectEqual(@as(usize, 1), p.changed);
    try testing.expectEqual(@as(usize, 1), p.lexicon_added);
    try testing.expectError(error.Mismatch, pairsFromReport(a, "# T\n\nOther text.\n\nNobody came.\n", report, &rej));
}
