//! Retrieval and claim checking over the frozen boris site artifact.
//!
//! Reads `<site>/artifact/search-index.json` and `completion.json` only;
//! no live indexing, no boris binary. `ask` is a byte-exact port of
//! `boris-site/ask.sh` (itself a port of the boris starter theme's search
//! client). `check` retrieves over claim pages the way `ask.sh --claims`
//! does, then decides yes / no / unknown from the claim's verdict tag, a
//! negation-polarity comparison and a term-coverage floor.
//!
//! Site = KNAP_BORIS_SITE, else `<templates_dir>/../../boris-site`.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const search_format = "boris-rendered-search-index";
pub const completion_format = "boris-completion-index";

pub const default_limit: usize = 5;
/// `check` answers unknown below this fraction of covered query terms.
pub const min_coverage: f64 = 0.5;

pub const Section = struct {
    level: i64 = 0,
    heading: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
    text: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

pub const Document = struct {
    path: []const u8,
    title: []const u8,
    sections: []const Section = &.{},
};

pub const Relation = struct {
    kind: []const u8,
    target: []const u8,
};

pub const Entity = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    relations: []const Relation = &.{},
};

pub const Artifact = struct {
    documents: []const Document,
    entities: []const Entity,

    pub fn entity(a: *const Artifact, id: []const u8) ?*const Entity {
        for (a.entities) |*e| {
            if (std.mem.eql(u8, e.id, id)) return e;
        }
        return null;
    }

    pub fn document(a: *const Artifact, id: []const u8) ?*const Document {
        for (a.documents) |*d| {
            if (std.mem.eql(u8, docId(d.path), id)) return d;
        }
        return null;
    }

    pub fn isClaim(a: *const Artifact, id: []const u8) bool {
        const e = a.entity(id) orelse return false;
        for (e.tags) |t| {
            if (std.mem.eql(u8, t, "claim")) return true;
        }
        return false;
    }
};

/// Entity id of a search-index document: its path minus `.html`.
pub fn docId(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".html")) path[0 .. path.len - ".html".len] else path;
}

/// The claim's verdict tag: its first tag other than `claim`.
pub fn verdictTag(e: *const Entity) ?[]const u8 {
    for (e.tags) |t| {
        if (!std.mem.eql(u8, t, "claim")) return t;
    }
    return null;
}

// --- loading -----------------------------------------------------------------

pub const ParseError = error{ BadArtifact, OutOfMemory };

/// Parse both artifact files. On `BadArtifact`, `msg` says which file and why.
pub fn parse(arena: Allocator, search_json: []const u8, completion_json: []const u8, msg: *[]const u8) ParseError!Artifact {
    const Search = struct { documents: []const Document };
    const Completion = struct { entities: []const Entity };
    const s = try parseChecked(Search, arena, search_json, search_format, "search-index.json", msg);
    const c = try parseChecked(Completion, arena, completion_json, completion_format, "completion.json", msg);
    return .{ .documents = s.documents, .entities = c.entities };
}

fn parseChecked(comptime T: type, arena: Allocator, bytes: []const u8, want: []const u8, name: []const u8, msg: *[]const u8) ParseError!T {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        msg.* = try std.fmt.allocPrint(arena, "{s} is not valid JSON", .{name});
        return error.BadArtifact;
    };
    if (v != .object) {
        msg.* = try std.fmt.allocPrint(arena, "{s} is not a JSON object", .{name});
        return error.BadArtifact;
    }
    const format = v.object.get("format") orelse .null;
    const version = v.object.get("schema_version") orelse .null;
    const format_ok = format == .string and std.mem.eql(u8, format.string, want);
    const version_ok = switch (version) {
        .integer => |i| i == 1,
        .float => |f| f == 1,
        else => false,
    };
    if (!format_ok or !version_ok) {
        msg.* = try std.fmt.allocPrint(arena, "{s}: unsupported format {s}, schema_version {s} (want \"{s}\", 1)", .{
            name,
            try std.json.Stringify.valueAlloc(arena, format, .{}),
            try std.json.Stringify.valueAlloc(arena, version, .{}),
            want,
        });
        return error.BadArtifact;
    }
    return std.json.parseFromValueLeaky(T, arena, v, .{ .ignore_unknown_fields = true }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        msg.* = try std.fmt.allocPrint(arena, "{s}: unexpected shape ({s})", .{ name, @errorName(e) });
        return error.BadArtifact;
    };
}

