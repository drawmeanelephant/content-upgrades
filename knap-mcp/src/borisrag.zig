//! Retrieval and claim checking over boris site artifacts.
//!
//! Two export shapes are readable. The frozen shape is
//! `artifact/search-index.json` + `completion.json`; `ask` over it is a
//! byte-exact port of `boris-site/ask.sh` (itself a port of the boris
//! starter theme's search client). The filed shape is a publish export:
//! `rag/working-*.md` verbatim context packs (+ `rag/manifest.json`) carry
//! the documents `ask` ranks, and `ir/completion.json` supplies entities
//! when present. Filed exports carry no claim-tagged pages, so `check`
//! there always reports unknown with an explicit reason rather than a
//! fabricated verdict.
//!
//! Artifact resolution: KNAP_BORIS_ARTIFACT points directly at a directory
//! holding either shape; else under the site (KNAP_BORIS_SITE, else
//! `<templates_dir>/../../boris-site`) `artifact/` is probed before
//! `publish/`, and at each root the frozen pair wins over `rag/`.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const search_format = "boris-rendered-search-index";
pub const completion_format = "boris-completion-index";
pub const rag_format = "boris-rag";

/// Which export shape an artifact was loaded from; reported in tool JSON.
pub const Shape = enum {
    frozen,
    filed_rag,

    pub fn name(s: Shape) []const u8 {
        return switch (s) {
            .frozen => "frozen",
            .filed_rag => "filed-rag",
        };
    }
};

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
    shape: Shape = .frozen,

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

const Search = struct { documents: []const Document };
const Completion = struct { entities: []const Entity };

/// Parse both artifact files. On `BadArtifact`, `msg` says which file and why.
pub fn parse(arena: Allocator, search_json: []const u8, completion_json: []const u8, msg: *[]const u8) ParseError!Artifact {
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

/// Resolve and read the artifact. KNAP_BORIS_ARTIFACT names a directory
/// holding either shape directly; otherwise the site dir (KNAP_BORIS_SITE,
/// else the shipped boris-site) is probed at `artifact/` then `publish/`.
/// A shape's signature file commits to that shape — a present but broken
/// export is an error, not a skip to the next candidate.
pub fn load(ctx: *Ctx) error{ ToolFailed, OutOfMemory }!Artifact {
    var probed: std.ArrayList(u8) = .empty;
    if (ctx.environ.get("KNAP_BORIS_ARTIFACT")) |dir| {
        if (try probe(ctx, dir, &probed)) |art| return art;
    } else {
        const site = try siteDir(ctx);
        inline for (.{ "artifact", "publish" }) |sub| {
            const root = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ site, sub });
            if (try probe(ctx, root, &probed)) |art| return art;
        }
    }
    return ctx.fail(
        "no readable boris artifact; probed: {s} (set KNAP_BORIS_SITE or KNAP_BORIS_ARTIFACT)",
        .{probed.items},
    );
}

/// One candidate root: the frozen pair first, then the filed `rag/` dir.
/// Null means neither signature file exists here.
fn probe(ctx: *Ctx, root: []const u8, probed: *std.ArrayList(u8)) error{ ToolFailed, OutOfMemory }!?Artifact {
    const a = ctx.arena;
    const search = try std.fmt.allocPrint(a, "{s}/search-index.json", .{root});
    const completion = try std.fmt.allocPrint(a, "{s}/completion.json", .{root});
    if (exists(ctx, search) or exists(ctx, completion)) {
        var msg: []const u8 = "";
        var art = parse(a, try readPath(ctx, search), try readPath(ctx, completion), &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadArtifact => return ctx.fail("boris artifact in {s}: {s}", .{ root, msg }),
        };
        art.shape = .frozen;
        return art;
    }
    try probeNote(a, probed, search);
    try probeNote(a, probed, completion);
    const manifest = try std.fmt.allocPrint(a, "{s}/rag/manifest.json", .{root});
    if (exists(ctx, manifest)) return try loadFiled(ctx, root, manifest);
    try probeNote(a, probed, manifest);
    return null;
}

