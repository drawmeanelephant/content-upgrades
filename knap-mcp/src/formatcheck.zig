//! Advisory structure lint over a rendered document — layer 2 of the
//! validation stack. Warnings only, never blocks: it surfaces the obvious
//! sins (dangling footnotes, bare URLs, skipped heading levels, fences
//! left open) as diagnostics instead of letting them ship silently.
//! Pure text in, warnings out; runs on artifact-store docs by handle.

const std = @import("std");

pub const Warning = struct {
    rule: []const u8,
    line: u32, // 1-based; 0 for document-wide findings
    detail: []const u8,
};

const Note = struct {
    id: []const u8,
    line: u32,
};

// Pinned thresholds — part of the rule contract; tune deliberately.
const wall_of_text_min = 4;
const heading_word_floor = 300;
const list_warn_min = 3;

pub fn check(alloc: std.mem.Allocator, doc: []const u8) ![]Warning {
    var warnings: std.ArrayList(Warning) = .empty;
    var refs: std.ArrayList(Note) = .empty;
    var defs: std.ArrayList(Note) = .empty;
    var ref_set: std.StringHashMapUnmanaged(void) = .empty;
    var def_set: std.StringHashMapUnmanaged(void) = .empty;

    // Leading frontmatter is skipped wholesale only when it closes; an
    // unterminated `---` block is prose, matching density.
    const front_end = frontmatterEnd(doc);
    var fence: ?Fence = null;
    var last_fence: u32 = 0;
    var prev_heading: usize = 0;
    var headings: usize = 0;
    var words: usize = 0;
    var list_lines: usize = 0;
    var prose_lines: usize = 0;
    var bare_urls: usize = 0;
    var first_bare: u32 = 0;
    var run_start: u32 = 0;
    var run_len: usize = 0;
    var callout_open: u32 = 0;
    var in_table = false;
    var prev_para = false;

    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const t = std.mem.trim(u8, line, " \r\t");

        if (line_no <= front_end) continue;

        if (fence) |f| {
            if (isFenceClose(t, f)) fence = null;
            prev_para = false;
            continue;
        }
        if (fenceOpen(line)) |f| {
            fence = f;
            last_fence = line_no;
            prev_para = false;
            continue;
        }

        // `===`/`---` under a prose line is a setext heading, not a rule.
        const setext = setextLevel(t);
        if (setext > 0 and prev_para) {
            headings += 1;
            if (setext > prev_heading + 1)
                try warnFmt(&warnings, alloc, "skipped-heading", line_no, "heading jumps h{d} to h{d}", .{ prev_heading, setext });
            prev_heading = setext;
            prose_lines -= 1;
            if (run_len > 0) run_len -= 1;
            try flushRun(&warnings, alloc, &run_start, &run_len);
            prev_para = false;
            continue;
        }

        // A GFM delimiter row means the pipe-shaped lines around it are a
        // table, not a wall of key/value text. Body rows stay out of the
        // prose/run counts until a line without a pipe ends the table.
        if (tableDelimiter(t)) {
            run_len = 0;
            run_start = 0;
            in_table = true;
        } else if (in_table and (t.len == 0 or std.mem.findScalar(u8, t, '|') == null)) {
            in_table = false;
        }

        // A `> [!type]` marker needs a `> ` body line next.
        if (callout_open != 0) {
            if (!(t.len > 1 and t[0] == '>'))
                try warn(&warnings, alloc, "empty-callout", callout_open, "callout marker has no '> ' body line");
            callout_open = 0;
        }
        if (std.mem.startsWith(u8, t, "> [!")) callout_open = line_no;

        const level = headingLevel(t);
        if (level > 0) {
            headings += 1;
            if (level > prev_heading + 1)
                try warnFmt(&warnings, alloc, "skipped-heading", line_no, "heading jumps h{d} to h{d}", .{ prev_heading, level });
            prev_heading = level;
        }

        try scanNotes(alloc, &refs, &defs, &ref_set, &def_set, t, line_no);

        // `[^x]:` footnote defs and `[x]: url` link defs are exempt from
        // raw-URL counting per the rule.
        if (footnoteDefId(t) == null and !isLinkDef(t)) {
            const n = countBareUrls(t);
            if (n > 0) {
                if (bare_urls == 0) first_bare = line_no;
                bare_urls += n;
            }
        }

        words += countWords(t);

        const list_line = t.len > 0 and !in_table and listItem(t) != null;
        if (level == 0 and t.len > 0 and !in_table) {
            if (list_line) list_lines += 1 else prose_lines += 1;
        }

        if (!in_table and level == 0 and t.len > 0 and tableShaped(t)) {
            if (run_len == 0) run_start = line_no;
            run_len += 1;
        } else if (!in_table) {
            try flushRun(&warnings, alloc, &run_start, &run_len);
        }

        prev_para = level == 0 and t.len > 0 and !list_line and !in_table and
            t[0] != '>' and t[0] != '[' and !isRule(t) and setext == 0;
    }

    if (callout_open != 0)
        try warn(&warnings, alloc, "empty-callout", callout_open, "callout marker has no '> ' body line");
    try flushRun(&warnings, alloc, &run_start, &run_len);

    for (refs.items) |r| {
        if (!def_set.contains(r.id))
            try warnFmt(&warnings, alloc, "unresolved-footnote", r.line, "footnote ref [^{s}] has no definition", .{r.id});
    }
    for (defs.items) |d| {
        if (!ref_set.contains(d.id))
            try warnFmt(&warnings, alloc, "unused-footnote", d.line, "footnote [^{s}] defined but never referenced", .{d.id});
    }

    if (bare_urls > 0)
        try warnFmt(&warnings, alloc, "raw-url-count", first_bare, "{d} bare URL(s) not wrapped in a link", .{bare_urls});
    if (fence != null)
        try warn(&warnings, alloc, "unclosed-fence", last_fence, "unclosed code fence");
    if (words > heading_word_floor and headings < 2)
        try warnFmt(&warnings, alloc, "heading-ratio", 0, "{d} words with fewer than 2 headings", .{words});
    if (list_lines >= list_warn_min and list_lines > prose_lines)
        try warnFmt(&warnings, alloc, "list-heavy", 0, "{d} list items vs {d} prose lines", .{ list_lines, prose_lines });

    return warnings.items;
}

