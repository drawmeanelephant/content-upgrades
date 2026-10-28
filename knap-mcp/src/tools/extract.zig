//! knap_extract + `knap-mcp extract`: doc -> template data extraction for
//! the filed.fyi template pack (FILED-TPL, #256). A record is split into
//! frontmatter, preamble and <=h2 sections; each section maps onto a canon
//! slot named by the shape's `"section"` keys (exact normalized heading
//! match first, then a token-subset fuzzy match). Bodies are lifted
//! verbatim — extraction never rewrites prose. Non-canon sections ride in
//! `extra_sections` so the render reproduces the record's skeleton;
//! anything the data cannot carry is listed in `unmapped`, never dropped.
//!
//! With a ratcheted `data` object the tool instead reports *insert
//! fragments*: for every canon slot the new data fills or appends to, the
//! rendered block for just that section plus the doc anchor it writes
//! back to — never a full re-render.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const frontmatter = @import("../frontmatter.zig");
const structhash = @import("../structhash.zig");
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;
const S = std.json.Stringify;

const fm_keys = [_][]const u8{ "title", "id", "parent", "status", "tags", "relations", "published_at", "summary" };

pub const tool: tools.Tool = .{
    .name = "knap_extract",
    .description = "Extract a filed.fyi record (doc_id from knap_ingest) into the JSON data object whose render through a filed-* template most closely matches it: canon sections map to slots (exact then fuzzy heading match), non-canon sections are captured verbatim in extra_sections, and every range the data cannot carry is reported in unmapped. Pass a ratcheted `data` object to get insert fragments — the rendered block for each newly filled canon slot and the doc anchor it writes back to.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"},"template_id":{"type":"string"},"data":{"type":"object"}},"required":["doc_id","template_id"]}
    ,
    .run = run,
};

fn str(o: ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// --- canon slots -------------------------------------------------------------

const Match = enum { none, exact, fuzzy };

/// A body slot the shape ties to a rendered section heading.
const Canon = struct {
    name: []const u8,
    /// Canonical heading text as declared (`"section"`).
    heading: []const u8 = "",
    /// Normalized `heading`.
    section: []const u8 = "",
    /// `"first"`: earliest fuzzy match wins over a later exact one.
    match_first: bool = false,
    /// array<string> slot: items come from `- ` lines of the body.
    list: bool = false,
    /// Companion `<name>_coda` verbatim field for non-list tail content.
    coda: ?[]const u8 = null,
    preamble: bool = false,
};

/// Shape -> canon slots in field order (preamble slot first if declared).
fn canonSlots(ctx: *Ctx, template_id: []const u8) tools.Error![]const Canon {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/shapes/{s}.json", .{ ctx.templates_dir, template_id });
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(1 << 20)) catch
        return ctx.fail("cannot read shape for '{s}'", .{template_id});
    const root = std.json.parseFromSliceLeaky(Value, ctx.arena, bytes, .{}) catch
        return ctx.fail("shape '{s}' is not valid JSON", .{template_id});
    if (root != .object) return ctx.fail("shape '{s}' is not a shape descriptor", .{template_id});
    const fields = switch (root.object.get("fields") orelse return ctx.fail("shape '{s}' has no fields", .{template_id})) {
        .object => |o| o,
        else => return ctx.fail("shape '{s}' fields is not an object", .{template_id}),
    };
    var out: std.ArrayList(Canon) = .empty;
    var it = fields.iterator();
    while (it.next()) |e| {
        const spec = e.value_ptr.*;
        if (spec != .object) continue;
        const name = e.key_ptr.*;
        const ty = str(spec.object, "type") orelse "string";
        if (boolean(spec.object, "preamble")) {
            try out.append(ctx.arena, .{ .name = name, .preamble = true });
            continue;
        }
        const heading = str(spec.object, "section") orelse continue;
        var c: Canon = .{
            .name = name,
            .heading = heading,
            .section = try normalize(ctx.arena, heading),
            .list = std.mem.eql(u8, ty, "array<string>"),
        };
        if (str(spec.object, "match")) |m| c.match_first = std.mem.eql(u8, m, "first");
        if (c.list) {
            const cn = try std.fmt.allocPrint(ctx.arena, "{s}_coda", .{name});
            if (fields.get(cn) != null) c.coda = cn;
        }
        try out.append(ctx.arena, c);
    }
    return out.items;
}

fn boolean(o: ObjectMap, key: []const u8) bool {
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

// --- headings ----------------------------------------------------------------

/// Normalized words of heading text: lowercase ASCII alnum runs
/// ("📜 Blamey's Limerick Log" -> "blamey s limerick log"), `{#anchor}`
/// dropped.
fn normalize(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var first = true;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, s, i, '}')) |e| {
                i = e + 1;
            } else {
                i += 1; // unterminated '{': drop it instead of spinning
            }
            continue;
        }
        while (i < s.len and !std.ascii.isAlphanumeric(s[i]) and s[i] != '{') i += 1;
        const st = i;
        while (i < s.len and std.ascii.isAlphanumeric(s[i])) i += 1;
        if (i == st) continue;
        if (!first) try aw.writer.writeByte(' ');
        first = false;
        for (s[st..i]) |c| try aw.writer.writeByte(std.ascii.toLower(c));
    }
    return aw.written();
}

