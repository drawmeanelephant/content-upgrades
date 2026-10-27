//! The voice pass behind `knap_voice`: rewrite the `voice: true` string
//! values of a data object in one tone, one model call per value, and keep
//! a rewrite only if it passes the fact guard. The template never changes,
//! so every tone renders with the same structure.
//!
//! prompts/voice/README.md is the contract. This file ports its eligibility
//! walk, "Never rewritten" list, call assembly (byte-identical to
//! assemble.sh), reply cleaning and voice.awk's guard to Zig.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const backend = @import("backend.zig");
const common = @import("tools/common.zig");
const structhash = @import("structhash.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Tone = enum { mild, spicy, feral };

pub fn parseTone(name: []const u8) ?Tone {
    return std.meta.stringToEnum(Tone, name);
}

pub const Status = enum { rewritten, unchanged, rejected };

pub const Field = struct {
    /// JSON path inside the data: `take`, `known_issues[1]`, `breaking[0].fix`.
    field: []const u8,
    before: []const u8,
    after: []const u8,
    status: Status,
    /// Guard failures for `rejected`; tone-budget overruns, prefixed
    /// `warning: `, for any status; a backend error for a failed call.
    reasons: []const []const u8,
};

pub const Result = struct {
    template_id: []const u8,
    tone: Tone,
    backend: backend.Kind,
    /// Values whose final text differs from the input.
    changed: usize,
    /// The input object with only rewritten values replaced.
    data: Value,
    fields: []const Field,

    pub fn rejected(r: Result) usize {
        var n: usize = 0;
        for (r.fields) |f| n += @intFromBool(f.status == .rejected);
        return n;
    }

    /// The `knap_voice` result object, keys in contract order.
    pub fn write(r: Result, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("{\"template_id\":");
        try std.json.Stringify.value(r.template_id, .{}, w);
        try w.print(",\"tone\":\"{s}\",\"backend\":\"{s}\",\"changed\":{d},\"data\":", .{
            @tagName(r.tone), @tagName(r.backend), r.changed,
        });
        try std.json.Stringify.value(r.data, .{}, w);
        try w.writeAll(",\"fields\":[");
        for (r.fields, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"field\":");
            try std.json.Stringify.value(f.field, .{}, w);
            try w.writeAll(",\"before\":");
            try std.json.Stringify.value(f.before, .{}, w);
            try w.writeAll(",\"after\":");
            try std.json.Stringify.value(f.after, .{}, w);
            try w.print(",\"status\":\"{s}\",\"reasons\":", .{@tagName(f.status)});
            try std.json.Stringify.value(f.reasons, .{}, w);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
};

/// Entry point for the tool and for later lanes (demo, ratchet). Voices
/// every eligible value of `data_json` (a JSON object) for the shipped
/// template `template_id`. `mock` replies come from
/// prompts/voice/mock/<tone>.jsonl; live kinds make one
/// `backend.complete(.voice)` call per value and need MODEL_API_KEY.
pub fn voiceData(ctx: *Ctx, template_id: []const u8, data_json: []const u8, tone: Tone, kind: backend.Kind) backend.Error!Result {
    const a = ctx.arena;
    _ = try common.templatePath(ctx, template_id);
    const shape_path = try std.fmt.allocPrint(a, "{s}/shapes/{s}.json", .{ ctx.templates_dir, template_id });
    const shape_bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, shape_path, a, .limited(1 << 20)) catch
        return ctx.fail("template '{s}' has no shape descriptor at {s}", .{ template_id, shape_path });
    const shape = std.json.parseFromSliceLeaky(Value, a, shape_bytes, .{}) catch
        return ctx.fail("shape descriptor {s} is not valid JSON", .{shape_path});
    // Unparsed numbers stringify back byte for byte.
    var data = std.json.parseFromSliceLeaky(Value, a, data_json, .{ .parse_numbers = false }) catch
        return ctx.fail("data is not valid JSON", .{});
    if (data != .object) return ctx.fail("data must be a JSON object", .{});
    if (kind != .mock and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("knap_voice: backend '{s}' needs MODEL_API_KEY (use --backend mock for canned replies)", .{@tagName(kind)});

    const slots = try collect(a, template_id, shape, &data);
    const dir = promptsDir(ctx);
    const tone_name = @tagName(tone);
    var mock_lines: []const u8 = "";
    var system: []const u8 = "";
    if (kind == .mock) {
        mock_lines = try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "mock/{s}.jsonl", .{tone_name}));
        // Counted, not sent: the system prefix a live call would carry,
        // when the prompts dir has it (eval/voice's private
        // KNAP_PROMPTS_DIR controls ship only mock lines).
        if (mockVoiceSystem(ctx, a, dir, tone_name)) |s| {
            system = s;
        } else |_| {
            ctx.err_msg = "";
        }
    } else {
        system = assembleSystem(
            a,
            try readPrompt(ctx, dir, "system.md"),
            try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "{s}.md", .{tone_name})),
            try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "examples/{s}.jsonl", .{tone_name})),
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.fail("voice examples/{s}.jsonl has a bad line ({s})", .{ tone_name, @errorName(e) }),
        };
    }

    var fields: std.ArrayList(Field) = .empty;
    var changed: usize = 0;
    for (slots) |slot| {
        const before = slot.ptr.string;
        const raw: ?[]const u8 = if (kind == .mock) blk: {
            ctx.countCall(system, try userMessage(a, slot.path, slot.role, before));
            break :blk mockReply(a, mock_lines, template_id, slot.path, before) catch
                return ctx.fail("voice mock/{s}.jsonl has a bad line", .{tone_name});
        } else
            backend.complete(ctx, kind, .voice, system, try userMessage(a, slot.path, slot.role, before)) catch |e| switch (e) {
                error.ToolFailed => {
                    const why = try std.fmt.allocPrint(a, "backend error: {s}", .{ctx.err_msg});
                    try fields.append(a, .{ .field = slot.path, .before = before, .after = before, .status = .rejected, .reasons = try a.dupe([]const u8, &.{why}) });
                    continue;
                },
                else => return e,
            };
        const reply = if (raw) |r| cleanReply(r, before) else before;
        if (std.mem.eql(u8, reply, before)) {
            try fields.append(a, .{ .field = slot.path, .before = before, .after = before, .status = .unchanged, .reasons = &.{} });
            continue;
        }
        const check = try guard(a, tone, slot.role, slot.footnote_abutting, before, reply);
        var reasons: std.ArrayList([]const u8) = .empty;
        try reasons.appendSlice(a, check.hard.items);
        for (check.budget.items) |b| try reasons.append(a, try std.fmt.allocPrint(a, "warning: {s}", .{b}));
        const ok = check.hard.items.len == 0;
        if (ok) {
            slot.ptr.* = .{ .string = reply };
            changed += 1;
        }
        try fields.append(a, .{
            .field = slot.path,
            .before = before,
            .after = if (ok) reply else before,
            .status = if (ok) .rewritten else .rejected,
            .reasons = reasons.items,
        });
    }
    // The voice-eval numbers line; stderr keeps stdout's JSON clean.
    // Skipped under `zig test`: stray stderr breaks the runner's
    // --listen protocol.
    if (!@import("builtin").is_test)
        std.debug.print("calls: {d}  mean slice: {d} B  max: {d} B  prefix: {d} B\n", .{
            ctx.calls, ctx.meanSlice(), ctx.slice_bytes_max, ctx.prefix_bytes,
        });
    return .{
        .template_id = template_id,
        .tone = tone,
        .backend = kind,
        .changed = changed,
        .data = data,
        .fields = fields.items,
    };
}