fn warn(warnings: *std.ArrayList(Warning), alloc: std.mem.Allocator, rule: []const u8, line: u32, detail: []const u8) !void {
    try warnings.append(alloc, .{ .rule = rule, .line = line, .detail = detail });
}

fn warnFmt(warnings: *std.ArrayList(Warning), alloc: std.mem.Allocator, rule: []const u8, line: u32, comptime fmt: []const u8, args: anytype) !void {
    try warn(warnings, alloc, rule, line, try std.fmt.allocPrint(alloc, fmt, args));
}

fn flushRun(warnings: *std.ArrayList(Warning), alloc: std.mem.Allocator, start: *u32, len: *usize) !void {
    if (len.* >= wall_of_text_min)
        try warnFmt(warnings, alloc, "wall-of-text", start.*, "{d} consecutive key/value or pipe-delimited lines — consider a table", .{len.*});
    len.* = 0;
    start.* = 0;
}

/// Line number of the frontmatter closer, or 0 when the doc doesn't open
/// with `---` or the block never terminates (then those lines are prose).
fn frontmatterEnd(doc: []const u8) u32 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    const first = it.next() orelse return 0;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \r\t"), "---")) return 0;
    var n: u32 = 1;
    while (it.next()) |line| {
        n += 1;
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) return n;
    }
    return 0;
}

/// `key: value` or `a | b` shaped prose — the wall-of-text heuristic.
/// Real table rows (leading `|`), headings, lists, quotes, and footnote
/// defs are excluded.
fn tableShaped(t: []const u8) bool {
    if (t.len == 0) return false;
    switch (t[0]) {
        '#', '>', '-', '*', '|', '[', '`' => return false,
        else => {},
    }
    if (std.mem.indexOf(u8, t, " | ") != null) return true;
    if (std.mem.indexOfScalar(u8, t, ':')) |c| {
        if (c == 0 or c > 40) return false;
        if (std.mem.indexOfAny(u8, t[0..c], " \t") != null) return false;
        return c + 1 == t.len or t[c + 1] == ' ';
    }
    return false;
}

