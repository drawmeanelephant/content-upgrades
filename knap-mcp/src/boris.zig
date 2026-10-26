//! knap_publish_check core: stage one rendered markdown doc into a
//! throwaway copy of the frozen boris site and run `boris validate` there.
//! A port of boris-site/stage-check.sh (--validate mode); keep the two in
//! parity, rule for rule (docs/tracks/B2.md).
//!
//! Staging adapts the doc without adding or removing body lines, so every
//! diagnostic maps back to the rendered doc exactly:
//!   - the frontmatter becomes `title` only (boris keys are a closed set);
//!   - `[[T]]` -> `[[slug(T)|T]]`, `[[T|L]]` -> `[[slug(T)|L]]`, `#frag`
//!     kept, slug-form targets untouched;
//!   - `![[T]]` loses its `!`: boris 0.8.2 cannot embed a page (it renders
//!     an image of T.html, EASSET), so an embed is checked as a link.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const store = @import("store.zig");

pub const Error = error{ ToolFailed, OutOfMemory };

pub const Diagnostic = struct {
    code: []const u8,
    severity: []const u8,
    /// 1-based line and byte column in the rendered doc; 0 = unknown.
    line: u32 = 0,
    column: u32 = 0,
    detail: []const u8,
    /// Original link text for a wiki-link diagnostic; an embed keeps its
    /// leading `!` (`![[T]]`), so a checked embed is visible as one.
    link: ?[]const u8 = null,
    /// Entity id boris looked up (the slug for a rewritten link).
    target: ?[]const u8 = null,
};

pub const Report = struct {
    ok: bool,
    /// Entity id of the staged doc: `staged/<name>`.
    staged_as: []const u8,
    /// Pages in the staged site, the doc included.
    pages: usize,
    /// Wiki-links and embeds in the doc body (frontmatter is dropped).
    links: usize,
    diagnostics: []Diagnostic,
    elapsed_ms: f64,
};

/// The boris site: KNAP_BORIS_SITE, else `<templates_dir>/../../boris-site`.
/// Lane B3 resolves the site with the same rule.
pub fn siteDir(ctx: *Ctx) Error![]const u8 {
    if (ctx.environ.get("KNAP_BORIS_SITE")) |dir| return dir;
    return std.fmt.allocPrint(ctx.arena, "{s}/../../boris-site", .{ctx.templates_dir});
}

/// Check that every wiki-link in `doc` (rendered markdown) resolves against
/// the frozen site. `name` names the staged copy (`staged/<name>`); bytes
/// outside [A-Za-z0-9._-] become `-`. Fails (ctx.err_msg) when the doc
/// cannot be staged or boris cannot run; content problems are diagnostics.
pub fn check(ctx: *Ctx, doc: []const u8, name: []const u8) Error!Report {
    const t0 = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const arena = ctx.arena;

    const staged = stage(arena, doc) catch |e| switch (e) {
        error.UnclosedFrontmatter => return ctx.fail("doc has an unclosed frontmatter block", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const base = try stagedName(arena, name);
    const rel = try std.fmt.allocPrint(arena, "staged/{s}.md", .{base});

    const dir = try store.scratchFile(ctx, "boris");
    defer std.Io.Dir.deleteTree(.cwd(), ctx.io, dir) catch {};
    const site = try siteDir(ctx);
    const pages = try copyTree(ctx, site, dir, "content") + 1;
    _ = try copyTree(ctx, site, dir, "themes");

    const doc_path = try std.fmt.allocPrint(arena, "{s}/content/{s}", .{ dir, rel });
    std.Io.Dir.createDirPath(.cwd(), ctx.io, std.fs.path.dirname(doc_path).?) catch
        return ctx.fail("cannot create staging dir", .{});
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = doc_path, .data = staged.text }) catch
        return ctx.fail("cannot write staged doc", .{});

    // boris resolves output paths against its working directory, so it runs
    // inside the staging dir; a relative KNAP_BORIS_PATH is made absolute.
    var exe: []const u8 = ctx.environ.get("KNAP_BORIS_PATH") orelse "boris";
    if (std.mem.indexOfScalar(u8, exe, '/') != null and !std.fs.path.isAbsolute(exe)) {
        const cwd = std.process.currentPathAlloc(ctx.io, arena) catch
            return ctx.fail("cannot resolve the working directory", .{});
        exe = try std.fs.path.join(arena, &.{ cwd, exe });
    }
    const result = std.process.run(arena, ctx.io, .{
        .argv = &.{ exe, "validate", "--input", "content", "--report", "report.json", "--quiet" },
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("boris not runnable: '{s}' ({s}); set KNAP_BORIS_PATH", .{ exe, @errorName(e) }),
    };
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return ctx.fail("boris terminated abnormally", .{}),
    };
    if (code > 1) return ctx.fail("boris validate exited {d}: {s}", .{ code, firstLine(result.stderr) });

    const report_path = try std.fmt.allocPrint(arena, "{s}/report.json", .{dir});
    const report = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, report_path, arena, .limited(16 * 1024 * 1024)) catch
        return ctx.fail("boris validate wrote no report: {s}", .{firstLine(result.stderr)});
    const diags = mapReport(arena, staged, rel, doc, report, result.stderr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("cannot parse the boris report ({s})", .{@errorName(e)}),
    };
    var errors: usize = 0;
    for (diags) |d| errors += @intFromBool(std.mem.eql(u8, d.severity, "error"));
    if (code == 1 and errors == 0)
        return ctx.fail("boris validate failed without an error diagnostic: {s}", .{firstLine(result.stderr)});

    const elapsed = t0.untilNow(ctx.io).raw.nanoseconds;
    return .{
        .ok = errors == 0,
        .staged_as = rel[0 .. rel.len - ".md".len],
        .pages = pages,
        .links = staged.links.len,
        .diagnostics = diags,
        .elapsed_ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms,
    };
}