pub fn siteDir(ctx: *Ctx) error{OutOfMemory}![]const u8 {
    if (ctx.environ.get("KNAP_BORIS_SITE")) |dir| return dir;
    return std.fmt.allocPrint(ctx.arena, "{s}/../../boris-site", .{ctx.templates_dir});
}

pub fn load(ctx: *Ctx) error{ ToolFailed, OutOfMemory }!Artifact {
    const site = try siteDir(ctx);
    const search = try readArtifact(ctx, site, "search-index.json");
    const completion = try readArtifact(ctx, site, "completion.json");
    var msg: []const u8 = "";
    return parse(ctx.arena, search, completion, &msg) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadArtifact => ctx.fail("boris artifact in {s}: {s}", .{ site, msg }),
    };
}

fn readArtifact(ctx: *Ctx, site: []const u8, name: []const u8) error{ ToolFailed, OutOfMemory }![]const u8 {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/artifact/{s}", .{ site, name });
    return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(64 * 1024 * 1024)) catch
        ctx.fail("cannot read {s} (set KNAP_BORIS_SITE to the boris site directory)", .{path});
}

// --- ask: the ask.sh port ----------------------------------------------------

pub const Hit = struct {
    score: i64,
    doc: *const Document,
    section: usize,
    doc_index: usize,
    snippet: []const u8 = "",
};

/// Ranked hits, best first, at most `limit`. Same scores, order and
/// snippets as `ask.sh [-k limit] [--claims] <query>`.
pub fn ask(arena: Allocator, art: *const Artifact, query: []const u8, limit: usize, claims_only: bool) Allocator.Error![]Hit {
    const phrase = try collapse(arena, query, true, true);
    var terms: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, phrase, ' ');
    while (it.next()) |t| {
        if (t.len > 0) try terms.append(arena, t);
    }

    var hits: std.ArrayList(Hit) = .empty;
    for (art.documents, 0..) |*doc, di| {
        if (claims_only and !art.isClaim(docId(doc.path))) continue;
        const title = try collapse(arena, doc.title, true, true);
        var best: ?Hit = null;
        for (doc.sections, 0..) |s, si| {
            const v = [3][]const u8{
                try collapse(arena, s.heading orelse "", true, true),
                try collapse(arena, s.text orelse "", true, true),
                try collapse(arena, s.code orelse "", true, true),
            };
            var base: i64 = 0;
            for (terms.items) |t| {
                if (has(title, t)) base += 12;
                if (has(v[0], t)) base += 8;
                if (has(v[1], t)) base += 2;
                if (has(v[2], t)) base += 1;
            }
            if (base == 0) continue;
            var score = base;
            if (s.level == 1) score += 1;
            if (has(title, phrase) or has(v[0], phrase) or has(v[1], phrase) or has(v[2], phrase)) score += 5;
            // jq's max_by keeps the last of equal maxima.
            if (best == null or score >= best.?.score)
                best = .{ .score = score, .doc = doc, .section = si, .doc_index = di };
        }
        if (best) |b| try hits.append(arena, b);
    }

    std.mem.sort(Hit, hits.items, {}, hitLess);
    const out = hits.items[0..@min(limit, hits.items.len)];
    for (out) |*h| h.snippet = try excerpt(arena, h.doc.sections[h.section], terms.items);
    return out;
}

