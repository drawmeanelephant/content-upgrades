//! Formatting-density score: how much structure and typographic apparatus
//! a rendered markdown doc carries per unit of prose. It is the number the
//! ratchet loop climbs, so it is deterministic, native, and never a model
//! call.
//!
//! Every signal is counted, length-normalized (per 1000 words, or as a
//! share of prose characters), then put through a plateau curve: credit
//! rises to the signal's full weight at `sat`, holds, and decays past
//! `over`, so confetti earns less than restraint (dense is not noisy).
//! Each positive signal past `over` also pays the `overload` tax, and
//! format_check warnings and bare URLs subtract. Every weight and threshold
//! lives in the two tables below.

const std = @import("std");
const formatcheck = @import("formatcheck.zig");

// --- Tuning ------------------------------------------------------------------

/// Scorer contract version. Any change to the tables below bumps it, and
/// every published number cites it.
pub const version = "density/1";

/// Short docs are normalized as if they had this many words, so a 40-word
/// stub with one table doesn't read as 25 tables per 1000 words.
pub const min_words: f64 = 200;

const no_decay = std.math.inf(f64);

pub const Basis = enum {
    /// count per 1000 prose words
    per_kwords,
    /// share of prose characters, 0..1
    share,
    /// the count itself (variety, property counts)
    absolute,
};

pub const Id = enum {
    callouts,
    footnotes,
    tables,
    wikilinks,
    embeds,
    fragment_links,
    links,
    frontmatter,
    code_fences,
    styled_runs,
    styled_coverage,
    emphasis_variety,
    blockquotes,
    heading_levels,
    heading_density,
    lists,
    block_variety,
    raw_urls,
    overload,
};

pub const Spec = struct {
    id: Id,
    /// Contribution at full credit; negative for penalties.
    weight: f64,
    basis: Basis,
    /// Value at which the signal earns full weight.
    sat: f64,
    /// Past this the signal reads as noise: credit decays linearly...
    over: f64 = no_decay,
    /// ...to nothing here.
    zero: f64 = no_decay,
};

/// Positive weights sum to 100 (checked below). Table order is breakdown
/// order; `overload` must stay last because it counts the rows above it.
pub const specs = [_]Spec{
    // Apparatus: what models skip, so it carries most of the weight (63).
    .{ .id = .callouts, .weight = 11, .basis = .per_kwords, .sat = 2, .over = 12, .zero = 24 },
    .{ .id = .footnotes, .weight = 12, .basis = .per_kwords, .sat = 4, .over = 30, .zero = 60 },
    .{ .id = .tables, .weight = 10, .basis = .per_kwords, .sat = 1.5, .over = 10, .zero = 20 },
    .{ .id = .wikilinks, .weight = 7, .basis = .per_kwords, .sat = 4, .over = 40, .zero = 80 },
    .{ .id = .embeds, .weight = 4, .basis = .per_kwords, .sat = 1, .over = 10, .zero = 20 },
    .{ .id = .fragment_links, .weight = 4, .basis = .per_kwords, .sat = 2, .over = 20, .zero = 40 },
    .{ .id = .links, .weight = 6, .basis = .per_kwords, .sat = 5, .over = 50, .zero = 100 },
    .{ .id = .frontmatter, .weight = 6, .basis = .absolute, .sat = 4 },
    .{ .id = .code_fences, .weight = 3, .basis = .per_kwords, .sat = 1, .over = 10, .zero = 20 },
    // Typography (18).
    .{ .id = .styled_runs, .weight = 5, .basis = .per_kwords, .sat = 15, .over = 80, .zero = 160 },
    .{ .id = .styled_coverage, .weight = 6, .basis = .share, .sat = 0.08, .over = 0.30, .zero = 0.60 },
    .{ .id = .emphasis_variety, .weight = 4, .basis = .absolute, .sat = 3 },
    .{ .id = .blockquotes, .weight = 3, .basis = .per_kwords, .sat = 1, .over = 8, .zero = 16 },
    // Structure: every model already does this, so it is cheap (19).
    .{ .id = .heading_levels, .weight = 3, .basis = .absolute, .sat = 3 },
    .{ .id = .heading_density, .weight = 4, .basis = .per_kwords, .sat = 8, .over = 50, .zero = 100 },
    .{ .id = .lists, .weight = 4, .basis = .per_kwords, .sat = 3, .over = 20, .zero = 40 },
    .{ .id = .block_variety, .weight = 8, .basis = .absolute, .sat = 6 },
    // Penalties.
    .{ .id = .raw_urls, .weight = -6, .basis = .per_kwords, .sat = 10 },
    .{ .id = .overload, .weight = -20, .basis = .absolute, .sat = 4 },
};

/// format_check warnings fold in as point deductions, per rule.
pub const Penalty = struct {
    rule: []const u8,
    /// Points off per warning...
    per: f64,
    /// ...and at most this many for the rule.
    cap: f64,
};

pub const penalties = [_]Penalty{
    .{ .rule = "skipped-heading", .per = 2, .cap = 6 },
    .{ .rule = "wall-of-text", .per = 4, .cap = 8 },
    .{ .rule = "unresolved-footnote", .per = 3, .cap = 9 },
    .{ .rule = "unused-footnote", .per = 2, .cap = 6 },
    .{ .rule = "empty-callout", .per = 3, .cap = 9 },
    .{ .rule = "raw-url-count", .per = 2, .cap = 2 },
    .{ .rule = "unclosed-fence", .per = 5, .cap = 5 },
    .{ .rule = "heading-ratio", .per = 4, .cap = 4 },
    .{ .rule = "list-heavy", .per = 4, .cap = 4 },
    // Catch-all for rules format_check adds later; must stay last.
    .{ .rule = "other", .per = 2, .cap = 6 },
};

