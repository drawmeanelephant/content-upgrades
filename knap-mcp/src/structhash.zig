//! Structure hash: the layout skeleton of a rendered doc, with every text
//! leaf dropped, hashed with Wyhash. Two renders of one template whose data
//! differs only in prose hash equal; one more list item, another heading
//! level, a lost callout or an injected `**` does not. This is the voice
//! proof (SPEC demo beat 6: "structure hashes equal, strings differ").
//!
//! Markdown (k4o output): frontmatter key names and list shape, headings
//! with level, paragraphs, lists (ordered or not, nesting, items), quotes
//! and callouts (with their `[!type]`), pipe tables (columns, alignment,
//! cells per row), code fences, thematic breaks, footnote definitions, and
//! the inline kinds: strong, emphasis, strikethrough, code, links, images,
//! wikilinks, embeds, footnote refs, raw URLs, inline html, hard breaks.
//! Whitespace-insensitive. Default mode drops link and image targets,
//! wikilink targets, footnote labels and raw-URL/autolink targets;
//! `strict` keeps them.
//!
//! HTML (dogbed output): tag names, nesting, attribute names, and values of
//! structural attributes (`class`, `type`, `colspan`, ...). Text nodes and
//! text-derived values (heading `id` slugs, `alt`, `title`, `href`, ...)
//! are dropped; `strict` keeps `href` and `src`.
//!
//! Self-contained on purpose: it needs no engine, model or other module.
//! Not a full CommonMark parser. It reads the subset k4o emits: no setext
//! headings, no indented code blocks, no reference links, no lazy
//! blockquote continuation. Unmatched emphasis runs become `delim:` tokens
//! so a stray `**` still changes the hash.

const std = @import("std");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

pub const Format = enum { markdown, html };

pub const Options = struct {
    /// Keep link, image, wikilink and embed targets, footnote labels,
    /// and raw-URL/autolink targets.
    strict: bool = false,
};

pub const Token = struct {
    /// Nesting depth, for `--explain` only; the hash ignores it.
    depth: u16,
    kind: []const u8,
};

pub fn formatFromName(name: []const u8) ?Format {
    if (eql(u8, name, "markdown") or eql(u8, name, "md")) return .markdown;
    if (eql(u8, name, "html") or eql(u8, name, "htm")) return .html;
    return null;
}

/// html when the doc opens with a tag and closes one; else markdown.
pub fn sniff(doc: []const u8) Format {
    const t = std.mem.trimStart(u8, doc, " \t\r\n\xef\xbb\xbf");
    if (t.len > 0 and t[0] == '<' and
        (std.mem.find(u8, t, "</") != null or std.mem.find(u8, t, "/>") != null)) return .html;
    return .markdown;
}

/// The skeleton in default mode. Token kinds are allocated in `alloc`;
/// pass an arena.
pub fn skeleton(alloc: Allocator, doc: []const u8, format: Format) ![]Token {
    return skeletonOpts(alloc, doc, format, .{});
}

pub fn skeletonOpts(alloc: Allocator, doc: []const u8, format: Format, opts: Options) ![]Token {
    var o: Out = .{ .alloc = alloc, .strict = opts.strict };
    switch (format) {
        .markdown => try mdDoc(&o, doc),
        .html => try htmlDoc(&o, doc),
    }
    return o.list.items;
}

/// Wyhash (seed 0) over the token kinds, each followed by a newline.
pub fn hashTokens(tokens: []const Token) u64 {
    var h = std.hash.Wyhash.init(0);
    for (tokens) |t| {
        h.update(t.kind);
        h.update("\n");
    }
    return h.final();
}

pub fn hashOpts(gpa: Allocator, doc: []const u8, format: Format, opts: Options) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return hashTokens(try skeletonOpts(arena.allocator(), doc, format, opts));
}

/// Default-mode hash. Panics only if the page allocator runs out.
pub fn hash(doc: []const u8, format: Format) u64 {
    return hashOpts(std.heap.page_allocator, doc, format, .{}) catch @panic("structhash: out of memory");
}

// --- Token sink --------------------------------------------------------------

const Out = struct {
    alloc: Allocator,
    strict: bool,
    list: std.ArrayList(Token) = .empty,
    depth: u16 = 0,

    fn emit(o: *Out, kind: []const u8) !void {
        try o.list.append(o.alloc, .{ .depth = o.depth, .kind = kind });
    }

    fn emitf(o: *Out, comptime fmt: []const u8, args: anytype) !void {
        try o.emit(try std.fmt.allocPrint(o.alloc, fmt, args));
    }

    fn open(o: *Out, kind: []const u8) !void {
        try o.emit(kind);
        o.depth += 1;
    }

    fn close(o: *Out, kind: []const u8) !void {
        o.depth -|= 1;
        try o.emit(kind);
    }

    /// A leaf block token, then its inline tokens one level deeper.
    fn leaf(o: *Out, kind: []const u8, text: []const u8) !void {
        try o.emit(kind);
        o.depth += 1;
        defer o.depth -= 1;
        try inlines(o, text);
    }
};

// --- Markdown blocks ---------------------------------------------------------

const Lines = []const []const u8;

fn mdDoc(o: *Out, doc: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |l| try lines.append(o.alloc, std.mem.trimEnd(u8, l, "\r"));
    var all: Lines = lines.items;

    if (all.len > 0 and eql(u8, std.mem.trimEnd(u8, all[0], " \t"), "---")) {
        for (all[1..], 1..) |l, n| {
            const t = std.mem.trimEnd(u8, l, " \t");
            if (eql(u8, t, "---") or eql(u8, t, "...")) {
                try frontmatter(o, all[1..n]);
                all = all[n + 1 ..];
                break;
            }
        }
    }
    try blocks(o, all);
}

/// Block containers nested deeper than this are flattened to one `deep`
/// token, and scanInline stops recursing into link text past it, so a
/// hostile doc cannot exhaust the stack on either axis.
const max_depth = 64;

fn blocks(o: *Out, lines: Lines) Allocator.Error!void {
    if (o.depth > max_depth) return o.emit("deep");
    var i: usize = 0;
    while (i < lines.len) {
        const s = trimWs(lines[i]);
        if (s.len == 0) {
            i += 1;
        } else if (fenceOpen(s)) |f| {
            try o.emit(if (f.lang.len > 0) try std.fmt.allocPrint(o.alloc, "code:{s}", .{f.lang}) else "code");
            i += 1;
            while (i < lines.len) : (i += 1) {
                if (fenceCloses(trimWs(lines[i]), f)) {
                    i += 1;
                    break;
                }
            }
        } else if (heading(s)) |h| {
            try o.leaf(headingKinds[h.level - 1], h.text);
            i += 1;
        } else if (isHr(s)) {
            try o.emit("hr");
            i += 1;
        } else if (s[0] == '>') {
            var sub: std.ArrayList([]const u8) = .empty;
            while (i < lines.len) : (i += 1) {
                const q = trimWs(lines[i]);
                if (q.len == 0 or q[0] != '>') break;
                try sub.append(o.alloc, if (q.len > 1 and q[1] == ' ') q[2..] else q[1..]);
            }
            try quote(o, sub.items);
        } else if (listMarker(lines[i]) != null) {
            i = try list(o, lines, i);
        } else if (isTableStart(lines, i)) {
            i = try table(o, lines, i);
        } else if (footnoteDef(s)) |fd| {
            i = try fnDef(o, lines, i, fd);
        } else {
            const start = i;
            i += 1;
            while (i < lines.len and !interrupts(lines, i)) i += 1;
            try o.leaf("p", try joinTrimmed(o.alloc, lines[start..i]));
        }
    }
}