/// Exact normalized equality, else canon words as an ordered subset of the
/// heading's words ("system messages" matches "known system messages").
fn headingMatch(canon_norm: []const u8, heading_norm: []const u8) Match {
    if (canon_norm.len == 0 or heading_norm.len == 0) return .none;
    if (std.mem.eql(u8, canon_norm, heading_norm)) return .exact;
    var ci = std.mem.tokenizeScalar(u8, canon_norm, ' ');
    var hi = std.mem.tokenizeScalar(u8, heading_norm, ' ');
    outer: while (ci.next()) |cw| {
        while (hi.next()) |hw| {
            if (std.mem.eql(u8, cw, hw)) continue :outer;
        }
        return .none;
    }
    return .fuzzy;
}

// --- doc model ---------------------------------------------------------------

const Section = struct {
    level: u8, // 1 or 2
    heading: []const u8,
    norm: []const u8,
    body: []const u8, // verbatim, trimmed
    line_lo: u32,
    line_hi: u32,
};

const DocModel = struct {
    fm: ObjectMap = .empty,
    fm_all: []const []const u8 = &.{},
    /// Body bytes before the first section heading; a consumed `# title`
    /// heading's body (the card/lede) is spliced in after them.
    preamble: []const u8 = "",
    /// `pre_text` is `preamble` trimmed; the verbatim preamble-slot value.
    pre_text: []const u8 = "",
    /// Verbatim body of the consumed `# title` heading, "" when none.
    title_body: []const u8 = "",
    /// Line range of the consumed `# title` heading's section.
    title_lines: [2]u32 = .{ 0, 0 },
    title_heading: bool = false,
    sections: []const Section = &.{},
};

fn headingLine(line: []const u8) ?u8 {
    var h: u8 = 0;
    while (h < line.len and line[h] == '#') h += 1;
    if (h == 0 or h > 2) return null;
    if (h < line.len and (line[h] == ' ' or line[h] == '\t')) return h;
    return null;
}

fn headingText(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t");
    while (t.len > 0 and t[0] == '#') t = std.mem.trim(u8, t[1..], " \t");
    if (std.mem.indexOf(u8, t, "{#")) |p| t = std.mem.trimEnd(u8, t[0..p], " \t");
    return t;
}

/// doc -> frontmatter values, preamble, <=h2 sections (###+ nests).
fn parseDoc(a: std.mem.Allocator, doc: []const u8) !DocModel {
    var m: DocModel = .{};
    var body = doc;
    var fm_lines: u32 = 0;
    if (try frontmatter.parse(a, doc)) |b| {
        body = doc[b.hi..];
        m.fm = try parseFmValues(a, doc[b.lo..b.hi]);
        m.fm_all = b.keys;
        fm_lines = b.close_line;
    }
    // first <=h2 heading ends the preamble
    var first_head: usize = body.len;
    var scan = std.mem.splitScalar(u8, body, '\n');
    var pos: usize = 0;
    while (scan.next()) |line| {
        if (headingLine(line) != null) {
            first_head = pos;
            break;
        }
        pos += line.len + 1;
    }
    m.preamble = body[0..first_head];
    m.pre_text = std.mem.trim(u8, m.preamble, " \t\r\n");
    // body line number offset: the preamble lines before first_head
    var ln: u32 = fm_lines;
    var pit = std.mem.splitScalar(u8, body[0..first_head], '\n');
    while (pit.next()) |_| ln += 1;
    var secs: std.ArrayList(Section) = .empty;
    var cur: ?usize = null;
    var body_start: usize = body.len;
    var off: usize = first_head;
    var sit = std.mem.splitScalar(u8, body[first_head..], '\n');
    while (sit.next()) |line| {
        ln += 1;
        if (headingLine(line)) |lv| {
            if (cur) |ci| {
                secs.items[ci].body = std.mem.trim(u8, body[body_start..off], " \t\r\n");
                secs.items[ci].line_hi = ln - 1;
            }
            const t = headingText(line);
            try secs.append(a, .{
                .level = lv,
                .heading = t,
                .norm = try normalize(a, t),
                .body = "",
                .line_lo = ln,
                .line_hi = ln,
            });
            cur = secs.items.len - 1;
            body_start = off + line.len + 1;
        }
        off += line.len + 1;
    }
    if (cur) |ci| {
        secs.items[ci].body = std.mem.trim(u8, body[@min(body_start, body.len)..body.len], " \t\r\n");
        secs.items[ci].line_hi = ln - 1;
    }
    m.sections = secs.items;
    // `# <title>` heading: a leading h1 equal to the fm title is consumed.
    // Its body — the card/lede the shapes declare as the preamble slot —
    // splices into the preamble after any pre-title bytes, not dropped.
    if (m.sections.len > 0 and m.sections[0].level == 1) {
        const title = str(m.fm, "title") orelse "";
        if (title.len > 0 and std.mem.eql(u8, m.sections[0].norm, try normalize(a, title))) {
            const s0 = m.sections[0];
            m.title_heading = true;
            m.title_body = s0.body;
            m.title_lines = .{ s0.line_lo, s0.line_hi };
            m.sections = m.sections[1..];
            if (s0.body.len > 0) {
                const pre = std.mem.trim(u8, m.preamble, " \t\r\n");
                m.preamble = if (pre.len > 0)
                    try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ pre, s0.body })
                else
                    s0.body;
                m.pre_text = m.preamble;
            }
        }
    }
    return m;
}