comptime {
    var sum: f64 = 0;
    for (specs) |sp| {
        if (sp.weight > 0) sum += sp.weight;
        if (!(sp.sat > 0 and sp.sat <= sp.over and (sp.over < sp.zero or sp.over == no_decay)))
            @compileError("density: bad curve for " ++ @tagName(sp.id));
    }
    if (sum != 100) @compileError("density: positive weights must sum to 100");
    if (specs.len != @typeInfo(Id).@"enum".field_names.len) @compileError("density: one spec per Id");
    if (specs[specs.len - 1].id != .overload) @compileError("density: overload must be the last spec");
}

const penalty_names = blk: {
    var names: [penalties.len][]const u8 = undefined;
    for (penalties, 0..) |p, i| names[i] = "format_check." ++ p.rule;
    break :blk names;
};

// --- Public surface ----------------------------------------------------------

pub const Signal = struct {
    name: []const u8,
    /// What was counted: items, styled characters, distinct kinds, warnings.
    raw: usize,
    /// `raw` after length normalization; what the curve sees.
    value: f64,
    /// 0..1 credit (or 0..1 of the penalty cap).
    normalized: f64,
    weight: f64,
    /// normalized * weight; the signals' contributions sum to the total
    /// before clamping.
    contribution: f64,
};

pub const Score = struct {
    /// 0..100.
    total: f64,
    /// Prose words: frontmatter and fenced code excluded.
    words: usize,
    /// One row per `specs` entry, then one per `penalties` entry.
    signals: []const Signal,
    warnings: []const formatcheck.Warning,
};

/// Scores a rendered markdown doc. Everything is allocated in `arena`;
/// free it as a whole.
pub fn score(arena: std.mem.Allocator, markdown: []const u8) !Score {
    var s: Scan = .{ .alloc = arena };
    try s.blocks(markdown);
    const warnings = try formatcheck.check(arena, markdown);

    var raw: std.EnumArray(Id, usize) = .initFill(0);
    raw.set(.callouts, s.callouts);
    raw.set(.footnotes, s.resolvedNotes());
    raw.set(.tables, s.tables);
    raw.set(.wikilinks, s.wikilinks);
    raw.set(.embeds, s.embeds);
    raw.set(.fragment_links, s.fragments);
    raw.set(.links, s.links);
    raw.set(.frontmatter, s.props);
    raw.set(.code_fences, s.fences);
    raw.set(.styled_runs, s.runs);
    raw.set(.styled_coverage, s.styled_chars);
    raw.set(.emphasis_variety, s.styles.count());
    raw.set(.blockquotes, s.quotes);
    raw.set(.heading_levels, @popCount(s.levels));
    raw.set(.heading_density, s.headings);
    raw.set(.lists, s.lists);
    raw.set(.block_variety, s.kinds.count());
    raw.set(.raw_urls, s.raw_urls);

    const words = @max(@as(f64, @floatFromInt(s.words)), min_words);
    const chars: f64 = @floatFromInt(s.text_chars);

    const out = try arena.alloc(Signal, specs.len + penalties.len);
    var total: f64 = 0;
    var overloaded: usize = 0;
    for (specs, out[0..specs.len]) |sp, *sig| {
        const r = if (sp.id == .overload) overloaded else raw.get(sp.id);
        const rf: f64 = @floatFromInt(r);
        const v = switch (sp.basis) {
            .per_kwords => rf * 1000 / words,
            .share => if (chars == 0) 0 else rf / chars,
            .absolute => rf,
        };
        if (sp.weight > 0 and v > sp.over) overloaded += 1;
        const n = curve(sp, v);
        // `+ 0.0` turns -0.0 (zero credit on a penalty row) into 0.0.
        sig.* = .{ .name = @tagName(sp.id), .raw = r, .value = v, .normalized = n, .weight = sp.weight, .contribution = n * sp.weight + 0.0 };
        total += sig.contribution;
    }

    var hits: [penalties.len]usize = @splat(0);
    for (warnings) |w| hits[penaltyIndex(w.rule)] += 1;
    for (penalties, hits, penalty_names, out[specs.len..]) |p, h, name, *sig| {
        const off = @min(@as(f64, @floatFromInt(h)) * p.per, p.cap);
        sig.* = .{ .name = name, .raw = h, .value = @floatFromInt(h), .normalized = off / p.cap, .weight = -p.cap, .contribution = -off + 0.0 };
        total += sig.contribution;
    }

    return .{ .total = std.math.clamp(total, 0, 100), .words = s.words, .signals = out, .warnings = warnings };
}