/// Copy `<site>/<sub>` to `<dir>/<sub>`; returns the number of `.md` files.
fn copyTree(ctx: *Ctx, site: []const u8, dir: []const u8, sub: []const u8) Error!usize {
    const src_path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ site, sub });
    var src = std.Io.Dir.openDir(.cwd(), ctx.io, src_path, .{ .iterate = true }) catch
        return ctx.fail("boris site has no '{s}' (KNAP_BORIS_SITE or <templates>/../../boris-site)", .{src_path});
    defer src.close(ctx.io);
    var walker = try src.walk(ctx.arena);
    defer walker.deinit();
    var md: usize = 0;
    while (walker.next(ctx.io) catch return ctx.fail("cannot read '{s}'", .{src_path})) |entry| {
        if (entry.kind != .file) continue;
        const dest = try std.fmt.allocPrint(ctx.arena, "{s}/{s}/{s}", .{ dir, sub, entry.path });
        std.Io.Dir.copyFile(entry.dir, entry.basename, .cwd(), dest, ctx.io, .{ .make_path = true }) catch
            return ctx.fail("cannot stage '{s}/{s}'", .{ src_path, entry.path });
        md += @intFromBool(std.mem.endsWith(u8, entry.basename, ".md"));
    }
    return md;
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

/// stage-check.sh naming: bytes outside [A-Za-z0-9._-] become `-`; an
/// empty or dot-leading name gets a `doc` prefix.
fn stagedName(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    const out = try arena.alloc(u8, name.len);
    for (name, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '-';
    if (out.len == 0 or out[0] == '.') return std.fmt.allocPrint(arena, "doc{s}", .{out});
    return out;
}

// --- staging adapter -----------------------------------------------------------

/// One wiki-link or embed: where boris sees it, where it is in the doc.
pub const Link = struct {
    staged_line: u32,
    staged_col: u32,
    line: u32,
    col: u32,
    id: []const u8,
    /// Original text; `![[...]]` for an embed.
    text: []const u8,
};

pub const Staged = struct {
    text: []const u8,
    links: []Link,
    /// Original line count minus staged line count (the frontmatter shrink).
    delta: i64,
    /// Doc lines of the title and the closing `---`; 0 when absent.
    title_line: u32 = 0,
    fm_close_line: u32 = 0,
};

/// slug: ASCII lowercase; keep [a-z0-9/]; every other run of bytes becomes
/// one `-`; trim `-` and `/` from both ends.
pub fn slug(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_run = false;
    for (s) |c| {
        const l = std.ascii.toLower(c);
        if (std.ascii.isLower(l) or std.ascii.isDigit(l) or l == '/') {
            try out.append(arena, l);
            in_run = false;
        } else if (!in_run) {
            try out.append(arena, '-');
            in_run = true;
        }
    }
    return std.mem.trim(u8, out.items, "-/");
}

/// The awk match `\[\[[^]]+\]\]`: leftmost `[[`, at least one non-`]` byte,
/// then `]]`. Returns [start, end) in `s`.
fn findLink(s: []const u8) ?[2]usize {
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] != '[' or s[i + 1] != '[') continue;
        const j = std.mem.indexOfScalarPos(u8, s, i + 2, ']') orelse return null;
        if (j > i + 2 and j + 1 < s.len and s[j + 1] == ']') return .{ i, j + 2 };
    }
    return null;
}