const headingKinds = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };

/// Does line i end a paragraph (blank, or the start of another block)?
fn interrupts(lines: Lines, i: usize) bool {
    const s = trimWs(lines[i]);
    if (s.len == 0 or s[0] == '>' or isHr(s) or fenceOpen(s) != null or heading(s) != null) return true;
    if (footnoteDef(s) != null or isTableStart(lines, i)) return true;
    // A list interrupts a paragraph when the item has content and, if
    // ordered, starts at 1 (CommonMark).
    const m = listMarker(lines[i]) orelse return false;
    if (m.empty) return false;
    return !m.ordered or m.start_one;
}

fn startsBlock(lines: Lines, i: usize) bool {
    return interrupts(lines, i) or listMarker(lines[i]) != null;
}

fn quote(o: *Out, sub: Lines) !void {
    if (sub.len > 0) {
        const first = trimWs(sub[0]);
        if (startsWith(u8, first, "[!")) {
            if (std.mem.findScalar(u8, first, ']')) |rb| {
                const kind = try std.ascii.allocLowerString(o.alloc, first[2..rb]);
                var rest = first[rb + 1 ..];
                var fold: []const u8 = "";
                if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
                    fold = rest[0..1];
                    rest = rest[1..];
                }
                try o.open(try std.fmt.allocPrint(o.alloc, "callout:{s}{s}", .{ kind, fold }));
                const title = trimWs(rest);
                if (title.len > 0) try o.leaf("title", title);
                try blocks(o, sub[1..]);
                try o.close("/callout");
                return;
            }
        }
    }
    try o.open("quote");
    try blocks(o, sub);
    try o.close("/quote");
}

const Marker = struct {
    indent: usize,
    ordered: bool,
    /// Bullet char, or the ordered delimiter ('.' or ')').
    char: u8,
    /// The ordered list's start number (0 for bullets).
    start: u32,
    start_one: bool,
    /// Column where the item's content starts.
    content: usize,
    empty: bool,
    /// The first line's content after the marker.
    text: []const u8,
};

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else if (c == '\t') n += 4 - n % 4 else break;
    }
    return n;
}

/// Drop up to `cols` columns of leading whitespace.
fn dedent(line: []const u8, cols: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < cols) : (i += 1) {
        if (line[i] == ' ') n += 1 else if (line[i] == '\t') n += 4 - n % 4 else break;
    }
    return line[i..];
}

fn listMarker(line: []const u8) ?Marker {
    const indent = indentOf(line);
    const s = trimWs(line);
    if (s.len == 0 or isHr(s)) return null;
    var w: usize = 0;
    var m: Marker = .{ .indent = indent, .ordered = false, .char = s[0], .start = 0, .start_one = false, .content = 0, .empty = false, .text = "" };
    if (s[0] == '-' or s[0] == '*' or s[0] == '+') {
        w = 1;
    } else {
        while (w < s.len and w < 9 and std.ascii.isDigit(s[w])) w += 1;
        if (w == 0 or w >= s.len or (s[w] != '.' and s[w] != ')')) return null;
        m.ordered = true;
        m.char = s[w];
        m.start = std.fmt.parseInt(u32, s[0..w], 10) catch 0;
        m.start_one = m.start == 1;
        w += 1;
    }
    if (w == s.len) {
        m.empty = true;
        m.content = indent + w + 1;
        return m;
    }
    if (s[w] != ' ' and s[w] != '\t') return null;
    const sp = indentOf(s[w..]);
    m.text = trimWs(s[w..]);
    m.empty = m.text.len == 0;
    m.content = indent + w + if (sp > 4 or m.empty) 1 else sp;
    return m;
}

fn sameList(a: Marker, b: Marker) bool {
    return a.ordered == b.ordered and a.char == b.char;
}

/// Parse a list starting at line i; returns the line after it.
fn list(o: *Out, lines: Lines, start: usize) !usize {
    const first = listMarker(lines[start]).?;
    // The start number is layout: `3.` renders a list numbered from 3.
    const kind: []const u8 = if (!first.ordered) "ul" else if (first.start == 1) "ol" else try std.fmt.allocPrint(o.alloc, "ol:{d}", .{first.start});
    try o.open(kind);
    var i = start;
    while (i < lines.len) {
        const m = listMarker(lines[i]) orelse break;
        if (!sameList(first, m)) break;
        var item: std.ArrayList([]const u8) = .empty;
        try item.append(o.alloc, m.text);
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            if (trimWs(l).len == 0) {
                var k = j + 1;
                while (k < lines.len and trimWs(lines[k]).len == 0) k += 1;
                if (k < lines.len and indentOf(lines[k]) >= m.content) {
                    while (j < k) : (j += 1) try item.append(o.alloc, "");
                    j -= 1;
                    continue;
                }
                break;
            }
            if (indentOf(l) >= m.content) {
                try item.append(o.alloc, dedent(l, m.content));
            } else if (trimWs(lines[j - 1]).len > 0 and !startsBlock(lines, j)) {
                try item.append(o.alloc, trimWs(l)); // lazy continuation
            } else break;
        }
        try o.open("li");
        try listItem(o, item.items);
        try o.close("/li");
        i = j;
        while (i < lines.len and trimWs(lines[i]).len == 0) i += 1;
        if (i < lines.len) {
            const next = listMarker(lines[i]) orelse break;
            if (!sameList(first, next) or next.indent >= m.content) break;
        }
    }
    try o.close(if (first.ordered) "/ol" else "/ul");
    return i;
}

fn listItem(o: *Out, item: [][]const u8) !void {
    if (item.len > 0) {
        const s = item[0];
        if (s.len >= 3 and s[0] == '[' and s[2] == ']' and (s.len == 3 or s[3] == ' ')) {
            switch (s[1]) {
                ' ' => try o.emit("task"),
                'x', 'X' => try o.emit("task:x"),
                else => {},
            }
            if (s[1] == ' ' or s[1] == 'x' or s[1] == 'X') item[0] = trimWs(s[3..]);
        }
    }
    try blocks(o, item);
}

fn isTableStart(lines: Lines, i: usize) bool {
    if (i + 1 >= lines.len) return false;
    if (std.mem.findScalar(u8, lines[i], '|') == null) return false;
    return isDelimRow(lines[i + 1]);
}

fn isDelimRow(line: []const u8) bool {
    const s = trimWs(line);
    if (std.mem.findScalar(u8, s, '|') == null and std.mem.findScalar(u8, s, '-') == null) return false;
    var it = CellIter.init(s);
    var n: usize = 0;
    while (it.next()) |cell| : (n += 1) {
        const c = trimWs(cell);
        const body = std.mem.trim(u8, c, ":");
        if (body.len == 0 or std.mem.findNone(u8, body, "-") != null) return false;
    }
    return n > 0 and std.mem.findScalar(u8, s, '|') != null;
}