fn hitLess(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    switch (std.mem.order(u8, a.doc.path, b.doc.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.section != b.section) return a.section < b.section;
    return a.doc_index < b.doc_index;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return needle.len > 0 and std.mem.indexOf(u8, hay, needle) != null;
}

/// ask.sh `excerpt`: the first term (in query order) found in the section's
/// prose (else code, else heading) anchors a 150-codepoint window starting
/// 48 codepoints before it, with `…` on each truncated side.
fn excerpt(arena: Allocator, s: Section, terms: []const []const u8) Allocator.Error![]const u8 {
    const raw = if (nonEmpty(s.text)) s.text.? else if (nonEmpty(s.code)) s.code.? else s.heading orelse "";
    const src = try collapse(arena, raw, false, false);
    const low = try std.ascii.allocLowerString(arena, src);
    var at: usize = 0;
    for (terms) |t| {
        if (std.mem.indexOf(u8, low, t)) |b| {
            at = cpLen(src[0..b]);
            break;
        }
    }
    const window = 150;
    const start = at -| 48;
    return std.mem.concat(arena, u8, &.{
        if (start > 0) "…" else "",
        src[cpByte(src, start)..cpByte(src, start + window)],
        if (start + window < cpLen(src)) "…" else "",
    });
}

fn nonEmpty(s: ?[]const u8) bool {
    return s != null and s.?.len > 0;
}

fn cpLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of codepoint `n`, clamped to `s.len`.
fn cpByte(s: []const u8, n: usize) usize {
    var seen: usize = 0;
    for (s, 0..) |b, i| {
        if (b & 0xc0 == 0x80) continue;
        if (seen == n) return i;
        seen += 1;
    }
    return s.len;
}

/// Byte length of the whitespace codepoint at `s[i]`, or 0. The set is
/// Unicode White_Space, which is what jq's (Oniguruma) `\s` matches.
fn wsLen(s: []const u8, i: usize) usize {
    const b = s[i];
    if (b == ' ' or (b >= 0x09 and b <= 0x0d)) return 1;
    if (b == 0xc2 and i + 1 < s.len and (s[i + 1] == 0x85 or s[i + 1] == 0xa0)) return 2;
    if (i + 2 >= s.len) return 0;
    const b1 = s[i + 1];
    const b2 = s[i + 2];
    return switch (b) {
        0xe1 => if (b1 == 0x9a and b2 == 0x80) 3 else 0, // U+1680
        0xe2 => if ((b1 == 0x80 and ((b2 >= 0x80 and b2 <= 0x8a) or b2 == 0xa8 or b2 == 0xa9 or b2 == 0xaf)) or
            (b1 == 0x81 and b2 == 0x9f)) 3 else 0, // U+2000..200A, 2028, 2029, 202F, 205F
        0xe3 => if (b1 == 0x80 and b2 == 0x80) 3 else 0, // U+3000
        else => 0,
    };
}

/// jq `gsub("\\s+"; " ")`, optionally with `ascii_downcase` and with one
/// leading and one trailing space removed (ask.sh `norm`).
fn collapse(arena: Allocator, s: []const u8, lower: bool, trim: bool) Allocator.Error![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        var n = wsLen(s, i);
        if (n == 0) {
            out.appendAssumeCapacity(if (lower) std.ascii.toLower(s[i]) else s[i]);
            i += 1;
            continue;
        }
        while (n > 0) : (n = if (i < s.len) wsLen(s, i) else 0) i += n;
        out.appendAssumeCapacity(' ');
    }
    var r = out.items;
    if (trim and r.len > 0 and r[0] == ' ') r = r[1..];
    if (trim and r.len > 0 and r[r.len - 1] == ' ') r = r[0 .. r.len - 1];
    return r;
}

// --- check -------------------------------------------------------------------

pub const Answer = enum { yes, no, unknown };
pub const Polarity = enum { same, opposite };

pub const Cite = struct {
    id: []const u8,
    title: ?[]const u8,
    url: ?[]const u8,
};

pub const Match = struct {
    id: []const u8,
    title: []const u8,
    verdict: ?[]const u8,
    cites: []const Cite,
};

pub const Verdict = struct {
    answer: Answer,
    /// `supported` | `refuted` | `unverified`; null when no decision was made.
    verdict: ?[]const u8,
    polarity: ?Polarity,
    coverage: f64,
    matched: ?Match,
    reason: []const u8,
};

const stopwords = [_][]const u8{
    "a",      "about", "all",     "also",  "am",   "an",    "and",  "any",    "are",    "as",
    "at",     "be",    "been",    "being", "but",  "by",    "can",  "could",  "did",    "do",
    "does",   "doing", "done",    "for",   "from", "get",   "gets", "had",    "has",    "have",
    "having", "how",   "i",       "if",    "in",   "into",  "is",   "it",     "it's",   "its",
    "just",   "may",   "might",   "must",  "of",   "on",    "or",   "really", "should", "so",
    "still",  "such",  "than",    "that",  "the",  "their", "them", "then",   "there",  "these",
    "they",   "this",  "those",   "to",    "true", "us",    "was",  "we",     "were",   "what",
    "when",   "where", "whether", "which", "who",  "will",  "with", "would",  "you",    "your",
};

const negation_cues = [_][]const u8{ "no", "not", "never", "without", "lacks", "missing", "cannot" };

fn inList(list: []const []const u8, w: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}

fn isNegation(w: []const u8) bool {
    return inList(&negation_cues, w) or std.mem.endsWith(u8, w, "n't");
}

fn hasNegation(ws: []const []const u8) bool {
    for (ws) |w| {
        if (isNegation(w)) return true;
    }
    return false;
}