/// The closed-schema subset of a `---` block: `key: scalar`, `key: [a, b]`
/// and `key:` + indented `- item` lists. Only fm_keys are collected.
fn parseFmValues(a: std.mem.Allocator, block: []const u8) !ObjectMap {
    var out: ObjectMap = .empty;
    var it = std.mem.splitScalar(u8, block, '\n');
    _ = it.next(); // opening ---
    var cur: ?[]const u8 = null; // key whose value is a '-' list
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) break;
        if (t.len == 0 or t[0] == '#') continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (cur) |k| {
                if (std.mem.startsWith(u8, t, "- ")) {
                    const p = out.getPtr(k).?;
                    try p.array.append(.{ .string = try a.dupe(u8, unquote(t[2..])) });
                }
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse {
            cur = null;
            continue;
        };
        const key = std.mem.trim(u8, t[0..colon], " \t\"'");
        cur = null;
        for (fm_keys) |fk| {
            if (!std.mem.eql(u8, key, fk)) continue;
            const rest = std.mem.trim(u8, t[colon + 1 ..], " \t");
            if (rest.len == 0) {
                try out.put(a, key, .{ .array = .init(a) });
                cur = key;
            } else if (rest[0] == '[') {
                var arr: std.json.Array = .init(a);
                const close = std.mem.lastIndexOfScalar(u8, rest, ']') orelse rest.len;
                var items = std.mem.splitScalar(u8, rest[1..close], ',');
                while (items.next()) |item| {
                    const v = std.mem.trim(u8, item, " \t");
                    if (v.len > 0) try arr.append(.{ .string = try a.dupe(u8, unquote(v)) });
                }
                try out.put(a, key, .{ .array = arr });
            } else {
                try out.put(a, key, .{ .string = try a.dupe(u8, unquote(rest)) });
            }
            break;
        }
    }
    return out;
}

fn unquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\'')))
        return t[1 .. t.len - 1];
    return t;
}

// --- extraction ---------------------------------------------------------------

const Mapped = struct {
    slot: []const u8,
    heading: []const u8, // actual doc heading text
    level: u8,
    match: []const u8,
    lines: [2]u32,
};

const Report = struct {
    data: ObjectMap = .empty,
    mapped: std.ArrayList(Mapped) = .empty,
    extra: std.ArrayList(Mapped) = .empty,
    unmapped: std.ArrayList(struct { kind: []const u8, detail: []const u8, lines: [2]u32 }) = .empty,
    missing: std.ArrayList([]const u8) = .empty,
    /// doc section index -> canon index, for mapped sections only.
    assign: []?usize = &.{},
    doc: DocModel = .{},
};

fn extract(ctx: *Ctx, canon: []const Canon, doc: *const DocModel) tools.Error!Report {
    const a = ctx.arena;
    var r: Report = .{ .doc = doc.* };
    r.assign = try a.alloc(?usize, doc.sections.len);
    @memset(r.assign, null);
    var taken = try a.alloc(bool, doc.sections.len);
    @memset(taken, false);

    var it = doc.fm.iterator();
    while (it.next()) |e| try r.data.put(a, e.key_ptr.*, e.value_ptr.*);
    if (doc.title_heading) try r.data.put(a, "title_heading", .{ .string = "yes" });

    // preamble slot: verbatim bytes before the first section — pre-title
    // text plus the consumed title heading's body (the card/lede). When the
    // shape declares no slot for it, the same text lands in unmapped.
    var preamble_slot = false;
    for (canon) |c| {
        if (!c.preamble) continue;
        preamble_slot = true;
        if (doc.pre_text.len > 0) {
            try r.data.put(a, c.name, .{ .string = doc.pre_text });
            try r.mapped.append(a, .{ .slot = c.name, .heading = "(preamble)", .level = 0, .match = "verbatim", .lines = .{ 0, 0 } });
        }
        break;
    }
    if (!preamble_slot and doc.pre_text.len > 0) {
        const detail = if (doc.title_body.len > 0)
            "card/lede body under the consumed title heading (the shape declares no preamble slot)"
        else
            "preamble before the first section (the shape declares no preamble slot)";
        try r.unmapped.append(a, .{ .kind = "preamble", .detail = detail, .lines = doc.title_lines });
    }

    // canon sections in shape order; each takes the earliest exact match,
    // else the earliest fuzzy ("first" skips the exact pass).
    for (canon, 0..) |c, ci| {
        if (c.preamble) continue;
        var pick: ?usize = null;
        var how: []const u8 = "exact";
        if (!c.match_first) {
            for (doc.sections, 0..) |s, si| {
                if (taken[si]) continue;
                if (headingMatch(c.section, s.norm) == .exact) {
                    pick = si;
                    break;
                }
            }
        }
        if (pick == null) {
            how = "fuzzy";
            for (doc.sections, 0..) |s, si| {
                if (taken[si]) continue;
                if (headingMatch(c.section, s.norm) != .none) {
                    pick = si;
                    break;
                }
            }
        }
        const si = pick orelse {
            try r.missing.append(a, c.name);
            continue;
        };
        taken[si] = true;
        r.assign[si] = ci;
        const s = doc.sections[si];
        if (std.mem.eql(u8, c.name, "verse") and !std.mem.eql(u8, s.heading, "Limerick Log"))
            try r.data.put(a, "verse_heading", .{ .string = s.heading });
        if (c.list) {
            const sp = try splitListBody(a, s.body);
            if (sp.items.items.len > 0) try r.data.put(a, c.name, .{ .array = sp.items });
            if (c.coda) |cn| {
                if (sp.coda.len > 0) try r.data.put(a, cn, .{ .string = sp.coda });
            } else if (sp.coda.len > 0) {
                try r.unmapped.append(a, .{ .kind = "prose", .detail = "non-list lines inside a list slot's section", .lines = .{ s.line_lo, s.line_hi } });
            }
        } else {
            try r.data.put(a, c.name, .{ .string = s.body });
        }
        try r.mapped.append(a, .{ .slot = c.name, .heading = s.heading, .level = s.level, .match = how, .lines = .{ s.line_lo, s.line_hi } });
    }

    // unconsumed sections -> extra_sections anchored to the nearest
    // preceding mapped canon slot (or "preamble").
    var extras: std.json.Array = .init(a);
    var last: ?usize = null;
    for (doc.sections, 0..) |s, si| {
        if (r.assign[si]) |v| {
            last = v;
            continue;
        }
        var e: ObjectMap = .empty;
        try e.put(a, "after", .{ .string = if (last) |l| canon[l].name else "preamble" });
        try e.put(a, "heading", .{ .string = s.heading });
        try e.put(a, "level", .{ .integer = @as(i64, s.level) });
        try e.put(a, "body", .{ .string = s.body });
        try extras.append(.{ .object = e });
        try r.extra.append(a, .{ .slot = "extra_sections", .heading = s.heading, .level = s.level, .match = "verbatim", .lines = .{ s.line_lo, s.line_hi } });
        // every non-skeleton range is also listed in unmapped (captured, not
        // dropped) so the report's unmapped covers all of them.
        try r.unmapped.append(a, .{ .kind = "extra_section", .detail = try std.fmt.allocPrint(a, "{s} (captured in extra_sections)", .{s.heading}), .lines = .{ s.line_lo, s.line_hi } });
    }
    if (extras.items.len > 0) try r.data.put(a, "extra_sections", .{ .array = extras });

    // frontmatter keys outside the closed schema are reported, not carried.
    for (doc.fm_all) |k| {
        for (fm_keys) |fk| {
            if (std.mem.eql(u8, k, fk)) break;
        } else try r.unmapped.append(a, .{ .kind = "frontmatter_key", .detail = k, .lines = .{ 0, 0 } });
    }
    return r;
}