/// Splits a pipe-table row into cells on unescaped `|` outside code spans,
/// ignoring one leading and one trailing pipe.
const CellIter = struct {
    s: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn init(line: []const u8) CellIter {
        var s = trimWs(line);
        if (s.len > 0 and s[0] == '|') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '|' and !(s.len > 1 and s[s.len - 2] == '\\')) s = s[0 .. s.len - 1];
        return .{ .s = s };
    }

    fn next(it: *CellIter) ?[]const u8 {
        if (it.done) return null;
        var i = it.pos;
        var in_code = false;
        while (i < it.s.len) : (i += 1) {
            switch (it.s[i]) {
                '\\' => i += 1,
                '`' => in_code = !in_code,
                '|' => if (!in_code) {
                    const cell = it.s[it.pos..i];
                    it.pos = i + 1;
                    return cell;
                },
                else => {},
            }
        }
        it.done = true;
        return it.s[it.pos..];
    }
};

fn table(o: *Out, lines: Lines, start: usize) !usize {
    var align_buf: std.ArrayList(u8) = .empty;
    var it = CellIter.init(lines[start + 1]);
    while (it.next()) |cell| {
        const c = trimWs(cell);
        const l = c.len > 0 and c[0] == ':';
        const r = c.len > 0 and c[c.len - 1] == ':';
        try align_buf.append(o.alloc, if (l and r) 'c' else if (l) 'l' else if (r) 'r' else '-');
    }
    try o.open(try std.fmt.allocPrint(o.alloc, "table:{d}:{s}", .{ align_buf.items.len, align_buf.items }));
    try row(o, lines[start], "th");
    var i = start + 2;
    while (i < lines.len and trimWs(lines[i]).len > 0 and !startsBlockInTable(lines, i)) : (i += 1)
        try row(o, lines[i], "td");
    try o.close("/table");
    return i;
}

fn startsBlockInTable(lines: Lines, i: usize) bool {
    const s = trimWs(lines[i]);
    return s[0] == '>' or isHr(s) or fenceOpen(s) != null or heading(s) != null or
        (listMarker(lines[i]) != null and std.mem.findScalar(u8, s, '|') == null);
}

fn row(o: *Out, line: []const u8, cell_kind: []const u8) !void {
    try o.open("tr");
    var it = CellIter.init(line);
    while (it.next()) |cell| try o.leaf(cell_kind, trimWs(cell));
    o.depth -|= 1;
}

const FootnoteDef = struct { label: []const u8, rest: []const u8 };

fn footnoteDef(s: []const u8) ?FootnoteDef {
    if (!startsWith(u8, s, "[^")) return null;
    const rb = std.mem.find(u8, s, "]:") orelse return null;
    const label = s[2..rb];
    if (label.len == 0 or std.mem.findAny(u8, label, " \t]") != null) return null;
    return .{ .label = label, .rest = trimWs(s[rb + 2 ..]) };
}

fn fnDef(o: *Out, lines: Lines, start: usize, fd: FootnoteDef) !usize {
    var sub: std.ArrayList([]const u8) = .empty;
    try sub.append(o.alloc, fd.rest);
    var i = start + 1;
    while (i < lines.len) : (i += 1) {
        const l = lines[i];
        if (trimWs(l).len == 0) {
            var k = i + 1;
            while (k < lines.len and trimWs(lines[k]).len == 0) k += 1;
            if (k < lines.len and indentOf(lines[k]) >= 4) {
                while (i < k) : (i += 1) try sub.append(o.alloc, "");
                i -= 1;
                continue;
            }
            break;
        }
        if (indentOf(l) >= 4) {
            try sub.append(o.alloc, dedent(l, 4));
        } else if (trimWs(lines[i - 1]).len > 0 and !startsBlock(lines, i)) {
            try sub.append(o.alloc, trimWs(l));
        } else break;
    }
    try o.open(if (o.strict) try std.fmt.allocPrint(o.alloc, "fndef({s})", .{fd.label}) else "fndef");
    try blocks(o, sub.items);
    try o.close("/fndef");
    return i;
}

const Fence = struct { char: u8, len: usize, lang: []const u8 };

fn fenceOpen(s: []const u8) ?Fence {
    if (s.len < 3 or (s[0] != '`' and s[0] != '~')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) n += 1;
    if (n < 3) return null;
    const info = trimWs(s[n..]);
    if (s[0] == '`' and std.mem.findScalar(u8, info, '`') != null) return null;
    const end = std.mem.findAny(u8, info, " \t") orelse info.len;
    return .{ .char = s[0], .len = n, .lang = info[0..end] };
}

fn fenceCloses(s: []const u8, f: Fence) bool {
    if (s.len < f.len) return false;
    for (s) |c| if (c != f.char) return false;
    return true;
}

const Heading = struct { level: usize, text: []const u8 };

fn heading(s: []const u8) ?Heading {
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < s.len and s[n] != ' ' and s[n] != '\t') return null;
    var text = trimWs(s[n..]);
    // Optional closing sequence: spaces then only '#'.
    const t = std.mem.trimEnd(u8, text, "#");
    if (t.len == 0 or t[t.len - 1] == ' ' or t[t.len - 1] == '\t') text = trimWs(t);
    return .{ .level = n, .text = text };
}