fn probeNote(a: Allocator, probed: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    if (probed.items.len > 0) try probed.appendSlice(a, ", ");
    try probed.appendSlice(a, path);
}

fn exists(ctx: *Ctx, path: []const u8) bool {
    std.Io.Dir.access(.cwd(), ctx.io, path, .{}) catch return false;
    return true;
}

fn readPath(ctx: *Ctx, path: []const u8) error{ ToolFailed, OutOfMemory }![]const u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(64 * 1024 * 1024)) catch
        ctx.fail("cannot read {s} (set KNAP_BORIS_SITE or KNAP_BORIS_ARTIFACT)", .{path});
}

/// The filed shape: `rag/` working packs become documents; entities come
/// from `ir/completion.json` when the publish run exported it.
fn loadFiled(ctx: *Ctx, root: []const u8, manifest_path: []const u8) error{ ToolFailed, OutOfMemory }!Artifact {
    const a = ctx.arena;
    const rag = try std.fmt.allocPrint(a, "{s}/rag", .{root});
    var docs: std.ArrayList(Document) = .empty;
    for (try ragPacks(ctx, rag, try readPath(ctx, manifest_path))) |pack| {
        const bytes = try readPath(ctx, try std.fmt.allocPrint(a, "{s}/{s}", .{ rag, pack }));
        try parsePack(a, bytes, &docs);
    }
    var entities: []const Entity = &.{};
    const ir = try std.fmt.allocPrint(a, "{s}/ir/completion.json", .{root});
    if (exists(ctx, ir)) {
        var msg: []const u8 = "";
        const c = parseChecked(Completion, a, try readPath(ctx, ir), completion_format, "ir/completion.json", &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadArtifact => return ctx.fail("boris artifact in {s}: {s}", .{ root, msg }),
        };
        entities = c.entities;
    }
    return .{ .documents = docs.items, .entities = entities, .shape = .filed_rag };
}

/// Pack filenames in manifest `upload_files` order; a manifest without
/// that list falls back to `working-*.md` sorted by pack number.
fn ragPacks(ctx: *Ctx, rag_dir: []const u8, manifest: []const u8) error{ ToolFailed, OutOfMemory }![]const []const u8 {
    const a = ctx.arena;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, manifest, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}/manifest.json is not valid JSON", .{rag_dir});
    };
    if (v != .object) return ctx.fail("{s}/manifest.json is not a JSON object", .{rag_dir});
    const format = v.object.get("format") orelse .null;
    if (!(format == .string and std.mem.eql(u8, format.string, rag_format))) {
        return ctx.fail("{s}/manifest.json: unsupported format {s} (want \"{s}\")", .{
            rag_dir,
            try std.json.Stringify.valueAlloc(a, format, .{}),
            rag_format,
        });
    }
    const Manifest = struct { upload_files: []const struct { path: []const u8 } = &.{} };
    const m = std.json.parseFromValueLeaky(Manifest, a, v, .{ .ignore_unknown_fields = true }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}/manifest.json: unexpected shape ({s})", .{ rag_dir, @errorName(e) });
    };
    if (m.upload_files.len > 0) {
        const names = try a.alloc([]const u8, m.upload_files.len);
        for (m.upload_files, names) |f, *n| n.* = f.path;
        return names;
    }
    var names: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, rag_dir, .{ .iterate = true }) catch
        return ctx.fail("cannot list {s} (set KNAP_BORIS_SITE or KNAP_BORIS_ARTIFACT)", .{rag_dir});
    defer d.close(ctx.io);
    var it = d.iterate();
    while (it.next(ctx.io) catch return ctx.fail("cannot list {s}", .{rag_dir})) |ent| {
        if (ent.kind != .file) continue;
        if (std.mem.startsWith(u8, ent.name, "working-") and std.mem.endsWith(u8, ent.name, ".md"))
            try names.append(a, try a.dupe(u8, ent.name));
    }
    std.mem.sort([]const u8, names.items, {}, packLess);
    if (names.items.len == 0)
        return ctx.fail("{s}/manifest.json lists no packs and no working-*.md files exist", .{rag_dir});
    return names.items;
}