/// `{"scorer":"density/1","total":..,"words":..,"signals":[{name,raw,
/// value,normalized,weight,contribution}..],"warnings":[{rule,line,
/// detail}..]}`. Fixed precision, so equal docs give byte-identical JSON.
pub fn writeJson(sc: Score, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"scorer\":\"{s}\",\"total\":{d:.1},\"words\":{d},\"signals\":[", .{ version, sc.total, sc.words });
    for (sc.signals, 0..) |sig, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(sig.name, .{}, w);
        try w.print(",\"raw\":{d},\"value\":{d:.3},\"normalized\":{d:.3},\"weight\":{d:.0},\"contribution\":{d:.2}}}", .{
            sig.raw, sig.value, sig.normalized, sig.weight, sig.contribution,
        });
    }
    try w.writeAll("],\"warnings\":[");
    for (sc.warnings, 0..) |warn, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try std.json.Stringify.value(warn.rule, .{}, w);
        try w.print(",\"line\":{d},\"detail\":", .{warn.line});
        try std.json.Stringify.value(warn.detail, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Plateau curve: ramps to 1 at `sat`, holds through `over`, then falls
/// linearly to 0 at `zero`.
pub fn curve(sp: Spec, v: f64) f64 {
    if (v <= 0) return 0;
    if (v < sp.sat) return v / sp.sat;
    if (v <= sp.over) return 1;
    if (v >= sp.zero) return 0;
    return 1 - (v - sp.over) / (sp.zero - sp.over);
}

fn penaltyIndex(rule: []const u8) usize {
    for (penalties[0 .. penalties.len - 1], 0..) |p, i| {
        if (std.mem.eql(u8, p.rule, rule)) return i;
    }
    return penalties.len - 1;
}

// --- Scanner -----------------------------------------------------------------
//
// Line-based block pass, then an inline pass over each block's text. It is
// a counting approximation of CommonMark + GFM + Obsidian syntax, not a
// parser: it only has to be consistent across docs.

const Error = std.mem.Allocator.Error;

const Kind = enum { frontmatter, paragraph, heading, list, quote, callout, table, code, footnote, rule };
const Style = enum { bold, italic, code, strike, highlight };

/// Styled runs nest inside each other; past this depth markers are literal.
const max_depth = 8;

/// Closers are searched at most this far ahead, which keeps a long line of
/// unmatched `[` or `*` linear instead of quadratic.
const max_span = 1024;

const Scan = struct {
    alloc: std.mem.Allocator,
    words: usize = 0,
    /// Alphanumeric bytes of prose: the coverage denominator.
    text_chars: usize = 0,
    /// Alphanumeric bytes inside outermost styled runs.
    styled_chars: usize = 0,
    runs: usize = 0,
    styles: std.EnumSet(Style) = .empty,
    kinds: std.EnumSet(Kind) = .empty,
    /// Bit n set = an h(n+1) appears.
    levels: u8 = 0,
    headings: usize = 0,
    callouts: usize = 0,
    quotes: usize = 0,
    tables: usize = 0,
    lists: usize = 0,
    fences: usize = 0,
    wikilinks: usize = 0,
    embeds: usize = 0,
    fragments: usize = 0,
    links: usize = 0,
    raw_urls: usize = 0,
    props: usize = 0,
    inline_notes: usize = 0,
    refs: std.ArrayList([]const u8) = .empty,
    defs: std.ArrayList([]const u8) = .empty,

    fn blocks(s: *Scan, doc: []const u8) Error!void {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |l| try lines.append(s.alloc, std.mem.trimEnd(u8, l, "\r"));
        const ls = lines.items;

        var i: usize = 0;
        if (ls.len > 0 and std.mem.eql(u8, trim(ls[0]), "---")) i = s.frontmatter(ls);

        while (i < ls.len) {
            const line = ls[i];
            const t = trim(line);
            if (t.len == 0) {
                i += 1;
            } else if (fenceOpen(line)) |f| {
                i = s.codeBlock(ls, i, f);
            } else if (headingLevel(t) > 0) {
                try s.heading(t);
                i += 1;
            } else if (t[0] == '>') {
                i = try s.quote(ls, i);
            } else if (isRule(t)) {
                s.kinds.insert(.rule);
                i += 1;
            } else if (std.ascii.startsWithIgnoreCase(t, "<table")) {
                i = try s.htmlTable(ls, i);
            } else if (pipeTableAt(ls, i)) {
                i = try s.pipeTable(ls, i);
            } else if (footnoteDefId(t)) |id| {
                i = try s.footnoteDef(ls, i, id);
            } else if (isLinkDef(t)) {
                i += 1;
            } else if (listItem(line) != null) {
                i = try s.list(ls, i);
            } else {
                i = try s.paragraph(ls, i);
            }
        }
    }

    /// Returns the first body line, or 0 if the block never closes (then
    /// it is just a rule and body text).
    fn frontmatter(s: *Scan, ls: []const []const u8) usize {
        var props: usize = 0;
        for (ls[1..], 1..) |line, j| {
            const t = trim(line);
            if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) {
                s.props = props;
                s.kinds.insert(.frontmatter);
                return j + 1;
            }
            if (isProperty(line)) props += 1;
        }
        return 0;
    }

    fn codeBlock(s: *Scan, ls: []const []const u8, start: usize, f: Fence) usize {
        for (ls[start + 1 ..], start + 1..) |line, i| {
            if (isFenceClose(line, f)) {
                s.fences += 1;
                s.kinds.insert(.code);
                return i + 1;
            }
        }
        // Unclosed: no credit; format_check charges for it.
        return ls.len;
    }

    fn heading(s: *Scan, t: []const u8) Error!void {
        const lv = headingLevel(t);
        s.headings += 1;
        s.levels |= @as(u8, 1) << @intCast(lv - 1);
        s.kinds.insert(.heading);
        try s.prose(std.mem.trimEnd(u8, trim(t[lv..]), " \t#"));
    }

    /// A `>` block is a callout if its first line is a `[!type]` marker. A
    /// callout earns credit only with a body line; a marker that appears
    /// inside a callout block starts the next callout.
    fn quote(s: *Scan, ls: []const []const u8, start: usize) Error!usize {
        const callout_block = std.mem.startsWith(u8, quoteText(ls[start]), "[!");
        var open = false;
        var body = false;
        var plain = false;
        var found: usize = 0;
        var i = start;
        while (i < ls.len) : (i += 1) {
            const t = trim(ls[i]);
            if (t.len == 0 or t[0] != '>') break;
            const c = quoteText(t);
            if (callout_block and std.mem.startsWith(u8, c, "[!")) {
                if (open and body) found += 1;
                open = true;
                body = false;
                const close = std.mem.findScalar(u8, c, ']') orelse c.len - 1;
                try s.prose(trim(std.mem.trimStart(u8, c[close + 1 ..], "+-")));
            } else {
                if (c.len > 0) {
                    if (callout_block) body = true else plain = true;
                }
                try s.prose(c);
            }
        }
        if (open and body) found += 1;
        if (found > 0) s.kinds.insert(.callout);
        s.callouts += found;
        if (plain) {
            s.quotes += 1;
            s.kinds.insert(.quote);
        }
        return i;
    }

    fn htmlTable(s: *Scan, ls: []const []const u8, start: usize) Error!usize {
        s.tables += 1;
        s.kinds.insert(.table);
        for (ls[start..], start..) |line, i| {
            try s.prose(trim(line));
            if (std.ascii.findIgnoreCase(line, "</table") != null) return i + 1;
        }
        return ls.len;
    }

    fn pipeTable(s: *Scan, ls: []const []const u8, start: usize) Error!usize {
        s.tables += 1;
        s.kinds.insert(.table);
        try s.cells(trim(ls[start]));
        var i = start + 2; // past the delimiter row
        while (i < ls.len) : (i += 1) {
            const t = trim(ls[i]);
            if (t.len == 0 or std.mem.findScalar(u8, t, '|') == null) break;
            try s.cells(t);
        }
        return i;
    }

    /// Cells are scanned one at a time so a marker can't pair across `|`.
    fn cells(s: *Scan, row: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, row, '|');
        while (it.next()) |cell| try s.prose(trim(cell));
    }

    fn footnoteDef(s: *Scan, ls: []const []const u8, start: usize, id: []const u8) Error!usize {
        try addNote(s.alloc, &s.defs, id);
        s.kinds.insert(.footnote);
        const t = trim(ls[start]);
        try s.prose(trim(t[id.len + 4 ..])); // past `[^id]:`
        var i = start + 1;
        while (i < ls.len and isIndented(ls[i]) and trim(ls[i]).len > 0) : (i += 1)
            try s.prose(trim(ls[i]));
        return i;
    }

    /// Items, indented continuation lines, and blank lines followed by
    /// either; anything else ends the list.
    fn list(s: *Scan, ls: []const []const u8, start: usize) Error!usize {
        s.lists += 1;
        s.kinds.insert(.list);
        var i = start;
        while (i < ls.len) {
            const line = ls[i];
            const t = trim(line);
            if (t.len == 0) {
                var j = i + 1;
                while (j < ls.len and trim(ls[j]).len == 0) j += 1;
                if (j < ls.len and (listItem(ls[j]) != null or isIndented(ls[j]))) {
                    i = j;
                    continue;
                }
                return i;
            }
            if (isRule(t)) return i;
            if (listItem(line)) |c| {
                try s.prose(c);
            } else if (isIndented(line)) {
                try s.prose(t);
            } else return i;
            i += 1;
        }
        return i;
    }

    fn paragraph(s: *Scan, ls: []const []const u8, start: usize) Error!usize {
        s.kinds.insert(.paragraph);
        var i = start;
        while (i < ls.len) : (i += 1) {
            const t = trim(ls[i]);
            if (t.len == 0 or (i > start and startsBlock(ls, i))) break;
            try s.prose(t);
        }
        return i;
    }

    fn prose(s: *Scan, text: []const u8) Error!void {
        s.words += countWords(text);
        try s.inlines(text, 0);
    }

    fn inlines(s: *Scan, text: []const u8, depth: u8) Error!void {
        var i: usize = 0;
        while (i < text.len) {
            if (try s.inlineAt(text, i, depth)) |next| {
                i = next;
                continue;
            }
            if (std.ascii.isAlphanumeric(text[i])) s.text_chars += 1;
            i += 1;
        }
    }

    /// Consumes one inline construct starting at `i` and returns the index
    /// past it, or null when `full[i]` is a plain character.
    fn inlineAt(s: *Scan, full: []const u8, i: usize, depth: u8) Error!?usize {
        const text = full[0..@min(full.len, i + max_span)];
        const rest = text[i..];
        switch (text[i]) {
            '\\' => return @min(i + 2, text.len),
            '`' => {
                const n = runLen(text, i, '`');
                const close = closeBackticks(text, i + n, n) orelse return i + n;
                const body = text[i + n .. close];
                s.mark(.code, body, depth);
                s.text_chars += alnum(body);
                return close + n;
            },
            '!' => {
                if (std.mem.startsWith(u8, rest, "![[")) {
                    const close = std.mem.findPos(u8, text, i + 3, "]]") orelse return null;
                    s.embeds += 1;
                    return close + 2;
                }
                if (i + 1 < text.len and text[i + 1] == '[') {
                    if (linkAt(text, i + 1)) |l| {
                        s.embeds += 1;
                        return l.end;
                    }
                }
                return null;
            },
            '[' => {
                if (std.mem.startsWith(u8, rest, "[[")) {
                    const close = std.mem.findPos(u8, text, i + 2, "]]") orelse return null;
                    const inner = text[i + 2 .. close];
                    if (inner.len > 0 and inner[0] == '#') s.fragments += 1 else s.wikilinks += 1;
                    const shown = if (std.mem.findScalar(u8, inner, '|')) |bar| inner[bar + 1 ..] else inner;
                    s.text_chars += alnum(shown);
                    return close + 2;
                }
                if (std.mem.startsWith(u8, rest, "[^")) {
                    const close = std.mem.findScalarPos(u8, text, i + 2, ']') orelse return null;
                    const id = text[i + 2 .. close];
                    if (id.len == 0 or std.mem.findAny(u8, id, " \t") != null) return null;
                    try addNote(s.alloc, &s.refs, id);
                    return close + 1;
                }
                const l = linkAt(text, i) orelse return null;
                // Any destination with a fragment is a deep link: `#anchor`,
                // `page#anchor`, or a `#:~:text=` citation (k4o `fragment_link`).
                if (std.mem.findScalar(u8, l.dest, '#') != null) s.fragments += 1 else s.links += 1;
                try s.inlines(l.label, depth);
                return l.end;
            },
            '^' => {
                if (!std.mem.startsWith(u8, rest, "^[")) return null;
                const close = matchBracket(text, i + 1) orelse return null;
                s.inline_notes += 1;
                try s.inlines(text[i + 2 .. close], depth);
                return close + 1;
            },
            '<' => {
                const close = std.mem.findScalarPos(u8, text, i + 1, '>') orelse return null;
                const inner = text[i + 1 .. close];
                if (std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://") or
                    std.mem.startsWith(u8, inner, "mailto:"))
                {
                    s.links += 1;
                    return close + 1;
                }
                // HTML tag: markup, not prose.
                if (inner.len > 0 and (std.ascii.isAlphabetic(inner[0]) or inner[0] == '/' or inner[0] == '!'))
                    return close + 1;
                return null;
            },
            'h' => {
                if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) return null;
                if (!std.mem.startsWith(u8, rest, "http://") and !std.mem.startsWith(u8, rest, "https://")) return null;
                var end = i;
                while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '<' and text[end] != ')') end += 1;
                s.raw_urls += 1;
                return end;
            },
            '*', '_', '~', '=' => return s.styledRun(text, i, depth),
            else => return null,
        }
    }

    /// `**b**` `__b__` `*i*` `_i_` `~~s~~` `==h==`. Openers need a
    /// non-space after them, closers a non-space before; `_` must not sit
    /// inside a word (snake_case is not emphasis).
    fn styledRun(s: *Scan, text: []const u8, i: usize, depth: u8) Error!?usize {
        if (depth >= max_depth) return null;
        const c = text[i];
        const double = i + 1 < text.len and text[i + 1] == c;
        const style: Style = switch (c) {
            '*', '_' => if (double) .bold else .italic,
            '~' => if (double) .strike else return null,
            '=' => if (double) .highlight else return null,
            else => return null,
        };
        const n: usize = if (double) 2 else 1;
        const open = i + n;
        if (open >= text.len or std.ascii.isWhitespace(text[open])) return null;
        if (c == '_' and i > 0 and std.ascii.isAlphanumeric(text[i - 1])) return null;
        const close = closeRun(text, open, c, n) orelse return null;
        const body = text[open..close];
        s.mark(style, body, depth);
        try s.inlines(body, depth + 1);
        return close + n;
    }

    fn mark(s: *Scan, style: Style, body: []const u8, depth: u8) void {
        s.runs += 1;
        s.styles.insert(style);
        if (depth == 0) s.styled_chars += alnum(body);
    }

    fn resolvedNotes(s: *const Scan) usize {
        var n = s.inline_notes;
        for (s.refs.items) |r| {
            for (s.defs.items) |d| {
                if (std.mem.eql(u8, r, d)) {
                    n += 1;
                    break;
                }
            }
        }
        return n;
    }
};