fn isHr(s: []const u8) bool {
    if (s.len < 3 or (s[0] != '-' and s[0] != '*' and s[0] != '_')) return false;
    var n: usize = 0;
    for (s) |c| {
        if (c == s[0]) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn joinTrimmed(alloc: Allocator, lines: Lines) ![]const u8 {
    if (lines.len == 1) return trimWs(lines[0]);
    var b: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, n| {
        if (n > 0) try b.append(alloc, '\n');
        // Keep a trailing backslash: it is a hard break.
        const t = trimWs(l);
        try b.appendSlice(alloc, t);
        // Two or more trailing spaces are the other hard break: leave the
        // scanner's `\<newline>` sentinel so it emits the same `br`.
        if (n + 1 < lines.len and t.len > 0 and t[t.len - 1] != '\\' and
            l.len - std.mem.trimEnd(u8, l, " ").len >= 2)
            try b.append(alloc, '\\');
    }
    return b.items;
}

// --- Frontmatter -------------------------------------------------------------

const FmEntry = struct {
    path: []const u8,
    indent: usize,
    scalar: bool,
    items: usize = 0,
    children: bool = false,
    flow: ?usize = null,
};

/// Key paths and container shapes; values are dropped (a slug derives
/// from the title, a date changes every release).
fn frontmatter(o: *Out, lines: Lines) !void {
    var entries: std.ArrayList(FmEntry) = .empty;
    for (lines) |line| {
        const s = trimWs(line);
        if (s.len == 0 or s[0] == '#') continue;
        const ind = indentOf(line);
        if (s[0] == '-' and (s.len == 1 or s[1] == ' ')) {
            var k = entries.items.len;
            while (k > 0) {
                k -= 1;
                const e = &entries.items[k];
                if (e.indent <= ind and !e.scalar) {
                    e.items += 1;
                    break;
                }
            }
            continue;
        }
        const colon = std.mem.find(u8, s, ": ") orelse
            (if (s[s.len - 1] == ':') s.len - 1 else continue);
        const key = std.mem.trim(u8, s[0..colon], " \t\"'");
        const value = trimWs(s[colon + 1 ..]);
        var parent: ?*FmEntry = null;
        var k = entries.items.len;
        while (k > 0) {
            k -= 1;
            if (entries.items[k].indent < ind) {
                parent = &entries.items[k];
                break;
            }
        }
        // A deeper key under a list item belongs to the item, not a map.
        if (parent) |p| if (p.items > 0 or p.scalar) continue;
        if (parent) |p| p.children = true;
        const path = if (parent) |p| try std.fmt.allocPrint(o.alloc, "{s}.{s}", .{ p.path, key }) else key;
        var e: FmEntry = .{ .path = path, .indent = ind, .scalar = value.len > 0 };
        if (value.len > 0 and value[0] == '[') e.flow = flowCount(value);
        if (value.len > 0 and (value[0] == '|' or value[0] == '>')) e.scalar = true;
        try entries.append(o.alloc, e);
    }
    try o.open("frontmatter");
    for (entries.items) |e| {
        if (e.flow) |n| {
            try o.emitf("fm:{s}[{d}]", .{ e.path, n });
        } else if (e.scalar) {
            try o.emitf("fm:{s}", .{e.path});
        } else if (e.children) {
            try o.emitf("fm:{s}{{}}", .{e.path});
        } else {
            try o.emitf("fm:{s}[{d}]", .{ e.path, e.items });
        }
    }
    try o.close("/frontmatter");
}

fn flowCount(v: []const u8) usize {
    const inner = trimWs(std.mem.trim(u8, trimWs(v), "[]"));
    if (inner.len == 0) return 0;
    var n: usize = 1;
    var q: u8 = 0;
    for (inner) |c| {
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == ',') n += 1;
    }
    return n;
}

// --- Markdown inlines --------------------------------------------------------

const Ev = struct {
    pos: usize,
    seq: usize,
    kind: []const u8,
};

const Delim = struct {
    pos: usize,
    char: u8,
    len: usize,
    left: usize,
    can_open: bool,
    can_close: bool,
};

const Inl = struct {
    o: *Out,
    evs: std.ArrayList(Ev) = .empty,

    fn add(p: *Inl, pos: usize, kind: []const u8) !void {
        try p.evs.append(p.o.alloc, .{ .pos = pos, .seq = p.evs.items.len, .kind = kind });
    }

    fn target(p: *Inl, base: []const u8, t: []const u8) ![]const u8 {
        if (!p.o.strict) return base;
        return std.fmt.allocPrint(p.o.alloc, "{s}({s})", .{ base, trimWs(t) });
    }
};

fn inlines(o: *Out, text: []const u8) !void {
    var p: Inl = .{ .o = o };
    try scanInline(&p, text, 0, 0);
    std.mem.sort(Ev, p.evs.items, {}, struct {
        fn lt(_: void, a: Ev, b: Ev) bool {
            return a.pos < b.pos or (a.pos == b.pos and a.seq < b.seq);
        }
    }.lt);
    const base = o.depth;
    defer o.depth = base;
    for (p.evs.items) |e| {
        if (e.kind[0] == '/') o.depth -|= 1;
        try o.emit(e.kind);
        if (isOpener(e.kind)) o.depth += 1;
    }
}

fn isOpener(kind: []const u8) bool {
    for ([_][]const u8{ "strong", "em", "del", "link" }) |k| {
        if (eql(u8, kind, k) or (startsWith(u8, kind, k) and kind.len > k.len and kind[k.len] == '(')) return true;
    }
    return false;
}

fn isPunct(c: u8) bool {
    return std.ascii.isPunctuation(c);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Scan `text` (at absolute offset `off`) for inline kinds. Emphasis is
/// resolved per call, so link text is its own scope (as in CommonMark).
/// `depth` counts nested links: past max_depth the text is left plain
/// under a single `deep` token, mirroring the block-container cap.
fn scanInline(p: *Inl, text: []const u8, off: usize, depth: u16) Allocator.Error!void {
    var delims: std.ArrayList(Delim) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => {
                if (i + 1 == text.len or text[i + 1] == '\n') {
                    if (i + 1 < text.len) try p.add(off + i, "br");
                    i += 2;
                } else i += if (isPunct(text[i + 1])) 2 else 1;
            },
            '`' => {
                const n = runLen(text, i);
                if (closingBackticks(text, i + n, n)) |end| {
                    try p.add(off + i, "code");
                    i = end + n;
                } else i += n;
            },
            '!' => {
                if (startsWith(u8, text[i + 1 ..], "[[")) {
                    if (std.mem.findPos(u8, text, i + 3, "]]")) |end| {
                        try p.add(off + i, try p.target("embed", text[i + 3 .. end]));
                        i = end + 2;
                        continue;
                    }
                } else if (i + 1 < text.len and text[i + 1] == '[') {
                    if (linkAt(text, i + 1)) |l| {
                        try p.add(off + i, try p.target("img", text[l.url_start..l.url_end]));
                        i = l.end;
                        continue;
                    }
                }
                i += 1;
            },
            '[' => {
                if (startsWith(u8, text[i..], "[[")) {
                    if (std.mem.findPos(u8, text, i + 2, "]]")) |end| {
                        const inner = text[i + 2 .. end];
                        const bar = std.mem.findScalar(u8, inner, '|');
                        const kind = if (bar != null) "wikilink|" else "wikilink";
                        try p.add(off + i, try p.target(kind, inner[0 .. bar orelse inner.len]));
                        i = end + 2;
                        continue;
                    }
                } else if (startsWith(u8, text[i..], "[^")) {
                    if (std.mem.findScalarPos(u8, text, i + 2, ']')) |end| {
                        const label = text[i + 2 .. end];
                        if (label.len > 0 and std.mem.findAny(u8, label, " \t\n[") == null) {
                            try p.add(off + i, try p.target("fnref", label));
                            i = end + 1;
                            continue;
                        }
                    }
                } else if (linkAt(text, i)) |l| {
                    try p.add(off + i, try p.target("link", text[l.url_start..l.url_end]));
                    if (depth < max_depth) {
                        try scanInline(p, text[i + 1 .. l.text_end], off + i + 1, depth + 1);
                    } else {
                        try p.add(off + i + 1, "deep");
                    }
                    try p.add(off + l.text_end, "/link");
                    i = l.end;
                    continue;
                }
                i += 1;
            },
            '<' => {
                if (try angle(p, text, i)) |a| {
                    try p.add(off + i, a.kind);
                    i = a.end;
                } else i += 1;
            },
            'h' => {
                if ((i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) and
                    (startsWith(u8, text[i..], "https://") or startsWith(u8, text[i..], "http://")))
                {
                    var j = i;
                    while (j < text.len and !isSpace(text[j]) and text[j] != '<' and text[j] != ')') j += 1;
                    try p.add(off + i, try p.target("rawurl", text[i..j]));
                    i = j;
                } else i += 1;
            },
            '*', '_', '~' => {
                const n = runLen(text, i);
                const prev: u8 = if (i == 0) ' ' else text[i - 1];
                const next: u8 = if (i + n >= text.len) ' ' else text[i + n];
                const left = !isSpace(next) and (!isPunct(next) or isSpace(prev) or isPunct(prev));
                const right = !isSpace(prev) and (!isPunct(prev) or isSpace(next) or isPunct(next));
                var d: Delim = .{ .pos = i, .char = c, .len = n, .left = n, .can_open = left, .can_close = right };
                if (c == '_') {
                    d.can_open = left and (!right or isPunct(prev));
                    d.can_close = right and (!left or isPunct(next));
                }
                if (c == '~' and n != 2) {
                    d.can_open = false;
                    d.can_close = false;
                }
                if (d.can_open or d.can_close) try delims.append(p.o.alloc, d);
                i += n;
            },
            else => i += 1,
        }
    }
    try resolveEmphasis(p, delims.items, off);
}