pub fn stage(arena: std.mem.Allocator, doc: []const u8) error{ UnclosedFrontmatter, OutOfMemory }!Staged {
    var out: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var st: Staged = .{ .text = "", .links = &.{}, .delta = 0 };
    var fm: enum { none, open, closed } = .none;
    var title: []const u8 = "";
    var nr: u32 = 0;
    var staged: u32 = 0;

    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break; // after the last newline
        nr += 1;
        if (nr == 1 and std.mem.eql(u8, line, "---")) {
            fm = .open;
            continue;
        }
        if (fm == .open) {
            if (std.mem.eql(u8, line, "---")) {
                fm = .closed;
                st.fm_close_line = nr;
                if (title.len > 0) {
                    // boris double quotes allow no escapes and no embedded quote
                    const q: []const u8 = if (std.mem.indexOfScalar(u8, title, '"') != null) "" else "\"";
                    try out.print(arena, "---\ntitle: {s}{s}{s}\n---\n", .{ q, title, q });
                    staged = 3;
                }
                continue;
            }
            if (title.len == 0 and std.mem.startsWith(u8, line, "title:")) {
                title = std.mem.trim(u8, line["title:".len..], " \t");
                if (title.len >= 2 and title[0] == '"' and title[title.len - 1] == '"')
                    title = title[1 .. title.len - 1];
                st.title_line = nr;
            }
            continue;
        }
        staged += 1;
        try rewriteLine(arena, &out, &links, line, nr, staged);
        try out.append(arena, '\n');
    }
    if (fm == .open) return error.UnclosedFrontmatter;
    st.text = out.items;
    st.links = links.items;
    st.delta = @as(i64, nr) - staged;
    return st;
}

fn rewriteLine(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    links: *std.ArrayList(Link),
    line: []const u8,
    nr: u32,
    staged_line: u32,
) !void {
    const line_start = out.items.len;
    var consumed: usize = 0;
    while (findLink(line[consumed..])) |m| {
        const rest = line[consumed..];
        const whole = rest[m[0]..m[1]];
        const inner = whole[2 .. whole.len - 2];
        // boris 0.8.2 cannot embed a page: ![[T]] is checked as the link [[T]]
        const bang = m[0] > 0 and rest[m[0] - 1] == '!';
        var target = inner;
        var label = inner;
        if (std.mem.indexOfScalar(u8, inner, '|')) |p| {
            target = inner[0..p];
            label = inner[p + 1 ..];
        }
        var frag: []const u8 = "";
        if (std.mem.indexOfScalar(u8, target, '#')) |h| {
            frag = target[h..];
            target = target[0..h];
        }
        const id = try slug(arena, target);

        try out.appendSlice(arena, rest[0 .. m[0] - @intFromBool(bang)]);
        try links.append(arena, .{
            .staged_line = staged_line,
            .staged_col = @intCast(out.items.len - line_start + 1),
            .line = nr,
            .col = @intCast(consumed + m[0] + 1),
            .id = id,
            .text = rest[m[0] - @intFromBool(bang) .. m[1]],
        });
        if (id.len == 0 or std.mem.eql(u8, id, target))
            try out.appendSlice(arena, whole)
        else
            try out.print(arena, "[[{s}{s}|{s}]]", .{ id, frag, label });
        consumed += m[1];
    }
    try out.appendSlice(arena, line[consumed..]);
}

// --- report mapping ---------------------------------------------------------------

const BorisDiag = struct {
    severity: []const u8 = "error",
    code: []const u8 = "",
    message: []const u8 = "",
    sourcePath: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    id: ?[]const u8 = null,
};

const BorisReport = struct {
    diagnostics: []BorisDiag = &.{},
};