/// `[^x]` is a ref, `[^x]:` a def; both collected per line. Sets dedupe so
/// a doc full of footnotes stays linear.
fn scanNotes(alloc: std.mem.Allocator, refs: *std.ArrayList(Note), defs: *std.ArrayList(Note), ref_set: *std.StringHashMapUnmanaged(void), def_set: *std.StringHashMapUnmanaged(void), t: []const u8, line_no: u32) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, "[^")) |at| {
        const close = std.mem.indexOfScalarPos(u8, t, at + 2, ']') orelse break;
        const id = t[at + 2 .. close];
        if (validFootnoteId(id)) {
            if (close + 1 < t.len and t[close + 1] == ':') {
                if (!def_set.contains(id)) {
                    try def_set.put(alloc, id, {});
                    try defs.append(alloc, .{ .id = id, .line = line_no });
                }
            } else if (!ref_set.contains(id)) {
                try ref_set.put(alloc, id, {});
                try refs.append(alloc, .{ .id = id, .line = line_no });
            }
        }
        i = close + 1;
    }
}

/// Bare http(s) URLs: not inside `[]()`, `<...>`, `[[]]`, or code spans.
/// One left-to-right pass keeping wiki/code state; per-line linear.
fn countBareUrls(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var code: usize = 0; // open backtick-run length; 0 outside a code span
    var wiki: usize = 0; // [[ nesting depth
    while (i < t.len) {
        switch (t[i]) {
            '`' => {
                const run = runLen(t, i, '`');
                if (code == 0) {
                    code = run;
                } else if (run == code) {
                    code = 0;
                }
                i += run;
            },
            '[' => {
                if (code != 0) {
                    i += 1;
                } else if (i + 1 < t.len and t[i + 1] == '[') {
                    wiki += 1;
                    i += 2;
                } else if (i + 1 < t.len and t[i + 1] == '^') {
                    // Footnote ref/def: the id is never scanned.
                    if (std.mem.findScalarPos(u8, t, i + 2, ']')) |close| {
                        i = close + 1;
                    } else i += 1;
                } else if (linkLabelEnd(t, i)) |end| {
                    // `[label](`/`[label][`: label text isn't a bare URL.
                    i = end;
                } else i += 1;
            },
            ']' => {
                if (code == 0 and i + 1 < t.len and t[i + 1] == ']') {
                    if (wiki > 0) wiki -= 1;
                    i += 2;
                } else i += 1;
            },
            'h' => {
                const bare = std.mem.startsWith(u8, t[i..], "http://") or std.mem.startsWith(u8, t[i..], "https://");
                if (bare and code == 0 and wiki == 0 and
                    !(i > 0 and (t[i - 1] == '(' or t[i - 1] == '<'))) n += 1;
                i += 1;
            },
            else => i += 1,
        }
    }
    return n;
}

/// `[label]` followed by `(` or `[` is a link; returns the index after the
/// `]` so its label text is never scanned for bare URLs.
fn linkLabelEnd(t: []const u8, i: usize) ?usize {
    const close = matchBracket(t, i) orelse return null;
    if (close + 1 < t.len and (t[close + 1] == '(' or t[close + 1] == '[')) return close + 1;
    return null;
}

// --- Shared predicates -------------------------------------------------------
//
// density.zig calls these too, so the scorer and the linter can never
// disagree on what a heading, fence, list item, footnote id, link
// definition, table delimiter, or word looks like.

/// `#{1-6}` followed by space, tab, or end of line: the ATX level, else 0.
pub fn headingLevel(t: []const u8) usize {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (t.len > n and t[n] != ' ' and t[n] != '\t') return 0;
    return n;
}

/// `===`/`---` under a paragraph line is a setext h1/h2. Returns the
/// heading level, or 0 when the line isn't a pure `=`/`-` run.
pub fn setextLevel(t: []const u8) usize {
    if (t.len == 0) return 0;
    const c = t[0];
    if (c != '=' and c != '-') return 0;
    for (t) |ch| {
        if (ch != c) return 0;
    }
    return if (c == '=') 1 else 2;
}

pub const Fence = struct { ch: u8, len: usize };

/// ``` or ~~~ fence opener: up to 3 leading spaces, a run of >=3, and a
/// backtick fence's info string can't itself contain a backtick.
pub fn fenceOpen(line: []const u8) ?Fence {
    const t = std.mem.trimStart(u8, line, " ");
    if (line.len - t.len > 3 or t.len < 3) return null;
    const ch = t[0];
    if (ch != '`' and ch != '~') return null;
    const n = runLen(t, 0, ch);
    if (n < 3) return null;
    if (ch == '`' and std.mem.findScalar(u8, t[n..], '`') != null) return null;
    return .{ .ch = ch, .len = n };
}

