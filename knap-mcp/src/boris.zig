//! knap_publish_check core: stage one rendered markdown doc into a
//! throwaway copy of a boris site and run `boris validate` there.
//! A port of boris-site/stage-check.sh (--validate mode); keep the two in
//! parity, rule for rule (docs/tracks/B2.md).
//!
//! The staging profile says how the doc is adapted. `frozen` (the
//! default, and the only behavior stage-check.sh has) adapts the doc
//! without adding or removing body lines, so every diagnostic maps back
//! to the rendered doc exactly:
//!   - the frontmatter becomes `title` only (boris keys are a closed set);
//!   - `[[T]]` -> `[[slug(T)|T]]`, `[[T|L]]` -> `[[slug(T)|L]]`, `#frag`
//!     kept, slug-form targets untouched.
//! `raw` (for canonical-id sites like filed.fyi, where `[[T]]` is an
//! identity, not a slug) is a passthrough:
//!   - the frontmatter block passes through verbatim;
//!   - `[[T]]` / `[[T|L]]` pass through unmodified — no slug, no label;
//!   - the doc lands at its source-relative path under content/ (`--as`,
//!     else `staged/<name>.md`), so path- and frontmatter-derived
//!     identity exercise the real graph.
//! In both profiles `![[T]]` loses its `!`: boris 0.8.2 cannot embed a
//! page (it renders an image of T.html, EASSET), so an embed is checked
//! as a link.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const store = @import("store.zig");
const formatcheck = @import("formatcheck.zig");

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

/// How staging adapts the doc. `frozen` is the default and keeps the
/// frozen demo site's conventions; `raw` passes a canonical-id site's
/// records through untouched. See the module comment for the rules.
pub const Profile = enum { frozen, raw };

pub const Report = struct {
    ok: bool,
    /// The staging profile this run used, for auditability.
    profile: Profile,
    /// Entity id of the staged doc: `staged/<name>` under frozen, the
    /// content-relative source path under raw.
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

/// The resolved site configuration: the staging profile plus the knobs
/// `boris validate` and the format-check rule pack need for a
/// non-default site.
pub const SiteConfig = struct {
    profile: Profile = .frozen,
    /// Theme root for `boris validate --theme` (validate renders pages,
    /// so a site whose layout is not `themes/boris` must name it). null
    /// keeps boris's built-in default.
    theme: ?[]const u8 = null,
    /// The closed frontmatter schema the site declares; empty = undeclared.
    schema: []const []const u8 = &.{},
    /// Wiki-link targets are canonical ids: default on under `raw`,
    /// overridable per site.
    canonical_ids: bool = false,
};

/// `<site>/knap-site.json`, discovered next to `content/`:
/// `{"staging"|"profile": "frozen"|"raw", "theme": "<theme root>",
///  "frontmatter": ["id", ...], "canonical_ids": true|false}`.
/// `profile` and `staging` name the same thing (`profile` wins when
/// both appear). Profile and theme have env overrides —
/// `KNAP_BORIS_STAGING`, `KNAP_BORIS_THEME` — and defaults (frozen;
/// boris's own theme default). A set-but-unknown profile name, a
/// malformed file, or an escaping theme path fails loudly — never a
/// silent fallback.
pub fn siteConfig(ctx: *Ctx, site: []const u8) Error!SiteConfig {
    var c: SiteConfig = .{};
    var ids_declared = false;
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/knap-site.json", .{site});
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return ctx.fail("cannot read {s} ({s})", .{ path, @errorName(e) }),
    };
    if (bytes) |b| {
        const SiteFile = struct {
            staging: ?[]const u8 = null,
            profile: ?[]const u8 = null,
            theme: ?[]const u8 = null,
            frontmatter: ?[]const []const u8 = null,
            canonical_ids: ?bool = null,
        };
        const p = std.json.parseFromSliceLeaky(SiteFile, ctx.arena, b, .{ .ignore_unknown_fields = true }) catch
            return ctx.fail("cannot parse {s} as JSON", .{path});
        if (p.profile orelse p.staging) |s| c.profile = std.meta.stringToEnum(Profile, s) orelse
            return ctx.fail("{s}: staging '{s}' is not a staging profile (frozen|raw)", .{ path, s });
        c.theme = p.theme;
        if (p.frontmatter) |f| c.schema = f;
        if (p.canonical_ids) |ids| {
            c.canonical_ids = ids;
            ids_declared = true;
        }
    }
    if (ctx.environ.get("KNAP_BORIS_STAGING")) |v| {
        const s = std.mem.trim(u8, v, " \t\r\n");
        if (s.len > 0) c.profile = std.meta.stringToEnum(Profile, s) orelse
            return ctx.fail("KNAP_BORIS_STAGING '{s}' is not a staging profile (frozen|raw)", .{s});
    }
    if (ctx.environ.get("KNAP_BORIS_THEME")) |v| {
        const s = std.mem.trim(u8, v, " \t\r\n");
        if (s.len > 0) c.theme = s;
    }
    if (c.theme) |t| {
        if (std.fs.path.isAbsolute(t) or std.mem.indexOf(u8, t, "..") != null)
            return ctx.fail("theme '{s}' must stay inside the site (a relative path like themes/boris)", .{t});
    }
    if (!ids_declared) c.canonical_ids = c.profile == .raw;
    return c;
}

