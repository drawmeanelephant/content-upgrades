//! Advisory structure lint over a rendered document — layer 2 of the
//! validation stack. Warnings only, never blocks: it surfaces the obvious
//! sins (dangling footnotes, bare URLs, skipped heading levels, fences
//! left open) as diagnostics instead of letting them ship silently.
//! Pure text in, warnings out; runs on artifact-store docs by handle.
//!
//! A resolved site profile (boris.zig's siteProfile → Site) opts the doc
//! into the boris-surface rule pack: closed frontmatter schemas,
//! `{{include}}` transclusions, `<Aside>`/`<Details>` components and
//! canonical-id wiki-link targets. No profile, no new warnings — the
//! frozen-site output stays byte-identical.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");

pub const Warning = struct {
    rule: []const u8,
    line: u32, // 1-based; 0 for document-wide findings
    detail: []const u8,
};

/// The boris-surface rule pack's inputs, resolved from the site profile.
/// Every field off/empty is the frozen-site behavior.
pub const Site = struct {
    /// Declared closed frontmatter schema (knap-site.json "frontmatter");
    /// an empty list skips the unknown-key check.
    schema: []const []const u8 = &.{},
    /// Wiki-link targets must be canonical ids (case-sensitive paths).
    canonical_ids: bool = false,
    /// Content root that `{{include}}` paths resolve against; null skips
    /// the existence half of the unresolved-include rule.
    content_dir: ?[]const u8 = null,
    /// IO for the existence probes; only read when content_dir is set.
    io: std.Io = undefined,
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
    return checkSite(alloc, doc, null);
}

/// `check` plus the profile-declared boris rules; `site == null` is the
/// frozen path — identical warnings, byte for byte.
pub fn checkSite(alloc: std.mem.Allocator, doc: []const u8, site: ?Site) ![]Warning {
    var warnings: std.ArrayList(Warning) = .empty;
    var refs: std.ArrayList(Note) = .empty;
    var defs: std.ArrayList(Note) = .empty;
    var ref_set: std.StringHashMapUnmanaged(void) = .empty;
    var def_set: std.StringHashMapUnmanaged(void) = .empty;

    // Leading frontmatter is skipped wholesale only when it closes; an
    // unterminated `---` block is prose, matching density.
    const front_end = frontmatterEnd(doc);

    // The closed-schema check reads the block's key set once, up front —
    // the keys sit inside the lines the main loop skips.
    if (site) |s| {
        if (s.schema.len > 0) {
            if (try frontmatter.parse(alloc, doc)) |b| {
                for (b.keys, 0..) |k, i| {
                    for (s.schema) |allowed| {
                        if (std.mem.eql(u8, k, allowed)) break;
                    } else try warnFmt(&warnings, alloc, "unknown-frontmatter-key", b.key_lines[i], "frontmatter key \"{s}\" is outside the declared schema", .{k});
                }
            }
        }
    }
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
    var open_component: ?Component = null;

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

        // The boris pack scans body lines with code spans masked — like
        // boris's own scanners, includes and component-looking text inside
        // backticks or fences are literal, never directives.
        if (site) |s| try scanBorisLine(alloc, &warnings, s, &open_component, t, line_no);

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
    if (open_component) |c|
        try warnFmt(&warnings, alloc, "unclosed-component", c.line, "<{s}> opened here is never closed (missing line-start </{s}>)", .{ c.name, c.name });
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

// --- Boris surface (opt-in via the site profile) -----------------------------
//
// The rules boris itself hard-errors on, downgraded to advisories: an
// `{{include}}` whose path is illegal or missing, an `<Aside>`/`<Details>`
// opened and never closed (or nested/cross-closed), and wiki-links whose
// targets aren't canonical ids for that site. Everything here keys off
// the resolved Site — nothing fires on the frozen path.

const Component = struct {
    name: []const u8,
    line: u32,
};

/// A trimmed line that opens `<Aside` or `<Details`: the name plus a
/// lexical boundary, with `>` reached on the same line (boris's open-tag
/// scan is line-bounded). Returns the component name.
fn componentOpen(t: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, t, "<") or (t.len > 1 and t[1] == '/')) return null;
    const name: []const u8 = if (std.mem.startsWith(u8, t[1..], "Aside"))
        "Aside"
    else if (std.mem.startsWith(u8, t[1..], "Details"))
        "Details"
    else
        return null;
    const after = t[1 + name.len ..];
    if (after.len == 0) return null;
    if (after[0] != ' ' and after[0] != '\t' and after[0] != '>' and after[0] != '/') return null;
    var q: u8 = 0;
    for (after) |c| {
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') {
            return name;
        } else if (c == '<') return null;
    }
    return null;
}