/// KNAP_PROMPTS_DIR, else <templates_dir>/../prompts.
fn promptsDir(ctx: *Ctx) []const u8 {
    if (ctx.environ.get("KNAP_PROMPTS_DIR")) |d| return d;
    return std.fmt.allocPrint(ctx.arena, "{s}/../prompts", .{ctx.templates_dir}) catch "prompts";
}

fn readPrompt(ctx: *Ctx, dir: []const u8, rel: []const u8) backend.Error![]const u8 {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/voice/{s}", .{ dir, rel });
    return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(4 * 1024 * 1024)) catch
        return ctx.fail("cannot read voice prompt {s} (set KNAP_PROMPTS_DIR)", .{path});
}

// --- eligibility -----------------------------------------------------------

pub const Slot = struct {
    path: []const u8,
    role: []const u8,
    ptr: *Value,
    /// The template puts a `[^note]` marker straight after this value
    /// (shape flag `footnote_abutting` + a `note` on the element): a
    /// trailing `!` in the reply renders as `![^...]`, an image.
    footnote_abutting: bool = false,
};

/// Keys that are never sent to the model, whatever a shape says (README,
/// "Never rewritten"). Applied to top-level keys and array<object> fields.
const never_keys = [_][]const u8{
    "id",      "source_ids",  "url",             "name",       "accessed",       "year",
    "rel",     "reliability", "gaf",             "confidence", "frontmatter",    "receipts",
    "product", "version",     "date",            "codename",   "claim",          "text",
    "related", "connections", "migration_guide", "up_next",    "screenshot",     "cover",
    "note",    "notes",       "tags",            "status",     "upgrade_matrix", "aged",
};

fn neverKey(k: []const u8) bool {
    for (never_keys) |n| if (std.mem.eql(u8, k, n)) return true;
    return std.mem.endsWith(u8, k, "_url") or std.mem.endsWith(u8, k, "_id") or std.mem.endsWith(u8, k, "_ids");
}

/// True for values the voice pass must never touch: `key` is the top-level
/// data key, `sub` the field inside an array<object> element.
pub fn neverRewritten(template_id: []const u8, key: []const u8, sub: ?[]const u8) bool {
    if (neverKey(key)) return true;
    // Inside an element: wikilink targets (`sources[*].title`) and
    // verbatim quotes (`sources[*].quotes`).
    if (sub) |s| return neverKey(s) or std.mem.eql(u8, s, "title") or std.mem.eql(u8, s, "quotes");
    // Page identities in the site, and titles whose kebab-case form is
    // the frontmatter slug: rewriting one moves the page URL, which
    // structhash cannot see (it drops frontmatter values).
    return std.mem.eql(u8, key, "title") and
        (std.mem.eql(u8, template_id, "apparatus") or
            std.mem.eql(u8, template_id, "reading-note") or
            std.mem.eql(u8, template_id, "release-notes"));
}

/// verdict's slug falls back to `title` via ?? when `subject` is absent:
/// the same slug hazard as release-notes, gated on the data.
fn slugFallbackTitle(template_id: []const u8, key: []const u8, data: *const Value) bool {
    if (!std.mem.eql(u8, template_id, "verdict") or !std.mem.eql(u8, key, "title")) return false;
    const s = data.object.get("subject") orelse return true;
    return s != .string or s.string.len == 0;
}

fn isVoice(desc: Value) bool {
    if (desc != .object) return false;
    const v = desc.object.get("voice") orelse return false;
    return v == .bool and v.bool;
}