/// List-slot body -> items (`- ` lines, backtick shells stripped when the
/// template re-adds `| code`) + verbatim non-list remainder (coda).
fn splitListBody(a: std.mem.Allocator, body: []const u8) !struct { items: std.json.Array, coda: []const u8 } {
    var items: std.json.Array = .init(a);
    var rest: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 2 and t[0] == '-' and t[1] == ' ') {
            var v = std.mem.trim(u8, t[2..], " \t");
            if (v.len >= 2 and v[0] == '`' and v[v.len - 1] == '`') v = v[1 .. v.len - 1];
            try items.append(.{ .string = try a.dupe(u8, v) });
        } else {
            if (rest.items.len > 0) try rest.append(a, '\n');
            try rest.appendSlice(a, line);
        }
    }
    return .{ .items = items, .coda = std.mem.trim(u8, rest.items, " \t\r\n") };
}

// --- skeleton round-trip ------------------------------------------------------

/// Newline-joined structhash token kinds (ignore_formatting) for one region.
fn skeletonText(a: std.mem.Allocator, region: []const u8) ![]const u8 {
    const toks = try structhash.skeletonOpts(a, region, .markdown, .{ .ignore_formatting = true });
    var aw: std.Io.Writer.Allocating = .init(a);
    for (toks) |t| {
        try aw.writer.writeAll(t.kind);
        try aw.writer.writeByte('\n');
    }
    return aw.written();
}

const RoundTrip = struct {
    sections: usize = 0,
    equal: usize = 0,
    mismatched: std.ArrayList([]const u8) = .empty,
    render_failed: ?[]const u8 = null,
};

/// One region under comparison: the text to skeleton plus the heading it
/// claims — `name` for `mismatched` reporting, `norm` for the
/// same-heading check.
const Region = struct {
    text: []const u8,
    name: []const u8,
    norm: []const u8,
};

/// [preamble] ++ ["#"/"##" heading + body] per section, in model order.
fn docRegions(a: std.mem.Allocator, m: *const DocModel) ![]Region {
    var out: std.ArrayList(Region) = .empty;
    try out.append(a, .{ .text = m.preamble, .name = "(preamble)", .norm = "(preamble)" });
    for (m.sections) |s| {
        try out.append(a, .{
            .text = try std.fmt.allocPrint(a, "{s}{s}\n\n{s}", .{ if (s.level == 1) "# " else "## ", s.heading, s.body }),
            .name = s.heading,
            .norm = s.norm,
        });
    }
    return out.items;
}

/// Do the regions claim the same section? headingMatch in either direction
/// covers a canon heading against the doc's fuzzy variant and the exact
/// heading a template prints instead of the canon name ("Known System
/// Messages" for "System Messages"); raw equality covers headings with no
/// alnum words.
fn sameHeading(x: Region, y: Region) bool {
    return headingMatch(x.norm, y.norm) != .none or
        headingMatch(y.norm, x.norm) != .none or
        std.mem.eql(u8, x.name, y.name);
}