fn runLen(text: []const u8, i: usize) usize {
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == text[i]) n += 1;
    return n;
}

fn closingBackticks(text: []const u8, from: usize, n: usize) ?usize {
    var j = from;
    while (j < text.len) {
        if (text[j] != '`') {
            j += 1;
            continue;
        }
        const m = runLen(text, j);
        if (m == n) return j;
        j += m;
    }
    return null;
}

const LinkSpan = struct { text_end: usize, url_start: usize, url_end: usize, end: usize };

/// `[text](url "title")` at text[i] == '['.
fn linkAt(text: []const u8, i: usize) ?LinkSpan {
    var depth: usize = 0;
    var j = i;
    const rb = while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break j;
            },
            else => {},
        }
    } else return null;
    if (rb + 1 >= text.len or text[rb + 1] != '(') return null;
    var pd: usize = 0;
    j = rb + 1;
    const rp = while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '(' => pd += 1,
            ')' => {
                pd -= 1;
                if (pd == 0) break j;
            },
            else => {},
        }
    } else return null;
    const inside = trimWs(text[rb + 2 .. rp]);
    const url_start = rb + 2 + (std.mem.find(u8, text[rb + 2 .. rp], inside) orelse 0);
    const url_len = std.mem.findAny(u8, inside, " \t\n") orelse inside.len;
    return .{ .text_end = rb, .url_start = url_start, .url_end = url_start + url_len, .end = rp + 1 };
}

const Angle = struct { kind: []const u8, end: usize };

/// An autolink `<scheme:...>` or an inline html tag at text[i] == '<'.
/// Tags keep their name and attributes, like the HTML side: every
/// attribute name survives, structural attribute values survive.
fn angle(p: *Inl, text: []const u8, i: usize) !?Angle {
    if (startsWith(u8, text[i..], "<!--")) {
        const end = std.mem.findPos(u8, text, i + 4, "-->") orelse return null;
        return .{ .kind = "html:comment", .end = end + 3 };
    }
    const gt = tagClose(text, i + 1) orelse return null;
    const inner = text[i + 1 .. gt];
    if (inner.len == 0) return null;
    if (std.mem.findAny(u8, inner, " \t\n<") == null and std.mem.findScalar(u8, inner, ':') != null and std.ascii.isAlphabetic(inner[0]))
        return .{ .kind = try p.target("autolink", inner), .end = gt + 1 };
    const closing = inner[0] == '/';
    const name_start: usize = if (closing) 1 else 0;
    var n = name_start;
    while (n < inner.len and (std.ascii.isAlphanumeric(inner[n]) or inner[n] == '-')) n += 1;
    if (n == name_start or !std.ascii.isAlphabetic(inner[name_start])) return null;
    if (n < inner.len and !isSpace(inner[n]) and inner[n] != '/') return null;
    const name = try std.ascii.allocLowerString(p.o.alloc, inner[name_start..n]);
    if (closing)
        return .{ .kind = try std.fmt.allocPrint(p.o.alloc, "html:</{s}>", .{name}), .end = gt + 1 };
    const attrs = try mdAttrs(p.o, inner[n..]);
    const tag = try tagToken(p.o, name, attrs.items);
    return .{ .kind = try std.fmt.allocPrint(p.o.alloc, "html:{s}", .{tag}), .end = gt + 1 };
}

/// The `>` ending a tag that opens at `from - 1`, skipping `>` inside
/// quoted attribute values.
fn tagClose(text: []const u8, from: usize) ?usize {
    var q: u8 = 0;
    var j = from;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') return j;
    }
    return null;
}

/// Attributes of a markdown inline-html tag, parsed like htmlDoc's:
/// `name`, `name=value` with quotes optional.
fn mdAttrs(o: *Out, s: []const u8) !std.ArrayList(Attr) {
    var attrs: std.ArrayList(Attr) = .empty;
    var j: usize = 0;
    while (j < s.len) {
        while (j < s.len and isSpace(s[j])) j += 1;
        if (j >= s.len or s[j] == '/') break;
        const an = j;
        while (j < s.len and !isSpace(s[j]) and s[j] != '=' and s[j] != '/') j += 1;
        if (j == an) {
            j += 1;
            continue;
        }
        const aname = try std.ascii.allocLowerString(o.alloc, s[an..j]);
        var value: ?[]const u8 = null;
        var k = j;
        while (k < s.len and isSpace(s[k])) k += 1;
        if (k < s.len and s[k] == '=') {
            k += 1;
            while (k < s.len and isSpace(s[k])) k += 1;
            if (k < s.len and (s[k] == '"' or s[k] == '\'')) {
                const q = s[k];
                const end = std.mem.findScalarPos(u8, s, k + 1, q) orelse s.len;
                value = s[k + 1 .. end];
                j = @min(end + 1, s.len);
            } else {
                const vs = k;
                while (k < s.len and !isSpace(s[k]) and s[k] != '/') k += 1;
                value = s[vs..k];
                j = k;
            }
        }
        try attrs.append(o.alloc, .{ .name = aname, .value = value });
    }
    return attrs;
}

/// CommonMark's process_emphasis, simplified: match each closer with the
/// nearest compatible opener, two chars when both sides have them.
/// Leftover runs that could open or close become `delim:` tokens.
fn resolveEmphasis(p: *Inl, ds: []Delim, off: usize) !void {
    var k: usize = 0;
    while (k < ds.len) : (k += 1) {
        while (ds[k].can_close and ds[k].left > 0) {
            var j = k;
            const opener = while (j > 0) {
                j -= 1;
                const d = ds[j];
                if (d.char != ds[k].char or !d.can_open or d.left == 0) continue;
                const both = d.can_close or ds[k].can_open;
                if (both and (d.len + ds[k].len) % 3 == 0 and !(d.len % 3 == 0 and ds[k].len % 3 == 0)) continue;
                break j;
            } else null;
            const oi = opener orelse break;
            const use: usize = if (ds[k].char == '~') 2 else if (ds[oi].left >= 2 and ds[k].left >= 2) 2 else 1;
            const kind: []const u8 = if (ds[k].char == '~') "del" else if (use == 2) "strong" else "em";
            const close_kind: []const u8 = if (ds[k].char == '~') "/del" else if (use == 2) "/strong" else "/em";
            ds[oi].left -= use;
            try p.add(off + ds[oi].pos + ds[oi].left, kind);
            try p.add(off + ds[k].pos + (ds[k].len - ds[k].left), close_kind);
            ds[k].left -= use;
            // Delimiters between opener and closer can no longer match.
            for (ds[oi + 1 .. k]) |*d| {
                if (d.left > 0) try leftover(p, d.*, off);
                d.left = 0;
            }
        }
    }
    for (ds) |d| if (d.left > 0) try leftover(p, d, off);
}