fn descStr(desc: Value, key: []const u8) []const u8 {
    if (desc != .object) return "";
    const v = desc.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// A string the model may see: non-empty, one line, no control characters.
fn eligible(v: *Value) bool {
    if (v.* != .string or v.string.len == 0) return false;
    return !hasControl(v.string);
}

/// Every value to voice, in shape order: README "Call assembly", step 1-2.
pub fn collect(a: Allocator, template_id: []const u8, shape: Value, data: *Value) Allocator.Error![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    if (shape != .object or data.* != .object) return out.items;
    const fields = shape.object.get("fields") orelse return out.items;
    if (fields != .object) return out.items;
    for (fields.object.keys(), fields.object.values()) |key, desc| {
        if (neverRewritten(template_id, key, null) or slugFallbackTitle(template_id, key, data)) continue;
        const v = data.object.getPtr(key) orelse continue;
        const ty = descStr(desc, "type");
        if (std.mem.eql(u8, ty, "array<object>")) {
            const sub_fields = if (desc == .object) desc.object.get("fields") else null;
            if (v.* != .array or sub_fields == null or sub_fields.? != .object) continue;
            for (v.array.items, 0..) |*elem, i| {
                const prefix = try std.fmt.allocPrint(a, "{s}[{d}]", .{ key, i });
                try collectFields(a, &out, template_id, key, prefix, sub_fields.?, elem);
            }
        } else if (isVoice(desc)) {
            try addValue(a, &out, key, desc, v, false);
        }
    }
    return out.items;
}

/// The `fields` of one array<object> element, applied to `elem`: a flagged
/// leaf becomes a slot at `prefix.sub`; a nested array<object> recurses
/// into its own fields (`sources[0].quotes[0].used_for`). The never-list
/// guards values, not containers: it is checked on the leaf's key, so
/// walking `quotes` still leaves each verbatim `text` untouched, while a
/// whole subtree named by a never-key (`receipts`, `frontmatter`) stays
/// off-limits.
fn collectFields(a: Allocator, out: *std.ArrayList(Slot), template_id: []const u8, key: []const u8, prefix: []const u8, fields: Value, elem: *Value) Allocator.Error!void {
    if (elem.* != .object or fields != .object) return;
    for (fields.object.keys(), fields.object.values()) |sub, sdesc| {
        const sv = elem.object.getPtr(sub) orelse continue;
        const path = try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, sub });
        if (std.mem.eql(u8, descStr(sdesc, "type"), "array<object>")) {
            if (neverKey(sub)) continue;
            const sub_fields = if (sdesc == .object) sdesc.object.get("fields") else null;
            if (sv.* != .array or sub_fields == null) continue;
            for (sv.array.items, 0..) |*inner, j| {
                const inner_prefix = try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, j });
                try collectFields(a, out, template_id, key, inner_prefix, sub_fields.?, inner);
            }
            continue;
        }
        if (!isVoice(sdesc) or neverRewritten(template_id, key, sub)) continue;
        try addValue(a, out, path, sdesc, sv, footnoteAbutting(sdesc, elem.*));
    }
}

/// True when the shape flags `footnote_abutting` and the element actually
/// carries a `note`: the template then emits `[^note]` right after the
/// value, so a trailing `!` reads as image syntax.
fn footnoteAbutting(sdesc: Value, elem: Value) bool {
    if (sdesc != .object or elem != .object) return false;
    const f = sdesc.object.get("footnote_abutting") orelse return false;
    if (f != .bool or !f.bool) return false;
    const note = elem.object.get("note") orelse return false;
    return note == .string and note.string.len > 0;
}

fn addValue(a: Allocator, out: *std.ArrayList(Slot), path: []const u8, desc: Value, v: *Value, footnote_abutting: bool) Allocator.Error!void {
    const ty = descStr(desc, "type");
    const role = descStr(desc, "role");
    if (std.mem.eql(u8, ty, "string")) {
        if (eligible(v)) try out.append(a, .{ .path = path, .role = role, .ptr = v, .footnote_abutting = footnote_abutting });
    } else if (std.mem.eql(u8, ty, "array<string>") and v.* == .array) {
        const item_role = try std.fmt.allocPrint(a, "{s} (one item)", .{role});
        for (v.array.items, 0..) |*e, i| {
            if (!eligible(e)) continue;
            try out.append(a, .{ .path = try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, i }), .role = item_role, .ptr = e, .footnote_abutting = footnote_abutting });
        }
    }
}

// --- call assembly ---------------------------------------------------------

/// One JSONL line of examples/, mock/ or testdata/.
pub const Line = struct {
    template: []const u8,
    field: []const u8,
    field_role: []const u8,
    input: []const u8,
    output: []const u8,
    tone: []const u8 = "",
    expect: []const u8 = "",
};

/// Parsed lines of a JSONL file, skipping blank ones.
pub fn parseLines(a: Allocator, jsonl: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, jsonl, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try out.append(a, try std.json.parseFromSliceLeaky(Line, a, line, .{}));
    }
    return out.items;
}

const rtrim_chars = " \t\r\n";

/// system.md + tone guide + examples, as `assemble.sh system <tone>` prints.
pub fn assembleSystem(a: Allocator, system_md: []const u8, tone_md: []const u8, examples_jsonl: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("{s}\n\n{s}\n\n## Examples", .{
        std.mem.trimEnd(u8, system_md, rtrim_chars),
        std.mem.trimEnd(u8, tone_md, rtrim_chars),
    }) catch return error.OutOfMemory;
    for (try parseLines(a, examples_jsonl)) |ex| {
        w.writer.print("\n\nField: {s}\nRole: {s}\nInput: {s}\nOutput: {s}", .{
            ex.field, ex.field_role, ex.input, ex.output,
        }) catch return error.OutOfMemory;
    }
    return w.written();
}

/// As `assemble.sh user <field> <role> <value>` prints.
pub fn userMessage(a: Allocator, field: []const u8, role: []const u8, value: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "Field: {s}\nRole: {s}\nInput: {s}", .{ field, role, value });
}

/// The system prompt a live call would carry, or null when the prompts
/// dir lacks the voice files — eval/voice's private KNAP_PROMPTS_DIR
/// controls ship only mock lines. Lets a mock run count the real prefix.
fn mockVoiceSystem(ctx: *Ctx, a: Allocator, dir: []const u8, tone_name: []const u8) ![]const u8 {
    const system_md = try readPrompt(ctx, dir, "system.md");
    const tone_md = try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "{s}.md", .{tone_name}));
    const examples = try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "examples/{s}.jsonl", .{tone_name}));
    return assembleSystem(a, system_md, tone_md, examples);
}

/// The canned reply for (template, field, input), or null on a miss.
pub fn mockReply(a: Allocator, mock_jsonl: []const u8, template_id: []const u8, field: []const u8, input: []const u8) !?[]const u8 {
    for (try parseLines(a, mock_jsonl)) |m| {
        if (std.mem.eql(u8, m.template, template_id) and std.mem.eql(u8, m.field, field) and
            std.mem.eql(u8, m.input, input)) return m.output;
    }
    return null;
}

/// Trim, drop a leading `Output:` label, and unwrap one pair of `"` that
/// the input doesn't have.
pub fn cleanReply(reply: []const u8, input: []const u8) []const u8 {
    var r = std.mem.trim(u8, reply, rtrim_chars);
    if (std.mem.startsWith(u8, r, "Output:")) r = std.mem.trim(u8, r["Output:".len..], rtrim_chars);
    if (r.len >= 2 and r[0] == '"' and r[r.len - 1] == '"' and
        !(input.len >= 2 and input[0] == '"' and input[input.len - 1] == '"'))
        r = r[1 .. r.len - 1];
    return r;
}