/// Lowercased ASCII words: runs of [a-z0-9] with interior `-` and `'`
/// (U+2019 counts as `'`). Other bytes, including non-ASCII, separate.
fn words(arena: Allocator, s: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i <= s.len) {
        var c: u8 = ' ';
        var n: usize = 1;
        if (i < s.len) {
            c = std.ascii.toLower(s[i]);
            if (std.mem.startsWith(u8, s[i..], "\u{2019}")) {
                c = '\'';
                n = 3;
            }
        }
        if (std.ascii.isAlphanumeric(c) or ((c == '-' or c == '\'') and cur.items.len > 0)) {
            try cur.append(arena, c);
        } else {
            const w = std.mem.trimEnd(u8, cur.items, "-'");
            if (w.len > 0) try list.append(arena, try arena.dupe(u8, w));
            cur.clearRetainingCapacity();
        }
        i += n;
    }
    return list.items;
}

/// Plural fold for coverage matching: drop `'s`, then one trailing `s`
/// (not `ss`) from words longer than 3 bytes.
fn fold(w: []const u8) []const u8 {
    var r = w;
    if (std.mem.endsWith(u8, r, "'s")) r = r[0 .. r.len - 2];
    if (r.len > 3 and r[r.len - 1] == 's' and r[r.len - 2] != 's') r = r[0 .. r.len - 1];
    return r;
}

const TermSet = std.StringHashMapUnmanaged(void);

/// Folded words of a page's title and every section, plus the parts of
/// hyphenated words.
fn pageTerms(arena: Allocator, doc: *const Document) Allocator.Error!TermSet {
    var set: TermSet = .empty;
    try addTerms(arena, &set, doc.title);
    for (doc.sections) |s| {
        try addTerms(arena, &set, s.heading orelse "");
        try addTerms(arena, &set, s.text orelse "");
        try addTerms(arena, &set, s.code orelse "");
    }
    return set;
}

fn addTerms(arena: Allocator, set: *TermSet, text: []const u8) Allocator.Error!void {
    for (try words(arena, text)) |w| {
        try set.put(arena, fold(w), {});
        if (std.mem.indexOfScalar(u8, w, '-') == null) continue;
        var parts = std.mem.splitScalar(u8, w, '-');
        while (parts.next()) |p| {
            if (p.len > 0) try set.put(arena, fold(p), {});
        }
    }
}