fn leftover(p: *Inl, d: Delim, off: usize) !void {
    const kind: []const u8 = switch (d.char) {
        '*' => "delim:*",
        '_' => "delim:_",
        else => "delim:~",
    };
    var n: usize = 0;
    while (n < d.left) : (n += 1) try p.add(off + d.pos + n, kind);
}

// --- HTML --------------------------------------------------------------------

/// Attributes whose values are layout. Every other attribute keeps only its
/// name: `id` slugs, `alt`, `title` and `href` come from text.
const structural_attrs = [_][]const u8{
    "class", "type",   "colspan", "rowspan",  "align",    "valign", "start", "scope",
    "role",  "open",   "checked", "disabled", "reversed", "span",   "dir",   "style",
    "width", "height",
};

const void_tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };

const Attr = struct { name: []const u8, value: ?[]const u8 };

fn htmlDoc(o: *Out, doc: []const u8) !void {
    var i: usize = 0;
    while (i < doc.len) {
        if (doc[i] != '<') {
            i += 1;
            continue;
        }
        const rest = doc[i..];
        if (startsWith(u8, rest, "<!--")) {
            i = if (std.mem.findPos(u8, doc, i + 4, "-->")) |e| e + 3 else doc.len;
            continue;
        }
        if (rest.len > 1 and (rest[1] == '!' or rest[1] == '?')) {
            i = if (std.mem.findScalarPos(u8, doc, i, '>')) |e| e + 1 else doc.len;
            continue;
        }
        const closing = rest.len > 1 and rest[1] == '/';
        var j = i + 1 + @intFromBool(closing);
        const name_start = j;
        while (j < doc.len and (std.ascii.isAlphanumeric(doc[j]) or doc[j] == '-' or doc[j] == ':')) j += 1;
        if (j == name_start or !std.ascii.isAlphabetic(doc[name_start])) {
            i += 1;
            continue;
        }
        const name = try std.ascii.allocLowerString(o.alloc, doc[name_start..j]);
        if (closing) {
            i = if (std.mem.findScalarPos(u8, doc, j, '>')) |e| e + 1 else doc.len;
            try o.close(try std.fmt.allocPrint(o.alloc, "</{s}>", .{name}));
            continue;
        }

        var attrs: std.ArrayList(Attr) = .empty;
        var self_close = false;
        while (j < doc.len) {
            while (j < doc.len and isSpace(doc[j])) j += 1;
            if (j >= doc.len) break;
            if (doc[j] == '>') {
                j += 1;
                break;
            }
            if (doc[j] == '/') {
                self_close = true;
                j += 1;
                continue;
            }
            const an = j;
            while (j < doc.len and !isSpace(doc[j]) and doc[j] != '=' and doc[j] != '>' and doc[j] != '/') j += 1;
            if (j == an) {
                j += 1;
                continue;
            }
            const aname = try std.ascii.allocLowerString(o.alloc, doc[an..j]);
            var value: ?[]const u8 = null;
            var k = j;
            while (k < doc.len and isSpace(doc[k])) k += 1;
            if (k < doc.len and doc[k] == '=') {
                k += 1;
                while (k < doc.len and isSpace(doc[k])) k += 1;
                if (k < doc.len and (doc[k] == '"' or doc[k] == '\'')) {
                    const q = doc[k];
                    const end = std.mem.findScalarPos(u8, doc, k + 1, q) orelse doc.len;
                    value = doc[k + 1 .. end];
                    j = @min(end + 1, doc.len);
                } else {
                    const vs = k;
                    while (k < doc.len and !isSpace(doc[k]) and doc[k] != '>') k += 1;
                    value = doc[vs..k];
                    j = k;
                }
            }
            try attrs.append(o.alloc, .{ .name = aname, .value = value });
        }
        i = j;

        try o.emit(try tagToken(o, name, attrs.items));
        const is_void = self_close or for (void_tags) |v| {
            if (eql(u8, v, name)) break true;
        } else false;
        if (!is_void) o.depth += 1;

        // Raw-text elements: skip to the close tag.
        if (eql(u8, name, "script") or eql(u8, name, "style")) {
            const close_tag = try std.fmt.allocPrint(o.alloc, "</{s}", .{name});
            i = findIgnoreCase(doc, i, close_tag) orelse doc.len;
        }
    }
}