/// Positional compare: a doc region is equal only when the rendered region
/// at its position claims the same heading and has the same
/// ignore-formatting skeleton — so a same-structure reorder is a mismatch.
fn compareRegions(a: std.mem.Allocator, orig: []const Region, rend: []const Region) !RoundTrip {
    var rt: RoundTrip = .{ .sections = orig.len };
    for (orig, 0..) |reg, i| {
        if (i < rend.len and sameHeading(reg, rend[i])) {
            const x = try skeletonText(a, reg.text);
            const y = try skeletonText(a, rend[i].text);
            if (std.mem.eql(u8, x, y)) {
                rt.equal += 1;
                continue;
            }
        }
        try rt.mismatched.append(a, reg.name);
    }
    return rt;
}

/// Render the extracted data and compare per-region: every original region
/// (preamble + sections, doc order) against the render's region at the same
/// position — same heading, then same skeleton.
fn roundTrip(ctx: *Ctx, tpl: []const u8, r: *const Report) tools.Error!RoundTrip {
    const a = ctx.arena;
    var rt: RoundTrip = .{};
    const data_json = try S.valueAlloc(a, Value{ .object = r.data }, .{});
    const doc = switch (try engine.render(ctx, .markdown, tpl, try common.stageData(ctx, data_json))) {
        .ok => |d| d,
        .diags => |ds| {
            rt.render_failed = if (ds.len > 0) ds[0].detail else "render failed";
            return rt;
        },
    };
    const rm = try parseDoc(a, doc);
    return compareRegions(a, try docRegions(a, &r.doc), try docRegions(a, &rm));
}

// --- insert plan + fragments ---------------------------------------------------

/// The doc anchor for a new section at canon index ci: the nearest earlier
/// canon mapped in the doc (after_slot), and the first mapped section whose
/// canon is later than ci (before_heading); null = preamble / EOF.
fn insertPos(r: *const Report, ci: usize) struct { after: ?usize, before: ?usize } {
    var after: ?usize = null;
    var before: ?usize = null;
    for (r.assign, 0..) |v, si| {
        const x = v orelse continue;
        if (x < ci) after = si else if (before == null) before = si;
    }
    return .{ .after = after, .before = before };
}

// --- output -------------------------------------------------------------------