/// Check that every wiki-link in `doc` (rendered markdown) resolves
/// against the site. `name` names the staged copy (`staged/<name>`;
/// bytes outside [A-Za-z0-9._-] become `-`); `as` overrides that with a
/// source path the doc occupies under content/ (raw profile only).
/// Fails (ctx.err_msg) when the doc cannot be staged or boris cannot
/// run; content problems are diagnostics.
pub fn check(ctx: *Ctx, doc: []const u8, name: []const u8, as: ?[]const u8) Error!Report {
    const t0 = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const arena = ctx.arena;

    const site = try siteDir(ctx);
    const config = try siteConfig(ctx, site);
    const profile = config.profile;
    if (as != null and profile != .raw)
        return ctx.fail("--as sets the staged source path; it needs the raw staging profile", .{});

    const staged = stage(arena, doc, profile) catch |e| switch (e) {
        error.UnclosedFrontmatter => return ctx.fail("doc has an unclosed frontmatter block", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const rel = if (as) |a|
        try sourceRelPath(ctx, a)
    else
        try std.fmt.allocPrint(arena, "staged/{s}.md", .{try stagedName(arena, name)});

    const dir = try store.scratchFile(ctx, "boris");
    defer std.Io.Dir.deleteTree(.cwd(), ctx.io, dir) catch {};
    var pages = try copyTree(ctx, site, dir, "content");
    _ = try copyTree(ctx, site, dir, "themes");

    const doc_path = try std.fmt.allocPrint(arena, "{s}/content/{s}", .{ dir, rel });
    // Under raw the doc can land on an existing record's path — replacing
    // it is the point — so it adds a page only when the path was free.
    std.Io.Dir.access(.cwd(), ctx.io, doc_path, .{}) catch |e| switch (e) {
        error.FileNotFound => pages += 1,
        else => {},
    };
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
    // One `boris validate` gets a hard deadline: the server is
    // single-threaded, so a hung boris would block every later request.
    // The deadline is absolute (not an idle timeout) and run() kills the
    // child when it fires.
    const secs = ctx.envSecs("KNAP_BORIS_TIMEOUT", 60);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "validate", "--input", "content", "--report", "report.json", "--quiet" });
    if (config.theme) |t| try argv.appendSlice(arena, &.{ "--theme", t });
    const result = std.process.run(arena, ctx.io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = ctx.deadline(secs),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return ctx.fail("boris validate timed out after {d}s", .{secs}),
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
        .profile = profile,
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

/// A `--as` source path becomes the doc's path under content/: the part
/// after the first `content` component when one is present (so both
/// `content/mascots/x.md` and `/site/content/mascots/x.md` land at
/// `mascots/x.md`), else the path itself (`mascots/x.md`). `.`
/// components are dropped; `..`, empty results, and non-`.md` names are
/// rejected — the staged doc must land inside content/ where boris
/// picks it up as a page.
fn sourceRelPath(ctx: *Ctx, as: []const u8) Error![]const u8 {
    const absolute = as.len > 0 and as[0] == '/';
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, as, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, ".."))
            return ctx.fail("--as path '{s}' cannot contain '..'", .{as});
        try comps.append(ctx.arena, c);
    }
    var start: usize = 0;
    var saw_content = false;
    for (comps.items, 0..) |c, i| {
        if (std.mem.eql(u8, c, "content")) {
            start = i + 1;
            saw_content = true;
            break;
        }
    }
    if (absolute and !saw_content)
        return ctx.fail("--as path '{s}' is absolute but names no content/ dir", .{as});
    const parts = comps.items[start..];
    if (parts.len == 0)
        return ctx.fail("--as path '{s}' ends at the content root", .{as});
    const rel = try std.mem.join(ctx.arena, "/", parts);
    if (!std.mem.endsWith(u8, rel, ".md"))
        return ctx.fail("--as path '{s}' must name a .md file", .{as});
    return rel;
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
    /// Bytes the link occupies in the staged text after rewriting; pairs
    /// with text.len to give the column drift this link introduces.
    staged_len: u32,
    line: u32,
    col: u32,
    id: []const u8,
    /// Original text; `![[...]]` for an embed.
    text: []const u8,
};