/// Decide a claim against the artifact's claim pages.
///
/// Candidates are the claim pages. `coverage` is the fraction of the
/// claim's content terms (non-stopword, non-negation, plural-folded words,
/// minus terms every claim page contains) found in a page. The match is the
/// page with the highest coverage; ties go to the `ask --claims` rank, then
/// document order. Below `min_coverage` the answer is unknown.
pub fn check(arena: Allocator, art: *const Artifact, claim: []const u8) Allocator.Error!Verdict {
    const query_words = try words(arena, claim);

    var pages: std.ArrayList(usize) = .empty;
    var sets: std.ArrayList(TermSet) = .empty;
    for (art.documents, 0..) |*doc, di| {
        if (!art.isClaim(docId(doc.path))) continue;
        try pages.append(arena, di);
        try sets.append(arena, try pageTerms(arena, doc));
    }

    var terms: std.ArrayList([]const u8) = .empty;
    for (query_words) |w| {
        if (inList(&stopwords, w) or isNegation(w)) continue;
        const f = fold(w);
        if (inList(terms.items, f)) continue;
        if (sets.items.len > 1) {
            const everywhere = for (sets.items) |s| {
                if (!s.contains(f)) break false;
            } else true;
            if (everywhere) continue;
        }
        try terms.append(arena, f);
    }

    const ranked = try ask(arena, art, claim, std.math.maxInt(usize), true);
    var best: ?usize = null;
    var best_found: usize = 0;
    var best_rank: usize = std.math.maxInt(usize);
    for (pages.items, sets.items, 0..) |di, set, pi| {
        var found: usize = 0;
        for (terms.items) |t| {
            if (set.contains(t)) found += 1;
        }
        var rank: usize = std.math.maxInt(usize);
        for (ranked, 0..) |h, r| {
            if (h.doc_index == di) rank = r;
        }
        if (best == null or found > best_found or (found == best_found and rank < best_rank)) {
            best = pi;
            best_found = found;
            best_rank = rank;
        }
    }

    const no_match: Verdict = .{
        .answer = .unknown,
        .verdict = null,
        .polarity = null,
        .coverage = 0,
        .matched = null,
        .reason = "no claim page shares a term with the query",
    };
    const pi = best orelse return no_match;
    if (best_found == 0 and best_rank == std.math.maxInt(usize)) return no_match;

    const doc = &art.documents[pages.items[pi]];
    const id = docId(doc.path);
    const ent = art.entity(id).?;
    const title = ent.title orelse doc.title;
    const tag = verdictTag(ent);
    const matched: Match = .{ .id = id, .title = title, .verdict = tag, .cites = try cites(arena, art, ent) };
    const coverage = if (terms.items.len == 0) 0 else @round(@as(f64, @floatFromInt(best_found)) / @as(f64, @floatFromInt(terms.items.len)) * 10000) / 10000;

    if (coverage < min_coverage) {
        var missing: std.ArrayList(u8) = .empty;
        for (terms.items) |t| {
            if (sets.items[pi].contains(t)) continue;
            if (missing.items.len > 0) try missing.appendSlice(arena, ", ");
            try missing.appendSlice(arena, t);
        }
        const reason = if (terms.items.len == 0)
            try std.fmt.allocPrint(arena, "the query has no terms beyond stopwords and words every claim page shares; best match \"{s}\" is not evidence either way", .{title})
        else
            try std.fmt.allocPrint(arena, "best match \"{s}\" covers {d} of {d} query terms (missing: {s}); below {d}, so unknown", .{ title, best_found, terms.items.len, missing.items, min_coverage });
        return .{ .answer = .unknown, .verdict = null, .polarity = null, .coverage = coverage, .matched = matched, .reason = reason };
    }

    const polarity: Polarity = if (hasNegation(query_words) != hasNegation(try words(arena, title))) .opposite else .same;
    const known = [_][]const u8{ "supported", "refuted", "unverified" };
    const verdict: ?[]const u8 = if (tag != null and inList(&known, tag.?)) tag else null;
    const v = verdict orelse "";
    const answer: Answer = if (std.mem.eql(u8, v, "supported"))
        (if (polarity == .same) .yes else .no)
    else if (std.mem.eql(u8, v, "refuted"))
        (if (polarity == .same) .no else .yes)
    else
        .unknown;

    const reason = if (verdict == null)
        try std.fmt.allocPrint(arena, "matched \"{s}\" carries no verdict tag (supported, refuted or unverified), so unknown", .{title})
    else if (answer == .unknown)
        try std.fmt.allocPrint(arena, "matched \"{s}\" is unverified; the artifact cannot answer either way", .{title})
    else if (polarity == .same)
        try std.fmt.allocPrint(arena, "matched \"{s}\" is {s} and says what the query says, so {s}", .{ title, v, @tagName(answer) })
    else
        try std.fmt.allocPrint(arena, "matched \"{s}\" is {s} and says the opposite of the query, so {s}", .{ title, v, @tagName(answer) });
    return .{ .answer = answer, .verdict = verdict, .polarity = polarity, .coverage = coverage, .matched = matched, .reason = reason };
}

fn cites(arena: Allocator, art: *const Artifact, e: *const Entity) Allocator.Error![]const Cite {
    var list: std.ArrayList(Cite) = .empty;
    for (e.relations) |r| {
        if (!std.mem.eql(u8, r.kind, "cites")) continue;
        const doc = art.document(r.target);
        const title = if (art.entity(r.target)) |t| t.title else null;
        try list.append(arena, .{
            .id = r.target,
            .title = title orelse if (doc) |d| d.title else null,
            .url = if (doc) |d| sourceUrl(d) else null,
        });
    }
    return list.items;
}