/// `working-9.md` before `working-10.md`: order by the number after the
/// last `-`, falling back to byte order.
fn packLess(_: void, a: []const u8, b: []const u8) bool {
    const na = packNumber(a);
    const nb = packNumber(b);
    return if (na != nb) na < nb else std.mem.order(u8, a, b) == .lt;
}

fn packNumber(name: []const u8) usize {
    const base = std.fs.path.stem(name);
    const dash = std.mem.lastIndexOfScalar(u8, base, '-') orelse return 0;
    return std.fmt.parseInt(usize, base[dash + 1 ..], 10) catch 0;
}

// --- filed-rag: working-pack parsing -----------------------------------------

const pack_marker = "<!-- boris-rag-doc:";

/// A working pack is verbatim boris source files, each opened by a
/// `<!-- boris-rag-doc: id="..." source="..." ... -->` marker. The marker
/// must start a line: the pack's own header names it inside backticks.
fn parsePack(arena: Allocator, bytes: []const u8, docs: *std.ArrayList(Document)) Allocator.Error!void {
    var pos: usize = 0;
    while (nextMarker(bytes, pos)) |at| {
        const end = nextMarker(bytes, at + 1) orelse bytes.len;
        pos = end;
        const block = bytes[at..end];
        const nl = std.mem.indexOfScalar(u8, block, '\n') orelse block.len;
        try docs.append(arena, try parseDoc(arena, block[0..nl], if (nl < block.len) block[nl + 1 ..] else ""));
    }
}

fn nextMarker(bytes: []const u8, from: usize) ?usize {
    var pos = from;
    while (std.mem.indexOfPos(u8, bytes, pos, pack_marker)) |at| {
        if (at == 0 or bytes[at - 1] == '\n') return at;
        pos = at + 1;
    }
    return null;
}

/// One marked-up source file -> a Document. The entity id is the
/// frontmatter `id`, else the marker `id` minus boris's `content/` prefix.
fn parseDoc(arena: Allocator, marker: []const u8, text0: []const u8) Allocator.Error!Document {
    var text = text0;
    var title: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    if (frontmatter(text)) |fm| {
        title = fmScalar(fm.data, "title");
        id = fmScalar(fm.data, "id");
        text = fm.rest;
    }
    const path = id orelse markerEntityId(marker) orelse "unknown";
    const sections = try splitSections(arena, text);
    return .{
        .path = path,
        .title = title orelse firstHeading(sections) orelse path,
        .sections = sections,
    };
}

/// `id` minus the `content/` prefix; `source` minus `.md` as fallback.
fn markerEntityId(marker: []const u8) ?[]const u8 {
    if (attr(marker, "id")) |id|
        return if (std.mem.startsWith(u8, id, "content/")) id["content/".len..] else id;
    if (attr(marker, "source")) |src|
        return if (std.mem.endsWith(u8, src, ".md")) src[0 .. src.len - ".md".len] else src;
    return null;
}

/// A ` name="value"` attribute on a boris-rag-doc marker line.
fn attr(marker: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, marker, pos, name)) |at| {
        pos = at + name.len;
        if (at == 0 or marker[at - 1] != ' ') continue;
        if (pos + 1 < marker.len and marker[pos] == '=' and marker[pos + 1] == '"') {
            const v1 = std.mem.indexOfScalarPos(u8, marker, pos + 2, '"') orelse return null;
            return marker[pos + 2 .. v1];
        }
    }
    return null;
}

const Frontmatter = struct { data: []const u8, rest: []const u8 };

/// `---\n ... \n---` opening a source file; the closing line may be `...`.
fn frontmatter(text: []const u8) ?Frontmatter {
    if (!std.mem.startsWith(u8, text, "---\n")) return null;
    var i: usize = "---\n".len;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[i..nl], " \t\r");
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "..."))
            return .{ .data = text["---\n".len..i], .rest = if (nl < text.len) text[nl + 1 ..] else "" };
        i = nl + 1;
    }
    return null;
}

/// A scalar frontmatter field: `key: value`, with one level of quotes
/// stripped. Block scalars and lists read as absent.
fn fmScalar(fm: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, fm, '\n');
    while (it.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) continue;
        var v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (v.len == 0) return null;
        if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\'')))
            v = v[1 .. v.len - 1];
        return v;
    }
    return null;
}