pub const Staged = struct {
    text: []const u8,
    links: []Link,
    /// The profile the text was staged under; report mapping needs it
    /// (raw keeps doc coordinates, so frontmatter lines need no remap).
    profile: Profile = .frozen,
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

pub fn stage(arena: std.mem.Allocator, doc: []const u8, profile: Profile) error{ UnclosedFrontmatter, OutOfMemory }!Staged {
    var out: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var st: Staged = .{ .text = "", .links = &.{}, .profile = profile, .delta = 0 };
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
            if (profile == .frozen) continue;
            staged += 1;
            try out.appendSlice(arena, "---\n");
            continue;
        }
        if (fm == .open) {
            if (profile == .raw) {
                if (std.mem.eql(u8, line, "---")) {
                    fm = .closed;
                    st.fm_close_line = nr;
                }
                staged += 1;
                try out.appendSlice(arena, line);
                try out.append(arena, '\n');
                continue;
            }
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
        try rewriteLine(arena, &out, &links, line, nr, staged, profile);
        try out.append(arena, '\n');
    }
    // raw is a passthrough: an unclosed frontmatter block reaches boris
    // as-is and comes back as a real diagnostic, not a staging failure.
    if (fm == .open and profile == .frozen) return error.UnclosedFrontmatter;
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
    profile: Profile,
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
        // raw: the target is a canonical id, emitted byte-for-byte; the
        // recorded id is the pre-frag, pre-label target boris looks up.
        const id = if (profile == .raw) target else try slug(arena, target);
        const rewritten = profile == .frozen and id.len > 0 and !std.mem.eql(u8, id, target);
        const emitted: u32 = @intCast(if (rewritten)
            "[[|]]".len + id.len + frag.len + label.len
        else
            whole.len);

        try out.appendSlice(arena, rest[0 .. m[0] - @intFromBool(bang)]);
        try links.append(arena, .{
            .staged_line = staged_line,
            .staged_col = @intCast(out.items.len - line_start + 1),
            .staged_len = emitted,
            .line = nr,
            .col = @intCast(consumed + m[0] + 1),
            .id = id,
            .text = rest[m[0] - @intFromBool(bang) .. m[1]],
        });
        if (rewritten)
            try out.print(arena, "[[{s}{s}|{s}]]", .{ id, frag, label })
        else
            try out.appendSlice(arena, whole);
        consumed += m[1];
    }
    try out.appendSlice(arena, line[consumed..]);
}

// --- site profile ------------------------------------------------------------------
// FILED-BORIS (#254) owns the schema-consumer side; FILED-PUB (#252)
// owns staging. Both resolve through `siteConfig` (above):
// `<site>/knap-site.json` may declare
//
//   {"profile": "frozen"|"raw",        // "staging" is accepted too
//    "frontmatter": ["id", "title", "parent", "status", "tags",
//                    "relations", "published_at", "summary"],
//    "canonical_ids": true|false}      // default: on under raw, off frozen
//
// `KNAP_BORIS_STAGING=<name>` overrides the file's profile name; an
// unknown name — file or env — fails loudly, never a silent frozen
// fallback. No file and no env is `frozen` with no declared schema.