fn findIgnoreCase(doc: []const u8, from: usize, needle: []const u8) ?usize {
    var i = from;
    while (i + needle.len <= doc.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(doc[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn keepValue(o: *Out, name: []const u8) bool {
    for (structural_attrs) |a| if (eql(u8, a, name)) return true;
    return o.strict and (eql(u8, name, "href") or eql(u8, name, "src"));
}

fn tagToken(o: *Out, name: []const u8, attrs: []Attr) ![]const u8 {
    std.mem.sort(Attr, attrs, {}, struct {
        fn lt(_: void, a: Attr, b: Attr) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    var b: std.ArrayList(u8) = .empty;
    try b.print(o.alloc, "<{s}", .{name});
    for (attrs) |a| {
        try b.print(o.alloc, " {s}", .{a.name});
        const v = a.value orelse continue;
        if (!keepValue(o, a.name)) continue;
        // Normalize whitespace inside the value (class lists, styles).
        try b.appendSlice(o.alloc, "=\"");
        var words = std.mem.tokenizeAny(u8, v, " \t\r\n");
        var first = true;
        while (words.next()) |w| {
            if (!first) try b.append(o.alloc, ' ');
            try b.appendSlice(o.alloc, w);
            first = false;
        }
        try b.append(o.alloc, '"');
    }
    try b.append(o.alloc, '>');
    return b.items;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn testHash(doc: []const u8, format: Format) !u64 {
    return hashOpts(testing.allocator, doc, format, .{});
}

fn expectSame(a: []const u8, b: []const u8, format: Format) !void {
    const ha = try testHash(a, format);
    const hb = try testHash(b, format);
    if (ha != hb) {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const ta = try skeleton(arena.allocator(), a, format);
        const tb = try skeleton(arena.allocator(), b, format);
        std.debug.print("\n--- a ---\n", .{});
        for (ta) |t| std.debug.print("{s}\n", .{t.kind});
        std.debug.print("--- b ---\n", .{});
        for (tb) |t| std.debug.print("{s}\n", .{t.kind});
        return error.TestExpectedEqual;
    }
}

fn expectDiffer(a: []const u8, b: []const u8, format: Format) !void {
    try testing.expect(try testHash(a, format) != try testHash(b, format));
}

fn kinds(arena: Allocator, doc: []const u8, format: Format, opts: Options) ![]const u8 {
    const toks = try skeletonOpts(arena, doc, format, opts);
    var b: std.ArrayList(u8) = .empty;
    for (toks, 0..) |t, n| {
        if (n > 0) try b.append(arena, ' ');
        try b.appendSlice(arena, t.kind);
    }
    return b.items;
}

const md_base =
    \\---
    \\title: "Verdict: AcmeDB"
    \\slug: "verdict-acmedb"
    \\genre:
    \\  - "Action"
    \\  - "Sci-fi"
    \\---
    \\# Verdict: AcmeDB
    \\
    \\**give a shit** — the boring database that actually ships
    \\
    \\## Blockers
    \\
    \\- no managed backup story yet
    \\- single-region only
    \\
    \\> [!tip] TL;DR
    \\> Snapshots exist now.[^1]
    \\
    \\| claim | evidence |
    \\| - | :-: |
    \\| p99 | vendor |
    \\
    \\See [[AcmeDB docs]] and [the docs](https://example.com/a).
    \\
    \\[^1]: Vendor-reported.
;

test "markdown: text-only changes keep the hash" {
    const voiced =
        \\---
        \\title: "Verdict: AcmeDB, No Punches Pulled"
        \\slug: "verdict-acmedb-no-punches-pulled"
        \\genre:
        \\  - "Drama"
        \\  - "Horror"
        \\---
        \\#   Verdict: AcmeDB, No Punches Pulled
        \\
        \\**absolutely give a shit**   —   the boring database that actually ships, somehow
        \\
        \\## Dealbreakers
        \\
        \\-   nothing to back up with
        \\- one region, that is it
        \\
        \\> [!tip] Short version
        \\> Snapshots finally exist, for real.[^1]
        \\
        \\|  the claim  | the evidence, at length |
        \\| --- | :---: |
        \\| p99 reads under 2ms | vendor benchmark only |
        \\
        \\See [[AcmeDB docs]] and [the actual docs](https://example.com/a).
        \\
        \\[^1]: Vendor-reported, so treat it as a ceiling.
    ;
    try expectSame(md_base, voiced, .markdown);
}

test "markdown: each structural change moves the hash" {
    const cases = [_][2][]const u8{
        .{ "- single-region only\n", "- single-region only\n- one more\n" },
        .{ "## Blockers\n", "### Blockers\n" },
        .{ "> [!tip] TL;DR\n", "> [!warning] TL;DR\n" },
        .{ "| claim | evidence |\n| - | :-: |\n| p99 | vendor |\n", "| claim | evidence | x |\n| - | :-: | - |\n| p99 | vendor | y |\n" },
        .{ "| - | :-: |\n", "| - | - |\n" },
        .{ "Snapshots exist now.[^1]", "Snapshots exist now." },
        .{ "the boring database", "the **boring** database" },
        .{ "the boring database that", "the boring database\n- that" },
        .{ "slug: \"verdict-acmedb\"\n", "slug: \"verdict-acmedb\"\nextra: 1\n" },
        .{ "  - \"Sci-fi\"\n", "" },
    };
    for (cases) |c| {
        const changed = try std.mem.replaceOwned(u8, testing.allocator, md_base, c[0], c[1]);
        defer testing.allocator.free(changed);
        try testing.expect(!eql(u8, changed, md_base));
        try expectDiffer(md_base, changed, .markdown);
    }
    // Dropping the callout entirely.
    const no_callout = try std.mem.replaceOwned(u8, testing.allocator, md_base, "> [!tip] TL;DR\n> Snapshots exist now.[^1]\n", "Snapshots exist now.[^1]\n");
    defer testing.allocator.free(no_callout);
    try testing.expect(!eql(u8, no_callout, md_base));
    try expectDiffer(md_base, no_callout, .markdown);
}

test "markdown: skeleton tokens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "frontmatter fm:title fm:slug fm:genre[2] /frontmatter h1 p strong /strong h2 ul li p /li li p /li /ul " ++
            "callout:tip title p fnref /callout table:2:-c tr th th tr td td /table p wikilink link /link fndef p /fndef",
        try kinds(a, md_base, .markdown, .{}),
    );
    try testing.expectEqualStrings(
        "p wikilink|(AcmeDB docs) link(https://example.com/a) /link fnref(1) img(x.png) embed(Note)",
        try kinds(a, "[[AcmeDB docs|docs]] [t](https://example.com/a) [^1] ![alt](x.png) ![[Note]]", .markdown, .{ .strict = true }),
    );
    try testing.expectEqualStrings("p wikilink| link /link fnref img embed", try kinds(a, "[[AcmeDB docs|docs]] [t](https://example.com/a) [^1] ![alt](x.png) ![[Note]]", .markdown, .{}));
}

test "markdown: strict mode keeps link targets and footnote labels" {
    const a = "See [docs](https://a.example) and [[Page]].[^one]\n\n[^one]: x\n";
    const b = "See [docs](https://b.example) and [[Other]].[^two]\n\n[^two]: x\n";
    try expectSame(a, b, .markdown);
    const sa = try hashOpts(testing.allocator, a, .markdown, .{ .strict = true });
    const sb = try hashOpts(testing.allocator, b, .markdown, .{ .strict = true });
    try testing.expect(sa != sb);
}

test "markdown: inline kinds and emphasis rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("p em strong /strong /em", try kinds(a, "***x***", .markdown, .{}));
    try testing.expectEqualStrings("p", try kinds(a, "wal_dir is now storage.wal_path, 5 * 3", .markdown, .{}));
    try testing.expectEqualStrings("p em /em code del /del rawurl", try kinds(a, "_a_ `b*c*` ~~d~~ https://x.example/y", .markdown, .{}));
    try testing.expectEqualStrings("p delim:* delim:* strong /strong", try kinds(a, "**give a **shit**", .markdown, .{}));
    try testing.expectEqualStrings("p html:<sup> html:</sup> autolink", try kinds(a, "a<sup>1</sup> <https://x.example>", .markdown, .{}));
    try testing.expectEqualStrings("p link strong /strong /link", try kinds(a, "[**bold** text](u)", .markdown, .{}));
}

test "markdown: nested and ordered lists, quotes, fences, rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\1. one
        \\2. two
        \\   - nested
        \\     continued lazily
        \\
        \\> plain quote
        \\> > nested
        \\
        \\```zig
        \\- not a list
        \\```
        \\
        \\---
        \\- [x] done
    ;
    try testing.expectEqualStrings(
        "ol li p /li li p ul li p /li /ul /li /ol quote p quote p /quote /quote code:zig hr ul li task:x p /li /ul",
        try kinds(a, doc, .markdown, .{}),
    );
    try expectDiffer("- a\n  - b\n", "- a\n- b\n", .markdown);
    try expectDiffer("1. a\n", "- a\n", .markdown);
    try expectDiffer("> [!warning]- Spoilers\n> x\n", "> [!warning] Spoilers\n> x\n", .markdown);
}

test "markdown: trailing-space hard breaks survive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("p br", try kinds(a, "a  \nb\n", .markdown, .{}));
    try testing.expectEqualStrings("p br", try kinds(a, "a\\\nb\n", .markdown, .{}));
    try expectSame("a  \nb\n", "a\\\nb\n", .markdown);
    // One trailing space is a soft break and stays invisible.
    try expectSame("a\nb\n", "a \nb\n", .markdown);
    try expectDiffer("a  \nb\n", "a\nb\n", .markdown);
    try expectDiffer("a  \nb\n", "a \nb\n", .markdown);
}

test "markdown: nested links are depth-capped, not fatal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ~10^5 nested links used to overflow the stack via scanInline.
    const n = 100_000;
    var b: std.ArrayList(u8) = .empty;
    for (0..n) |_| try b.appendSlice(a, "[a ");
    try b.appendSlice(a, "x");
    for (0..n) |_| try b.appendSlice(a, "](u)");
    const toks = try skeleton(a, b.items, .markdown);
    var links: usize = 0;
    var deeps: usize = 0;
    for (toks) |t| {
        if (eql(u8, t.kind, "link")) links += 1;
        if (eql(u8, t.kind, "deep")) deeps += 1;
    }
    try testing.expectEqual(@as(usize, max_depth + 1), links);
    try testing.expectEqual(@as(usize, 1), deeps);
    try testing.expectEqualStrings("p link link /link /link", try kinds(a, "[a [b](u)](u)", .markdown, .{}));
}

test "markdown: inline html keeps tag names and attributes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("p html:<video controls>", try kinds(a, "x <video controls> y", .markdown, .{}));
    try testing.expectEqualStrings("p html:<span class=\"a\"> html:</span>", try kinds(a, "x <span class=\"a\">1</span> y", .markdown, .{}));
    try testing.expectEqualStrings("p html:<br> html:<img src>", try kinds(a, "x<br/><img src=i.png>", .markdown, .{}));
    try expectDiffer("x <video controls> y", "x <audio> y", .markdown);
    try expectDiffer("x <video controls> y", "x <video> y", .markdown);
    try expectDiffer("x <span class=\"a\"> y", "x <span class=\"b\"> y", .markdown);
    // Attribute order and text-derived values (id, title) are still dropped.
    try expectSame("x <span id=\"a\" class=\"k\"> y", "x <span class=\"k\" id=\"b\"> y", .markdown);
}

test "markdown: ordered-list start number is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ol:3 li p /li li p /li /ol", try kinds(a, "3. a\n4. b\n", .markdown, .{}));
    try testing.expectEqualStrings("ol li p /li /ol", try kinds(a, "1. a\n", .markdown, .{}));
    try expectDiffer("3. a\n4. b\n", "1. a\n2. b\n", .markdown);
    try expectSame("3. a\n4. b\n", "3. x\n4. y\n", .markdown);
}