fn addNote(alloc: std.mem.Allocator, notes: *std.ArrayList([]const u8), id: []const u8) Error!void {
    for (notes.items) |x| {
        if (std.mem.eql(u8, x, id)) return;
    }
    try notes.append(alloc, id);
}

// --- Block helpers -----------------------------------------------------------

fn trim(t: []const u8) []const u8 {
    return std.mem.trim(u8, t, " \t");
}

fn isIndented(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "  ") or std.mem.startsWith(u8, line, "\t");
}

fn headingLevel(t: []const u8) usize {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (t.len > n and t[n] != ' ' and t[n] != '\t') return 0;
    return n;
}

const Fence = struct { ch: u8, len: usize };

fn fenceOpen(line: []const u8) ?Fence {
    const t = std.mem.trimStart(u8, line, " ");
    if (line.len - t.len > 3 or t.len < 3) return null;
    const ch = t[0];
    if (ch != '`' and ch != '~') return null;
    const n = runLen(t, 0, ch);
    if (n < 3) return null;
    // A backtick fence's info string can't itself contain backticks.
    if (ch == '`' and std.mem.findScalar(u8, t[n..], '`') != null) return null;
    return .{ .ch = ch, .len = n };
}

fn isFenceClose(line: []const u8, f: Fence) bool {
    const t = trim(line);
    if (t.len < f.len) return false;
    for (t) |c| {
        if (c != f.ch) return false;
    }
    return true;
}

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

