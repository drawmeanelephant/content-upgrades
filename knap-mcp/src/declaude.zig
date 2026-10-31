//! declaude — mechanical cleanup of character-level marks in generated
//! text, the same hygiene job format_check and the voice guards do for
//! style, but for watermark vectors and lookalikes (#412).
//!
//! Three tiers in one code-point pass:
//!
//!   strip     the default. Removes the invisible set (Cf format chars:
//!             ZWSP/ZWNJ, word joiner, soft hyphen, mid-text BOM, bidi
//!             embeddings and isolates, interlinear anchors, tag chars,
//!             supplementary variation selectors), folds Unicode space
//!             variants to ASCII space, and drops trailing whitespace
//!             per line — the whitespace-steganography vector.
//!   normalize opt-in (Options.normalize). Canonicalizes visible
//!             lookalikes — dashes, curly quotes, minus sign, ellipsis —
//!             to ASCII. Lossy by design; every substitution is tallied.
//!   flag      always on, never rewrites: Cyrillic/Greek confusables in
//!             Latin words (a wrong guess corrupts text), C0/C1 controls
//!             and U+2028/9 (the #333 escapees), undecodable bytes, and
//!             a small slop-phrase list.
//!
//! Never stripped: ZWJ U+200D (it holds emoji sequences together), the
//! BMP variation selectors U+FE00–FE0F (VS15/VS16 carry legitimate
//! emoji/text presentation), combining marks, and a U+FEFF at offset 0
//! (a real signature; the mark vector is mid-text).
//!
//! Honest limits: this handles character-level marks only. If the mark
//! is statistical — woven into token choice — no mechanical strip
//! removes it; only paraphrase does. And the lookalikes are stylistic
//! tells, not marks: normalizing them removes nothing, which is why
//! normalize is opt-in and every substitution reported.

const std = @import("std");

const Error = std.mem.Allocator.Error;

/// Report contract version; bump on any behavior change.
pub const version = "declaude/1";

pub const Options = struct {
    /// Tier 2: also canonicalize visible lookalikes to ASCII. Lossy.
    normalize: bool = false,
    /// Detect and tally only: the text comes back byte-identical.
    report: bool = false,
};

pub const Action = enum { removed, space, substituted, flagged };

/// One report row: what was found, what was done about it, how often.
/// Rows merge while every field but `count` matches.
pub const Entry = struct {
    /// "U+XXXX" label for code-point rows; null on text rows.
    codepoint: ?[]const u8 = null,
    /// The finding itself on text rows (slop phrase, "invalid UTF-8").
    text: ?[]const u8 = null,
    name: []const u8 = "",
    detail: []const u8 = "",
    action: Action,
    /// The replacement on .space / .substituted rows.
    to: ?[]const u8 = null,
    count: usize,
};

pub const Result = struct {
    /// Cleaned text (the input itself when Options.report).
    text: []const u8,
    /// Tier-1 rows: removed marks, space folds, trailing whitespace.
    stripped: []const Entry,
    /// Tier-2 rows: ASCII substitutions (empty unless normalize).
    normalized: []const Entry,
    /// Report-only rows: homoglyphs, controls, bad bytes, slop.
    flagged: []const Entry,
    /// Whether cleaning changes the bytes — in report mode, "would
    /// change". Flag-only findings do not set it.
    changed: bool,
    /// Echoed options, so a saved report states its mode.
    normalize: bool,
    report: bool,
    /// Set by the data-record path instead of `text`.
    data: ?std.json.Value = null,
};

/// Clean `input` per `opts`. Everything is allocated in `a`.
pub fn run(a: std.mem.Allocator, input: []const u8, opts: Options) Error!Result {
    var s: Scan = .{ .a = a, .opts = opts };
    try s.transform(input);
    try s.flagPass(input);
    return .{
        .text = if (opts.report) input else s.out.items,
        .stripped = s.stripped.items,
        .normalized = s.normalized.items,
        .flagged = s.flagged.items,
        .changed = !std.mem.eql(u8, s.out.items, input),
        .normalize = opts.normalize,
        .report = opts.report,
    };
}