/// format-check's view of the site config: null under `frozen` so
/// frozen-site warnings stay byte-identical; else the boris-surface rule
/// pack inputs.
pub fn siteRules(ctx: *Ctx) Error!?formatcheck.Site {
    const site = try siteDir(ctx);
    const c = try siteConfig(ctx, site);
    if (c.profile == .frozen) return null;
    return formatcheck.Site{
        .schema = c.schema,
        .canonical_ids = c.canonical_ids,
        .content_dir = try std.fmt.allocPrint(ctx.arena, "{s}/content", .{site}),
        .io = ctx.io,
    };
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

/// Saturating i64 -> u32: a hostile or hand-edited report.json line or
/// column clamps instead of panicking the process.
fn clampU32(v: i64) u32 {
    return @intCast(@min(@max(v, 0), std.math.maxInt(u32)));
}

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
        const bl: u32 = if (d.line) |v| clampU32(v) else 0;
        const bc: u32 = if (d.column) |v| clampU32(v) else 0;
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
                o.line = clampU32(@as(i64, bl) + st.delta);
                // Rewrites change a staged line's length, so a staged byte
                // column is shifted relative to the doc: subtract the
                // net drift of every link that ends left of it.
                var drift: i64 = 0;
                if (bc > 0) for (st.links) |k| {
                    if (k.staged_line != bl) continue;
                    if (@as(i64, k.staged_col) + @as(i64, k.staged_len) <= @as(i64, bc))
                        drift += @as(i64, k.staged_len) - @as(i64, @intCast(k.text.len));
                };
                o.column = clampU32(@as(i64, bc) - drift);
            } else {
                // frozen rewrote the frontmatter to a fixed 3-line block;
                // raw staged it verbatim, so boris lines are doc lines.
                o.line = if (st.profile == .raw) bl else switch (bl) {
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
    const st = try stage(a.allocator(), doc, .frozen);
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
        .{ .staged_line = 5, .staged_col = 6, .staged_len = 47, .line = 8, .col = 6, .id = "acmedb-docs-backups", .text = "[[AcmeDB docs — backups]]" },
        .{ .staged_line = 5, .staged_col = 58, .staged_len = 21, .line = 8, .col = 38, .id = "claims/backup-gap", .text = "[[claims/backup-gap]]" },
        .{ .staged_line = 6, .staged_col = 1, .staged_len = 57, .line = 9, .col = 2, .id = "acmedb-2-0-migration-guide", .text = "![[AcmeDB 2.0 migration guide]]" },
        .{ .staged_line = 6, .staged_col = 59, .staged_len = 35, .line = 9, .col = 33, .id = "sources", .text = "[[Sources#reliability-scale|scale]]" },
    };
    for (want, st.links) |w, g| {
        try testing.expectEqual(w.staged_line, g.staged_line);
        try testing.expectEqual(w.staged_col, g.staged_col);
        try testing.expectEqual(w.staged_len, g.staged_len);
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
    const no_title = try stage(ar, "---\nyear: 1\n---\nbody", .frozen);
    try testing.expectEqualStrings("body\n", no_title.text);
    try testing.expectEqual(@as(i64, 3), no_title.delta);
    const quoted = try stage(ar, "---\ntitle:  say \"hi\" \n---\n", .frozen);
    try testing.expectEqualStrings("---\ntitle: say \"hi\"\n---\n", quoted.text);
    const plain = try stage(ar, "# x\n\n[[a b]]\n", .frozen);
    try testing.expectEqualStrings("# x\n\n[[a-b|a b]]\n", plain.text);
    try testing.expectEqual(@as(i64, 0), plain.delta);
    try testing.expectError(error.UnclosedFrontmatter, stage(ar, "---\ntitle: x\n", .frozen));
}

test "mapReport maps links, body lines, frontmatter and routes back to the doc" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const doc = "---\ntitle: \"T\"\nyear: 1\n---\n# T\n\n- [[AcmeDB SOC 2 audit report]] x\n[a](Full%20changelog) ![[Gone]]\n";
    const st = try stage(ar, doc, .frozen);
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

test "mapReport clamps out-of-range positions and undoes per-line column drift" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const doc = "# T\n\n- [[AcmeDB docs — backups]] tail\n";
    const st = try stage(ar, doc, .frozen);
    const report =
        \\{"ok":false,"diagnostics":[
        \\{"severity":"error","code":"EXYZ","message":"huge","sourcePath":"staged/t.md","line":99999999999,"column":-5},
        \\{"severity":"error","code":"EXYZ","message":"drifted","sourcePath":"staged/t.md","line":3,"column":51}]}
    ;
    const ds = try mapReport(ar, st, "staged/t.md", doc, report, "");
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), ds[0].line);
    try testing.expectEqual(@as(u32, 0), ds[0].column);
    // Staged line 3 grew 20 bytes at the rewritten link ([[T]] ->
    // [[slug|T]]), so staged col 51 is doc col 31 (the 't' of "tail").
    try testing.expectEqual(@as(u32, 3), ds[1].line);
    try testing.expectEqual(@as(u32, 31), ds[1].column);
}