/// A row with a `|` followed by a delimiter row (`| --- | :-: |`).
fn pipeTableAt(ls: []const []const u8, i: usize) bool {
    if (i + 1 >= ls.len or std.mem.findScalar(u8, ls[i], '|') == null) return false;
    const d = trim(ls[i + 1]);
    if (std.mem.findScalar(u8, d, '|') == null or std.mem.findScalar(u8, d, '-') == null) return false;
    for (d) |c| {
        switch (c) {
            '|', '-', ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

/// `- x`, `* x`, `+ x`, `1. x`, `1) x` (any indent): returns the item text.
fn listItem(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0) return null;
    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        if (t.len == 1) return "";
        if (t[1] == ' ' or t[1] == '\t') return trim(t[2..]);
        return null;
    }
    var n: usize = 0;
    while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
    if (n + 1 == t.len) return "";
    if (t[n + 1] != ' ' and t[n + 1] != '\t') return null;
    return trim(t[n + 2 ..]);
}

/// `[^id]: text` at the start of a line: returns `id`.
fn footnoteDefId(t: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, t, "[^")) return null;
    const close = std.mem.findScalar(u8, t, ']') orelse return null;
    if (close <= 2 or close + 1 >= t.len or t[close + 1] != ':') return null;
    return t[2..close];
}