fn writeReport(r: *const Report, rt: ?RoundTrip, data_id: ?[]const u8, source: []const u8, template_id: []const u8, w: *std.Io.Writer) !void {
    try w.writeAll("{\"ok\":true,\"template_id\":");
    try S.value(template_id, .{}, w);
    try w.writeAll(",\"source\":");
    try S.value(source, .{}, w);
    if (data_id) |d| {
        try w.writeAll(",\"data_id\":");
        try S.value(d, .{}, w);
    }
    try w.writeAll(",\"mapped\":[");
    for (r.mapped.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"slot\":");
        try S.value(m.slot, .{}, w);
        try w.writeAll(",\"heading\":");
        try S.value(m.heading, .{}, w);
        try w.print(",\"level\":{d},\"match\":", .{m.level});
        try S.value(m.match, .{}, w);
        try w.print(",\"lines\":[{d},{d}]}}", .{ m.lines[0], m.lines[1] });
    }
    try w.writeAll("],\"extra\":[");
    for (r.extra.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"heading\":");
        try S.value(e.heading, .{}, w);
        try w.print(",\"level\":{d},\"lines\":[{d},{d}]}}", .{ e.level, e.lines[0], e.lines[1] });
    }
    try w.writeAll("],\"unmapped\":[");
    for (r.unmapped.items, 0..) |u, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":");
        try S.value(u.kind, .{}, w);
        try w.writeAll(",\"detail\":");
        try S.value(u.detail, .{}, w);
        try w.print(",\"lines\":[{d},{d}]}}", .{ u.lines[0], u.lines[1] });
    }
    try w.writeAll("],\"missing\":[");
    for (r.missing.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try S.value(m, .{}, w);
    }
    try w.writeAll("]");
    if (rt) |v| {
        try w.writeAll(",\"round_trip\":{");
        if (v.render_failed) |why| {
            try w.writeAll("\"render_failed\":");
            try S.value(why, .{}, w);
        } else {
            try w.print("\"sections\":{d},\"equal\":{d},\"mismatched\":[", .{ v.sections, v.equal });
            for (v.mismatched.items, 0..) |m, i| {
                if (i > 0) try w.writeAll(",");
                try S.value(m, .{}, w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const template_id = try common.requireStr(ctx, args, "template_id");
    const doc = (store.read(ctx, doc_id) catch null) orelse return ctx.fail("no such doc '{s}'", .{doc_id});
    const tpl = try common.templatePath(ctx, template_id);
    const canon = try canonSlots(ctx, template_id);
    const m = try parseDoc(ctx.arena, doc);
    var r = try extract(ctx, canon, &m);
    if (args) |a| {
        if (a.get("data")) |v| {
            if (v != .object) return ctx.fail("data must be a JSON object", .{});
            const plan = try fragments(ctx, tpl, canon, &r, v.object);
            try out.writer.writeAll(plan);
            return;
        }
    }
    const rt = try roundTrip(ctx, tpl, &r);
    const data_id = try store.put(ctx, "json", try S.valueAlloc(ctx.arena, Value{ .object = r.data }, .{}));
    try writeReport(&r, rt, data_id, doc_id, template_id, &out.writer);
}

// --- CLI -----------------------------------------------------------------------

const usage_line = "usage: knap-mcp extract <doc_id|file> --template <id> [--report <file>] [--data <ratcheted.json>]";

fn usage(msg: []const u8) u8 {
    std.debug.print("knap-mcp: {s}\n{s}\n", .{ msg, usage_line });
    return 1;
}

/// `knap-mcp extract <doc_id|file> --template <id>` — the report goes to
/// stdout (or --report <file>, stdout then carries just the data object,
/// pipeable into `-d`). With --data <ratcheted.json> stdout carries the
/// insert-fragment plan instead.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var template: ?[]const u8 = null;
    var report_path: ?[]const u8 = null;
    var data_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const val = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--template")) {
            template = val;
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--template=")) {
            template = a["--template=".len..];
        } else if (std.mem.eql(u8, a, "--report")) {
            report_path = val;
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--report=")) {
            report_path = a["--report=".len..];
        } else if (std.mem.eql(u8, a, "--data") or std.mem.eql(u8, a, "-d")) {
            data_path = val;
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--data=") or std.mem.startsWith(u8, a, "-d=")) {
            data_path = a[std.mem.indexOfScalar(u8, a, '=').? + 1 ..];
        } else if (a.len > 1 and a[0] == '-') {
            return usage(try std.fmt.allocPrint(ctx.arena, "extract: unknown option '{s}'", .{a}));
        } else if (target != null) {
            return usage(try std.fmt.allocPrint(ctx.arena, "extract: unexpected argument '{s}'", .{a}));
        } else target = a;
    }
    const arg = target orelse return usage("extract needs a doc_id or file");
    const template_id = template orelse return usage("extract needs --template <id>");
    const res = common.resolveDoc(ctx, arg) orelse
        return usage(try std.fmt.allocPrint(ctx.arena, "no such file or doc '{s}'", .{arg}));
    const tpl = common.templatePath(ctx, template_id) catch return failCli(ctx);
    const canon = canonSlots(ctx, template_id) catch return failCli(ctx);
    const m = try parseDoc(ctx.arena, res.bytes);
    var rep = extract(ctx, canon, &m) catch return failCli(ctx);

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    if (data_path) |dp| {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, dp, ctx.arena, .limited(64 * 1024 * 1024)) catch {
            std.debug.print("knap-mcp: cannot read data file '{s}'\n", .{dp});
            return 1;
        };
        const v = std.json.parseFromSliceLeaky(Value, ctx.arena, bytes, .{}) catch {
            std.debug.print("knap-mcp: '{s}' is not valid JSON\n", .{dp});
            return 1;
        };
        if (v != .object) {
            std.debug.print("knap-mcp: --data must be a JSON object\n", .{});
            return 1;
        }
        const plan = fragments(ctx, tpl, canon, &rep, v.object) catch return failCli(ctx);
        try w.interface.writeAll(plan);
    } else {
        const rt = roundTrip(ctx, tpl, &rep) catch return failCli(ctx);
        const data_json = S.valueAlloc(ctx.arena, Value{ .object = rep.data }, .{}) catch return error.OutOfMemory;
        const data_id = store.put(ctx, "json", data_json) catch return failCli(ctx);
        var full: Allocating = .init(ctx.arena);
        try writeReport(&rep, rt, data_id, arg, template_id, &full.writer);
        if (report_path) |p| {
            std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = p, .data = full.written() }) catch {
                std.debug.print("knap-mcp: cannot write --report file '{s}'\n", .{p});
                return 1;
            };
            try w.interface.writeAll(data_json);
        } else {
            try w.interface.writeAll(full.written());
        }
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return 0;
}

fn failCli(ctx: *Ctx) u8 {
    std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "extract failed"});
    return 1;
}

/// Insert fragments for `new_data` vs the extraction `r`: the rendered
/// block for each canon slot that went empty -> filled, and append deltas
/// for grown arrays, each keyed to its doc anchor.
fn fragments(ctx: *Ctx, tpl: []const u8, canon: []const Canon, r: *const Report, new_data: ObjectMap) tools.Error![]const u8 {
    const a = ctx.arena;
    const render = struct {
        fn go(c: *Ctx, t: []const u8, data: ObjectMap) tools.Error!DocModel {
            const path = try common.stageData(c, try S.valueAlloc(c.arena, Value{ .object = data }, .{}));
            const d = switch (try engine.render(c, .markdown, t, path)) {
                .ok => |x| x,
                .diags => |ds| return c.fail("data does not render: {s}", .{if (ds.len > 0) ds[0].detail else "?"}),
            };
            return parseDoc(c.arena, d);
        }
    };
    const rm_old = try render.go(ctx, tpl, r.data);
    const rm_new = try render.go(ctx, tpl, new_data);

    var aw: Allocating = .init(a);
    const w = &aw.writer;
    try w.writeAll("{\"ok\":true,\"fragments\":[");
    var first = true;
    for (canon, 0..) |c, ci| {
        if (c.preamble) continue;
        const old_v = r.data.get(c.name);
        const new_v = new_data.get(c.name);
        const old_empty = old_v == null or isEmptyVal(old_v.?);
        const new_empty = new_v == null or isEmptyVal(new_v.?);
        var mode: ?[]const u8 = null;
        var frag: []const u8 = "";
        if (old_empty and !new_empty) {
            mode = "section";
            frag = try renderSectionText(a, rm_new, c);
        } else if (!old_empty and !new_empty and old_v.? == .array and new_v.? == .array and
            new_v.?.array.items.len > old_v.?.array.items.len)
        {
            mode = "append";
            const o = try renderSectionText(a, rm_old, c);
            const n = try renderSectionText(a, rm_new, c);
            frag = if (std.mem.startsWith(u8, n, o)) n[o.len..] else n;
        }
        const m = mode orelse continue;
        if (frag.len == 0) continue;
        const pos = insertPos(r, ci);
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"slot\":");
        try S.value(c.name, .{}, w);
        try w.writeAll(",\"mode\":");
        try S.value(m, .{}, w);
        try w.writeAll(",\"section\":");
        try S.value(c.heading, .{}, w);
        try w.writeAll(",\"fragment\":");
        try S.value(frag, .{}, w);
        try w.writeAll(",\"insert\":{\"after_slot\":");
        try S.value(if (pos.after) |si| canon[r.assign[si].?].name else "preamble", .{}, w);
        try w.writeAll(",\"after_heading\":");
        try S.value(if (pos.after) |si| r.doc.sections[si].heading else null, .{}, w);
        try w.writeAll(",\"before_heading\":");
        try S.value(if (pos.before) |si| r.doc.sections[si].heading else null, .{}, w);
        try w.writeAll("}}");
    }
    try w.writeAll("]}");
    return aw.written();
}