/// `URL: <url>` from a source page's level-1 section text.
fn sourceUrl(doc: *const Document) ?[]const u8 {
    for (doc.sections) |s| {
        if (s.level != 1) continue;
        const text = s.text orelse continue;
        const at = std.mem.indexOf(u8, text, "URL:") orelse continue;
        const rest = std.mem.trimStart(u8, text[at + "URL:".len ..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
        if (end > 0) return rest[0..end];
    }
    return null;
}

// --- JSON output -------------------------------------------------------------

pub fn writeAskJson(w: *Writer, query: []const u8, hits: []const Hit) Writer.Error!void {
    try w.writeAll("{\"query\":");
    try str(w, query);
    try w.writeAll(",\"results\":[");
    for (hits, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        const s = h.doc.sections[h.section];
        try w.print("{{\"score\":{d},\"id\":", .{h.score});
        try str(w, docId(h.doc.path));
        try w.writeAll(",\"path\":");
        try str(w, h.doc.path);
        try w.writeAll(",\"fragment\":");
        try str(w, s.fragment);
        try w.writeAll(",\"title\":");
        try str(w, h.doc.title);
        try w.writeAll(",\"heading\":");
        try str(w, s.heading);
        try w.writeAll(",\"snippet\":");
        try str(w, h.snippet);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

pub fn writeCheckJson(w: *Writer, claim: []const u8, v: Verdict) Writer.Error!void {
    try w.writeAll("{\"claim\":");
    try str(w, claim);
    try w.print(",\"answer\":\"{s}\",\"verdict\":", .{@tagName(v.answer)});
    try str(w, v.verdict);
    try w.writeAll(",\"polarity\":");
    try str(w, if (v.polarity) |p| @tagName(p) else null);
    try w.print(",\"coverage\":{d},\"matched\":", .{v.coverage});
    if (v.matched) |m| {
        try w.writeAll("{\"id\":");
        try str(w, m.id);
        try w.writeAll(",\"title\":");
        try str(w, m.title);
        try w.writeAll(",\"verdict\":");
        try str(w, m.verdict);
        try w.writeAll(",\"cites\":[");
        for (m.cites, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try str(w, c.id);
            try w.writeAll(",\"title\":");
            try str(w, c.title);
            try w.writeAll(",\"url\":");
            try str(w, c.url);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    } else try w.writeAll("null");
    try w.writeAll(",\"reason\":");
    try str(w, v.reason);
    try w.writeAll("}");
}

fn str(w: *Writer, s: ?[]const u8) Writer.Error!void {
    try std.json.Stringify.value(s, .{}, w);
}

// --- tests -------------------------------------------------------------------

const fixture_search =
    \\{"format":"boris-rendered-search-index","schema_version":1,"documents":[
    \\ {"path":"claims/no-backups.html","title":"Zed has no managed backups","sections":[
    \\  {"level":0,"heading":"","fragment":"","text":"","code":""},
    \\  {"level":1,"heading":"Zed has no managed backups","fragment":"zed-has-no-managed-backups","text":"","code":""},
    \\  {"level":2,"heading":"Claim","fragment":"claim","text":"Zed has no managed backup today.","code":""},
    \\  {"level":2,"heading":"Verdict","fragment":"verdict","text":"Supported. The docs list only a manual dump.","code":""}]},
    \\ {"path":"claims/sharding.html","title":"Zed shards the keyspace","sections":[
    \\  {"level":1,"heading":"Zed shards the keyspace","fragment":"zed-shards-the-keyspace","text":"","code":""},
    \\  {"level":2,"heading":"Claim","fragment":"claim","text":"Zed partitions keys across nodes.","code":""},
    \\  {"level":2,"heading":"Verdict","fragment":"verdict","text":"Refuted. One node owns the keyspace.","code":""}]},
    \\ {"path":"docs.html","title":"Zed docs \u2014 backups","sections":[
    \\  {"level":1,"heading":"Zed docs \u2014 backups","fragment":"zed-docs-backups","text":"URL: https://example.com/zed#backups Kind: documentation","code":""},
    \\  {"level":2,"heading":"Notes","fragment":"notes","text":"Backups\u00a0are   manual.","code":"zed dump"},
    \\  {"level":2,"heading":"More notes","fragment":"more-notes","text":"Backups are manual.","code":""}]}]}
;

const fixture_completion =
    \\{"format":"boris-completion-index","schema_version":1,"entities":[
    \\ {"id":"claims/no-backups","title":"Zed has no managed backups","tags":["claim","supported"],
    \\  "relations":[{"kind":"cites","target":"docs"},{"kind":"related","target":"claims/sharding"}]},
    \\ {"id":"claims/sharding","title":"Zed shards the keyspace","tags":["claim","refuted"],"relations":[]},
    \\ {"id":"docs","title":"Zed docs \u2014 backups","tags":["source"],"relations":[]}]}
;

fn fixture(arena: Allocator) !Artifact {
    var msg: []const u8 = "";
    return parse(arena, fixture_search, fixture_completion, &msg);
}

test "parse rejects a wrong format or schema_version" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var msg: []const u8 = "";
    try std.testing.expectError(error.BadArtifact, parse(a.allocator(),
        \\{"format":"boris-rendered-search-index","schema_version":2,"documents":[]}
    , fixture_completion, &msg));
    try std.testing.expect(std.mem.indexOf(u8, msg, "schema_version 2") != null);
    try std.testing.expectError(error.BadArtifact, parse(a.allocator(), fixture_search,
        \\{"format":"something-else","schema_version":1,"entities":[]}
    , &msg));
    try std.testing.expect(std.mem.startsWith(u8, msg, "completion.json: unsupported format \"something-else\""));
    try std.testing.expectError(error.BadArtifact, parse(a.allocator(), "[", fixture_completion, &msg));
}

test "ask scores, ties and order match ask.sh" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixture(a.allocator());
    const hits = try ask(a.allocator(), &art, "managed backups", 5, false);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // Title 12+12, heading 8+8, level 1, phrase 5 = 46 on the level-1 section.
    try std.testing.expectEqualStrings("claims/no-backups.html", hits[0].doc.path);
    try std.testing.expectEqual(@as(i64, 46), hits[0].score);
    try std.testing.expectEqual(@as(usize, 1), hits[0].section);
    // docs: title 12 on every section; the level-1 section adds heading 8,
    // text 2 (the URL) and level 1 (23); the notes sections get 12+2.
    try std.testing.expectEqualStrings("docs.html", hits[1].doc.path);
    try std.testing.expectEqual(@as(i64, 23), hits[1].score);
    try std.testing.expectEqual(@as(usize, 0), hits[1].section);

    // "manual": docs sections 1 and 2 tie at 2; max_by keeps the last one.
    const tie = try ask(a.allocator(), &art, "manual", 5, false);
    try std.testing.expectEqual(@as(usize, 2), tie.len);
    try std.testing.expectEqualStrings("claims/no-backups.html", tie[0].doc.path);
    try std.testing.expectEqual(@as(usize, 2), tie[1].section);

    // Equal scores sort by path: both claim titles contain "zed".
    const both = try ask(a.allocator(), &art, "ZED", 1, true);
    try std.testing.expectEqual(@as(usize, 1), both.len);
    try std.testing.expectEqualStrings("claims/no-backups.html", both[0].doc.path);

    try std.testing.expectEqual(@as(usize, 0), (try ask(a.allocator(), &art, "kubernetes", 5, false)).len);
    try std.testing.expectEqual(@as(usize, 0), (try ask(a.allocator(), &art, "  ", 5, false)).len);
    try std.testing.expectEqual(@as(usize, 0), (try ask(a.allocator(), &art, "zed", 0, false)).len);
}

test "unicode whitespace collapses and the phrase bonus sees it" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("a b c d", try collapse(a.allocator(), " A\u{00a0}\u{2003} b\t\nC\u{3000}D ", true, true));
    try std.testing.expectEqualStrings(" A b ", try collapse(a.allocator(), "\u{2028}A  b\u{205f}", false, false));
    try std.testing.expectEqualStrings("a\u{200b}b", try collapse(a.allocator(), "a\u{200b}b", true, true));
    const art = try fixture(a.allocator());
    const hits = try ask(a.allocator(), &art, "backups are manual", 5, false);
    try std.testing.expectEqualStrings("docs.html", hits[0].doc.path);
    // Notes: title 12, text 2+2+2, phrase 5 (through the NBSP). All three
    // docs sections tie at 23, so the last one is kept.
    try std.testing.expectEqual(@as(i64, 12 + 2 + 2 + 2 + 5), hits[0].score);
    try std.testing.expectEqual(@as(usize, 2), hits[0].section);
}

test "excerpt windows by codepoint with ellipses" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const rep = struct {
        fn rep(alloc: Allocator, s: []const u8, n: usize) ![]const u8 {
            var l: std.ArrayList(u8) = .empty;
            for (0..n) |_| try l.appendSlice(alloc, s);
            return l.items;
        }
    }.rep;
    const long = try std.mem.concat(al, u8, &.{ try rep(al, "\u{2014}", 60), "needle", try rep(al, "x", 200) });
    const snip = try excerpt(al, .{ .text = long }, &.{ "absent", "needle" });
    try std.testing.expect(std.mem.startsWith(u8, snip, try std.mem.concat(al, u8, &.{ "\u{2026}", try rep(al, "\u{2014}", 48), "needle" })));
    try std.testing.expectEqual(@as(usize, 1 + 150 + 1), cpLen(snip));
    try std.testing.expect(std.mem.endsWith(u8, snip, "x\u{2026}"));
    // No hit anchors at 0; short sources get no ellipsis; code then heading.
    try std.testing.expectEqualStrings("Short text.", try excerpt(a.allocator(), .{ .text = "Short  text." }, &.{"zzz"}));
    try std.testing.expectEqualStrings("zed dump", try excerpt(a.allocator(), .{ .text = "", .code = "zed dump" }, &.{"zed"}));
    try std.testing.expectEqualStrings("Head", try excerpt(a.allocator(), .{ .heading = "Head" }, &.{"x"}));
}

test "check: opposite polarity on a supported claim answers no" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixture(a.allocator());
    const v = try check(a.allocator(), &art, "Does Zed have managed backups?");
    try std.testing.expectEqual(Answer.no, v.answer);
    try std.testing.expectEqual(Polarity.opposite, v.polarity.?);
    try std.testing.expectEqualStrings("supported", v.verdict.?);
    try std.testing.expectEqual(@as(f64, 1), v.coverage);
    try std.testing.expectEqualStrings("Zed has no managed backups", v.matched.?.title);
    try std.testing.expectEqual(@as(usize, 1), v.matched.?.cites.len);
    try std.testing.expectEqualStrings("https://example.com/zed#backups", v.matched.?.cites[0].url.?);
    try std.testing.expectEqualStrings("Zed docs \u{2014} backups", v.matched.?.cites[0].title.?);

    const same = try check(a.allocator(), &art, "Zed lacks managed backups");
    try std.testing.expectEqual(Answer.yes, same.answer);
    try std.testing.expectEqual(Polarity.same, same.polarity.?);
}