// --- the guard (voice.awk) -------------------------------------------------

const Kind = enum {
    url,
    wikilink,
    footnote_ref,
    quote,
    number,
    name,
    acronym,
    proper_noun,

    fn label(k: Kind) []const u8 {
        return switch (k) {
            .footnote_ref => "footnote ref",
            .proper_noun => "proper noun",
            else => @tagName(k),
        };
    }

    /// Matched as substrings; the others as whole words.
    fn substring(k: Kind) bool {
        return switch (k) {
            .url, .wikilink, .footnote_ref, .quote => true,
            else => false,
        };
    }
};

const Token = struct { text: []const u8, kind: Kind };

/// Protected tokens of a string, in discovery order. Like an awk array, a
/// later `put` of the same text overwrites its kind.
const Facts = struct {
    list: std.ArrayList(Token) = .empty,

    fn has(f: *const Facts, t: []const u8) bool {
        for (f.list.items) |tok| if (std.mem.eql(u8, tok.text, t)) return true;
        return false;
    }

    fn put(f: *Facts, a: Allocator, t: []const u8, k: Kind) !void {
        for (f.list.items) |*tok| if (std.mem.eql(u8, tok.text, t)) {
            tok.kind = k;
            return;
        };
        try f.list.append(a, .{ .text = t, .kind = k });
    }
};

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// `w` occurs in `s` with no letter or digit on either side.
fn hasWord(s: []const u8, w: []const u8) bool {
    if (w.len == 0) return false;
    var off: usize = 0;
    while (std.mem.indexOfPos(u8, s, off, w)) |p| {
        const end = p + w.len;
        if ((p == 0 or !isAlnum(s[p - 1])) and (end >= s.len or !isAlnum(s[end]))) return true;
        off = p + 1;
    }
    return false;
}

fn present(s: []const u8, tok: Token) bool {
    if (tok.kind.substring()) return std.mem.indexOf(u8, s, tok.text) != null;
    return hasWord(s, tok.text);
}

fn urls(a: Allocator, s: []const u8, f: *Facts) !void {
    var i: usize = 0;
    while (i < s.len) {
        const scheme: usize = if (std.mem.startsWith(u8, s[i..], "https://"))
            8
        else if (std.mem.startsWith(u8, s[i..], "http://"))
            7
        else
            0;
        var e = i + scheme;
        while (scheme > 0 and e < s.len and std.mem.indexOfScalar(u8, " \t\"'<>)", s[e]) == null) e += 1;
        if (scheme == 0 or e == i + scheme) {
            i += 1;
            continue;
        }
        try f.put(a, std.mem.trimEnd(u8, s[i..e], ".,;:!?"), .url);
        i = e;
    }
}

fn spans(a: Allocator, s: []const u8, f: *Facts, opener: []const u8, closer: []const u8, k: Kind) !void {
    var rest = s;
    while (std.mem.indexOf(u8, rest, opener)) |p| {
        rest = rest[p..];
        const q = std.mem.indexOf(u8, rest[opener.len..], closer) orelse return f.put(a, rest, k);
        const end = opener.len + q + closer.len;
        try f.put(a, rest[0..end], k);
        rest = rest[end..];
    }
}

/// "double" spans, and 'single' spans whose quotes are not apostrophes.
fn quotes(a: Allocator, s: []const u8, f: *Facts) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '"') {
            const j = std.mem.indexOfScalarPos(u8, s, i + 1, '"') orelse return;
            try f.put(a, s[i .. j + 1], .quote);
            i = j + 1;
            continue;
        }
        if (s[i] == '\'' and (i == 0 or !isAlnum(s[i - 1]))) {
            var j = i + 1;
            while (j < s.len) : (j += 1) {
                if (s[j] == '\'' and (j + 1 >= s.len or !isAlnum(s[j + 1]))) break;
            }
            if (j < s.len and j > i + 1) {
                try f.put(a, s[i .. j + 1], .quote);
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
}

fn numChar(c: u8) bool {
    return isAlnum(c) or std.mem.indexOfScalar(u8, "$#~<>.,%/:_+-", c) != null;
}

/// Maximal runs of number characters that contain a digit.
fn numbers(a: Allocator, s: []const u8, f: *Facts) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (!numChar(s[i])) {
            i += 1;
            continue;
        }
        var e = i;
        var digit = false;
        while (e < s.len and numChar(s[e])) : (e += 1) digit = digit or std.ascii.isDigit(s[e]);
        if (digit) try f.put(a, std.mem.trimEnd(u8, s[i..e], ".,:/_+-"), .number);
        i = e;
    }
}

/// name: two or more capitals with lowercase (AcmeDB, PhD). acronym: all
/// capitals (WAL). proper noun: one leading capital, not at a sentence start.
fn names(a: Allocator, s: []const u8, f: *Facts) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (!isAlnum(s[i])) {
            i += 1;
            continue;
        }
        const p = i;
        while (i < s.len and isAlnum(s[i])) i += 1;
        const w = s[p..i];
        var nu: usize = 0;
        var nl: usize = 0;
        var digit = false;
        for (w) |c| {
            nu += @intFromBool(std.ascii.isUpper(c));
            nl += @intFromBool(std.ascii.isLower(c));
            digit = digit or std.ascii.isDigit(c);
        }
        if (digit) continue;
        if (nu >= 2) {
            try f.put(a, w, if (nl > 0) .name else .acronym);
            continue;
        }
        if (nu != 1 or w.len < 2 or !std.ascii.isUpper(w[0]) or f.has(w)) continue;
        const pre = std.mem.trimEnd(u8, s[0..p], " \t\"(['");
        if (pre.len > 0 and std.mem.indexOfScalar(u8, ".!?", pre[pre.len - 1]) == null)
            try f.put(a, w, .proper_noun);
    }
}

fn facts(a: Allocator, s: []const u8) !Facts {
    var f: Facts = .{};
    try urls(a, s, &f);
    try spans(a, s, &f, "[[", "]]", .wikilink);
    try spans(a, s, &f, "[^", "]", .footnote_ref);
    try quotes(a, s, &f);
    try numbers(a, s, &f);
    try names(a, s, &f);
    return f;
}