/// Map a `boris validate --report` JSON onto the original doc, as
/// stage-check.sh does: a diagnostic at a staged link's (line, col) takes
/// the link's doc position; any other body diagnostic shifts by `delta`;
/// a frontmatter diagnostic points at the doc's frontmatter (column 0).
/// EROUTEMISSING is reported on the staged HTML; it maps to the doc's
/// `](href)` when found. `stderr` supplies the messages (the JSON message
/// of some codes drops the href); the i-th stderr `error:` line is used
/// for the i-th diagnostic when its code matches.
pub fn mapReport(
    arena: std.mem.Allocator,
    st: Staged,
    rel: []const u8,
    doc: []const u8,
    report_json: []const u8,
    stderr: []const u8,
) ![]Diagnostic {
    const report = try std.json.parseFromSliceLeaky(BorisReport, arena, report_json, .{ .ignore_unknown_fields = true });
    const rel_html = try std.fmt.allocPrint(arena, "{s}.html", .{rel[0 .. rel.len - ".md".len]});

    var err_lines: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "error: ")) try err_lines.append(arena, l);
    }

    const out = try arena.alloc(Diagnostic, report.diagnostics.len);
    for (report.diagnostics, out, 0..) |d, *o, i| {
        const sp = d.sourcePath orelse "";
        const bl: u32 = if (d.line) |v| @intCast(@max(v, 0)) else 0;
        const bc: u32 = if (d.column) |v| @intCast(@max(v, 0)) else 0;
        var detail = stripRemediation(d.message);
        if (i < err_lines.items.len) {
            const prefix = try std.fmt.allocPrint(arena, "error: {s}: ", .{d.code});
            const l = err_lines.items[i];
            if (std.mem.startsWith(u8, l, prefix)) {
                const rest = l[prefix.len..];
                if (std.mem.indexOf(u8, rest, ": ")) |c| detail = stripRemediation(rest[c + 2 ..]);
            }
        }
        o.* = .{ .code = d.code, .severity = d.severity, .detail = detail, .target = d.id };

        if (std.mem.eql(u8, sp, rel)) {
            for (st.links) |k| {
                if (d.column != null and k.staged_line == bl and k.staged_col == bc) {
                    o.line = k.line;
                    o.column = k.col;
                    o.link = k.text;
                    o.target = k.id;
                    break;
                }
            } else if (!std.mem.startsWith(u8, d.code, "EFRONTMATTER")) {
                o.line = @intCast(@max(@as(i64, bl) + st.delta, 0));
                o.column = bc;
            } else {
                o.line = switch (bl) {
                    2 => st.title_line,
                    3 => st.fm_close_line,
                    else => bl,
                };
            }
        } else if (std.mem.eql(u8, sp, rel_html) and std.mem.eql(u8, d.code, "EROUTEMISSING")) {
            var nth: usize = 0;
            for (out[0..i]) |prev| nth += @intFromBool(std.mem.eql(u8, prev.detail, detail));
            if (hrefPosition(doc, detail, nth)) |pos| {
                o.line = pos[0];
                o.column = pos[1];
            }
        } else if (sp.len > 0) {
            o.detail = if (bl > 0)
                try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ sp, bl, detail })
            else
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ sp, detail });
        }
    }
    return out;
}

fn stripRemediation(msg: []const u8) []const u8 {
    if (msg.len == 0 or msg[msg.len - 1] != ']') return msg;
    const i = std.mem.lastIndexOf(u8, msg, " [") orelse return msg;
    return msg[0..i];
}

/// Doc (line, column) of the `nth` markdown link target `](<href>)`, where
/// href comes from boris's `href="<href>" ...` message. Column is the href's.
fn hrefPosition(doc: []const u8, detail: []const u8, nth: usize) ?[2]u32 {
    const open = "href=\"";
    if (!std.mem.startsWith(u8, detail, open)) return null;
    const end = std.mem.indexOfScalarPos(u8, detail, open.len, '"') orelse return null;
    const href = detail[open.len..end];
    var seen: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "](")) |p| {
        pos = p + 2;
        if (!std.mem.startsWith(u8, doc[pos..], href) or
            pos + href.len >= doc.len or doc[pos + href.len] != ')') continue;
        if (seen < nth) {
            seen += 1;
            continue;
        }
        const line_start = if (std.mem.lastIndexOfScalar(u8, doc[0..pos], '\n')) |n| n + 1 else 0;
        return .{
            @intCast(std.mem.countScalar(u8, doc[0..pos], '\n') + 1),
            @intCast(pos - line_start + 1),
        };
    }
    return null;
}