test "check: refuted claims and low coverage" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixture(a.allocator());
    const refuted = try check(a.allocator(), &art, "Zed shards its keyspace");
    try std.testing.expectEqual(Answer.no, refuted.answer);
    try std.testing.expectEqualStrings("claims/sharding", refuted.matched.?.id);
    const flipped = try check(a.allocator(), &art, "Zed doesn't shard the keyspace");
    try std.testing.expectEqual(Answer.yes, flipped.answer);
    try std.testing.expectEqual(Polarity.opposite, flipped.polarity.?);

    // "zed" is on every claim page, so it does not count; "sql" and
    // "supports" are nowhere. The best match is still returned.
    const sql = try check(a.allocator(), &art, "Zed supports SQL");
    try std.testing.expectEqual(Answer.unknown, sql.answer);
    try std.testing.expect(sql.verdict == null and sql.polarity == null);
    try std.testing.expectEqual(@as(f64, 0), sql.coverage);
    try std.testing.expect(sql.matched != null);

    const none = try check(a.allocator(), &art, "kubernetes operators");
    try std.testing.expectEqual(Answer.unknown, none.answer);
    try std.testing.expect(none.matched == null);
}

test "words and fold" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ws = try words(a.allocator(), "Doesn\u{2019}t AcmeDB's single-region—setup -x- p99?");
    const want = [_][]const u8{ "doesn't", "acmedb's", "single-region", "setup", "x", "p99" };
    try std.testing.expectEqual(want.len, ws.len);
    for (want, ws) |e, g| try std.testing.expectEqualStrings(e, g);
    try std.testing.expectEqualStrings("acmedb", fold("acmedb's"));
    try std.testing.expectEqualStrings("backup", fold("backups"));
    try std.testing.expectEqualStrings("across", fold("across"));
    try std.testing.expectEqualStrings("2ms", fold("2ms"));
    try std.testing.expect(isNegation("doesn't") and isNegation("without") and !isNegation("nothing"));
}

test "JSON output shapes" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixture(a.allocator());
    var out: Writer.Allocating = .init(a.allocator());
    try writeAskJson(&out.writer, "zed \"q\"", try ask(a.allocator(), &art, "keyspace", 1, false));
    try std.testing.expectEqualStrings(
        \\{"query":"zed \"q\"","results":[{"score":26,"id":"claims/sharding","path":"claims/sharding.html","fragment":"zed-shards-the-keyspace","title":"Zed shards the keyspace","heading":"Zed shards the keyspace","snippet":"Zed shards the keyspace"}]}
    , out.written());

    var out2: Writer.Allocating = .init(a.allocator());
    try writeCheckJson(&out2.writer, "Zed supports SQL", try check(a.allocator(), &art, "Zed supports SQL"));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), out2.written(), .{});
    try std.testing.expectEqualStrings("unknown", parsed.object.get("answer").?.string);
    try std.testing.expect(parsed.object.get("verdict").? == .null);
    try std.testing.expect(parsed.object.get("matched").? == .object);
}