const profanity = [_][]const u8{
    "shit",    "shits", "shitty", "bullshit", "fuck", "fucks", "fucked", "fucking", "damn", "damned",
    "goddamn", "hell",  "crap",   "crappy",   "ass",  "asses", "piss",   "pissed",
};
const fwords = [_][]const u8{ "fuck", "fucks", "fucked", "fucking" };
const markup = "*_`|#<>[]{}~^@\\\"";

fn listed(list: []const []const u8, w: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn budgetOf(tone: Tone) struct { prof: usize, caps: usize, bang: usize } {
    return switch (tone) {
        .mild => .{ .prof = 0, .caps = 0, .bang = 0 },
        .spicy => .{ .prof = 1, .caps = 1, .bang = 1 },
        .feral => .{ .prof = 2, .caps = 3, .bang = 2 },
    };
}

fn startsWithBlockMarker(s: []const u8) bool {
    if (s.len >= 2 and std.mem.indexOfScalar(u8, "-+*=>#", s[0]) != null and s[1] == ' ') return true;
    if (std.mem.startsWith(u8, s, "---")) return true;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i > 0 and i + 1 < s.len and (s[i] == '.' or s[i] == ')') and s[i + 1] == ' ') return true;
    inline for (.{ "h1", "h2", "h3", "h4", "h5", "h6", "p", "bq", "bc", "pre" }) |tag| {
        if (std.mem.startsWith(u8, s, tag ++ ". ")) return true;
    }
    if (std.mem.startsWith(u8, s, "fn")) {
        i = 2;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i > 2 and std.mem.startsWith(u8, s[i..], ". ")) return true;
    }
    return false;
}

fn has4Byte(s: []const u8) bool {
    for (s) |c| if (c >= 0xf0 and c <= 0xf4) return true;
    return false;
}

/// U+2600 to U+27BF: E2 98 80 .. E2 9E BF.
fn hasSymbol(s: []const u8) bool {
    for (s, 0..) |c, i| if (c == 0xe2 and i + 1 < s.len and s[i + 1] >= 0x98 and s[i + 1] <= 0x9e) return true;
    return false;
}

// Content-word sets and stemming: verifier.zig's tokenizer, re-implemented
// here because its helpers are private. `verifier.normalize` is reused.
const verifier = @import("verifier.zig");

const stopwords = [_][]const u8{
    "a",     "an",    "the",   "and",   "or",    "but",   "of",    "to",    "in",
    "on",    "at",    "for",   "by",    "with",  "from",  "as",    "is",    "are",
    "was",   "were",  "be",    "been",  "being", "it",    "its",   "this",  "that",
    "these", "those", "has",   "have",  "had",   "do",    "does",  "did",   "will",
    "would", "can",   "could", "should", "may",  "might", "must",  "so",    "than",
    "then",  "there", "their", "they",  "them",  "we",    "our",   "you",   "your",
    "he",    "she",   "his",   "her",   "i",     "me",    "my",    "if",    "into",
    "about", "just",  "also",  "any",   "some",  "each",  "very",  "too",   "which",
    "who",   "whom",  "what",  "when",  "where", "how",   "why",   "s",     "t",
};

const negations = [_][]const u8{
    "no", "not", "never", "without", "cannot", "none", "nobody", "nothing", "neither", "nor",
};

const number_words = [_][]const u8{
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
};

/// Crude suffix stripping so light inflection still overlaps (verifier.zig).
fn stem(w: []const u8) []const u8 {
    var s = w;
    if (s.len > 3 and s[s.len - 1] == 's' and s[s.len - 2] != 's') s = s[0 .. s.len - 1];
    if (s.len > 4 and s[s.len - 1] == 'e') s = s[0 .. s.len - 1];
    if (s.len > 5 and std.mem.endsWith(u8, s, "ing")) s = s[0 .. s.len - 3];
    if (s.len > 5 and std.mem.endsWith(u8, s, "ed")) s = s[0 .. s.len - 2];
    return s;
}

/// Deduped, stemmed content words of `s`, in order.
fn contentWords(a: Allocator, s: []const u8) ![]const []const u8 {
    const text = try verifier.normalize(a, s);
    var content: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (!isAlnum(c)) {
            i += 1;
            continue;
        }
        const start = i;
        const digits = std.ascii.isDigit(c);
        while (i < text.len) : (i += 1) {
            const d = text[i];
            if (digits and std.ascii.isDigit(d)) continue;
            if (!digits and std.ascii.isAlphabetic(d)) continue;
            if (!digits and d == '\'' and i + 1 < text.len and std.ascii.isAlphabetic(text[i + 1])) continue;
            break;
        }
        var w = text[start..i];
        if (!digits) {
            if (std.mem.endsWith(u8, w, "n't")) continue;
            if (std.mem.endsWith(u8, w, "'s")) w = w[0 .. w.len - 2];
            if (std.mem.indexOfScalar(u8, w, '\'') != null) continue;
            if (listed(&negations, w)) continue;
            if (listed(&stopwords, w)) continue;
            w = for (number_words, 0..) |nw, n| {
                if (std.mem.eql(u8, nw, w)) break try std.fmt.allocPrint(a, "{d}", .{n});
            } else stem(w);
            if (w.len < 2 and !std.ascii.isDigit(w[0])) continue;
        }
        const gop = try seen.getOrPut(a, w);
        if (!gop.found_existing) try content.append(a, w);
    }
    return content.items;
}

/// Same inline-structure token stream, kind and depth. The hash ignores
/// depth but the guard wants the same comparison the renderer sees.
fn sameSkeleton(x: []const structhash.Token, y: []const structhash.Token) bool {
    if (x.len != y.len) return false;
    for (x, y) |a_tok, b_tok|
        if (a_tok.depth != b_tok.depth or !std.mem.eql(u8, a_tok.kind, b_tok.kind)) return false;
    return true;
}

pub const Check = struct {
    /// Hard rules (facts, markup both directions, structure, overlap,
    /// length, UTF-8), plus profanity in a mild reply. Any entry keeps
    /// the original value.
    hard: std.ArrayList([]const u8) = .empty,
    /// The other tone budgets: advisory at runtime, failures in check.sh.
    budget: std.ArrayList([]const u8) = .empty,

    pub fn passes(c: Check) bool {
        return c.hard.items.len == 0;
    }

    /// check.sh's verdict: every reason, budgets included.
    pub fn strict(c: Check) bool {
        return c.hard.items.len == 0 and c.budget.items.len == 0;
    }
};