// --- tests -----------------------------------------------------------------------

const testing = std.testing;

test "slug matches stage-check.sh" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try testing.expectEqualStrings("acmedb-docs-backups", try slug(ar, "AcmeDB docs — backups"));
    try testing.expectEqualStrings("verdict-acmedb", try slug(ar, "Verdict: AcmeDB"));
    try testing.expectEqualStrings("e-m-forster", try slug(ar, "E. M. Forster"));
    try testing.expectEqualStrings("acmedb-2-0-migration-guide", try slug(ar, "AcmeDB 2.0 migration guide"));
    try testing.expectEqualStrings("claims/backup-gap", try slug(ar, "claims/backup-gap"));
    try testing.expectEqualStrings("a-/-b", try slug(ar, "/A - / -- B!/"));
    try testing.expectEqualStrings("", try slug(ar, " — "));
}

test "findLink is the awk regex" {
    try testing.expectEqual([2]usize{ 0, 5 }, findLink("[[a]]").?);
    try testing.expectEqual([2]usize{ 0, 6 }, findLink("[[[a]]").?);
    try testing.expectEqual([2]usize{ 5, 10 }, findLink("[[]] [[b]]").?);
    try testing.expectEqual([2]usize{ 5, 10 }, findLink("[[a] [[b]]").?);
    try testing.expect(findLink("[[a]") == null);
    try testing.expect(findLink("[[]]") == null);
}