/// A fence closer is a run of the open char at least the open length.
pub fn isFenceClose(t: []const u8, f: Fence) bool {
    if (t.len < f.len) return false;
    for (t) |c| {
        if (c != f.ch) return false;
    }
    return true;
}

/// `- x`, `* x`, `+ x`, `1. x`, `1) x` (any indent): returns the item text.
pub fn listItem(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0) return null;
    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        if (t.len == 1) return "";
        if (t[1] == ' ' or t[1] == '\t') return t[2..];
        return null;
    }
    var n: usize = 0;
    while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
    if (n + 1 == t.len) return "";
    if (t[n + 1] != ' ' and t[n + 1] != '\t') return null;
    return t[n + 2 ..];
}

/// A `[^id]` id is non-empty and contains no whitespace.
pub fn validFootnoteId(id: []const u8) bool {
    return id.len > 0 and std.mem.findAny(u8, id, " \t") == null;
}

/// `[^id]: text` at the start of a line: returns `id`.
pub fn footnoteDefId(t: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, t, "[^")) return null;
    const close = std.mem.findScalar(u8, t, ']') orelse return null;
    if (close <= 2 or close + 1 >= t.len or t[close + 1] != ':') return null;
    const id = t[2..close];
    return if (validFootnoteId(id)) id else null;
}

/// `[label]: url` reference definitions: plumbing, not prose. The links
/// that use them are counted where they appear.
pub fn isLinkDef(t: []const u8) bool {
    if (t.len < 4 or t[0] != '[' or t[1] == '^' or t[1] == '[') return false;
    const close = std.mem.findScalar(u8, t, ']') orelse return false;
    return close > 1 and close + 2 < t.len and t[close + 1] == ':' and t[close + 2] == ' ';
}

/// `***`, `---`, `___` thematic breaks (spaces allowed between markers).
pub fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

/// `| --- | :-: |` — a GFM delimiter row: only pipes, hyphens, colons and
/// whitespace, with at least one pipe and one hyphen.
pub fn tableDelimiter(t: []const u8) bool {
    if (std.mem.findScalar(u8, t, '|') == null or std.mem.findScalar(u8, t, '-') == null) return false;
    for (t) |c| {
        switch (c) {
            '|', '-', ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

/// Length of the run of `ch` starting at `i`.
pub fn runLen(t: []const u8, i: usize, ch: u8) usize {
    var n: usize = 0;
    while (i + n < t.len and t[i + n] == ch) n += 1;
    return n;
}

/// Index of the `]` matching the `[` at `open`, honoring nesting and
/// backslash escapes.
pub fn matchBracket(t: []const u8, open: usize) ?usize {
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

/// Whitespace-separated tokens holding at least one letter or digit; HTML
/// tags are word boundaries, not words. CJK ideographs and kana each count
/// as a word (that prose has no spaces); other multibyte characters are
/// word material, so `café` stays one word.
pub fn countWords(t: []const u8) usize {
    var n: usize = 0;
    var word = false;
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c == '<' and i + 1 < t.len and (std.ascii.isAlphabetic(t[i + 1]) or t[i + 1] == '/')) {
            if (std.mem.findScalarPos(u8, t, i, '>')) |close| {
                if (word) n += 1;
                word = false;
                i = close + 1;
                continue;
            }
        }
        if (c < 0x80) {
            if (std.ascii.isWhitespace(c)) {
                if (word) n += 1;
                word = false;
            } else if (std.ascii.isAlphanumeric(c)) {
                word = true;
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > t.len) {
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(t[i..][0..len]) catch {
            i += len;
            continue;
        };
        if (isUnicodeSpace(cp) or isNonWordCp(cp)) {
            if (word) n += 1;
            word = false;
        } else if (isCjk(cp)) {
            if (word) n += 1;
            word = false;
            n += 1;
        } else {
            word = true;
        }
        i += len;
    }
    if (word) n += 1;
    return n;
}

/// ASCII alphanumeric plus any non-ASCII byte: UTF-8 text is text.
pub fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Count of word bytes in `t` — the coverage denominator's unit.
pub fn alnum(t: []const u8) usize {
    var n: usize = 0;
    for (t) |c| {
        if (wordByte(c)) n += 1;
    }
    return n;
}

/// Scripts whose characters each carry a word in spaceless prose: CJK
/// ideographs and Japanese kana. Korean (Hangul) uses spaces, so it stays
/// word material like accented latin.
fn isCjk(cp: u21) bool {
    return switch (cp) {
        0x2E80...0x2EFF, 0x2F00...0x2FDF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF => true,
        else => false,
    };
}

/// Multibyte punctuation and symbols are boundaries, never word material:
/// general/CJK/supplemental punctuation, fullwidth forms, arrows,
/// dingbats, emoji.
fn isNonWordCp(cp: u21) bool {
    return switch (cp) {
        // Latin-1 punctuation (currency, ordinals, superscripts and
        // fractions stay word material), then general/CJK/supplemental
        // punctuation, fullwidth forms, arrows, dingbats, emoji.
        0x00A1, 0x00A6...0x00A9, 0x00AB...0x00AC, 0x00AE...0x00B1, 0x00B4, 0x00B6...0x00B8, 0x00BB, 0x00BF, 0x00D7, 0x00F7, 0x2000...0x206F, 0x2E00...0x2E7F, 0x3001...0x303F, 0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0x2190...0x27BF, 0x1F000...0x1FAFF => true,
        else => false,
    };
}

fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn countRule(warnings: []const Warning, rule: []const u8) usize {
    var n: usize = 0;
    for (warnings) |w| {
        if (std.mem.eql(u8, w.rule, rule)) n += 1;
    }
    return n;
}

// check() never frees (production callers pass an arena), so each test
// runs it in its own arena.
test "clean doc produces no warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "# Title\n\nSome prose with a [link](https://x.com) and a footnote[^n].\n\n[^n]: the note\n");
    try std.testing.expectEqual(@as(usize, 0), w.len);
}

test "frontmatter block is skipped, not flagged as wall-of-text" {
    const doc = "---\nyear: 1999\ngenre:\n  - \"Action\"\n---\n\n# Title\n\nBody.\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 0), countRule(w, "wall-of-text"));
}

test "unterminated frontmatter is prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "---\na: 1\nb: 2\nc: 3\nd: 4\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "wall-of-text"));
}