/// `[label]: url` reference definitions: plumbing, not prose. The links
/// that use them are counted where they appear.
fn isLinkDef(t: []const u8) bool {
    if (t.len < 4 or t[0] != '[' or t[1] == '^' or t[1] == '[') return false;
    const close = std.mem.findScalar(u8, t, ']') orelse return false;
    return close > 1 and close + 2 < t.len and t[close + 1] == ':' and t[close + 2] == ' ';
}

fn isProperty(line: []const u8) bool {
    if (line.len == 0) return false;
    switch (line[0]) {
        ' ', '\t', '-', '#' => return false,
        else => {},
    }
    const c = std.mem.findScalar(u8, line, ':') orelse return false;
    return c > 0 and (c + 1 == line.len or line[c + 1] == ' ');
}

fn quoteText(line: []const u8) []const u8 {
    const t = trim(line);
    if (t.len == 0 or t[0] != '>') return t;
    return trim(t[1..]);
}

/// Can line `i` interrupt a paragraph?
fn startsBlock(ls: []const []const u8, i: usize) bool {
    const line = ls[i];
    const t = trim(line);
    return fenceOpen(line) != null or headingLevel(t) > 0 or t[0] == '>' or isRule(t) or
        std.ascii.startsWithIgnoreCase(t, "<table") or footnoteDefId(t) != null or
        listItem(line) != null or pipeTableAt(ls, i);
}

// --- Inline helpers ----------------------------------------------------------

/// Whitespace-separated tokens holding at least one letter or digit; HTML
/// tags are word boundaries, not words.
fn countWords(t: []const u8) usize {
    var n: usize = 0;
    var word = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '<' and i + 1 < t.len and (std.ascii.isAlphabetic(t[i + 1]) or t[i + 1] == '/')) {
            if (std.mem.findScalarPos(u8, t, i, '>')) |close| {
                if (word) n += 1;
                word = false;
                i = close;
                continue;
            }
        }
        if (std.ascii.isWhitespace(c)) {
            if (word) n += 1;
            word = false;
        } else if (std.ascii.isAlphanumeric(c)) {
            word = true;
        }
    }
    if (word) n += 1;
    return n;
}

fn alnum(t: []const u8) usize {
    var n: usize = 0;
    for (t) |c| {
        if (std.ascii.isAlphanumeric(c)) n += 1;
    }
    return n;
}

fn runLen(t: []const u8, i: usize, ch: u8) usize {
    var n: usize = 0;
    while (i + n < t.len and t[i + n] == ch) n += 1;
    return n;
}

/// A closing backtick run of exactly `n`.
fn closeBackticks(t: []const u8, from: usize, n: usize) ?usize {
    var p = from;
    while (std.mem.findScalarPos(u8, t, p, '`')) |at| {
        const len = runLen(t, at, '`');
        if (len == n) return at;
        p = at + len;
    }
    return null;
}

/// Finds the closer for an `n`-long run of `ch` opened just before `from`.
/// Closers are whole delimiter runs preceded by a non-space; the closer is
/// the run's last `n` chars, so `**a *b***` closes bold after the italic.
/// A single delimiter skips even runs: those close a nested `**`.
fn closeRun(t: []const u8, from: usize, ch: u8, n: usize) ?usize {
    var p = from;
    while (std.mem.findScalarPos(u8, t, p, ch)) |at| {
        const len = runLen(t, at, ch);
        p = at + len;
        if (at == from or std.ascii.isWhitespace(t[at - 1])) continue;
        if (if (n == 1) len % 2 == 0 else len < n) continue;
        if (ch == '_' and p < t.len and std.ascii.isAlphanumeric(t[p])) continue;
        return p - n;
    }
    return null;
}