test "stage rewrites frontmatter, links and embeds without moving body lines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const doc =
        \\---
        \\title: "Verdict: AcmeDB"
        \\year: 1999
        \\genre:
        \\  - "Action"
        \\---
        \\# Verdict
        \\- é [[AcmeDB docs — backups]] and [[claims/backup-gap]]
        \\![[AcmeDB 2.0 migration guide]] [[Sources#reliability-scale|scale]]
        \\
    ;
    const st = try stage(a.allocator(), doc);
    try testing.expectEqualStrings(
        \\---
        \\title: "Verdict: AcmeDB"
        \\---
        \\# Verdict
        \\- é [[acmedb-docs-backups|AcmeDB docs — backups]] and [[claims/backup-gap]]
        \\[[acmedb-2-0-migration-guide|AcmeDB 2.0 migration guide]] [[sources#reliability-scale|scale]]
        \\
    , st.text);
    try testing.expectEqual(@as(i64, 3), st.delta);
    try testing.expectEqual(@as(u32, 2), st.title_line);
    try testing.expectEqual(@as(u32, 6), st.fm_close_line);
    try testing.expectEqual(@as(usize, 4), st.links.len);
    const want = [_]Link{
        .{ .staged_line = 5, .staged_col = 6, .line = 8, .col = 6, .id = "acmedb-docs-backups", .text = "[[AcmeDB docs — backups]]" },
        .{ .staged_line = 5, .staged_col = 58, .line = 8, .col = 38, .id = "claims/backup-gap", .text = "[[claims/backup-gap]]" },
        .{ .staged_line = 6, .staged_col = 1, .line = 9, .col = 2, .id = "acmedb-2-0-migration-guide", .text = "![[AcmeDB 2.0 migration guide]]" },
        .{ .staged_line = 6, .staged_col = 59, .line = 9, .col = 33, .id = "sources", .text = "[[Sources#reliability-scale|scale]]" },
    };
    for (want, st.links) |w, g| {
        try testing.expectEqual(w.staged_line, g.staged_line);
        try testing.expectEqual(w.staged_col, g.staged_col);
        try testing.expectEqual(w.line, g.line);
        try testing.expectEqual(w.col, g.col);
        try testing.expectEqualStrings(w.id, g.id);
        try testing.expectEqualStrings(w.text, g.text);
    }
}

test "stage edge cases: no title, no frontmatter, unclosed frontmatter" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const no_title = try stage(ar, "---\nyear: 1\n---\nbody");
    try testing.expectEqualStrings("body\n", no_title.text);
    try testing.expectEqual(@as(i64, 3), no_title.delta);
    const quoted = try stage(ar, "---\ntitle:  say \"hi\" \n---\n");
    try testing.expectEqualStrings("---\ntitle: say \"hi\"\n---\n", quoted.text);
    const plain = try stage(ar, "# x\n\n[[a b]]\n");
    try testing.expectEqualStrings("# x\n\n[[a-b|a b]]\n", plain.text);
    try testing.expectEqual(@as(i64, 0), plain.delta);
    try testing.expectError(error.UnclosedFrontmatter, stage(ar, "---\ntitle: x\n"));
}

test "mapReport maps links, body lines, frontmatter and routes back to the doc" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const doc = "---\ntitle: \"T\"\nyear: 1\n---\n# T\n\n- [[AcmeDB SOC 2 audit report]] x\n[a](Full%20changelog) ![[Gone]]\n";
    const st = try stage(ar, doc);
    const report =
        \\{"ok":false,"diagnostics":[
        \\{"severity":"error","code":"EREFERENCEMISSING","message":"wiki-link target \"acmedb-soc-2-audit-report\" not found in the page graph","sourcePath":"staged/t.md","line":6,"column":3,"id":"acmedb-soc-2-audit-report"},
        \\{"severity":"error","code":"EROUTEMISSING","message":"does not resolve to a published output [fix the path, or publish the file it names]","sourcePath":"staged/t.html","line":110,"column":null,"id":null},
        \\{"severity":"error","code":"EREFERENCEMISSING","message":"wiki-link target \"gone\" not found in the page graph","sourcePath":"staged/t.md","line":7,"column":23,"id":"gone"},
        \\{"severity":"error","code":"EXYZ","message":"body","sourcePath":"staged/t.md","line":5,"column":1,"id":null},
        \\{"severity":"error","code":"EFRONTMATTER","message":"bad","sourcePath":"staged/t.md","line":2,"column":1,"id":null},
        \\{"severity":"error","code":"ELAYOUT","message":"target 'default' compilation failed: LinkAuditFailed","sourcePath":"themes/boris/layouts/main.html","line":null,"column":null,"id":null}]}
    ;
    const stderr =
        \\error: EREFERENCEMISSING: staged/t.md:6:3: wiki-link target "acmedb-soc-2-audit-report" not found in the page graph [Point the wiki-link at an existing page]
        \\error: EROUTEMISSING: staged/t.html:110: href="Full%20changelog" does not resolve to a published output [fix the path, or publish the file it names]
        \\
    ;
    const ds = try mapReport(ar, st, "staged/t.md", doc, report, stderr);
    try testing.expectEqual(@as(usize, 6), ds.len);
    try testing.expectEqual(@as(u32, 7), ds[0].line);
    try testing.expectEqual(@as(u32, 3), ds[0].column);
    try testing.expectEqualStrings("[[AcmeDB SOC 2 audit report]]", ds[0].link.?);
    try testing.expectEqualStrings("acmedb-soc-2-audit-report", ds[0].target.?);
    try testing.expectEqualStrings("wiki-link target \"acmedb-soc-2-audit-report\" not found in the page graph", ds[0].detail);
    try testing.expectEqualStrings("href=\"Full%20changelog\" does not resolve to a published output", ds[1].detail);
    try testing.expectEqual(@as(u32, 8), ds[1].line);
    try testing.expectEqual(@as(u32, 5), ds[1].column);
    try testing.expectEqual(@as(u32, 8), ds[2].line);
    try testing.expectEqual(@as(u32, 24), ds[2].column);
    try testing.expectEqualStrings("![[Gone]]", ds[2].link.?);
    try testing.expectEqual(@as(u32, 6), ds[3].line);
    try testing.expectEqual(@as(u32, 2), ds[4].line);
    try testing.expectEqual(@as(u32, 0), ds[4].column);
    try testing.expectEqual(@as(u32, 0), ds[5].line);
    try testing.expectEqualStrings("themes/boris/layouts/main.html: target 'default' compilation failed: LinkAuditFailed", ds[5].detail);
}

test "stagedName follows stage-check.sh" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("doc-1-2", try stagedName(a.allocator(), "doc-1-2"));
    try testing.expectEqualStrings("a-b-c", try stagedName(a.allocator(), "a b/c"));
    try testing.expectEqualStrings("doc.x", try stagedName(a.allocator(), ".x"));
}