/// Every way `out` breaks the voice contract for `in_` (README, "The
/// guard"). Inputs are assumed eligible: non-empty, one line.
/// `footnote_abutting` marks slots the template follows with `[^note]`.
pub fn guard(a: Allocator, tone: Tone, role: []const u8, footnote_abutting: bool, in_: []const u8, out: []const u8) Allocator.Error!Check {
    var c: Check = .{};
    const H = struct {
        fn add(al: Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
            try list.append(al, try std.fmt.allocPrint(al, fmt, args));
        }
    };
    if (out.len == 0) {
        try H.add(a, &c.hard, "empty output", .{});
        return c;
    }
    if (hasControl(out)) try H.add(a, &c.hard, "control character or line break", .{});
    if (!std.unicode.utf8ValidateSlice(out)) try H.add(a, &c.hard, "invalid UTF-8", .{});

    const fi = try facts(a, in_);
    const fo = try facts(a, out);
    for (fi.list.items) |t| if (!present(out, t)) try H.add(a, &c.hard, "drops {s} {s}", .{ t.kind.label(), t.text });
    for (fo.list.items) |t| {
        if (t.kind == .acronym or t.kind == .proper_noun or present(in_, t)) continue;
        try H.add(a, &c.hard, "adds {s} {s}", .{ t.kind.label(), t.text });
    }

    for (markup) |m| {
        const ni = std.mem.count(u8, in_, &[1]u8{m});
        const no = std.mem.count(u8, out, &[1]u8{m});
        if (no > ni) try H.add(a, &c.hard, "adds markup character {c}", .{m});
        if (no < ni) try H.add(a, &c.hard, "drops markup character {c}", .{m});
    }
    // Same token stream means the value renders with the same structure
    // hash; a dropped `**` changes it as surely as an injected one.
    const si = try structhash.skeletonOpts(a, in_, .markdown, .{});
    const so = try structhash.skeletonOpts(a, out, .markdown, .{});
    if (!sameSkeleton(si, so)) try H.add(a, &c.hard, "changes inline structure", .{});
    if (footnote_abutting and std.mem.endsWith(u8, out, "!"))
        try H.add(a, &c.hard, "ends with ! where a footnote marker follows (renders as image syntax)", .{});
    inline for (.{ "!!", "??" }) |pair| {
        if (std.mem.indexOf(u8, out, pair) != null and std.mem.indexOf(u8, in_, pair) == null)
            try H.add(a, &c.hard, "adds " ++ pair, .{});
    }
    if (startsWithBlockMarker(out)) try H.add(a, &c.hard, "starts with a block marker", .{});
    if ((has4Byte(out) and !has4Byte(in_)) or (hasSymbol(out) and !hasSymbol(in_)))
        try H.add(a, &c.hard, "adds emoji", .{});

    const lo = (in_.len + 1) / 2;
    const hi = @max(2 * in_.len, in_.len + 40);
    if (out.len < lo) try H.add(a, &c.hard, "too short: {d} bytes, min {d}", .{ out.len, lo });
    if (out.len > hi) try H.add(a, &c.hard, "too long: {d} bytes, max {d}", .{ out.len, hi });
    if (std.mem.indexOf(u8, role, "one-word") != null or std.mem.indexOf(u8, role, "four word") != null) {
        var nw: usize = 0;
        var it = std.mem.tokenizeAny(u8, out, " \t\n");
        while (it.next()) |_| nw += 1;
        if (nw > 4) try H.add(a, &c.hard, "word-limited role, {d} words, max 4", .{nw});
    }

    // A rewrite must reword the value, not abandon it or wrap it in meta
    // prose: keep at least half the input's content words, and no reply
    // that contains the input verbatim may lead with two or more content
    // words the input lacks ("Sure! Here is the take: ...").
    const ci = try contentWords(a, in_);
    const co = try contentWords(a, out);
    if (ci.len >= 3) {
        var kept: usize = 0;
        for (ci) |w| kept += @intFromBool(listed(co, w));
        if (kept * 2 < ci.len)
            try H.add(a, &c.hard, "keeps only {d} of {d} input content words", .{ kept, ci.len });
    }
    if (std.mem.indexOf(u8, out, in_)) |p| {
        const lead = try contentWords(a, out[0..p]);
        var extra: usize = 0;
        for (lead) |w| extra += @intFromBool(!listed(ci, w));
        if (extra >= 2) try H.add(a, &c.hard, "wraps the input with extra prose", .{});
    }

    const max = budgetOf(tone);
    const name = @tagName(tone);
    var nprof: usize = 0;
    var nf: usize = 0;
    var i: usize = 0;
    while (i < out.len) {
        if (!std.ascii.isAlphabetic(out[i])) {
            i += 1;
            continue;
        }
        const p = i;
        while (i < out.len and std.ascii.isAlphabetic(out[i])) i += 1;
        const w = try std.ascii.allocLowerString(a, out[p..i]);
        nprof += @intFromBool(listed(&profanity, w));
        nf += @intFromBool(listed(&fwords, w));
    }
    if (nprof > max.prof)
        try H.add(a, if (tone == .mild) &c.hard else &c.budget, "{s}: {d} profanity words, max {d}", .{ name, nprof, max.prof });
    if (tone == .spicy and nf > 0) try H.add(a, &c.budget, "spicy: f-word", .{});
    var ncaps: usize = 0;
    for (fo.list.items) |t| ncaps += @intFromBool(t.kind == .acronym and !hasWord(in_, t.text));
    if (ncaps > max.caps) try H.add(a, &c.budget, "{s}: {d} new all-caps words, max {d}", .{ name, ncaps, max.caps });
    const nbang = std.mem.count(u8, out, "!");
    if (nbang > max.bang) try H.add(a, &c.budget, "{s}: {d} exclamation marks, max {d}", .{ name, nbang, max.bang });
    return c;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Test fixtures sit outside the module root, and the test binary inherits
/// the cwd `zig build test` was started from: try both likely roots.
fn testRoot() []const u8 {
    std.Io.Dir.access(.cwd(), testing.io, "prompts/voice/system.md", .{}) catch return "knap-mcp/";
    return "";
}

fn readTest(a: Allocator, comptime rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}{s}", .{ testRoot(), rel });
    return std.Io.Dir.readFileAlloc(.cwd(), testing.io, path, a, .limited(4 << 20)) catch |e| {
        std.debug.print("voice: cannot read {s}; run zig build test from knap-mcp/ or the repo root\n", .{path});
        return e;
    };
}