fn isEmptyVal(v: Value) bool {
    return switch (v) {
        .null => true,
        .string => |s| std.mem.trim(u8, s, " \t\r\n").len == 0,
        .array => |a| a.items.len == 0,
        .object => |o| o.count() == 0,
        else => false,
    };
}

/// The rendered text of canon slot `c`'s section in a parsed render.
fn renderSectionText(a: std.mem.Allocator, rm: DocModel, c: Canon) ![]const u8 {
    for (rm.sections) |s| {
        if (headingMatch(c.section, s.norm) != .none)
            return std.fmt.allocPrint(a, "{s}{s}\n\n{s}\n", .{ if (s.level == 1) "# " else "## ", s.heading, s.body });
    }
    return "";
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "normalize strips emoji, anchors, punctuation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("limerick log", try normalize(a, "Limerick Log"));
    try testing.expectEqualStrings("blamey s limerick log", try normalize(a, "📜 Blamey's Limerick Log"));
    try testing.expectEqualStrings("defining failure trauma", try normalize(a, "Defining Failure/Trauma"));
    try testing.expectEqualStrings("bricky s filing notes", try normalize(a, "Bricky's Filing Notes {#x-2}"));
}

test "headingMatch exact then subset" {
    try testing.expect(headingMatch("system messages", "system messages") == .exact);
    try testing.expect(headingMatch("system messages", "known system messages") == .fuzzy);
    try testing.expect(headingMatch("day in the life", "day in the life vignette") == .fuzzy);
    try testing.expect(headingMatch("limerick log", "blamey s limerick log") == .fuzzy);
    try testing.expect(headingMatch("biography", "origin myth") == .none);
}

test "parseDoc splits preamble and sections, consumes the title heading" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "---\ntitle: \"Blamey McTypoface\"\nid: mascots/M-0003\n---\n\n# Blamey McTypoface\n\n**Role:** X\n\n## Biography\n\nbio\n\n### Sub\n\n### Still inside\n\n## Aphorisms\n\nres\n";
    const m = try parseDoc(a, doc);
    try testing.expect(m.title_heading);
    try testing.expectEqual(@as(usize, 2), m.sections.len);
    try testing.expectEqualStrings("Biography", m.sections[0].heading);
    try testing.expectEqualStrings("bio\n\n### Sub\n\n### Still inside", m.sections[0].body);
    try testing.expectEqualStrings("res", m.sections[1].body);
    try testing.expectEqualStrings("mascots/M-0003", str(m.fm, "id").?);
}

test "normalize drops an unterminated {" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("cue", try normalize(a, "Cue {"));
    try testing.expectEqualStrings("cue", try normalize(a, "Cue {#x-1} {"));
}

test "parseDoc terminates on an unterminated { in a heading or fm title" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = try parseDoc(a, "---\ntitle: T\n---\n# T\n\n## Cue {\n\nbody text\n");
    try testing.expectEqual(@as(usize, 1), m1.sections.len);
    try testing.expectEqualStrings("cue", m1.sections[0].norm);
    const m2 = try parseDoc(a, "---\ntitle: \"Cue {\"\n---\n# T\n\nbody\n");
    try testing.expect(!m2.title_heading);
    try testing.expectEqualStrings("Cue {", str(m2.fm, "title").?);
}

test "parseDoc on a doc whose last line is a heading" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = try parseDoc(a, "---\ntitle: T\n---\n# T\n\n## Last");
    try testing.expectEqual(@as(usize, 1), m1.sections.len);
    try testing.expectEqualStrings("Last", m1.sections[0].heading);
    try testing.expectEqualStrings("", m1.sections[0].body);
    const m2 = try parseDoc(a, "---\ntitle: T\n---\n# T\n\n## Last\n");
    try testing.expectEqual(@as(usize, 1), m2.sections.len);
    try testing.expectEqualStrings("", m2.sections[0].body);
}