/// `{"version":"declaude/1","normalize":..,"report":..,"changed":..,
/// "stripped":[..],"normalized":[..],"flagged":[..],"text":..}` — with
/// `"data"` in place of `"text"` when the record path set it.
pub fn writeJson(r: Result, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"version\":\"{s}\",\"normalize\":{s},\"report\":{s},\"changed\":{s},\"stripped\":[", .{
        version, boolStr(r.normalize), boolStr(r.report), boolStr(r.changed),
    });
    try writeEntries(r.stripped, w);
    try w.writeAll("],\"normalized\":[");
    try writeEntries(r.normalized, w);
    try w.writeAll("],\"flagged\":[");
    try writeEntries(r.flagged, w);
    try w.writeAll("],");
    if (r.data) |d| {
        try w.writeAll("\"data\":");
        try std.json.Stringify.value(d, .{}, w);
    } else {
        try w.writeAll("\"text\":");
        try std.json.Stringify.value(r.text, .{}, w);
    }
    try w.writeAll("}");
}

fn writeEntries(entries: []const Entry, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('{');
        if (e.codepoint) |c| {
            try w.writeAll("\"codepoint\":");
            try std.json.Stringify.value(c, .{}, w);
        }
        if (e.text) |t| {
            try w.writeAll("\"text\":");
            try std.json.Stringify.value(t, .{}, w);
        }
        if (e.name.len > 0) {
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(e.name, .{}, w);
        }
        if (e.detail.len > 0) {
            try w.writeAll(",\"detail\":");
            try std.json.Stringify.value(e.detail, .{}, w);
        }
        try w.writeAll(",\"action\":");
        try std.json.Stringify.value(@tagName(e.action), .{}, w);
        if (e.to) |to| {
            try w.writeAll(",\"to\":");
            try std.json.Stringify.value(to, .{}, w);
        }
        try w.print(",\"count\":{d}}}", .{e.count});
    }
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Fold `src` report rows into `dst` (the data-record path aggregates
/// per-string results).
pub fn mergeEntries(dst: *std.ArrayList(Entry), a: std.mem.Allocator, src: []const Entry) Error!void {
    for (src) |e| try addEntry(dst, a, e);
}

// --- Classification tables ----------------------------------------------------

/// The invisible set strip removes outright (keeps: ZWJ, the BMP
/// variation selectors, combining marks, a leading BOM).
fn stripName(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x00AD => "soft hyphen",
        0x061C => "arabic letter mark",
        0x070F => "syriac abbreviation mark",
        0x180E => "mongolian vowel separator",
        0x200B => "zero width space",
        0x200C => "zero width non-joiner",
        // 0x200D zero width joiner: kept — it holds emoji sequences together.
        0x200E => "left-to-right mark",
        0x200F => "right-to-left mark",
        0x202A...0x202E => "bidi embedding/override",
        0x2060 => "word joiner",
        0x2061...0x2064 => "invisible operator",
        0x2066...0x206F => "bidi isolate/deprecated format char",
        0xFEFF => "zero-width no-break space",
        0xFFF9...0xFFFB => "interlinear annotation anchor",
        0xE0000...0xE007F => "tag character",
        0xE0100...0xE01EF => "supplementary variation selector",
        else => null,
    };
}

/// Unicode space variants folded to ASCII space — the whitespace
/// steganography vector. U+2028/9 are White_Space too but stay: they are
/// the #333 escapees, flagged report-only.
fn spaceName(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x00A0 => "no-break space",
        0x1680 => "ogham space mark",
        0x2000...0x200A => "unicode space variant",
        0x202F => "narrow no-break space",
        0x205F => "medium mathematical space",
        0x3000 => "ideographic space",
        else => null,
    };
}

const Norm = struct { cp: u21, name: []const u8, to: []const u8 };