/// Markdown body -> search-index-ish sections: an ATX heading opens a new
/// section, fenced code lands in `code`, prose in `text`; content before
/// the first heading is the level-0 preamble.
fn splitSections(arena: Allocator, text: []const u8) Allocator.Error![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    var sec: Section = .{ .level = 0 };
    var prose: std.ArrayList(u8) = .empty;
    var code: std.ArrayList(u8) = .empty;
    var in_code = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (isFence(std.mem.trimStart(u8, line, " \t"))) {
            in_code = !in_code;
            continue;
        }
        if (!in_code) {
            if (heading(line)) |h| {
                try flushSection(arena, &sections, &sec, &prose, &code);
                sec = .{ .level = h.level, .heading = h.text, .fragment = try slug(arena, h.text) };
                continue;
            }
        }
        const buf = if (in_code) &code else &prose;
        try buf.appendSlice(arena, line0);
        try buf.append(arena, '\n');
    }
    try flushSection(arena, &sections, &sec, &prose, &code);
    return sections.items;
}

fn flushSection(arena: Allocator, sections: *std.ArrayList(Section), sec: *Section, prose: *std.ArrayList(u8), code: *std.ArrayList(u8)) Allocator.Error!void {
    const t = std.mem.trim(u8, prose.items, " \t\r\n");
    const c = std.mem.trim(u8, code.items, " \t\r\n");
    defer {
        prose.clearRetainingCapacity();
        code.clearRetainingCapacity();
    }
    if (sec.heading == null and t.len == 0 and c.len == 0) return;
    sec.text = if (t.len > 0) try arena.dupe(u8, t) else null;
    sec.code = if (c.len > 0) try arena.dupe(u8, c) else null;
    try sections.append(arena, sec.*);
}

fn isFence(trimmed_line: []const u8) bool {
    return std.mem.startsWith(u8, trimmed_line, "```") or std.mem.startsWith(u8, trimmed_line, "~~~");
}

const Heading = struct { level: i64, text: []const u8 };

/// An ATX heading line: 1-6 `#`, whitespace, text; an optional closing
/// hash run is stripped.
fn heading(line: []const u8) ?Heading {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < line.len and line[n] != ' ' and line[n] != '\t') return null;
    var t = std.mem.trim(u8, line[n..], " \t");
    var end = t.len;
    while (end > 0 and t[end - 1] == '#') end -= 1;
    if (end < t.len and (end == 0 or t[end - 1] == ' ' or t[end - 1] == '\t'))
        t = std.mem.trimEnd(u8, t[0..end], " \t");
    return .{ .level = @intCast(n), .text = t };
}

/// Lowercase ASCII slug matching the search-index fragment style:
/// alnum runs joined by `-`.
fn slug(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, s.len);
    var dash = false;
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b)) {
            if (dash and out.items.len > 0) out.appendAssumeCapacity('-');
            dash = false;
            out.appendAssumeCapacity(std.ascii.toLower(b));
        } else dash = true;
    }
    return out.items;
}