/// A trimmed line that is exactly `</Aside>` or `</Details>` (optional
/// outer whitespace already trimmed by the caller).
fn componentClose(t: []const u8) ?[]const u8 {
    inline for (.{ "Aside", "Details" }) |name| {
        if (std.mem.eql(u8, t, "</" ++ name ++ ">")) return name;
    }
    return null;
}

/// `include <path>` after `{{include`, per boris's directive form; returns
/// the path span, or null when the text isn't a terminated directive
/// (`{{includeX` and an unterminated `{{include x` are not directives).
const Include = struct { path: []const u8, end: usize };

fn includeAt(t: []const u8, i: usize) ?Include {
    const kw = "{{include";
    if (!std.mem.startsWith(u8, t[i..], kw)) return null;
    var j = i + kw.len;
    if (j >= t.len or (t[j] != ' ' and t[j] != '\t')) return null;
    while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
    const ps = j;
    while (j < t.len and t[j] != '}') j += 1;
    var pe = j;
    while (pe > ps and (t[pe - 1] == ' ' or t[pe - 1] == '\t')) pe -= 1;
    if (j + 1 >= t.len or t[j] != '}' or t[j + 1] != '}') return null;
    return .{ .path = t[ps..pe], .end = j + 2 };
}

/// Content-root-relative include path grammar, verbatim from boris's
/// validateIncludePath: `/`-joined `[A-Za-z0-9._-]` segments, no `\`, no
/// absolute, no empty/`. ` /`..`/dot-leading segment.
fn validIncludePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (seg[0] == '.') return false;
        for (seg) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
        }
    }
    return true;
}

/// `limericks/LIM-0155` — the canonical-id shape for a case-sensitive
/// entity graph: `/`-joined segments of word/path bytes (non-ASCII text
/// stays legal), no empty/`.`/`..` segment, no page extension, ≤255
/// bytes. A slug-rewritten title ("AcmeDB docs — backups") fails it.
pub fn isCanonicalId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255) return false;
    inline for (.{ ".md", ".mdx", ".textile", ".cook" }) |ext| {
        if (std.mem.endsWith(u8, id, ext)) return false;
    }
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-' and c < 0x80) return false;
        }
    }
    return true;
}

/// The link target of `[[t]]`, `[[t|label]]`, `[[t#frag]]`,
/// `[[t#frag|label]]` or `![[…]]` starting at `[`/`!`: the entity id is
/// the text before `|`/`#`. Returns the target or null (no `]]`).
fn wikiTarget(t: []const u8, i: usize) ?struct { target: []const u8, end: usize } {
    const inner_start = i + 2;
    const end = std.mem.indexOfPos(u8, t, inner_start, "]]") orelse return null;
    var target = t[inner_start..end];
    if (std.mem.indexOfScalar(u8, target, '|')) |p| target = target[0..p];
    if (std.mem.indexOfScalar(u8, target, '#')) |h| target = target[0..h];
    return .{ .target = target, .end = end + 2 };
}

/// A copy of `line` with complete inline code spans blanked: directives
/// and component text inside matching backtick runs are literal.
fn maskCodeSpans(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    const m = try alloc.dupe(u8, line);
    var i: usize = 0;
    while (i < m.len) {
        if (m[i] != '`') {
            i += 1;
            continue;
        }
        const n = runLen(m, i, '`');
        const ticks = try alloc.alloc(u8, n);
        @memset(ticks, '`');
        if (std.mem.indexOfPos(u8, m, i + n, ticks)) |e| {
            @memset(m[i .. e + n], ' ');
            i = e + n;
        } else i += n;
    }
    return m;
}