/// Opt-in lookalike canonicalization. Dashes fold to a single "-"
/// (not "--": a fixed-width replacement keeps the text one char per
/// mark and matches what ASCII prose actually carries).
const norms = [_]Norm{
    .{ .cp = 0x2010, .name = "hyphen", .to = "-" },
    .{ .cp = 0x2011, .name = "non-breaking hyphen", .to = "-" },
    .{ .cp = 0x2012, .name = "figure dash", .to = "-" },
    .{ .cp = 0x2013, .name = "en dash", .to = "-" },
    .{ .cp = 0x2014, .name = "em dash", .to = "-" },
    .{ .cp = 0x2015, .name = "horizontal bar", .to = "-" },
    .{ .cp = 0x2212, .name = "minus sign", .to = "-" },
    .{ .cp = 0x2018, .name = "left single quotation mark", .to = "'" },
    .{ .cp = 0x2019, .name = "right single quotation mark", .to = "'" },
    .{ .cp = 0x201A, .name = "single low-9 quotation mark", .to = "'" },
    .{ .cp = 0x201B, .name = "single high-reversed-9 quotation mark", .to = "'" },
    .{ .cp = 0x201C, .name = "left double quotation mark", .to = "\"" },
    .{ .cp = 0x201D, .name = "right double quotation mark", .to = "\"" },
    .{ .cp = 0x201E, .name = "double low-9 quotation mark", .to = "\"" },
    .{ .cp = 0x201F, .name = "double high-reversed-9 quotation mark", .to = "\"" },
    .{ .cp = 0x2026, .name = "horizontal ellipsis", .to = "..." },
};

fn normOf(cp: u21) ?Norm {
    for (norms) |n| if (n.cp == cp) return n;
    return null;
}

/// Controls that flag report-only: the #333 escapees (C1, U+2028/9)
/// plus stray C0 and DEL — none of them belong in generated text, but
/// removing bytes silently is the strip tier's job and these are not
/// in its set.
fn controlName(cp: u21) ?[]const u8 {
    if (cp == 0x2028) return "line separator";
    if (cp == 0x2029) return "paragraph separator";
    if (cp < 0x20 and cp != '\t' and cp != '\n' and cp != '\r') return "C0 control";
    if (cp >= 0x7F and cp <= 0x9F) return "C1 control";
    return null;
}

const Confusable = struct { cp: u21, script: []const u8, like: u8 };