fn firstHeading(sections: []const Section) ?[]const u8 {
    for (sections) |s| {
        if (s.heading) |h| return h;
    }
    return null;
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
    if (pages.items.len == 0) return .{
        .answer = .unknown,
        .verdict = null,
        .polarity = null,
        .coverage = 0,
        .matched = null,
        .reason = if (art.shape == .filed_rag)
            "filed publish exports carry no claim-tagged pages (no claim/verdict tags or cites relations), so a claim cannot be checked either way"
        else
            "the artifact has no claim pages to check against",
    };

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

pub fn writeAskJson(w: *Writer, query: []const u8, hits: []const Hit, shape: Shape) Writer.Error!void {
    try w.writeAll("{\"query\":");
    try str(w, query);
    try w.print(",\"artifact\":\"{s}\",\"results\":[", .{shape.name()});
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

pub fn writeCheckJson(w: *Writer, claim: []const u8, v: Verdict, shape: Shape) Writer.Error!void {
    try w.writeAll("{\"claim\":");
    try str(w, claim);
    try w.print(",\"artifact\":\"{s}\",\"answer\":\"{s}\",\"verdict\":", .{ shape.name(), @tagName(v.answer) });
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
    try writeAskJson(&out.writer, "zed \"q\"", try ask(a.allocator(), &art, "keyspace", 1, false), art.shape);
    try std.testing.expectEqualStrings(
        \\{"query":"zed \"q\"","artifact":"frozen","results":[{"score":26,"id":"claims/sharding","path":"claims/sharding.html","fragment":"zed-shards-the-keyspace","title":"Zed shards the keyspace","heading":"Zed shards the keyspace","snippet":"Zed shards the keyspace"}]}
    , out.written());

    var out2: Writer.Allocating = .init(a.allocator());
    try writeCheckJson(&out2.writer, "Zed supports SQL", try check(a.allocator(), &art, "Zed supports SQL"), art.shape);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), out2.written(), .{});
    try std.testing.expectEqualStrings("frozen", parsed.object.get("artifact").?.string);
    try std.testing.expectEqualStrings("unknown", parsed.object.get("answer").?.string);
    try std.testing.expect(parsed.object.get("verdict").? == .null);
    try std.testing.expect(parsed.object.get("matched").? == .object);
}

const fixture_pack =
    \\# Boris working context pack 1/1
    \\
    \\Each document below is a complete Boris source file. To reuse one, copy
    \\everything after its `<!-- boris-rag-doc: ... -->` marker through the next
    \\marker (or the end of the file).
    \\
    \\<!-- boris-rag-doc: id="content/lorelog/bin-8c" source="lorelog/bin-8c.md" category="content" -->
    \\---
    \\title: "Bin 8C Stabilization"
    \\id: lorelog/bin-8c
    \\parent: lorelog
    \\tags: [lorelog]
    \\---
    \\
    \\# Bin 8C Stabilization
    \\
    \\Preamble mentions custody drift.
    \\
    \\## Corrective Intent
    \\
    \\The RCI band clamps Bin 8C custody.
    \\
    \\```
    \\rci.clamp(1.0, 2.0);
    \\```
    \\
    \\## Aftermath
    \\
    \\Bin 8C stays in service.
    \\
    \\<!-- boris-rag-doc: id="content/mascots/peppy" source="mascots/peppy.md" category="content" -->
    \\---
    \\title: Peppy the Seal
    \\---
    \\
    \\Peppy barks at auditors.
    \\
;

fn fixtureFiled(arena: Allocator) !Artifact {
    var docs: std.ArrayList(Document) = .empty;
    try parsePack(arena, fixture_pack, &docs);
    return .{ .documents = docs.items, .entities = &.{}, .shape = .filed_rag };
}

test "filed pack: markers, frontmatter, headings and code fences" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixtureFiled(a.allocator());
    try std.testing.expectEqual(@as(usize, 2), art.documents.len);

    const d0 = art.documents[0];
    // Frontmatter id wins over the marker's content/-prefixed id.
    try std.testing.expectEqualStrings("lorelog/bin-8c", d0.path);
    try std.testing.expectEqualStrings("Bin 8C Stabilization", d0.title);
    try std.testing.expectEqual(@as(usize, 3), d0.sections.len);
    try std.testing.expectEqual(@as(i64, 1), d0.sections[0].level);
    try std.testing.expectEqualStrings("bin-8c-stabilization", d0.sections[0].fragment.?);
    try std.testing.expect(std.mem.indexOf(u8, d0.sections[0].text.?, "custody drift") != null);
    try std.testing.expectEqualStrings("Corrective Intent", d0.sections[1].heading.?);
    try std.testing.expectEqualStrings("rci.clamp(1.0, 2.0);", d0.sections[1].code.?);
    try std.testing.expect(std.mem.indexOf(u8, d0.sections[1].text.?, "RCI band") != null);
    try std.testing.expectEqualStrings("Aftermath", d0.sections[2].heading.?);

    const d1 = art.documents[1];
    // No frontmatter id: the marker id minus "content/" supplies the path.
    try std.testing.expectEqualStrings("mascots/peppy", d1.path);
    try std.testing.expectEqualStrings("Peppy the Seal", d1.title);
    try std.testing.expectEqual(@as(usize, 1), d1.sections.len);
    try std.testing.expect(std.mem.indexOf(u8, d1.sections[0].text.?, "barks at auditors") != null);
}