test "stagedName follows stage-check.sh" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("doc-1-2", try stagedName(a.allocator(), "doc-1-2"));
    try testing.expectEqualStrings("a-b-c", try stagedName(a.allocator(), "a b/c"));
    try testing.expectEqualStrings("doc.x", try stagedName(a.allocator(), ".x"));
}

test "stage raw: frontmatter and link targets pass through, embeds stay link-checked" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const doc =
        \\---
        \\title: "Blamey McTypoface"
        \\id: mascots/M-0003
        \\parent: mascots
        \\status: archived
        \\tags: ["mascots"]
        \\---
        \\# Blamey
        \\- Mentored by [[limericks/LIM-0155|Patchy Mx.CLI]]
        \\- Also [[limericks/LIM-0155]] and ![[aphorisms/APH-0008]]
        \\
    ;
    const st = try stage(a.allocator(), doc, .raw);
    // Byte-identical except the dropped embed bang; no slug, no label
    // injection, frontmatter untouched, delta 0.
    try testing.expectEqualStrings(
        \\---
        \\title: "Blamey McTypoface"
        \\id: mascots/M-0003
        \\parent: mascots
        \\status: archived
        \\tags: ["mascots"]
        \\---
        \\# Blamey
        \\- Mentored by [[limericks/LIM-0155|Patchy Mx.CLI]]
        \\- Also [[limericks/LIM-0155]] and [[aphorisms/APH-0008]]
        \\
    , st.text);
    try testing.expectEqual(@as(i64, 0), st.delta);
    try testing.expectEqual(@as(usize, 3), st.links.len);
    try testing.expectEqualStrings("limericks/LIM-0155", st.links[0].id);
    try testing.expectEqualStrings("[[limericks/LIM-0155|Patchy Mx.CLI]]", st.links[0].text);
    // The embed's staged [[ lands one column left of the doc's bang.
    try testing.expectEqual(@as(u32, 36), st.links[2].col);
    try testing.expectEqual(@as(u32, 35), st.links[2].staged_col);
    try testing.expectEqualStrings("![[aphorisms/APH-0008]]", st.links[2].text);
    // Raw is a passthrough: unclosed frontmatter stages, not an error.
    const open = try stage(a.allocator(), "---\ntitle: x\n", .raw);
    try testing.expectEqualStrings("---\ntitle: x\n", open.text);
    try testing.expectEqual(@as(usize, 0), open.links.len);
}

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map) Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = "x",
        .project_root = ".",
    };
}

fn writeSiteFile(a: std.mem.Allocator, dir: *const std.testing.TmpDir, data: []const u8) ![]const u8 {
    try dir.dir.writeFile(testing.io, .{ .sub_path = "knap-site.json", .data = data });
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{dir.sub_path});
}

test "siteConfig: env wins, file next, default frozen, unknown fails" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var ctx = testCtx(ar, &env);
    const writeProfile = struct {
        fn f(dir: std.testing.TmpDir, data: []const u8) !void {
            try dir.dir.writeFile(std.testing.io, .{ .sub_path = "knap-site.json", .data = data });
        }
    }.f;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // No env, no file: frozen, boris's default theme.
    var c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.frozen, c.profile);
    try testing.expect(c.theme == null);
    // File pins raw and a theme.
    try writeProfile(tmp, "{\"staging\":\"raw\",\"theme\":\"themes/cantilever\"}");
    c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.raw, c.profile);
    try testing.expectEqualStrings("themes/cantilever", c.theme.?);
    // File without a staging key still defaults frozen.
    try writeProfile(tmp, "{\"schema\":{}}");
    try testing.expectEqual(Profile.frozen, (try siteConfig(&ctx, site)).profile);
    // Unknown file value and malformed JSON fail, no silent fallback.
    try writeProfile(tmp, "{\"staging\":\"bogus\"}");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    try writeProfile(tmp, "not json");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    // A theme escaping the site fails too.
    try writeProfile(tmp, "{\"theme\":\"../outside\"}");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    try writeProfile(tmp, "{\"theme\":\"/abs/theme\"}");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    // Env overrides the file; an unknown env value fails the same way.
    try writeProfile(tmp, "{\"staging\":\"raw\",\"theme\":\"themes/cantilever\"}");
    try env.put("KNAP_BORIS_STAGING", " frozen ");
    try env.put("KNAP_BORIS_THEME", "themes/local");
    c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.frozen, c.profile);
    try testing.expectEqualStrings("themes/local", c.theme.?);
    try env.put("KNAP_BORIS_STAGING", "bogus");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    try testing.expectEqualStrings(
        "KNAP_BORIS_STAGING 'bogus' is not a staging profile (frozen|raw)",
        ctx.err_msg,
    );
}