/// The boris rules on one body line (already frontmatter/fence filtered).
/// `t` is the trimmed line; `open` tracks the pending component.
fn scanBorisLine(
    alloc: std.mem.Allocator,
    warnings: *std.ArrayList(Warning),
    site: Site,
    open: *?Component,
    t: []const u8,
    line_no: u32,
) !void {
    if (open.*) |c| {
        if (componentClose(t)) |n| {
            if (std.mem.eql(u8, n, c.name)) {
                open.* = null;
            } else {
                // boris: cross-nested close is a hard error; the open stays.
                try warnFmt(warnings, alloc, "mismatched-component-close", line_no, "</{s}> cannot close an open <{s}> (line {d})", .{ n, c.name, c.line });
            }
        }
    } else if (componentClose(t)) |n| {
        try warnFmt(warnings, alloc, "stray-component-close", line_no, "</{s}> closes nothing — no <{s}> is open", .{ n, n });
    }
    if (componentOpen(t)) |n| {
        if (open.*) |c| {
            try warnFmt(warnings, alloc, "nested-component", line_no, "<{s}> opens inside <{s}> (line {d}); components cannot nest", .{ n, c.name, c.line });
        } else {
            open.* = .{ .name = n, .line = line_no };
        }
    }

    const masked = try maskCodeSpans(alloc, t);
    var i: usize = 0;
    while (i < masked.len) {
        switch (masked[i]) {
            '{' => {
                if (includeAt(masked, i)) |inc| {
                    if (!validIncludePath(inc.path)) {
                        try warnFmt(warnings, alloc, "bad-include-path", line_no, "include path \"{s}\" is not a content-root-relative path", .{inc.path});
                    } else if (site.content_dir) |root| {
                        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, inc.path });
                        std.Io.Dir.access(.cwd(), site.io, full, .{}) catch
                            try warnFmt(warnings, alloc, "unresolved-include", line_no, "include target \"{s}\" not found under the site content root", .{inc.path});
                    }
                    i = inc.end;
                    continue;
                }
                // `{{` that never reaches `}}` on this line isn't a
                // directive; boris's unterminated include is a syntax
                // error only when the keyword matched.
                if (std.mem.startsWith(u8, masked[i..], "{{include") and
                    (masked.len == i + "{{include".len or masked[i + "{{include".len] == ' ' or masked[i + "{{include".len] == '\t'))
                    try warn(warnings, alloc, "bad-include-path", line_no, "unterminated {{include …}} directive");
                i += 1;
            },
            '[', '!' => {
                const at = i + @intFromBool(masked[i] == '!');
                if (at + 1 < masked.len and masked[at] == '[' and masked[at + 1] == '[') {
                    if (wikiTarget(masked, at)) |w| {
                        if (site.canonical_ids and !isCanonicalId(w.target))
                            try warnFmt(warnings, alloc, "noncanonical-link", line_no, "wiki-link target \"{s}\" is not a canonical id for this site", .{w.target});
                        i = w.end;
                        continue;
                    }
                }
                i += 1;
            },
            else => i += 1,
        }
    }
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

fn countRules(warnings: []const Warning, rules: []const []const u8) usize {
    var n: usize = 0;
    for (rules) |r| n += countRule(warnings, r);
    return n;
}

const boris_rules = [_][]const u8{
    "unknown-frontmatter-key", "bad-include-path",      "unresolved-include",
    "unclosed-component",      "stray-component-close", "mismatched-component-close",
    "nested-component",        "noncanonical-link",
};

fn filedSite(io: std.Io, content_dir: ?[]const u8) Site {
    return .{
        .schema = &.{ "id", "title", "parent", "status", "tags", "relations", "published_at", "summary" },
        .canonical_ids = true,
        .content_dir = content_dir,
        .io = io,
    };
}

test "boris pack: a declared schema flags foreign frontmatter keys, frozen stays silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "---\ntitle: T\nid: limericks/LIM-0001\nmood: feral\nyear: 2026\n---\n\nBody.\n";
    const w = try checkSite(a, doc, filedSite(std.testing.io, null));
    try std.testing.expectEqual(@as(usize, 2), countRule(w, "unknown-frontmatter-key"));
    try std.testing.expectEqual(@as(u32, 4), w[0].line);
    // The frozen path — no profile at all — reports nothing new.
    const frozen = try check(a, doc);
    try std.testing.expectEqual(@as(usize, 0), countRules(frozen, &boris_rules));
    // An empty schema declaration also stays silent.
    const bare = try checkSite(a, doc, .{});
    try std.testing.expectEqual(@as(usize, 0), countRules(bare, &boris_rules));
}