/// Cyrillic/Greek letters that render as Latin. Detection only —
/// guessing the intended ASCII char corrupts real text.
const confusables = [_]Confusable{
    .{ .cp = 0x0430, .script = "cyrillic", .like = 'a' },
    .{ .cp = 0x0435, .script = "cyrillic", .like = 'e' },
    .{ .cp = 0x043E, .script = "cyrillic", .like = 'o' },
    .{ .cp = 0x0440, .script = "cyrillic", .like = 'p' },
    .{ .cp = 0x0441, .script = "cyrillic", .like = 'c' },
    .{ .cp = 0x0443, .script = "cyrillic", .like = 'y' },
    .{ .cp = 0x0445, .script = "cyrillic", .like = 'x' },
    .{ .cp = 0x0455, .script = "cyrillic", .like = 's' },
    .{ .cp = 0x0456, .script = "cyrillic", .like = 'i' },
    .{ .cp = 0x0458, .script = "cyrillic", .like = 'j' },
    .{ .cp = 0x0475, .script = "cyrillic", .like = 'v' },
    .{ .cp = 0x04BB, .script = "cyrillic", .like = 'h' },
    .{ .cp = 0x0501, .script = "cyrillic", .like = 'd' },
    .{ .cp = 0x0405, .script = "cyrillic", .like = 'S' },
    .{ .cp = 0x0406, .script = "cyrillic", .like = 'I' },
    .{ .cp = 0x0408, .script = "cyrillic", .like = 'J' },
    .{ .cp = 0x0410, .script = "cyrillic", .like = 'A' },
    .{ .cp = 0x0412, .script = "cyrillic", .like = 'B' },
    .{ .cp = 0x0415, .script = "cyrillic", .like = 'E' },
    .{ .cp = 0x041A, .script = "cyrillic", .like = 'K' },
    .{ .cp = 0x041C, .script = "cyrillic", .like = 'M' },
    .{ .cp = 0x041D, .script = "cyrillic", .like = 'H' },
    .{ .cp = 0x041E, .script = "cyrillic", .like = 'O' },
    .{ .cp = 0x0420, .script = "cyrillic", .like = 'P' },
    .{ .cp = 0x0421, .script = "cyrillic", .like = 'C' },
    .{ .cp = 0x0422, .script = "cyrillic", .like = 'T' },
    .{ .cp = 0x0425, .script = "cyrillic", .like = 'X' },
    .{ .cp = 0x04AE, .script = "cyrillic", .like = 'Y' },
    .{ .cp = 0x03B1, .script = "greek", .like = 'a' },
    .{ .cp = 0x03B7, .script = "greek", .like = 'n' },
    .{ .cp = 0x03B9, .script = "greek", .like = 'i' },
    .{ .cp = 0x03BD, .script = "greek", .like = 'v' },
    .{ .cp = 0x03BF, .script = "greek", .like = 'o' },
    .{ .cp = 0x03C1, .script = "greek", .like = 'p' },
    .{ .cp = 0x03C5, .script = "greek", .like = 'u' },
    .{ .cp = 0x03C7, .script = "greek", .like = 'x' },
    .{ .cp = 0x03C9, .script = "greek", .like = 'w' },
    .{ .cp = 0x0391, .script = "greek", .like = 'A' },
    .{ .cp = 0x0392, .script = "greek", .like = 'B' },
    .{ .cp = 0x0395, .script = "greek", .like = 'E' },
    .{ .cp = 0x0396, .script = "greek", .like = 'Z' },
    .{ .cp = 0x0397, .script = "greek", .like = 'H' },
    .{ .cp = 0x0399, .script = "greek", .like = 'I' },
    .{ .cp = 0x039A, .script = "greek", .like = 'K' },
    .{ .cp = 0x039C, .script = "greek", .like = 'M' },
    .{ .cp = 0x039D, .script = "greek", .like = 'N' },
    .{ .cp = 0x039F, .script = "greek", .like = 'O' },
    .{ .cp = 0x03A1, .script = "greek", .like = 'P' },
    .{ .cp = 0x03A4, .script = "greek", .like = 'T' },
    .{ .cp = 0x03A5, .script = "greek", .like = 'Y' },
    .{ .cp = 0x03A7, .script = "greek", .like = 'X' },
};

fn confusable(cp: u21) ?Confusable {
    for (confusables) |c| if (c.cp == cp) return c;
    return null;
}

/// A tiny slop-phrase list for the report. Flagged, never rewritten —
/// regex-rewriting prose produces garbage. `stem` lets "delve" catch
/// delves/delved/delving.
const Slop = struct { text: []const u8, stem: bool = false };

const slop = [_]Slop{
    .{ .text = "delve", .stem = true },
    .{ .text = "a testament to" },
    .{ .text = "it's not just" },
    .{ .text = "it's worth noting" },
    .{ .text = "in today's fast-paced" },
    .{ .text = "the ever-evolving" },
    .{ .text = "navigate the complexities" },
    .{ .text = "rich tapestry" },
};

// --- Scanner ------------------------------------------------------------------

const Cp = struct { cp: u21, len: usize, ok: bool };

/// The code point starting at s[i]; ok=false on bytes that don't decode
/// (the flag pass reports them; the transform passes them through
/// untouched so a stray high byte can never be eaten by a cp table).
fn nextCp(s: []const u8, i: usize) Cp {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1, .ok = false };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1, .ok = false };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1, .ok = false };
    return .{ .cp = cp, .len = n, .ok = true };
}