test "dangling footnote ref and unused def both warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "A ref[^a] here.\n\n[^b]: never used\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "unresolved-footnote"));
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "unused-footnote"));
}

test "whitespace footnote ids are not refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "A ref[^ ] and one[^a b] here.\n");
    try std.testing.expectEqual(@as(usize, 0), countRule(w, "unresolved-footnote"));
}

test "skipped heading level warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "# A\n\n### C\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "skipped-heading"));
}

test "tab after the hash still makes a heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "#\tTitle\n\n## Sub\n");
    try std.testing.expectEqual(@as(usize, 0), countRule(w, "skipped-heading"));
}

test "setext headings count as headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "Title\n===\n\nSub\n---\n\n#### Deep\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "skipped-heading"));
}

test "empty callout warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "> [!warning]\n\nnext paragraph\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "empty-callout"));
}

test "bare URLs counted, linked ones ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "See https://x.com and [y](https://y.com) and [[https://z.com]].\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "raw-url-count"));
}

test "a URL outside closed wikilinks still warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "[[Page]] and https://x.com/a plus [[Other]]\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "raw-url-count"));
}

test "code spans, link labels, and link defs hide no bare URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = "`https://a.com` and [https://b.com/p](https://b.com) and <https://c.com>\n\n[r]: https://d.com/dest\n";
    const w = try check(arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 0), countRule(w, "raw-url-count"));
}

test "tilde fences hide their contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "~~~\nhttps://x.com and [^q]\n~~~\n");
    try std.testing.expectEqual(@as(usize, 0), w.len);
    const open = try check(arena.allocator(), "~~~\ntext\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(open, "unclosed-fence"));
}

test "unclosed fence warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "```zig\nconst x = 1;\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "unclosed-fence"));
}

test "key/value wall of text warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "a: 1\nb: 2\nc: 3\nd: 4\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "wall-of-text"));
}

test "a table without leading pipes is not a wall of text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "a | b\n--- | ---\n1 | 2\n3 | 4\n5 | 6\n7 | 8\n");
    try std.testing.expectEqual(@as(usize, 0), countRule(w, "wall-of-text"));
}

test "plus-marked list items count as list lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "+ a\n+ b\n+ c\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "list-heavy"));
}

test "bare URL counting is linear in URL count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try std.mem.concat(a, u8, &.{ try repeat(a, "https://x.com/a ", 3000), "\n" });
    const w = try check(a, doc);
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "raw-url-count"));
}

fn repeat(a: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}