fn joined(a: Allocator, list: []const []const u8) ![]const u8 {
    return std.mem.join(a, "; ", list);
}

test "guard catches every known-bad rewrite in testdata/bad.jsonl" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try parseLines(a, try readTest(a, "prompts/voice/testdata/bad.jsonl"));
    try testing.expectEqual(@as(usize, 21), lines.len);
    for (lines) |l| {
        const c = try guard(a, parseTone(l.tone).?, l.field_role, false, l.input, l.output);
        const all = try joined(a, c.hard.items);
        const budget = try joined(a, c.budget.items);
        if (std.mem.indexOf(u8, all, l.expect) == null and std.mem.indexOf(u8, budget, l.expect) == null) {
            std.debug.print("bad.jsonl {s}: want \"{s}\", got hard [{s}] budget [{s}]\n", .{ l.field, l.expect, all, budget });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!c.strict());
    }
}

test "every example and mock reply passes the guard, budgets included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mocks: usize = 0;
    inline for (.{ "examples", "mock" }) |kind| {
        inline for (.{ "mild", "spicy", "feral" }) |tone| {
            const lines = try parseLines(a, try readTest(a, "prompts/voice/" ++ kind ++ "/" ++ tone ++ ".jsonl"));
            try testing.expect(lines.len > 0);
            for (lines) |l| {
                const c = try guard(a, parseTone(tone).?, l.field_role, false, l.input, l.output);
                if (!c.strict()) {
                    std.debug.print("{s}/{s}.jsonl {s} {s}: [{s}] [{s}]\n", .{ kind, tone, l.template, l.field, try joined(a, c.hard.items), try joined(a, c.budget.items) });
                    return error.TestUnexpectedResult;
                }
                try testing.expect(!std.mem.eql(u8, l.input, l.output));
                if (std.mem.eql(u8, kind, "mock")) mocks += 1;
            }
        }
    }
    try testing.expect(mocks >= 3 * 4);
}

test "assembled messages equal the assemble.sh goldens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const system_md = try readTest(a, "prompts/voice/system.md");
    inline for (.{ "mild", "spicy", "feral" }) |tone| {
        const got = try assembleSystem(
            a,
            system_md,
            try readTest(a, "prompts/voice/" ++ tone ++ ".md"),
            try readTest(a, "prompts/voice/examples/" ++ tone ++ ".jsonl"),
        );
        try testing.expectEqualStrings(try readTest(a, "prompts/voice/testdata/system." ++ tone ++ ".txt"), got);
    }
    try testing.expectEqualStrings(
        try readTest(a, "prompts/voice/testdata/user.take.txt"),
        try userMessage(a, "take", "one-line hot take", "the boring database that actually ships"),
    );
}

test "cleanReply trims, drops the label and unwraps added quotes" {
    try testing.expectEqualStrings("a take", cleanReply("  Output:  a take \n", "x"));
    try testing.expectEqualStrings("a take", cleanReply("\"a take\"", "x"));
    try testing.expectEqualStrings("\"kept\"", cleanReply("\"kept\"", "\"orig\""));
    try testing.expectEqualStrings("\"", cleanReply("\"", "x"));
}

test "never-rewritten keys win over a shape's voice flag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shape = try std.json.parseFromSliceLeaky(Value, a,
        \\{"fields":{"title":{"type":"string","role":"t","voice":true},"url":{"type":"string","role":"u","voice":true},
        \\"take":{"type":"string","role":"k","voice":true},"blank":{"type":"string","role":"b","voice":true},
        \\"items":{"type":"array<string>","role":"bullets","voice":true},
        \\"sources":{"type":"array<object>","role":"s","fields":{"name":{"type":"string","role":"n","voice":true},
        \\"title":{"type":"string","role":"w","voice":true},"why":{"type":"string","role":"y","voice":true},
        \\"quotes":{"type":"array<string>","role":"q","voice":true}}}}}
    , .{});
    var data = try std.json.parseFromSliceLeaky(Value, a,
        \\{"title":"T","subject":"S","url":"https://x","take":"hot","blank":"","items":["one","two\nlines",3],
        \\"sources":[{"name":"N","title":"W","why":"because","quotes":["q"]}]}
    , .{});
    const want = [_][2][]const u8{ .{ "take", "k" }, .{ "items[0]", "bullets (one item)" }, .{ "sources[0].why", "y" } };
    const slots = try collect(a, "apparatus", shape, &data);
    try testing.expectEqual(want.len, slots.len);
    for (want, slots) |w, s| {
        try testing.expectEqualStrings(w[0], s.path);
        try testing.expectEqualStrings(w[1], s.role);
    }
    // verdict's title is flagged and safe while `subject` carries the slug;
    // without a subject the slug falls back to `title`, so it drops out.
    try testing.expectEqual(want.len + 1, (try collect(a, "verdict", shape, &data)).len);
    _ = data.object.orderedRemove("subject");
    try testing.expectEqual(want.len, (try collect(a, "verdict", shape, &data)).len);
    // release-notes title is a slug too, whatever the shape says.
    try testing.expectEqual(want.len, (try collect(a, "release-notes", shape, &data)).len);
}

test "collect flags footnote-abutting slots only when the element has a note" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shape = try std.json.parseFromSliceLeaky(Value, a,
        \\{"fields":{"items":{"type":"array<object>","role":"rows","fields":{
        \\"what":{"type":"string","role":"w","voice":true,"footnote_abutting":true},
        \\"note":{"type":"string","role":"n","optional":true}}}}}
    , .{});
    var data = try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"what":"one","note":"n1"},{"what":"two"}]}
    , .{});
    const slots = try collect(a, "release-notes", shape, &data);
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expect(slots[0].footnote_abutting);
    try testing.expect(!slots[1].footnote_abutting);
}