test "boris pack: canonical-id wiki-link targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const site = filedSite(std.testing.io, null);
    const doc = "See [[limericks/LIM-0155|L]], [[lorelog]], [[id#frag|x]] and ![[mascots/M-0090]].\n";
    try std.testing.expectEqual(@as(usize, 0), countRule(try checkSite(a, doc, site), "noncanonical-link"));
    const bad = "See [[AcmeDB docs — backups|x]], [[limericks/lim 0155]] and [[page.md]].\n";
    const w = try checkSite(a, bad, site);
    try std.testing.expectEqual(@as(usize, 3), countRule(w, "noncanonical-link"));
    // canonical_ids off: the same doc is silent.
    const off = try checkSite(a, bad, .{});
    try std.testing.expectEqual(@as(usize, 0), countRule(off, "noncanonical-link"));
    // `[[x]]` inside a code span is literal, not a link.
    const literal = try checkSite(a, "`[[AcmeDB docs]]` [[limericks/LIM-1]]\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRule(literal, "noncanonical-link"));
}

test "boris pack: includes resolve against the content root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "content/includes");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "content/includes/note.md", .data = "x\n" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    const site = filedSite(std.testing.io, root);

    const good = try checkSite(a, "lead {{include includes/note.md}} tail\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRule(good, "unresolved-include"));
    const missing = try checkSite(a, "lead {{include includes/gone.md}} tail\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(missing, "unresolved-include"));
    const illegal = try checkSite(a, "a {{include ../escape.md}} b {{include /abs.md}} c\n", site);
    try std.testing.expectEqual(@as(usize, 2), countRule(illegal, "bad-include-path"));
    const unterminated = try checkSite(a, "a {{include x.md\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(unterminated, "bad-include-path"));
    // Fenced and inline code keep directives literal.
    const fenced = try checkSite(a, "```\n{{include gone.md}}\n```\n`{{include gone.md}}`\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRules(fenced, &boris_rules));
}

test "boris pack: components must close, same-name only, never nest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const site = filedSite(std.testing.io, null);
    const ok = try checkSite(a, "<Aside kind=\"tip\">\nx\n</Aside>\n<Details summary=\"s\">\ny\n</Details>\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRules(ok, &boris_rules));
    const unclosed = try checkSite(a, "<Aside kind=\"note\">\nx\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(unclosed, "unclosed-component"));
    const stray = try checkSite(a, "text\n</Aside>\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(stray, "stray-component-close"));
    const crossed = try checkSite(a, "<Aside>\nx\n</Details>\ny\n</Aside>\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(crossed, "mismatched-component-close"));
    try std.testing.expectEqual(@as(usize, 0), countRule(crossed, "unclosed-component"));
    const nested = try checkSite(a, "<Aside>\n<Details summary=\"s\">\n</Details>\n</Aside>\n", site);
    try std.testing.expectEqual(@as(usize, 1), countRule(nested, "nested-component"));
    // Mid-line tags and fenced tags are not components.
    const midline = try checkSite(a, "text <Aside> here\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRules(midline, &boris_rules));
    const fenced = try checkSite(a, "```\n<Aside>\n```\n", site);
    try std.testing.expectEqual(@as(usize, 0), countRule(fenced, "unclosed-component"));
}

test "isCanonicalId: canonical paths pass, slugs and titles fail" {
    try std.testing.expect(isCanonicalId("limericks/LIM-0155"));
    try std.testing.expect(isCanonicalId("lorelog"));
    try std.testing.expect(isCanonicalId("mascots/003.blamey-mctypoface"));
    try std.testing.expect(isCanonicalId("claims/backup-gap"));
    try std.testing.expect(!isCanonicalId("AcmeDB docs — backups"));
    try std.testing.expect(!isCanonicalId("limericks/lim 0155"));
    try std.testing.expect(!isCanonicalId("page.md"));
    try std.testing.expect(!isCanonicalId("../x"));
    try std.testing.expect(!isCanonicalId("a//b"));
    try std.testing.expect(!isCanonicalId("/abs"));
    try std.testing.expect(!isCanonicalId("a\\b"));
    try std.testing.expect(!isCanonicalId("a#frag"));
    try std.testing.expect(!isCanonicalId(""));
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