test "sourceRelPath maps --as onto a content-relative .md path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var ctx = testCtx(ar, &env);

    try testing.expectEqualStrings("mascots/x.md", try sourceRelPath(&ctx, "content/mascots/x.md"));
    try testing.expectEqualStrings("mascots/x.md", try sourceRelPath(&ctx, "mascots/x.md"));
    try testing.expectEqualStrings("mascots/x.md", try sourceRelPath(&ctx, "./content/mascots/x.md"));
    try testing.expectEqualStrings("mascots/x.md", try sourceRelPath(&ctx, "/site/filed/content/mascots/x.md"));
    // Canonical ids keep their case and their dots.
    try testing.expectEqualStrings("limericks/LIM-0155.md", try sourceRelPath(&ctx, "limericks/LIM-0155.md"));

    try testing.expectError(error.ToolFailed, sourceRelPath(&ctx, "content/../out.md"));
    try testing.expectError(error.ToolFailed, sourceRelPath(&ctx, "content/"));
    try testing.expectError(error.ToolFailed, sourceRelPath(&ctx, "content/mascots/x"));
    try testing.expectError(error.ToolFailed, sourceRelPath(&ctx, "/tmp/x.md"));
}

test "siteConfig: no file is frozen with no declared schema" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try env.put("KNAP_BORIS_SITE", site);
    var ctx = testCtx(ar, &env);
    const c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.frozen, c.profile);
    try testing.expectEqual(@as(usize, 0), c.schema.len);
    try testing.expect(!c.canonical_ids);
    try testing.expect((try siteRules(&ctx)) == null);
}

test "siteConfig: knap-site.json declares profile, schema and canonical_ids" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try writeSiteFile(ar, &tmp,
        \\{"profile": "raw", "frontmatter": ["id", "title", "parent"],
        \\"canonical_ids": false}
    );
    try env.put("KNAP_BORIS_SITE", site);
    var ctx = testCtx(ar, &env);
    const c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.raw, c.profile);
    try testing.expectEqual(@as(usize, 3), c.schema.len);
    try testing.expectEqualStrings("parent", c.schema[2]);
    try testing.expect(!c.canonical_ids);
    const rules = (try siteRules(&ctx)).?;
    try testing.expectEqual(@as(usize, 3), rules.schema.len);
    try testing.expect(!rules.canonical_ids);
    try testing.expectEqualStrings(try std.fmt.allocPrint(ar, "{s}/content", .{site}), rules.content_dir.?);
}

test "siteConfig: raw defaults canonical_ids on; staging key and env override work" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try writeSiteFile(ar, &tmp, "{\"staging\": \"raw\"}");
    try env.put("KNAP_BORIS_SITE", site);
    var ctx = testCtx(ar, &env);
    var c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.raw, c.profile);
    try testing.expect(c.canonical_ids);
    // The env override wins over the file, either direction.
    try env.put("KNAP_BORIS_STAGING", "frozen");
    c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.frozen, c.profile);
    try testing.expect((try siteRules(&ctx)) == null);
    try env.put("KNAP_BORIS_STAGING", "raw");
    c = try siteConfig(&ctx, site);
    try testing.expectEqual(Profile.raw, c.profile);
}

test "siteConfig: env-only raw needs no file; unknown names fail loudly" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try env.put("KNAP_BORIS_STAGING", "raw");
    var ctx = testCtx(ar, &env);
    try testing.expectEqual(Profile.raw, (try siteConfig(&ctx, site)).profile);
    try env.put("KNAP_BORIS_STAGING", "bogus");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
    try testing.expect(std.mem.indexOf(u8, ctx.err_msg, "is not a staging profile") != null);
    try testing.expect(env.swapRemove("KNAP_BORIS_STAGING"));
    _ = try writeSiteFile(ar, &tmp, "{\"profile\": \"bogus\"}");
    try testing.expectError(error.ToolFailed, siteConfig(&ctx, site));
}
