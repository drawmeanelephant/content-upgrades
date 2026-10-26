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

    var in_front = false;
    var in_fence = false;
    var fences: usize = 0;
    var last_fence: u32 = 0;
    var prev_heading: u32 = 0;
    var headings: usize = 0;
    var words: usize = 0;
    var list_lines: usize = 0;
    var prose_lines: usize = 0;
    var bare_urls: usize = 0;
    var first_bare: u32 = 0;
    var run_start: u32 = 0;
    var run_len: usize = 0;
    var callout_open: u32 = 0;

    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const t = std.mem.trim(u8, line, " \r\t");

        // Leading YAML frontmatter is skipped wholesale — `key: value`
        // lines there are metadata, not table-shaped prose.
        if (line_no == 1 and std.mem.eql(u8, t, "---")) {
            in_front = true;
            continue;
        }
        if (in_front) {
            if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) in_front = false;
            continue;
        }

        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            fences += 1;
            last_fence = line_no;
            continue;
        }
        if (in_fence) continue;

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

        try scanNotes(alloc, &refs, &defs, t, line_no);

        // `[^x]:` def lines are exempt from raw-URL counting per the rule.
        if (!std.mem.startsWith(u8, t, "[^")) {
            const n = countBareUrls(t);
            if (n > 0) {
                if (bare_urls == 0) first_bare = line_no;
                bare_urls += n;
            }
        }

        words += countWords(t);
        if (level == 0 and t.len > 0) {
            if (isListItem(t)) list_lines += 1 else prose_lines += 1;
        }

        if (level == 0 and t.len > 0 and tableShaped(t)) {
            if (run_len == 0) run_start = line_no;
            run_len += 1;
        } else {
            try flushRun(&warnings, alloc, &run_start, &run_len);
        }
    }

    if (callout_open != 0)
        try warn(&warnings, alloc, "empty-callout", callout_open, "callout marker has no '> ' body line");
    try flushRun(&warnings, alloc, &run_start, &run_len);

    for (refs.items) |r| {
        if (!hasId(defs.items, r.id))
            try warnFmt(&warnings, alloc, "unresolved-footnote", r.line, "footnote ref [^{s}] has no definition", .{r.id});
    }
    for (defs.items) |d| {
        if (!hasId(refs.items, d.id))
            try warnFmt(&warnings, alloc, "unused-footnote", d.line, "footnote [^{s}] defined but never referenced", .{d.id});
    }

    if (bare_urls > 0)
        try warnFmt(&warnings, alloc, "raw-url-count", first_bare, "{d} bare URL(s) not wrapped in a link", .{bare_urls});
    if (fences % 2 != 0)
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

fn headingLevel(t: []const u8) u32 {
    var n: u32 = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (t.len > n and t[n] != ' ') return 0;
    return n;
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

fn isListItem(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) return true;
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    return i > 0 and i + 1 < t.len and t[i] == '.' and t[i + 1] == ' ';
}

fn countWords(t: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, t, " \t");
    while (it.next()) |_| n += 1;
    return n;
}

fn hasId(notes: []const Note, id: []const u8) bool {
    for (notes) |n| {
        if (std.mem.eql(u8, n.id, id)) return true;
    }
    return false;
}

/// `[^x]` is a ref, `[^x]:` a def; both collected per line.
fn scanNotes(alloc: std.mem.Allocator, refs: *std.ArrayList(Note), defs: *std.ArrayList(Note), t: []const u8, line_no: u32) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, "[^")) |at| {
        const close = std.mem.indexOfScalarPos(u8, t, at + 2, ']') orelse break;
        const id = t[at + 2 .. close];
        if (id.len > 0) {
            if (close + 1 < t.len and t[close + 1] == ':') {
                if (!hasId(defs.items, id)) try defs.append(alloc, .{ .id = id, .line = line_no });
            } else if (!hasId(refs.items, id)) {
                try refs.append(alloc, .{ .id = id, .line = line_no });
            }
        }
        i = close + 1;
    }
}

/// Bare http(s) URLs: not inside `[]()`, `<...>`, or `[[]]` constructs.
fn countBareUrls(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const h1 = std.mem.indexOfPos(u8, t, i, "http://");
        const h2 = std.mem.indexOfPos(u8, t, i, "https://");
        const p = if (h1 == null) (h2 orelse break) else if (h2 == null) h1.? else @min(h1.?, h2.?);
        const linked = (p > 0 and (t[p - 1] == '(' or t[p - 1] == '<')) or
            (std.mem.indexOf(u8, t[0..p], "[[") != null and std.mem.indexOf(u8, t[p..], "]]") != null);
        if (!linked) n += 1;
        i = p + 1;
    }
    return n;
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

test "dangling footnote ref and unused def both warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "A ref[^a] here.\n\n[^b]: never used\n");
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "unresolved-footnote"));
    try std.testing.expectEqual(@as(usize, 1), countRule(w, "unused-footnote"));
}

test "skipped heading level warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try check(arena.allocator(), "# A\n\n### C\n");
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