fn eqlOpt(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn addEntry(list: *std.ArrayList(Entry), a: std.mem.Allocator, e: Entry) Error!void {
    for (list.items) |*x| {
        if (eqlOpt(x.codepoint, e.codepoint) and eqlOpt(x.text, e.text) and
            std.mem.eql(u8, x.name, e.name) and x.action == e.action and
            eqlOpt(x.to, e.to) and std.mem.eql(u8, x.detail, e.detail))
        {
            x.count += e.count;
            return;
        }
    }
    try list.append(a, e);
}

const Scan = struct {
    a: std.mem.Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    stripped: std.ArrayList(Entry) = .empty,
    normalized: std.ArrayList(Entry) = .empty,
    flagged: std.ArrayList(Entry) = .empty,

    fn cpLabel(s: *Scan, cp: u21) Error![]const u8 {
        return std.fmt.allocPrint(s.a, "U+{X:0>4}", .{cp});
    }

    /// The transform pass: strips and (with normalize) substitutes.
    /// Flag-only findings are emitted untouched — the flag pass tallies
    /// them against the original.
    fn transform(s: *Scan, input: []const u8) Error!void {
        var i: usize = 0;
        while (i < input.len) {
            const pos = i;
            const d = nextCp(input, i);
            i += d.len;
            if (!d.ok) {
                try s.out.appendSlice(s.a, input[pos..i]);
                continue;
            }
            if (d.cp == '\r' or d.cp == '\n') {
                try s.endLine();
                try s.out.appendSlice(s.a, input[pos..i]);
                continue;
            }
            // A BOM at offset 0 is a real signature; the mark vector is
            // mid-text.
            if (d.cp == 0xFEFF and pos == 0) {
                try s.out.appendSlice(s.a, input[pos..i]);
                continue;
            }
            if (stripName(d.cp)) |name| {
                try addEntry(&s.stripped, s.a, .{
                    .codepoint = try s.cpLabel(d.cp),
                    .name = name,
                    .action = .removed,
                    .count = 1,
                });
                continue;
            }
            if (spaceName(d.cp)) |name| {
                try addEntry(&s.stripped, s.a, .{
                    .codepoint = try s.cpLabel(d.cp),
                    .name = name,
                    .action = .space,
                    .to = " ",
                    .count = 1,
                });
                try s.out.append(s.a, ' ');
                continue;
            }
            if (s.opts.normalize) {
                if (normOf(d.cp)) |n| {
                    try addEntry(&s.normalized, s.a, .{
                        .codepoint = try s.cpLabel(d.cp),
                        .name = n.name,
                        .action = .substituted,
                        .to = n.to,
                        .count = 1,
                    });
                    try s.out.appendSlice(s.a, n.to);
                    continue;
                }
            }
            try s.out.appendSlice(s.a, input[pos..i]);
        }
        try s.endLine();
    }

    /// Trailing [ \t]+ on the emitted line is whitespace steganography:
    /// count it, drop it. Runs before a line ending is emitted and once
    /// at EOF. (A space a variant just folded into lands here too, so a
    /// NBSP at line end leaves two honest rows.)
    fn endLine(s: *Scan) Error!void {
        var tail = s.out.items.len;
        var spaces: usize = 0;
        var tabs: usize = 0;
        while (tail > 0 and (s.out.items[tail - 1] == ' ' or s.out.items[tail - 1] == '\t')) {
            tail -= 1;
            if (s.out.items[tail] == ' ') spaces += 1 else tabs += 1;
        }
        if (spaces > 0) {
            try addEntry(&s.stripped, s.a, .{
                .codepoint = try s.cpLabel(0x20),
                .name = "trailing whitespace",
                .action = .removed,
                .count = spaces,
            });
        }
        if (tabs > 0) {
            try addEntry(&s.stripped, s.a, .{
                .codepoint = try s.cpLabel(0x09),
                .name = "trailing whitespace",
                .action = .removed,
                .count = tabs,
            });
        }
        s.out.shrinkRetainingCapacity(tail);
    }

    /// Report-only findings against the original text: homoglyph
    /// confusables inside words that also carry ASCII letters, control
    /// characters, undecodable bytes, slop phrases.
    fn flagPass(s: *Scan, input: []const u8) Error!void {
        var i: usize = 0;
        while (i < input.len) {
            const d = nextCp(input, i);
            i += d.len;
            if (!d.ok) {
                try addEntry(&s.flagged, s.a, .{
                    .text = "invalid UTF-8",
                    .name = "undecodable byte(s) passed through untouched",
                    .action = .flagged,
                    .count = 1,
                });
                continue;
            }
            if (controlName(d.cp)) |name| {
                try addEntry(&s.flagged, s.a, .{
                    .codepoint = try s.cpLabel(d.cp),
                    .name = name,
                    .detail = "reported, not removed",
                    .action = .flagged,
                    .count = 1,
                });
            }
        }
        try s.homoglyphs(input);
        try s.slopScan(input);
    }

    /// Whitespace-delimited tokens that mix an ASCII letter with a
    /// confusable Cyrillic/Greek letter are the homoglyph signature —
    /// a pure Cyrillic word is legitimate text and stays unflagged.
    /// Invisible format chars and controls do not break a token: they
    /// are invisible, the word still reads as one.
    fn homoglyphs(s: *Scan, input: []const u8) Error!void {
        var i: usize = 0;
        while (i < input.len) {
            while (i < input.len) {
                const d = nextCp(input, i);
                if (!d.ok or !boundaryCp(d.cp)) break;
                i += d.len;
            }
            if (i >= input.len) return;
            var latin = false;
            var confs: std.ArrayList(Confusable) = .empty;
            while (i < input.len) {
                const d = nextCp(input, i);
                if (d.ok and boundaryCp(d.cp)) break;
                i += d.len;
                if (!d.ok) continue;
                if ((d.cp >= 'a' and d.cp <= 'z') or (d.cp >= 'A' and d.cp <= 'Z')) latin = true;
                if (confusable(d.cp)) |c| try confs.append(s.a, c);
            }
            if (latin) {
                for (confs.items) |c| {
                    try addEntry(&s.flagged, s.a, .{
                        .codepoint = try s.cpLabel(c.cp),
                        .name = "homoglyph",
                        .detail = try std.fmt.allocPrint(s.a, "{s} letter, looks like '{c}'", .{ c.script, c.like }),
                        .action = .flagged,
                        .count = 1,
                    });
                }
            }
        }
    }

    /// Word-boundary, case-insensitive phrase scan. `'` in a phrase
    /// matches the ASCII apostrophe or a curly U+2018/9 so slop survives
    /// a curly-quote render.
    fn slopScan(s: *Scan, input: []const u8) Error!void {
        for (slop) |p| {
            var n: usize = 0;
            var pos: usize = 0;
            while (pos < input.len) {
                if (phraseMatchAt(input, pos, p)) |len| {
                    n += 1;
                    pos += @max(len, 1);
                } else pos += 1;
            }
            if (n > 0) {
                try addEntry(&s.flagged, s.a, .{
                    .text = p.text,
                    .name = "slop phrase",
                    .action = .flagged,
                    .count = n,
                });
            }
        }
    }
};

/// Token boundary for the homoglyph scan: any whitespace a word could
/// end on, including the space variants and the line/paragraph
/// separators.
fn boundaryCp(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or
        cp == 0x0B or cp == 0x0C or
        cp == 0x2028 or cp == 0x2029 or
        spaceName(cp) != null;
}

/// Length of a slop match starting at `pos`, or null. Left edge is a
/// word boundary; the right edge is one too unless the phrase is a
/// `stem` (delve*). Case-insensitive; pattern `'` also matches the
/// UTF-8 of U+2018/9.
fn phraseMatchAt(hay: []const u8, pos: usize, p: Slop) ?usize {
    if (pos > 0 and std.ascii.isAlphanumeric(hay[pos - 1])) return null;
    var j = pos;
    var k: usize = 0;
    while (k < p.text.len) : (k += 1) {
        const pc = p.text[k];
        if (pc == '\'') {
            if (j < hay.len and hay[j] == '\'') {
                j += 1;
            } else if (std.mem.startsWith(u8, hay[j..], "\u{2019}") or
                std.mem.startsWith(u8, hay[j..], "\u{2018}"))
            {
                j += 3;
            } else return null;
            continue;
        }
        if (j >= hay.len or std.ascii.toLower(hay[j]) != std.ascii.toLower(pc)) return null;
        j += 1;
    }
    if (!p.stem and j < hay.len and std.ascii.isAlphanumeric(hay[j])) return null;
    return j - pos;
}

// --- Tests --------------------------------------------------------------------

/// Returned arena owns the Result's slices; the caller deinit()s it.
/// `run` must finish before `arena` moves into the result — fields
/// evaluate in order, so an in-literal `try` would copy the empty state
/// and strand the buffers the local arena then accumulates.
fn runText(input: []const u8, opts: Options) !struct { arena: std.heap.ArenaAllocator, r: Result } {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const r = try run(arena.allocator(), input, opts);
    return .{ .arena = arena, .r = r };
}

fn entryCount(entries: []const Entry, codepoint: []const u8) usize {
    for (entries) |e| {
        if (e.codepoint) |c| {
            if (std.mem.eql(u8, c, codepoint)) return e.count;
        }
    }
    return 0;
}

fn flaggedText(entries: []const Entry, text: []const u8) usize {
    for (entries) |e| {
        if (e.text) |t| {
            if (std.mem.eql(u8, t, text)) return e.count;
        }
    }
    return 0;
}

test "strip: invisible marks removed and tallied per code point" {
    const input = "he\u{200B}llo\u{2060} w\u{00AD}or\u{E0001}ld\u{FEFF} end";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    const r = t.r;
    try std.testing.expectEqualStrings("hello world end", r.text);
    try std.testing.expect(r.changed);
    try std.testing.expectEqual(@as(usize, 1), entryCount(r.stripped, "U+200B"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(r.stripped, "U+2060"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(r.stripped, "U+00AD"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(r.stripped, "U+E0001"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(r.stripped, "U+FEFF"));
}

test "strip is idempotent" {
    const input = "a\u{200B}b\u{00A0}c  \nd\u{2014}e\u{2066}";
    var once = try runText(input, .{});
    defer once.arena.deinit();
    var twice = try runText(once.r.text, .{});
    defer twice.arena.deinit();
    try std.testing.expectEqualStrings(once.r.text, twice.r.text);
    try std.testing.expect(!twice.r.changed);
}

test "ASCII passes through byte-identical" {
    const input = "# Title\n\nplain text, no marks.\n";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expect(!t.r.changed);
    try std.testing.expectEqual(@as(usize, 0), t.r.stripped.len);
}

test "emoji ZWJ and VS16 survive; combining marks kept" {
    const input = "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} heart \u{2764}\u{FE0F} cafe\u{0301}";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expect(!t.r.changed);
    var tn = try runText(input, .{ .normalize = true });
    defer tn.arena.deinit();
    try std.testing.expectEqualStrings(input, tn.r.text);
}

test "BOM at offset 0 kept, mid-text stripped" {
    const input = "\u{FEFF}lead\u{FEFF}mid";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings("\u{FEFF}leadmid", t.r.text);
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+FEFF"));
}

test "space variants fold to space; U+2028 flagged not removed" {
    const input = "a\u{00A0}b\u{202F}c\u{2007}d\u{3000}e\u{2028}f";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings("a b c d e\u{2028}f", t.r.text);
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+00A0"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+202F"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+2007"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+3000"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+2028"));
}

test "trailing spaces and tabs dropped per line" {
    const input = "one  \ntwo\t\nthree \t \nlast   ";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings("one\ntwo\nthree\nlast", t.r.text);
    try std.testing.expectEqual(@as(usize, 7), entryCount(t.r.stripped, "U+0020"));
    try std.testing.expectEqual(@as(usize, 2), entryCount(t.r.stripped, "U+0009"));
}

test "normalize is opt-in: off keeps lookalikes, on substitutes" {
    const input = "a\u{2014}b \u{201C}q\u{201D} e\u{2026}f \u{2212}1";
    var off = try runText(input, .{});
    defer off.arena.deinit();
    try std.testing.expectEqualStrings(input, off.r.text);
    try std.testing.expectEqual(@as(usize, 0), off.r.normalized.len);
    var on = try runText(input, .{ .normalize = true });
    defer on.arena.deinit();
    try std.testing.expectEqualStrings("a-b \"q\" e...f -1", on.r.text);
    try std.testing.expectEqual(@as(usize, 1), entryCount(on.r.normalized, "U+2014"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(on.r.normalized, "U+201C"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(on.r.normalized, "U+201D"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(on.r.normalized, "U+2026"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(on.r.normalized, "U+2212"));
}

test "homoglyph in a latin word flagged, never rewritten" {
    const input = "h\u{0435}llo w\u{03BF}rld \u{043A}\u{043E}\u{0442} fine";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expect(!t.r.changed);
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+0435"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+03BF"));
    // кот is a pure Cyrillic word: legitimate text, unflagged.
    try std.testing.expectEqual(@as(usize, 0), entryCount(t.r.flagged, "U+043A"));
    try std.testing.expectEqual(@as(usize, 0), entryCount(t.r.flagged, "U+0442"));
}

test "report mode rewrites nothing but still tallies" {
    const input = "a\u{200B}b  \nc\u{2014}d";
    var t = try runText(input, .{ .report = true, .normalize = true });
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expect(t.r.changed);
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+200B"));
    try std.testing.expectEqual(@as(usize, 2), entryCount(t.r.stripped, "U+0020"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.normalized, "U+2014"));
}

test "controls flag report-only and stay in the output" {
    const input = "a\u{0085}b\u{0007}c\u{007F}";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+0085"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+0007"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.flagged, "U+007F"));
}

test "slop phrases flagged with count, curly apostrophe matches" {
    const input = "It\u{2019}s worth noting this is a testament to delves.";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expectEqual(@as(usize, 1), flaggedText(t.r.flagged, "it's worth noting"));
    try std.testing.expectEqual(@as(usize, 1), flaggedText(t.r.flagged, "a testament to"));
    try std.testing.expectEqual(@as(usize, 1), flaggedText(t.r.flagged, "delve"));
}

test "undecodable bytes pass through and flag once each" {
    const input = "a\x80b\xffc";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings(input, t.r.text);
    try std.testing.expectEqual(@as(usize, 2), flaggedText(t.r.flagged, "invalid UTF-8"));
}

test "ZWJ and tag-block edge: keep set never tallied as stripped" {
    const input = "x\u{200D}y\u{E007F}z\u{FE0E}\u{FE0F}\u{E0100}w";
    var t = try runText(input, .{});
    defer t.arena.deinit();
    try std.testing.expectEqualStrings("x\u{200D}yz\u{FE0E}\u{FE0F}w", t.r.text);
    try std.testing.expectEqual(@as(usize, 0), entryCount(t.r.stripped, "U+200D"));
    try std.testing.expectEqual(@as(usize, 0), entryCount(t.r.stripped, "U+FE0E"));
    try std.testing.expectEqual(@as(usize, 0), entryCount(t.r.stripped, "U+FE0F"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+E007F"));
    try std.testing.expectEqual(@as(usize, 1), entryCount(t.r.stripped, "U+E0100"));
}

test "writeJson emits the report contract" {
    var t = try runText("a\u{200B}b\u{0435}c", .{});
    defer t.arena.deinit();
    var out: std.Io.Writer.Allocating = .init(t.arena.allocator());
    try writeJson(t.r, &out.writer);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, t.arena.allocator(), out.written(), .{});
    const obj = v.object;
    try std.testing.expectEqualStrings(version, obj.get("version").?.string);
    try std.testing.expect(obj.get("changed").?.bool);
    try std.testing.expectEqual(@as(usize, 1), obj.get("stripped").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), obj.get("flagged").?.array.items.len);
    try std.testing.expectEqualStrings("ab\u{0435}c", obj.get("text").?.string);
}