test "collect reaches flagged leaves inside a nested array<object>" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shape = try std.json.parseFromSliceLeaky(Value, a,
        \\{"fields":{"sources":{"type":"array<object>","role":"s","fields":{
        \\"name":{"type":"string","role":"n","voice":true},
        \\"receipts":{"type":"array<object>","role":"r","fields":{
        \\"claim":{"type":"string","role":"c","voice":true}}},
        \\"quotes":{"type":"array<object>","role":"q","fields":{
        \\"text":{"type":"string","role":"t","voice":true},
        \\"used_for":{"type":"string","role":"u","voice":true}}}}}}}
    , .{});
    var data = try std.json.parseFromSliceLeaky(Value, a,
        \\{"sources":[{"name":"N","receipts":[{"claim":"c"}],
        \\"quotes":[{"text":"q1","used_for":"u1"},{"text":"q2","used_for":"u2"}]}]}
    , .{});
    // name is a never-keyed leaf, text is verbatim, and a nested subtree
    // under a never-key name stays untouched; only used_for is a slot.
    const slots = try collect(a, "verdict", shape, &data);
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expectEqualStrings("sources[0].quotes[0].used_for", slots[0].path);
    try testing.expectEqualStrings("sources[0].quotes[1].used_for", slots[1].path);
}

test "guard rejects markup removal, wrappers, bad UTF-8 and a footnote-abutting bang" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Markup removal trips both the count rule and the skeleton check.
    var c = try guard(a, .mild, "r", false, "the **boring** database", "the boring database");
    const all = try joined(a, c.hard.items);
    try testing.expect(std.mem.indexOf(u8, all, "drops markup character *") != null);
    try testing.expect(std.mem.indexOf(u8, all, "changes inline structure") != null);

    // Meta prose around the verbatim input is not a rewrite.
    c = try guard(a, .spicy, "one-line hot take", false, "the boring database that actually ships", "Sure! Here is the take: the boring database that actually ships.");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "wraps the input") != null);

    // Topic drift keeps too few content words.
    c = try guard(a, .spicy, "r", false, "the boring database that actually ships", "an entirely unrelated remark about the weather");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "keeps only") != null);

    // Invalid UTF-8 must never reach the result object.
    c = try guard(a, .spicy, "r", false, "the boring database", "the \xf0\x28 boring database");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "invalid UTF-8") != null);

    // A trailing `!` is fine mid-table, fatal right before a footnote marker.
    c = try guard(a, .feral, "r", false, "it just works", "it just works, dammit!");
    try testing.expect(c.passes());
    c = try guard(a, .feral, "r", true, "it just works", "it just works, dammit!");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "ends with ! where a footnote marker follows") != null);
}

test "mock voice pass changes every sample, keeps structure and other values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const root = testRoot();
    var ctx: Ctx = .{
        .arena = a,
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = try std.fmt.allocPrint(a, "{s}templates", .{root}),
        .store_dir = "",
        .project_root = "",
    };
    inline for (.{ "verdict", "apparatus", "release-notes", "reading-note" }) |id| {
        const sample = try readTest(a, "data/" ++ id ++ ".sample.json");
        inline for (.{ Tone.mild, Tone.spicy, Tone.feral }) |tone| {
            const r = try voiceData(&ctx, id, sample, tone, .mock);
            try testing.expect(r.changed > 0);
            try testing.expectEqual(@as(usize, 0), r.rejected());
            // Putting every original value back gives the input exactly.
            var orig = try std.json.parseFromSliceLeaky(Value, a, sample, .{ .parse_numbers = false });
            var voiced = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, r.data, .{}), .{ .parse_numbers = false });
            const shape = try std.json.parseFromSliceLeaky(Value, a, try readTest(a, "templates/shapes/" ++ id ++ ".json"), .{});
            const os = try collect(a, id, shape, &orig);
            const vs = try collect(a, id, shape, &voiced);
            try testing.expectEqual(os.len, vs.len);
            for (os, vs) |o, v| v.ptr.* = o.ptr.*;
            try testing.expectEqualStrings(
                try std.json.Stringify.valueAlloc(a, orig, .{}),
                try std.json.Stringify.valueAlloc(a, voiced, .{}),
            );
        }
    }
    try testing.expectError(error.ToolFailed, voiceData(&ctx, "verdict", "{}", .spicy, .spark));
    try testing.expect(std.mem.indexOf(u8, ctx.err_msg, "MODEL_API_KEY") != null);
}

test "a guard failure keeps the original; a budget overrun only warns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "voice/mock");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "voice/mock/spicy.jsonl", .data =
        \\{"template": "verdict", "field": "take", "field_role": "r", "input": "the boring cache", "output": "the boring cache, 4 stars"}
        \\{"template": "verdict", "field": "bottom_line", "field_role": "r", "input": "Ship it.", "output": "Ship the damn thing, hell yes."}
        \\
    });
    var env: std.process.Environ.Map = .init(a);
    try env.put("KNAP_PROMPTS_DIR", try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var ctx: Ctx = .{
        .arena = a,
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = try std.fmt.allocPrint(a, "{s}templates", .{testRoot()}),
        .store_dir = "",
        .project_root = "",
    };
    const r = try voiceData(&ctx, "verdict", "{\"year\":1.50,\"take\":\"the boring cache\",\"bottom_line\":\"Ship it.\",\"title\":\"\"}", .spicy, .mock);
    try testing.expectEqual(@as(usize, 1), r.changed);
    try testing.expectEqual(@as(usize, 2), r.fields.len);
    try testing.expectEqual(Status.rejected, r.fields[0].status);
    try testing.expectEqualStrings("the boring cache", r.fields[0].after);
    try testing.expectEqualStrings("adds number 4", r.fields[0].reasons[0]);
    try testing.expectEqual(Status.rewritten, r.fields[1].status);
    try testing.expectEqualStrings("warning: spicy: 2 profanity words, max 1", r.fields[1].reasons[0]);
    try testing.expectEqualStrings(
        "{\"year\":1.50,\"take\":\"the boring cache\",\"bottom_line\":\"Ship the damn thing, hell yes.\",\"title\":\"\"}",
        try std.json.Stringify.valueAlloc(a, r.data, .{}),
    );
}