/// Index of the `]` matching the `[` at `open`, honoring nesting and
/// backslash escapes.
fn matchBracket(t: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < t.len) : (i += 1) {
        switch (t[i]) {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

const Link = struct { label: []const u8, dest: []const u8, end: usize };

/// `[label](dest "title")` or `[label][ref]` with `[` at `i`.
fn linkAt(t: []const u8, i: usize) ?Link {
    const close = matchBracket(t, i) orelse return null;
    const label = t[i + 1 .. close];
    if (close + 1 >= t.len) return null;
    switch (t[close + 1]) {
        '(' => {
            var depth: usize = 0;
            var j = close + 1;
            while (j < t.len) : (j += 1) {
                switch (t[j]) {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if (depth == 0) {
                            const inner = trim(t[close + 2 .. j]);
                            const dest = inner[0 .. std.mem.findAny(u8, inner, " \t") orelse inner.len];
                            return .{ .label = label, .dest = dest, .end = j + 1 };
                        }
                    },
                    else => {},
                }
            }
            return null;
        },
        '[' => {
            const ref_close = std.mem.findScalarPos(u8, t, close + 2, ']') orelse return null;
            return .{ .label = label, .dest = "", .end = ref_close + 1 };
        },
        else => return null,
    }
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn signal(sc: Score, name: []const u8) Signal {
    for (sc.signals) |x| {
        if (std.mem.eql(u8, x.name, name)) return x;
    }
    std.debug.panic("density: no signal named {s}", .{name});
}

fn rawOf(sc: Score, name: []const u8) usize {
    return signal(sc, name).raw;
}

fn repeat(a: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}
test "empty doc scores zero" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sc = try score(arena.allocator(), "");
    try testing.expectEqual(@as(f64, 0), sc.total);
    try testing.expectEqual(@as(usize, 0), sc.words);
    try testing.expectEqual(specs.len + penalties.len, sc.signals.len);
}

test "callouts need a body to count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sc = try score(a, "> [!note] Title\n> body line\n> [!tip]\n> second\n\n> [!warning]\n\nprose\n\n> plain quote\n");
    try testing.expectEqual(@as(usize, 2), rawOf(sc, "callouts"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "blockquotes"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "format_check.empty-callout"));
}

test "footnotes count resolved pairs only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sc = try score(arena.allocator(), "One[^a] two[^b] again[^a] inline^[note].\n\n[^a]: defined\n[^c]: orphan\n");
    try testing.expectEqual(@as(usize, 2), rawOf(sc, "footnotes"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "format_check.unresolved-footnote"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "format_check.unused-footnote"));
}

test "styled runs, kinds, and coverage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sc = try score(arena.allocator(), "**bold *nested*** and _it_ `code` ~~gone~~ ==lit== snake_case_name 2 * 3 * 4 a == b\n");
    try testing.expectEqual(@as(usize, 6), rawOf(sc, "styled_runs"));
    try testing.expectEqual(@as(usize, 5), rawOf(sc, "emphasis_variety"));
    // bold+nested(10) it(2) code(4) gone(4) lit(3)
    try testing.expectEqual(@as(usize, 23), rawOf(sc, "styled_coverage"));
    const cov = signal(sc, "styled_coverage").value;
    try testing.expect(cov > 0.3 and cov < 0.7);
}

test "links: apparatus vs raw URLs, fragments, wikilinks, embeds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc =
        \\See [docs](https://x.com/a_b_c) and <https://y.com> and [ref][r] and https://raw.example/x_y.
        \\Jump to [the table](#receipts) or [[#Receipts]] or [quote](https://x.com/p#:~:text=snap%20shots).
        \\Read [[Page]] or [[Page|alias]].
        \\![[diagram.png]] ![alt](img.png)
        \\
        \\[r]: https://ref.example
        \\
    ;
    const sc = try score(arena.allocator(), doc);
    try testing.expectEqual(@as(usize, 3), rawOf(sc, "links"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "raw_urls"));
    try testing.expectEqual(@as(usize, 3), rawOf(sc, "fragment_links"));
    try testing.expectEqual(@as(usize, 2), rawOf(sc, "wikilinks"));
    try testing.expectEqual(@as(usize, 2), rawOf(sc, "embeds"));
    try testing.expectEqual(@as(usize, 0), rawOf(sc, "styled_runs"));
}

test "pipe and html tables both count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pipe = try score(a, "| a | b |\n| --- | :-: |\n| 1 | **2** |\n\nafter\n");
    try testing.expectEqual(@as(usize, 1), rawOf(pipe, "tables"));
    try testing.expectEqual(@as(usize, 1), rawOf(pipe, "styled_runs"));
    const html = try score(a, "<table>\n<tr><td>one two</td><td>three</td></tr>\n</table>\n");
    try testing.expectEqual(@as(usize, 1), rawOf(html, "tables"));
    try testing.expectEqual(@as(usize, 3), html.words);
    const not_table = try score(a, "a | b\nplain line\n");
    try testing.expectEqual(@as(usize, 0), rawOf(not_table, "tables"));
}

test "frontmatter properties count; code fences are not prose" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = "---\ntitle: \"x\"\ntags:\n  - a\n  - b\nyear: 1999\n---\n\n# H\n\n```zig\nconst words = here * not * counted;\n```\n\nthree words here\n";
    const sc = try score(arena.allocator(), doc);
    try testing.expectEqual(@as(usize, 3), rawOf(sc, "frontmatter"));
    try testing.expectEqual(@as(usize, 1), rawOf(sc, "code_fences"));
    try testing.expectEqual(@as(usize, 4), sc.words);
    try testing.expectEqual(@as(usize, 0), rawOf(sc, "styled_runs"));
}

test "lists: blocks, not items; rules are not lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sc = try score(arena.allocator(), "- a\n- b\n  continued\n\n- c\n\n---\n\n1. one\n2) two\n\nprose\n\n* * *\n");
    try testing.expectEqual(@as(usize, 2), rawOf(sc, "lists"));
}

test "heading levels and density" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sc = try score(arena.allocator(), "# A\n\n## B\n\n## C\n\n### D\n\n#hashtag is not a heading\n");
    try testing.expectEqual(@as(usize, 3), rawOf(sc, "heading_levels"));
    try testing.expectEqual(@as(usize, 4), rawOf(sc, "heading_density"));
}