test "filed ask ranks pack docs; check reports no claim surface" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const art = try fixtureFiled(a.allocator());
    const hits = try ask(a.allocator(), &art, "Bin 8C custody", 5, false);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("lorelog/bin-8c", hits[0].doc.path);
    try std.testing.expect(std.mem.indexOf(u8, hits[0].snippet, "custody") != null);

    const v = try check(a.allocator(), &art, "Bin 8C is decommissioned");
    try std.testing.expectEqual(Answer.unknown, v.answer);
    try std.testing.expect(v.matched == null);
    try std.testing.expect(std.mem.indexOf(u8, v.reason, "no claim-tagged pages") != null);
}

const filed_manifest =
    \\{"format":"boris-rag","schema_version":2,"upload_files":[{"path":"working-1.md"}],"documents":[]}
;
const filed_completion =
    \\{"format":"boris-completion-index","schema_version":1,"entities":[
    \\ {"id":"mascots/peppy","title":"Peppy the Seal","tags":["mascots"],"relations":[]}]}
;

fn testCtx(arena: Allocator, env: *std.process.Environ.Map) Ctx {
    return .{
        .arena = arena,
        .gpa = arena,
        .io = std.testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
}

fn writeFile(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    try dir.createDirPath(std.testing.io, std.fs.path.dirname(sub_path) orelse ".");
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

test "load: publish/rag filed shape, artifact override, probed-paths failure" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const site = try std.fmt.allocPrint(al, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    const publish = try std.fmt.allocPrint(al, "{s}/publish", .{site});

    try writeFile(tmp.dir, "site/publish/rag/manifest.json", filed_manifest);
    try writeFile(tmp.dir, "site/publish/rag/working-1.md", fixture_pack);
    try writeFile(tmp.dir, "site/publish/ir/completion.json", filed_completion);

    // No artifact/ dir: the site probe falls through to publish/.
    var env: std.process.Environ.Map = .init(al);
    try env.put("KNAP_BORIS_SITE", site);
    var ctx = testCtx(al, &env);
    const art = try load(&ctx);
    try std.testing.expectEqual(Shape.filed_rag, art.shape);
    try std.testing.expectEqual(@as(usize, 2), art.documents.len);
    try std.testing.expectEqual(@as(usize, 1), art.entities.len);
    try std.testing.expectEqualStrings("mascots/peppy", art.entities[0].id);

    // KNAP_BORIS_ARTIFACT points at the export dir directly.
    var env2: std.process.Environ.Map = .init(al);
    try env2.put("KNAP_BORIS_ARTIFACT", publish);
    try env2.put("KNAP_BORIS_SITE", "/nonexistent");
    var ctx2 = testCtx(al, &env2);
    try std.testing.expectEqual(Shape.filed_rag, (try load(&ctx2)).shape);

    // The frozen pair wins over publish/ at the same site.
    try writeFile(tmp.dir, "site/artifact/search-index.json", fixture_search);
    try writeFile(tmp.dir, "site/artifact/completion.json", fixture_completion);
    try std.testing.expectEqual(Shape.frozen, (try load(&ctx)).shape);

    // A site with neither shape names every probed path.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const bare = try std.fmt.allocPrint(al, ".zig-cache/tmp/{s}/bare", .{tmp2.sub_path});
    try tmp2.dir.createDirPath(std.testing.io, "bare");
    var env3: std.process.Environ.Map = .init(al);
    try env3.put("KNAP_BORIS_SITE", bare);
    var ctx3 = testCtx(al, &env3);
    try std.testing.expectError(error.ToolFailed, load(&ctx3));
    try std.testing.expect(std.mem.indexOf(u8, ctx3.err_msg, "no readable boris artifact; probed:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx3.err_msg, "artifact/search-index.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx3.err_msg, "publish/rag/manifest.json") != null);
}