test "markdown: strict keeps raw-url and autolink targets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc_a = "see https://a.example/x and <https://a.example/y>\n";
    const doc_b = "see https://b.example/x and <https://b.example/y>\n";
    try expectSame(doc_a, doc_b, .markdown);
    const sa = try hashOpts(testing.allocator, doc_a, .markdown, .{ .strict = true });
    const sb = try hashOpts(testing.allocator, doc_b, .markdown, .{ .strict = true });
    try testing.expect(sa != sb);
    try testing.expectEqualStrings(
        "p rawurl(https://a.example/x) autolink(https://a.example/y)",
        try kinds(a, doc_a, .markdown, .{ .strict = true }),
    );
}

test "markdown: table cell padding is ignored, cell count is not" {
    try expectSame("|a|b|\n|-|-|\n|c|d|\n", "| a long header | b |\n| ------------- | --- |\n|  c  | dddddddddd |\n", .markdown);
    try expectDiffer("|a|b|\n|-|-|\n|c|d|\n", "|a|b|\n|-|-|\n|c|d|\n|e|f|\n", .markdown);
    try expectDiffer("|a|b|\n|-|-|\n|c|d|\n", "|a|b|\n|-|-|\n|c|d|x|\n", .markdown);
}

const html_base =
    \\<h1 id="verdict-acmedb">Verdict: AcmeDB</h1>
    \\<p><strong>give a shit</strong> — the boring database</p>
    \\<div class="callout callout-tip">
    \\<div class="callout-title">TL;DR</div>
    \\<p>Snapshots exist.<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup></p>
    \\</div>
    \\<ul>
    \\<li>one</li>
    \\<li>two</li>
    \\</ul>
    \\<table><tr><th>a</th><th colspan="2">b</th></tr></table>
    \\<p><img src="x.png" alt="a cat" /><br></p>
;

test "html: text and text-derived attributes are dropped" {
    const voiced =
        \\<h1 id="verdict-acmedb-no-punches-pulled">Verdict: AcmeDB, No Punches Pulled</h1>
        \\<p><strong>absolutely give a shit</strong>— the boring database, somehow</p>
        \\<div class="callout  callout-tip">
        \\  <div class="callout-title">Short version</div>
        \\  <p>Snapshots finally exist.<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup></p>
        \\</div>
        \\<ul><li>uno</li><li>dos, longer</li></ul>
        \\<table><tr><th>alpha</th><th colspan="2">beta</th></tr></table>
        \\<p><img alt="a very angry cat" src="x.png"/><br></p>
    ;
    try expectSame(html_base, voiced, .html);
}

test "html: each structural change moves the hash" {
    const cases = [_][2][]const u8{
        .{ "<li>two</li>\n", "<li>two</li>\n<li>three</li>\n" },
        .{ "<h1 id=\"verdict-acmedb\">Verdict: AcmeDB</h1>", "<h2 id=\"verdict-acmedb\">Verdict: AcmeDB</h2>" },
        .{ "callout-tip", "callout-warning" },
        .{ "colspan=\"2\"", "colspan=\"3\"" },
        .{ "<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup>", "" },
        .{ "the boring database", "the <strong>boring</strong> database" },
    };
    for (cases) |c| {
        const changed = try std.mem.replaceOwned(u8, testing.allocator, html_base, c[0], c[1]);
        defer testing.allocator.free(changed);
        try testing.expect(!eql(u8, changed, html_base));
        try expectDiffer(html_base, changed, .html);
    }
}

test "html: skeleton tokens and strict mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "<p> <a href> </a> <img alt src> <br> </p>",
        try kinds(a, "<!-- c --><p>x <a href=\"u\">t</a><IMG SRC='i.png' alt=\"z\"/><br></p>", .html, .{}),
    );
    try testing.expectEqualStrings(
        "<p> <a href=\"u\"> </a> </p>",
        try kinds(a, "<p><a href=\"u\">t</a></p>", .html, .{ .strict = true }),
    );
    try testing.expectEqualStrings("<script> </script>", try kinds(a, "<script>if (a<b) x()</script>", .html, .{}));
}

test "sniff and formatFromName" {
    try testing.expectEqual(Format.html, sniff("\n<h1>x</h1>"));
    try testing.expectEqual(Format.html, sniff("<hr />\n<p>x</p>"));
    try testing.expectEqual(Format.markdown, sniff("---\ntitle: x\n---\n# x"));
    try testing.expectEqual(Format.markdown, sniff("# x <b>y</b>"));
    try testing.expectEqual(Format.html, formatFromName("html").?);
    try testing.expect(formatFromName("textile") == null);
}

test "hash is deterministic and empty docs are stable" {
    try testing.expectEqual(hash(md_base, .markdown), hash(md_base, .markdown));
    try testing.expectEqual(hash("", .markdown), hash("\n\n  \n", .markdown));
    try testing.expect(hash(md_base, .markdown) != hash(md_base, .html));
}