test "unmatched markers stay cheap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const brackets = try repeat(a, "[", 16 * 1024);
    const stars = try repeat(a, "**a ", 4 * 1024);
    const sc = try score(a, try std.mem.concat(a, u8, &.{ brackets, " ", stars }));
    try testing.expect(sc.total >= 0 and sc.total <= 100);
}

test "curve ramps, plateaus, and decays" {
    const sp: Spec = .{ .id = .callouts, .weight = 10, .basis = .per_kwords, .sat = 2, .over = 10, .zero = 20 };
    try testing.expectEqual(@as(f64, 0), curve(sp, 0));
    try testing.expectEqual(@as(f64, 0.5), curve(sp, 1));
    try testing.expectEqual(@as(f64, 1), curve(sp, 10));
    try testing.expectEqual(@as(f64, 0.5), curve(sp, 15));
    try testing.expectEqual(@as(f64, 0), curve(sp, 40));
}

test "stacking callouts past the cap lowers the score" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prose = try repeat(a, "word ", 200);
    const one = "\n\n> [!note]\n> body";
    const sane = try score(a, try std.mem.concat(a, u8, &.{ prose, try repeat(a, one, 2) }));
    const noisy = try score(a, try std.mem.concat(a, u8, &.{ prose, try repeat(a, one, 8) }));
    try testing.expect(signal(noisy, "callouts").normalized < signal(sane, "callouts").normalized);
    try testing.expectEqual(@as(usize, 1), rawOf(noisy, "overload"));
    try testing.expect(noisy.total < sane.total);
}

test "score is length-normalized" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try loadFixture(a, "generic.md");
    const once = try score(a, doc);
    const twice = try score(a, try std.mem.concat(a, u8, &.{ doc, "\n", doc }));
    try testing.expectApproxEqAbs(once.total, twice.total, 1.0);
}

test "writeJson is deterministic and parses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try loadFixture(a, "verdict.md");
    var first: std.Io.Writer.Allocating = .init(a);
    var second: std.Io.Writer.Allocating = .init(a);
    try writeJson(try score(a, doc), &first.writer);
    try writeJson(try score(a, doc), &second.writer);
    try testing.expectEqualStrings(first.written(), second.written());

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, first.written(), .{});
    const sigs = v.object.get("signals").?.array;
    try testing.expectEqual(specs.len + penalties.len, sigs.items.len);
    try testing.expectEqualStrings(version, v.object.get("scorer").?.string);
    try testing.expectEqualStrings("callouts", sigs.items[0].object.get("name").?.string);
    try testing.expect(v.object.get("warnings").?.array.items.len > 0);
}

// Calibration fixtures live in knap-mcp/eval/density/. They sit outside the
// module root, so they can't be @embedFile'd, and the test binary inherits
// the cwd `zig build test` was started from: try both likely roots.
const fixture_dirs = [_][]const u8{ "eval/density/", "knap-mcp/eval/density/" };

fn loadFixture(a: std.mem.Allocator, comptime name: []const u8) ![]const u8 {
    inline for (fixture_dirs) |dir| {
        if (std.Io.Dir.readFileAlloc(.cwd(), testing.io, dir ++ name, a, .limited(1 << 20))) |bytes| {
            return bytes;
        } else |err| if (err != error.FileNotFound) return err;
    }
    std.debug.print("density: fixture {s} not found; run zig build test from knap-mcp/ or the repo root\n", .{name});
    return error.FileNotFound;
}

test "calibration fixtures rank as the rubric says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const barf = (try score(a, try loadFixture(a, "flat-barf.md"))).total;
    const generic = (try score(a, try loadFixture(a, "generic.md"))).total;
    const apparatus = (try score(a, try loadFixture(a, "apparatus.md"))).total;
    const verdict = (try score(a, try loadFixture(a, "verdict.md"))).total;
    const verdict_html = (try score(a, try loadFixture(a, "verdict.html-table.md"))).total;
    const cunty = (try score(a, try loadFixture(a, "cunty.md"))).total;
    const confetti = (try score(a, try loadFixture(a, "confetti.md"))).total;

    try testing.expect(barf < generic);
    try testing.expect(generic < verdict);
    try testing.expect(verdict < cunty);
    try testing.expect(barf < apparatus);
    // Dense is not noisy: piling on markup must not beat the real doc.
    try testing.expect(confetti < verdict);
    // Same doc, pipe table (k4o main) vs HTML table (k4o f97c5db markdown).
    try testing.expectApproxEqAbs(verdict, verdict_html, 2.0);
    // The ratchet's start and finish lines: the required-fields-only render
    // of each T1 template scores well below its full sample.
    inline for (.{ "release-notes", "reading-note" }) |t| {
        const min = (try score(a, try loadFixture(a, t ++ ".min.md"))).total;
        const full = (try score(a, try loadFixture(a, t ++ ".md"))).total;
        try testing.expect(min + 15 < full);
        try testing.expect(generic < min);
    }
}

test "scoring every fixture takes under 50ms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_][]const u8{
        try loadFixture(a, "flat-barf.md"),
        try loadFixture(a, "generic.md"),
        try loadFixture(a, "apparatus.md"),
        try loadFixture(a, "verdict.md"),
        try loadFixture(a, "verdict.html-table.md"),
        try loadFixture(a, "release-notes.md"),
        try loadFixture(a, "reading-note.md"),
        try loadFixture(a, "cunty.md"),
        try loadFixture(a, "confetti.md"),
    };
    const t0 = std.Io.Timestamp.now(testing.io, .awake);
    for (docs) |d| _ = try score(a, d);
    const ns = t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
    try testing.expect(ns < 50 * std.time.ns_per_ms);
}