test "compareRegions reports a reorder the kind skeleton cannot see" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orig = try parseDoc(a, "---\ntitle: T\n---\n# T\n\n## Biography\n\nbio\n\n## Image\n\nimg\n");
    // Canon order renders Image first: same token kinds, swapped headings.
    const flipped = try parseDoc(a, "---\ntitle: T\n---\n# T\n\n## Image\n\nimg\n\n## Biography\n\nbio\n");
    const rt = try compareRegions(a, try docRegions(a, &orig), try docRegions(a, &flipped));
    try testing.expectEqual(@as(usize, 3), rt.sections);
    try testing.expectEqual(@as(usize, 1), rt.equal);
    try testing.expectEqual(@as(usize, 2), rt.mismatched.items.len);
    try testing.expectEqualStrings("Biography", rt.mismatched.items[0]);
    try testing.expectEqualStrings("Image", rt.mismatched.items[1]);
}

test "compareRegions matches a canon heading printed instead of the doc variant" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The template prints "Known System Messages" for the canon slot; the
    // doc may carry either name — same position, still equal.
    const orig = try parseDoc(a, "## System Messages\n\n- `a`\n");
    const rend = try parseDoc(a, "## Known System Messages\n\n- `a`\n");
    const rt = try compareRegions(a, try docRegions(a, &orig), try docRegions(a, &rend));
    try testing.expectEqual(@as(usize, 2), rt.equal);
    try testing.expectEqual(@as(usize, 0), rt.mismatched.items.len);
}

test "parseDoc splices a consumed title heading's body into the preamble" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "---\ntitle: T\n---\n\npre\n\n# T\n\n**Role:** R\n\n## S\n\nbody\n";
    const m = try parseDoc(a, doc);
    try testing.expect(m.title_heading);
    try testing.expectEqualStrings("**Role:** R", m.title_body);
    try testing.expectEqualStrings("pre\n\n**Role:** R", m.pre_text);
    try testing.expectEqual(@as(usize, 1), m.sections.len);
    // an empty title body changes nothing
    const m2 = try parseDoc(a, "---\ntitle: T\n---\n\n# T\n\n## S\n\nbody\n");
    try testing.expect(m2.title_heading);
    try testing.expectEqualStrings("", m2.title_body);
    try testing.expectEqualStrings("", m2.pre_text);
}

fn extractTestCtx(a: std.mem.Allocator, env: *std.process.Environ.Map, root: []const u8) !Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = try std.fmt.allocPrint(a, "{s}templates", .{root}),
        .store_dir = ".zig-cache/tmp/extract-test",
        .project_root = ".",
    };
}

fn evalFixture(a: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), testing.io, try std.fmt.allocPrint(a, "{s}eval/extract/{s}", .{ root, name }), a, .limited(1 << 20));
}

test "extract fills the preamble slot with the post-title card (eval fixture)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (std.Io.Dir.access(.cwd(), testing.io, "templates/filed-mascot.knap", .{})) |_| "" else |_| "knap-mcp/";
    var env: std.process.Environ.Map = .init(a);
    var ctx = try extractTestCtx(a, &env, root);
    const m = try parseDoc(a, try evalFixture(a, root, "card-after-title.md"));
    try testing.expect(m.title_heading);
    const r = try extract(&ctx, try canonSlots(&ctx, "filed-mascot"), &m);
    try testing.expectEqualStrings(
        "**Role:** Fixture Custodian\n**Function:** Keeps the card where the title left it",
        str(r.data, "card").?,
    );
    var seen = false;
    for (r.mapped.items) |e| {
        if (std.mem.eql(u8, e.slot, "card")) {
            seen = true;
            try testing.expectEqualStrings("(preamble)", e.heading);
        }
    }
    try testing.expect(seen);
}

test "extract reports the post-title card in unmapped when no preamble slot exists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (std.Io.Dir.access(.cwd(), testing.io, "templates/filed-mascot.knap", .{})) |_| "" else |_| "knap-mcp/";
    var env: std.process.Environ.Map = .init(a);
    var ctx = try extractTestCtx(a, &env, root);
    const m = try parseDoc(a, try evalFixture(a, root, "card-after-title.md"));
    try testing.expect(m.title_heading);
    const r = try extract(&ctx, &.{.{ .name = "biography", .heading = "Biography", .section = "biography" }}, &m);
    var found = false;
    for (r.unmapped.items) |u| {
        if (std.mem.eql(u8, u.kind, "preamble")) {
            found = true;
            try testing.expect(u.lines[0] > 0);
            try testing.expect(u.lines[1] >= u.lines[0]);
        }
    }
    try testing.expect(found);
}

test "prelude is byte-identical across filed templates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (std.Io.Dir.access(.cwd(), testing.io, "templates/filed-mascot.knap", .{})) |_| "" else |_| "knap-mcp/";
    var prev: []const u8 = "";
    for ([_][]const u8{ "filed-mascot", "filed-lorelog", "filed-reference" }) |t| {
        const p = try std.fmt.allocPrint(a, "{s}templates/{s}.knap", .{ root, t });
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), testing.io, p, a, .limited(1 << 20));
        const close = std.mem.indexOfPos(u8, bytes, 4, "---").?;
        const pre = bytes[0 .. close + 4]; // through "---\n"
        if (prev.len > 0) try testing.expectEqualStrings(prev, pre);
        prev = pre;
    }
}
