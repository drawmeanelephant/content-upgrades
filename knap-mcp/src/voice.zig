//! The voice pass behind `knap_voice`: rewrite the `voice: true` string
//! values of a data object in one tone, one model call per value, and keep
//! a rewrite only if it passes the fact guard. The template never changes,
//! so every tone renders with the same structure modulo the inline
//! formatting the reply is allowed to insert (`structhash --ignore-formatting`
//! is the cross-tone proof).
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
    if (backend.needsKey(kind) and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("knap_voice: backend '{s}' needs MODEL_API_KEY (use --backend mock for canned replies)", .{@tagName(kind)});

    const slots = try collect(a, template_id, shape, &data);
    const dir = promptsDir(ctx);
    const tone_name = @tagName(tone);
    var mock_lines: []const u8 = "";
    if (kind == .mock)
        mock_lines = try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "mock/{s}.jsonl", .{tone_name}));
    const system = try systemPrompt(ctx, kind, tone);

    var fields: std.ArrayList(Field) = .empty;
    var changed: usize = 0;
    for (slots) |slot| {
        const before = slot.ptr.string;
        const raw: ?[]const u8 = if (kind == .mock) blk: {
            ctx.countCall(system, try userMessage(a, slot.path, slot.role, before));
            break :blk mockReply(a, mock_lines, template_id, slot.path, before) catch
                return ctx.fail("voice mock/{s}.jsonl has a bad line", .{tone_name});
        } else backend.complete(ctx, kind, .voice, system, try userMessage(a, slot.path, slot.role, before)) catch |e| switch (e) {
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

/// The system prompt for `tone`. Live kinds need every voice prompt file.
/// Mock calls are counted, not sent: the prefix a live call would carry,
/// when the prompts dir has it (eval/voice's private KNAP_PROMPTS_DIR
/// controls ship only mock lines), else "".
fn systemPrompt(ctx: *Ctx, kind: backend.Kind, tone: Tone) backend.Error![]const u8 {
    const a = ctx.arena;
    const dir = promptsDir(ctx);
    const tone_name = @tagName(tone);
    if (kind == .mock) {
        if (mockVoiceSystem(ctx, a, dir, tone_name)) |s| return s else |_| {
            ctx.err_msg = "";
            return "";
        }
    }
    return assembleSystem(
        a,
        try readPrompt(ctx, dir, "system.md"),
        try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "{s}.md", .{tone_name})),
        try readPrompt(ctx, dir, try std.fmt.allocPrint(a, "examples/{s}.jsonl", .{tone_name})),
    ) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("voice examples/{s}.jsonl has a bad line ({s})", .{ tone_name, @errorName(e) }),
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
    footnote_abutting: bool = false,
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
    embed,
    footnote_ref,
    quote,
    number,
    name,
    acronym,
    proper_noun,
    include,
    component,

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
            .url, .wikilink, .embed, .footnote_ref, .quote, .include, .component => true,
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

/// A URL token ends at whitespace, a quote, `<`, `>`, `)` or a
/// backtick — so a code span may quote the input's URL (W6, #334).
/// Trailing `.,;:!?` is trimmed: that is the sentence's punctuation,
/// not the target's — `script: https://x/b` and `script, https://x/b,`
/// carry the same URL (dogbed renders bare URLs as text, and linkifiers
/// exclude trailing punctuation from the target). The trim is the
/// documented rule (prompts/voice/README.md); it may change.
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
        while (scheme > 0 and e < s.len and std.mem.indexOfScalar(u8, " \t\"'<>`)", s[e]) == null) e += 1;
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

/// `<Aside …>`/`<Details …>` open tags and `</Aside>`/`</Details>`
/// closes: one atom per tag, so a reply can neither rewrap a component
/// nor slip markup inside the tag text. An unterminated tag protects the
/// rest of the string, like an unclosed span.
fn components(a: Allocator, s: []const u8, f: *Facts) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |p| {
        i = p + 1;
        const end = componentEnd(s, p) orelse continue;
        try f.put(a, s[p..end], .component);
        i = end;
    }
}

/// End of the `<Aside …>`/`</Details>` tag starting at s[p] == '<', or
/// null when no component tag starts there.
fn componentEnd(s: []const u8, p: usize) ?usize {
    var rest = s[p + 1 ..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    const name_len: usize = if (std.mem.startsWith(u8, rest, "Aside"))
        "Aside".len
    else if (std.mem.startsWith(u8, rest, "Details"))
        "Details".len
    else
        return null;
    const bound: u8 = if (name_len < rest.len) rest[name_len] else 0;
    if (bound != 0 and std.mem.indexOfScalar(u8, " \t>/", bound) == null) return null;
    var q: u8 = 0;
    var j = p;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') break;
    }
    return @min(j + 1, s.len);
}

fn facts(a: Allocator, s: []const u8) !Facts {
    var f: Facts = .{};
    try urls(a, s, &f);
    try spans(a, s, &f, "![[", "]]", .embed);
    try spans(a, s, &f, "[[", "]]", .wikilink);
    try spans(a, s, &f, "[^", "]", .footnote_ref);
    try spans(a, s, &f, "{{", "}}", .include);
    try components(a, s, &f);
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
/// Locked markup characters: a reply may neither add nor drop them. `$` is
/// locked because dogbed renders `$…$` as math and structhash cannot see it.
const locked_markup = "_|#<>[]{}^@\\\"$";
/// The characters a reply may insert as inline formatting, subject to the
/// delimiter accounting (W2) and the plain-slot rule (W4). Dropping them
/// stays a hard failure.
const insertable = "*`~=";

fn listed(list: []const []const u8, w: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn budgetOf(tone: Tone) struct { prof: usize, caps: usize, bang: usize, spans: usize, emoji: usize } {
    return switch (tone) {
        .mild => .{ .prof = 0, .caps = 0, .bang = 0, .spans = 1, .emoji = 0 },
        .spicy => .{ .prof = 1, .caps = 1, .bang = 1, .spans = 2, .emoji = 1 },
        .feral => .{ .prof = 2, .caps = 3, .bang = 2, .spans = 3, .emoji = 2 },
    };
}

fn startsWithBlockMarker(s: []const u8) bool {
    if (s.len >= 2 and std.mem.indexOfScalar(u8, "-+*=>#", s[0]) != null and s[1] == ' ') return true;
    if (std.mem.startsWith(u8, s, "---")) return true;
    // Fences: a value starting ``` or ~~~ opens a code block.
    if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) return true;
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

/// Roles whose rendered context already supplies the styling or swallows
/// the markup: verdicts (`| bold` + frontmatter), h1/frontmatter titles,
/// `| italic` deck lines, image alt text. A reply in a plain slot may add
/// no formatting and no emoji (W4). The markers are matched on normalized
/// words — lowercase, split on non-alphanumerics — so `ALT TEXT` and
/// `frontmatter tags` match but `rendered boldly` and `image alt` don't.
fn plainRole(role: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    var prev: []const u8 = "";
    var i: usize = 0;
    while (i < role.len) {
        while (i < role.len and !isAlnum(role[i])) i += 1;
        const p = i;
        while (i < role.len and isAlnum(role[i])) i += 1;
        const w = role[p..i];
        if (w.len == 0) break;
        if (eq(w, "frontmatter") or
            (eq(prev, "rendered") and (eq(w, "bold") or eq(w, "italic") or eq(w, "highlight"))) or
            (eq(prev, "alt") and eq(w, "text")) or
            (eq(prev, "page") and eq(w, "heading"))) return true;
        prev = w;
    }
    return false;
}

const Cp = struct { cp: u21, len: usize };

/// The code point starting at s[i], or the byte itself when the input is
/// not valid UTF-8 (the guard already reports that separately).
fn nextCp(s: []const u8, i: usize) Cp {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn containsCp(s: []const u8, cp: u21) bool {
    var i: usize = 0;
    while (i < s.len) {
        const d = nextCp(s, i);
        if (d.cp == cp) return true;
        i += d.len;
    }
    return false;
}

/// Unicode White_Space — so a word cap cannot be evaded by joining the
/// words with NBSP, thin space or friends instead of U+0020 (#334).
fn isWordSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680 => true,
        0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Words are runs separated by any Unicode whitespace.
fn wordCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var in_word = false;
    while (i < s.len) {
        const d = nextCp(s, i);
        if (isWordSpace(d.cp)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
        i += d.len;
    }
    return n;
}

/// The emoji allowlist: a named set — the listed dingbats plus a short
/// curated pictograph list. Each may be followed by U+FE0F. A named
/// list, not blocks, so a new emoji needs an explicit entry here.
const allowed_emoji = [_]u21{
    0x2728, 0x26A1, 0x26A0, 0x2705, 0x274C, 0x2615, // ✨ ⚡ ⚠ ✅ ❌ ☕
    0x1F525, 0x1F480, 0x1F644, 0x1F381, 0x1FAA3, 0x1F3DB, // 🔥 💀 🙄 🎁 🪣 🏛
    0x1F680, 0x1F41B, 0x1F389, 0x1F4C9, // 🚀 🐛 🎉 📉
};

fn isAllowedEmoji(cp: u21) bool {
    for (allowed_emoji) |e| if (e == cp) return true;
    return false;
}

/// Everything else in the emoji blocks: the gestures, faces, food,
/// weapons, blood and skin tones a block allowlist used to admit.
fn isDisallowedEmoji(cp: u21) bool {
    return cp >= 0x1F000 and cp <= 0x1FAFF;
}

fn isInvisible(cp: u21) bool {
    return cp == 0x200D or cp == 0x00AD or
        (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2060 and cp <= 0x2064) or
        (cp >= 0x2066 and cp <= 0x2069) or
        cp == 0xFEFF;
}

const CpClass = enum { text, emoji, disallowed, symbol, invisible, bang_pair };

fn classifyCp(cp: u21) CpClass {
    if (isInvisible(cp)) return .invisible;
    if (cp == 0x203C or cp == 0x2049) return .bang_pair; // ‼ and ⁉ read as !!
    // The allowlist wins first: every allowlisted code point sits inside
    // the emoji blocks isDisallowedEmoji covers.
    if (isAllowedEmoji(cp)) return .emoji;
    if (isDisallowedEmoji(cp)) return .disallowed;
    // Any other astral code point (fake bold, flags, tags) or a non-allowlist
    // dingbat. Ordinary non-ASCII (—, ’, é, …) stays allowed.
    if (cp >= 0x10000 or (cp >= 0x2600 and cp <= 0x27BF)) return .symbol;
    return .text;
}

/// UTF-8 length of `s` with `*`, `` ` ``, `~`, `=`, allowed emoji and VS16
/// left out: the length bounds measure the text, not its formatting.
fn textLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = nextCp(s, i);
        i += d.len;
        if (d.len == 1 and (d.cp == '*' or d.cp == '`' or d.cp == '~' or d.cp == '=')) continue;
        if (d.cp == 0xFE0F) continue;
        if (isAllowedEmoji(d.cp)) continue;
        n += d.len;
    }
    return n;
}

fn runLenAt(s: []const u8, i: usize) usize {
    var n: usize = 0;
    while (i + n < s.len and s[i + n] == s[i]) n += 1;
    return n;
}

// Content-word sets and stemming: verifier.zig's tokenizer, re-implemented
// here because its helpers are private. `verifier.normalize` is reused.
const verifier = @import("verifier.zig");

const stopwords = [_][]const u8{
    "a",     "an",    "the",   "and",    "or",    "but",   "of",   "to",   "in",
    "on",    "at",    "for",   "by",     "with",  "from",  "as",   "is",   "are",
    "was",   "were",  "be",    "been",   "being", "it",    "its",  "this", "that",
    "these", "those", "has",   "have",   "had",   "do",    "does", "did",  "will",
    "would", "can",   "could", "should", "may",   "might", "must", "so",   "than",
    "then",  "there", "their", "they",   "them",  "we",    "our",  "you",  "your",
    "he",    "she",   "his",   "her",    "i",     "me",    "my",   "if",   "into",
    "about", "just",  "also",  "any",    "some",  "each",  "very", "too",  "which",
    "who",   "whom",  "what",  "when",   "where", "how",   "why",  "s",    "t",
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

/// Two stems match when equal or when one is a ≥4-byte prefix of the
/// other — the crude stemmer misses doubled-consonant inflections
/// (`shipped` → `shipp` where the input has `ships` → `ship`).
fn sameStem(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const m = @min(a.len, b.len);
    return m >= 4 and std.mem.eql(u8, a[0..m], b[0..m]);
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

/// `so` is `si` with only inline-formatting tokens inserted (W1). Kinds
/// only: an inserted opener shifts the depth of everything inside it. The
/// input's skeleton must survive in order; every extra token must be
/// formatting, so a code span can't swallow a `[^1]` or a `**`, and a
/// wikilink, link or `delim:` run can never appear.
fn insertOnly(si: []const structhash.Token, so: []const structhash.Token) bool {
    var j: usize = 0;
    for (so) |t| {
        if (j < si.len and std.mem.eql(u8, t.kind, si[j].kind)) {
            j += 1;
        } else if (!structhash.isFormatting(t.kind)) return false;
    }
    return j == si.len;
}

fn opened(toks: []const structhash.Token, kind: []const u8) isize {
    var n: isize = 0;
    for (toks) |t| n += @intFromBool(std.mem.eql(u8, t.kind, kind));
    return n;
}

/// voice.awk's W3 code-span mask: every byte of a `` `…` `` span becomes
/// `x` so a `~~` quoted in code can't pair as a strike. The mask keeps
/// `out`'s length so positions line up — the strike inner is then read
/// from `out` itself, and a strike around a code span quoting input
/// words can't hide its contents behind the mask. An unclosed backtick
/// stays literal.
fn hideCodeSpans(a: Allocator, out: []const u8) Allocator.Error![]const u8 {
    var hid: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, out, i + 1, '`')) |j| {
                try hid.appendNTimes(a, 'x', j + 1 - i);
                i = j + 1;
                continue;
            }
        }
        try hid.append(a, out[i]);
        i += 1;
    }
    return hid.items;
}

/// May a `~~inner~~` span stand in the reply? It may not retract anything
/// the input said: no number token at all, none of the input's protected
/// tokens, no negation, and no word sharing a stem with an input content
/// word (exact stems plus inflections the crude stemmer misses). Returns
/// the offending token when the inner retracts input content, else null.
fn strikeInnerBad(a: Allocator, inner: []const u8, fi: *const Facts, ci: []const []const u8) Allocator.Error!?[]const u8 {
    var nf: Facts = .{};
    try numbers(a, inner, &nf);
    if (nf.list.items.len > 0) return nf.list.items[0].text;
    for (fi.list.items) |t| if (present(inner, t)) return t.text;
    var i: usize = 0;
    while (i < inner.len) {
        if (!std.ascii.isAlphabetic(inner[i])) {
            i += 1;
            continue;
        }
        const p = i;
        while (i < inner.len and std.ascii.isAlphabetic(inner[i])) i += 1;
        const w = try std.ascii.allocLowerString(a, inner[p..i]);
        if (listed(&negations, w)) return w;
    }
    for (try contentWords(a, inner)) |w| {
        for (ci) |c| if (sameStem(w, c)) return w;
    }
    return null;
}

/// True when `out` adds an HTML entity (`&#…;` or `&name;`) the input
/// doesn't have: entities smuggle `*` and emoji past the markup checks.
fn addsEntity(in_: []const u8, out: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out, i, '&')) |p| {
        var j = p + 1;
        if (j < out.len and out[j] == '#') {
            j += 1;
            const d0 = j;
            while (j < out.len and std.ascii.isDigit(out[j])) j += 1;
            if (j > d0 and j < out.len and out[j] == ';') {
                if (std.mem.indexOf(u8, in_, out[p .. j + 1]) == null) return true;
            }
        } else {
            while (j < out.len and isAlnum(out[j])) j += 1;
            if (j > p + 1 and j < out.len and out[j] == ';') {
                if (std.mem.indexOf(u8, in_, out[p .. j + 1]) == null) return true;
            }
        }
        i = p + 1;
    }
    return false;
}

pub const Check = struct {
    /// Hard rules (facts, markup both directions, structure, overlap,
    /// length, UTF-8), plus profanity, formatting-span and emoji
    /// overruns in a mild reply. Any entry keeps the original value.
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

    for (locked_markup) |m| {
        const ni = std.mem.count(u8, in_, &[1]u8{m});
        const no = std.mem.count(u8, out, &[1]u8{m});
        if (no > ni) try H.add(a, &c.hard, "adds markup character {c}", .{m});
        if (no < ni) try H.add(a, &c.hard, "drops markup character {c}", .{m});
    }
    for (insertable) |m| {
        if (std.mem.count(u8, out, &[1]u8{m}) < std.mem.count(u8, in_, &[1]u8{m}))
            try H.add(a, &c.hard, "drops markup character {c}", .{m});
    }

    // A dropped non-ASCII code point — an emoji the input carried, a
    // curly quote, an accent — is a removal like a dropped markup char.
    {
        var seen: std.ArrayList(u21) = .empty;
        var ci: usize = 0;
        while (ci < in_.len) {
            const d = nextCp(in_, ci);
            ci += d.len;
            if (d.cp < 0x80) continue;
            var dup = false;
            for (seen.items) |s| dup = dup or s == d.cp;
            if (dup) continue;
            try seen.append(a, d.cp);
            if (!containsCp(out, d.cp))
                try H.add(a, &c.hard, "drops non-ASCII character U+{X:0>4}", .{d.cp});
        }
    }

    // W1: the input's inline skeleton survives in order; the reply may only
    // insert formatting tokens (a code span hiding `[^1]` still fails here).
    const si = try structhash.skeletonOpts(a, in_, .markdown, .{});
    const so = try structhash.skeletonOpts(a, out, .markdown, .{});
    if (!insertOnly(si, so)) try H.add(a, &c.hard, "changes inline structure", .{});

    // W2: every added `*`, `` ` ``, `~` and `=` is accounted for by a
    // resolved span. A lone space-flanked `*` or `==`, an unclosed
    // backtick, a single `~` or a multi-backtick span emits no token, so
    // W1 alone accepts them.
    const a_star = @as(isize, @intCast(std.mem.count(u8, out, "*"))) - @as(isize, @intCast(std.mem.count(u8, in_, "*")));
    const a_bt = @as(isize, @intCast(std.mem.count(u8, out, "`"))) - @as(isize, @intCast(std.mem.count(u8, in_, "`")));
    const a_tilde = @as(isize, @intCast(std.mem.count(u8, out, "~"))) - @as(isize, @intCast(std.mem.count(u8, in_, "~")));
    const a_eq = @as(isize, @intCast(std.mem.count(u8, out, "="))) - @as(isize, @intCast(std.mem.count(u8, in_, "=")));
    const d_strong = opened(so, "strong") - opened(si, "strong");
    const d_em = opened(so, "em") - opened(si, "em");
    const d_del = opened(so, "del") - opened(si, "del");
    const d_hl = opened(so, "hl") - opened(si, "hl");
    const d_code = opened(so, "code") - opened(si, "code");
    if (a_star != 4 * d_strong + 2 * d_em) try H.add(a, &c.hard, "unbalanced *", .{});
    if (a_bt != 2 * d_code) try H.add(a, &c.hard, "unbalanced `", .{});
    if (a_tilde != 4 * d_del) try H.add(a, &c.hard, "unbalanced ~", .{});
    if (a_eq != 4 * d_hl) try H.add(a, &c.hard, "unbalanced =", .{});

    const ci = try contentWords(a, in_);

    // W3: a strike retracts meaning, so `~~` may only surround words the
    // reply itself added — no input fact, negation or content word. Code
    // spans are masked for the pairing scan so a quoted `~~` can't open
    // a strike; the inner is judged on `out` itself.
    {
        const hid = try hideCodeSpans(a, out);
        var open: ?usize = null;
        var i: usize = 0;
        while (i < hid.len) {
            if (hid[i] != '~') {
                i += 1;
                continue;
            }
            const n = runLenAt(hid, i);
            if (n != 2) {
                i += n;
                continue;
            }
            if (open == null) {
                open = i + 2;
                i += 2;
                continue;
            }
            const inner = out[open.?..i];
            open = null;
            i += 2;
            const span = try std.fmt.allocPrint(a, "~~{s}~~", .{inner});
            if (std.mem.indexOf(u8, in_, span) != null) continue;
            if (try strikeInnerBad(a, inner, &fi, ci)) |bad|
                try H.add(a, &c.hard, "strikes input words: {s}", .{bad});
        }
    }

    // The emoji scan feeds both W4 (plain slots take no emoji) and W5.
    var n_emoji: usize = 0;
    var emoji_reasons: std.ArrayList([]const u8) = .empty;
    {
        var prev_allowed_emoji = false;
        var i: usize = 0;
        while (i < out.len) {
            const d = nextCp(out, i);
            defer i += d.len;
            if (d.cp < 0x80 or containsCp(in_, d.cp)) {
                prev_allowed_emoji = isAllowedEmoji(d.cp);
                continue;
            }
            defer prev_allowed_emoji = isAllowedEmoji(d.cp);
            if (d.cp == 0xFE0F) {
                if (!prev_allowed_emoji)
                    try emoji_reasons.append(a, "adds invisible character U+FE0F");
                continue;
            }
            switch (classifyCp(d.cp)) {
                .emoji => n_emoji += 1,
                .disallowed => try emoji_reasons.append(a, try std.fmt.allocPrint(a, "adds disallowed emoji U+{X:0>4}", .{d.cp})),
                .symbol => try emoji_reasons.append(a, try std.fmt.allocPrint(a, "adds symbol U+{X:0>4}", .{d.cp})),
                .invisible => try emoji_reasons.append(a, try std.fmt.allocPrint(a, "adds invisible character U+{X:0>4}", .{d.cp})),
                .bang_pair => try emoji_reasons.append(a, "adds !!"),
                .text => {},
            }
        }
    }

    // W4: plain slots stay plain — no added formatting and no added emoji.
    if (plainRole(role) and (a_star != 0 or a_bt != 0 or a_tilde != 0 or a_eq != 0 or n_emoji != 0))
        try H.add(a, &c.hard, "formatting in a plain slot", .{});
    try c.hard.appendSlice(a, emoji_reasons.items);

    // W6: an added code span may only quote text the input already has,
    // and may not wrap the entire input verbatim (that adds markup
    // without rewording anything).
    {
        var i: usize = 0;
        while (i < out.len) {
            if (out[i] != '`') {
                i += 1;
                continue;
            }
            const n = runLenAt(out, i);
            i += n;
            if (n != 1) continue;
            const j = std.mem.indexOfScalarPos(u8, out, i, '`') orelse break;
            if (std.mem.eql(u8, out[i..j], in_))
                try H.add(a, &c.hard, "code span wraps the whole input", .{})
            else if (std.mem.indexOf(u8, in_, out[i..j]) == null)
                try H.add(a, &c.hard, "code span text not in the input", .{});
            i = j + 1;
        }
    }

    // `![` is raw adjacency (`!**[^1]**` is fine); `!!`/`??` are checked on
    // the text projection so `wow!**!**` is still caught.
    if (std.mem.indexOf(u8, out, "![") != null and std.mem.indexOf(u8, in_, "![") == null)
        try H.add(a, &c.hard, "adds ![ (renders as image syntax)", .{});
    {
        var pi: std.ArrayList(u8) = .empty;
        var po: std.ArrayList(u8) = .empty;
        for (in_) |ch| if (ch != '*' and ch != '`' and ch != '~' and ch != '=') try pi.append(a, ch);
        for (out) |ch| if (ch != '*' and ch != '`' and ch != '~' and ch != '=') try po.append(a, ch);
        inline for (.{ "!!", "??" }) |pair| {
            if (std.mem.indexOf(u8, po.items, pair) != null and std.mem.indexOf(u8, pi.items, pair) == null)
                try H.add(a, &c.hard, "adds " ++ pair, .{});
        }
    }
    if (addsEntity(in_, out)) try H.add(a, &c.hard, "adds HTML entity", .{});
    if (footnote_abutting and std.mem.endsWith(u8, out, "!"))
        try H.add(a, &c.hard, "ends with ! where a footnote marker follows (renders as image syntax)", .{});
    if (startsWithBlockMarker(out)) try H.add(a, &c.hard, "starts with a block marker", .{});

    const li = textLen(in_);
    const lo = (li + 1) / 2;
    const hi = @max(2 * li, li + 40);
    const o_len = textLen(out);
    if (o_len < lo) try H.add(a, &c.hard, "too short: {d} bytes, min {d}", .{ o_len, lo });
    if (o_len > hi) try H.add(a, &c.hard, "too long: {d} bytes, max {d}", .{ o_len, hi });
    if (std.mem.indexOf(u8, role, "one-word") != null or std.mem.indexOf(u8, role, "four word") != null) {
        const nw = wordCount(out);
        if (nw > 4) try H.add(a, &c.hard, "word-limited role, {d} words, max 4", .{nw});
    }

    // A rewrite must reword the value, not abandon it or wrap it in meta
    // prose: keep at least half the input's content words, and no reply
    // that contains the input verbatim may lead with two or more content
    // words the input lacks ("Sure! Here is the take: ...").
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
    const nspans: usize = @intCast(@max(0, d_strong + d_em + d_del + d_hl));
    // Mild is the conservative tone: its formatting-span and emoji
    // overruns are hard failures, not advisory like the other budgets.
    if (nspans > max.spans)
        try H.add(a, if (tone == .mild) &c.hard else &c.budget, "{s}: {d} formatting spans, max {d}", .{ name, nspans, max.spans });
    if (tone == .mild and d_strong + d_del + d_hl > 0)
        try H.add(a, &c.hard, "mild: only *italic*", .{});
    if (n_emoji > max.emoji)
        try H.add(a, if (tone == .mild) &c.hard else &c.budget, "{s}: {d} emoji, max {d}", .{ name, n_emoji, max.emoji });
    return c;
}

// --- doc-level pass (FILED-VOICE, #257) ------------------------------------
//
// A filed record has no data object: it is the doc. The doc pass walks
// prose paragraphs and list-item text runs, sends each one through the
// field prompt contract and guard, and copies every other byte verbatim.
// Frozen by construction: frontmatter, headings, fences, `$$` blocks,
// quotes and callouts, tables, html and `<Aside>`/`<Details>` blocks,
// footnote and link definitions, `{{include}}`/embed lines, and every
// multi-line line group (verse: haiku and limerick lines are not
// paragraphs). Whole-doc invariants are then proven on the patched text;
// a doc that can't prove them is never written.

const frontmatter = @import("frontmatter.zig");
const density = @import("density.zig");

pub const RunKind = enum {
    paragraph,
    list_item,

    /// The policy region name (policy.Region) this run kind falls under.
    pub fn region(k: RunKind) []const u8 {
        return switch (k) {
            .paragraph => "paragraphs",
            .list_item => "list_items",
        };
    }
};

/// The run kinds the doc's collection policy grants for the tone
/// (`policy.voiceAllowed`). Both false denies the doc outright.
pub const Gate = struct {
    paragraphs: bool = false,
    list_items: bool = false,

    fn allows(g: Gate, k: RunKind) bool {
        return switch (k) {
            .paragraph => g.paragraphs,
            .list_item => g.list_items,
        };
    }
};

/// One rewritable text run: doc[lo..hi] is the paragraph text or the
/// list item's text after its marker, without line-edge whitespace.
pub const Run = struct { kind: RunKind, lo: usize, hi: usize, line: u32 };

pub const Walk = struct {
    runs: []const Run,
    /// Multi-line plain line groups (verse, soft-wrapped label blocks).
    line_groups: usize = 0,
    /// Every other block, copied verbatim.
    frozen_blocks: usize = 0,
};

const DocLine = struct { lo: usize, end: usize, no: u32 };

/// Multi-line verbatim blocks that may contain blank lines.
const BlockState = struct {
    fence_ch: u8 = 0,
    fence_n: usize = 0,
    math: bool = false,
    components: usize = 0,
    raw_close: ?[]const u8 = null,

    const Step = enum { none, opened, inside };

    fn step(st: *BlockState, line: []const u8) Step {
        const t = std.mem.trim(u8, line, " \t");
        if (st.fence_ch != 0) {
            const n = runLenAt(t, 0);
            if (t.len > 0 and t[0] == st.fence_ch and n >= st.fence_n and n == t.len) st.fence_ch = 0;
            return .inside;
        }
        if (st.math) {
            if (std.mem.endsWith(u8, t, "$$")) st.math = false;
            return .inside;
        }
        if (st.raw_close) |c| {
            if (std.ascii.findIgnoreCase(t, c) != null) st.raw_close = null;
            return .inside;
        }
        if (st.components > 0) {
            st.components = componentDepth(t, st.components);
            return .inside;
        }
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
            st.fence_ch = t[0];
            st.fence_n = runLenAt(t, 0);
            return .opened;
        }
        if (std.mem.startsWith(u8, t, "$$")) {
            st.math = !(t.len >= 4 and std.mem.endsWith(u8, t, "$$"));
            return .opened;
        }
        if (t.len > 0 and t[0] == '<') {
            if (componentEnd(t, 0) != null) {
                st.components = componentDepth(t, 0);
                return .opened;
            }
            inline for (.{ .{ "<!--", "-->" }, .{ "<pre", "</pre>" }, .{ "<script", "</script>" }, .{ "<style", "</style>" }, .{ "<textarea", "</textarea>" } }) |pair| {
                if (std.ascii.startsWithIgnoreCase(t, pair[0])) {
                    if (std.ascii.findIgnoreCase(t[pair[0].len..], pair[1]) == null) st.raw_close = pair[1];
                    return .opened;
                }
            }
        }
        return .none;
    }
};

/// Component nesting depth after `t`, starting from `depth`.
fn componentDepth(t: []const u8, depth: usize) usize {
    var d = depth;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, t, i, '<')) |p| {
        i = p + 1;
        const end = componentEnd(t, p) orelse continue;
        const tag = t[p..end];
        if (tag.len > 1 and tag[1] == '/') {
            d -|= 1;
        } else if (!std.mem.endsWith(u8, tag, "/>")) d += 1;
        i = end;
    }
    return d;
}

fn isThematic(t: []const u8) bool {
    if (t.len < 3 or std.mem.indexOfScalar(u8, "-*_", t[0]) == null) return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == t[0]) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

/// [lo, hi) of a list item's text inside `line` (offsets into `line`), or
/// null when the line isn't a single-line `-`/`+`/`*`/`1.`/`1)` item.
fn listItemText(line: []const u8) ?[2]usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (isThematic(std.mem.trim(u8, line, " \t"))) return null;
    var m = i;
    if (m < line.len and std.mem.indexOfScalar(u8, "-+*", line[m]) != null) {
        m += 1;
    } else {
        while (m < line.len and m - i < 9 and std.ascii.isDigit(line[m])) m += 1;
        if (m == i or m >= line.len or (line[m] != '.' and line[m] != ')')) return null;
        m += 1;
    }
    if (m >= line.len or line[m] != ' ') return null;
    var s = m;
    while (s < line.len and line[s] == ' ') s += 1;
    // Five or more spaces after the marker start an indented code block.
    if (s - m > 4) return null;
    const hi = std.mem.trimEnd(u8, line, " \t").len;
    if (hi <= s) return null;
    return .{ s, hi };
}

/// A line that can only be prose: no block marker, link or footnote
/// definition, include/embed line, setext underline or indented code.
fn plainLine(line: []const u8) bool {
    if (line.len > 0 and line[0] == '\t') return false;
    var ind: usize = 0;
    while (ind < line.len and line[ind] == ' ') ind += 1;
    if (ind >= 4) return false;
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0 or listItemText(line) != null or isThematic(t)) return false;
    if (std.mem.indexOfScalar(u8, "#>|<=-:", t[0]) != null) return false;
    if (t[0] == '[' and !std.mem.startsWith(u8, t, "[[")) return false;
    inline for (.{ "{{", "![", "$$", "```", "~~~" }) |p| {
        if (std.mem.startsWith(u8, t, p)) return false;
    }
    return true;
}

/// The doc's rewritable runs, in order. Conservative on purpose: a line
/// group that is not a single plain paragraph line or a run of
/// single-line list items is frozen whole.
pub fn docWalk(a: Allocator, doc: []const u8) Allocator.Error!Walk {
    const body: usize = if (try frontmatter.parse(a, doc)) |fm| fm.hi else 0;
    var w: Walk = .{ .runs = &.{} };
    var runs: std.ArrayList(Run) = .empty;
    var group: std.ArrayList(DocLine) = .empty;
    var st: BlockState = .{};
    var line_no: u32 = 1 + @as(u32, @intCast(std.mem.count(u8, doc[0..body], "\n")));
    var pos = body;
    while (pos < doc.len) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, doc, pos, '\n') orelse doc.len;
        const end = if (nl > pos and doc[nl - 1] == '\r') nl - 1 else nl;
        const text = doc[pos..end];
        switch (st.step(text)) {
            .none => if (std.mem.trim(u8, text, " \t").len == 0)
                try classify(a, doc, &group, &runs, &w)
            else
                try group.append(a, .{ .lo = pos, .end = end, .no = line_no }),
            .opened => {
                try classify(a, doc, &group, &runs, &w);
                w.frozen_blocks += 1;
            },
            .inside => {},
        }
        pos = nl + 1;
    }
    try classify(a, doc, &group, &runs, &w);
    w.runs = runs.items;
    return w;
}

fn classify(a: Allocator, doc: []const u8, group: *std.ArrayList(DocLine), runs: *std.ArrayList(Run), w: *Walk) Allocator.Error!void {
    const lines = group.items;
    defer group.clearRetainingCapacity();
    if (lines.len == 0) return;
    const all_items = for (lines) |l| {
        if (listItemText(doc[l.lo..l.end]) == null) break false;
    } else true;
    if (all_items) {
        for (lines) |l| {
            const r = listItemText(doc[l.lo..l.end]).?;
            if (!plainLine(doc[l.lo + r[0] .. l.lo + r[1]])) continue;
            try runs.append(a, .{ .kind = .list_item, .lo = l.lo + r[0], .hi = l.lo + r[1], .line = l.no });
        }
        return;
    }
    for (lines) |l| if (!plainLine(doc[l.lo..l.end])) {
        w.frozen_blocks += 1;
        return;
    };
    if (lines.len > 1) {
        w.line_groups += 1;
        return;
    }
    const l = lines[0];
    const t = doc[l.lo..l.end];
    const lead = t.len - std.mem.trimStart(u8, t, " ").len;
    try runs.append(a, .{ .kind = .paragraph, .lo = l.lo + lead, .hi = l.lo + std.mem.trimEnd(u8, t, " \t").len, .line = l.no });
}

/// Protected atoms of `s` in document order: URLs, embeds, wikilinks,
/// footnote refs, `{{…}}` includes and component tags — the boris-aware
/// set the guard freezes (#254). An unclosed span protects the rest.
pub fn atomList(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const rest = s[i..];
        const end: ?usize = blk: {
            inline for (.{ .{ "![[", "]]" }, .{ "[[", "]]" }, .{ "[^", "]" }, .{ "{{", "}}" } }) |p| {
                if (std.mem.startsWith(u8, rest, p[0])) {
                    const q = std.mem.indexOf(u8, rest[p[0].len..], p[1]) orelse break :blk rest.len;
                    break :blk p[0].len + q + p[1].len;
                }
            }
            if (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://")) {
                var e: usize = 0;
                while (e < rest.len and std.mem.indexOfScalar(u8, " \t\"'<>)", rest[e]) == null) e += 1;
                break :blk std.mem.trimEnd(u8, rest[0..e], ".,;:!?*_~=`").len;
            }
            if (rest[0] == '<') break :blk componentEnd(rest, 0);
            break :blk null;
        };
        if (end) |e| {
            try out.append(a, rest[0..e]);
            i += e;
        } else i += 1;
    }
    return out.items;
}

/// Wiki-link and embed targets (the part before `|`), in order.
pub fn linkTargets(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try atomList(a, s)) |t| {
        const open: usize = if (std.mem.startsWith(u8, t, "![[")) 3 else if (std.mem.startsWith(u8, t, "[[")) 2 else continue;
        const inner = t[open .. t.len - @as(usize, if (std.mem.endsWith(u8, t, "]]")) 2 else 0)];
        try out.append(a, inner[0 .. std.mem.indexOfScalar(u8, inner, '|') orelse inner.len]);
    }
    return out.items;
}

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The field guard plus the doc pass's own rule: protected atoms keep
/// their exact order (the field guard checks presence, not order).
pub fn docGuard(a: Allocator, tone: Tone, role: []const u8, in_: []const u8, out: []const u8) Allocator.Error!Check {
    var c = try guard(a, tone, role, false, in_, out);
    if (!sameList(try atomList(a, in_), try atomList(a, out)))
        try c.hard.append(a, "moves or edits a protected atom");
    return c;
}

/// Whole-doc invariants of a patched doc against its original.
pub const Proof = struct {
    frontmatter_equal: bool,
    structhash_equal: bool,
    links_equal: bool,
    atoms_equal: bool,
    density_before: f64,
    density_after: f64,

    pub fn holds(p: Proof) bool {
        return p.frontmatter_equal and p.structhash_equal and p.links_equal and p.atoms_equal and
            p.density_after >= p.density_before;
    }
};

pub fn prove(a: Allocator, before: []const u8, after: []const u8) Allocator.Error!Proof {
    const fb = try frontmatter.parse(a, before);
    const fa = try frontmatter.parse(a, after);
    const fm_equal = if (fb != null and fa != null)
        std.mem.eql(u8, before[fb.?.lo..fb.?.hi], after[fa.?.lo..fa.?.hi])
    else
        fb == null and fa == null;
    const norm: structhash.Options = .{ .ignore_formatting = true };
    return .{
        .frontmatter_equal = fm_equal,
        .structhash_equal = structhash.hashTokens(try structhash.skeletonOpts(a, before, .markdown, norm)) ==
            structhash.hashTokens(try structhash.skeletonOpts(a, after, .markdown, norm)),
        .links_equal = sameList(try linkTargets(a, before), try linkTargets(a, after)),
        .atoms_equal = sameList(try atomList(a, before), try atomList(a, after)),
        .density_before = (try density.score(a, before)).total,
        .density_after = (try density.score(a, after)).total,
    };
}

/// A canned reply keyed by the exact input text: eval fixtures and
/// crafted guard cases. JSONL `{"input": "...", "output": "..."}`.
pub const Canned = struct { input: []const u8, output: []const u8 };

pub fn parseCanned(a: Allocator, jsonl: []const u8) ![]const Canned {
    var out: std.ArrayList(Canned) = .empty;
    var it = std.mem.splitScalar(u8, jsonl, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try out.append(a, try std.json.parseFromSliceLeaky(Canned, a, line, .{ .ignore_unknown_fields = true }));
    }
    return out.items;
}

fn cannedReply(canned: []const Canned, input: []const u8) ?[]const u8 {
    for (canned) |c| if (std.mem.eql(u8, c.input, input)) return c.output;
    return null;
}

/// The mock backend's offline reply: the longest plain lowercase word
/// (5+ letters, outside every bracket, quote, code span and existing
/// emphasis) wrapped in the tone's emphasis — `*x*` for mild, `**x**`
/// otherwise. No candidate returns the input unchanged. The guard still
/// judges the result like any reply.
pub fn mockEmphasis(a: Allocator, tone: Tone, s: []const u8) Allocator.Error![]const u8 {
    var depth: isize = 0;
    var code = false;
    var quote = false;
    var fmt = false;
    var best: ?[2]usize = null;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '`') code = !code;
        if (code or c == '`') {
            i += 1;
            continue;
        }
        switch (c) {
            '[', '(', '<', '{' => depth += 1,
            ']', ')', '>', '}' => depth -= 1,
            '"' => quote = !quote,
            '*', '~', '=', '_' => {
                const n = runLenAt(s, i);
                const intraword = c == '_' and i > 0 and isAlnum(s[i - 1]) and i + n < s.len and isAlnum(s[i + n]);
                if (!intraword) fmt = !fmt;
                i += n;
                continue;
            },
            else => {},
        }
        if (std.ascii.isLower(c) and (i == 0 or s[i - 1] == ' ')) {
            var j = i;
            while (j < s.len and std.ascii.isLower(s[j])) j += 1;
            const free = depth == 0 and !quote and !fmt;
            const bounded = j == s.len or std.mem.indexOfScalar(u8, " ,.;:", s[j]) != null;
            if (free and bounded and j - i >= 5 and (best == null or j - i > best.?[1] - best.?[0])) best = .{ i, j };
            i = j;
            continue;
        }
        i += 1;
    }
    const b = best orelse return s;
    const d: []const u8 = if (tone == .mild) "*" else "**";
    return std.mem.concat(a, u8, &.{ s[0..b[0]], d, s[b[0]..b[1]], d, s[b[1]..] });
}

pub const DocStatus = enum { rewritten, unchanged, rejected, skipped };

pub const DocField = struct {
    /// 1-based index among the doc's runs.
    para: usize,
    line: u32,
    kind: RunKind,
    status: DocStatus,
    before: []const u8,
    after: []const u8,
    /// Guard failures (rejected), skip reason (skipped), `warning: `
    /// budget overruns (any), or a backend error.
    reasons: []const []const u8,
};

pub const DocOptions = struct {
    tone: Tone,
    kind: backend.Kind,
    gate: Gate,
    canned: []const Canned = &.{},
};

pub const DocResult = struct {
    /// The patched doc: runs replaced, every other byte the input's.
    doc: []const u8,
    fields: []const DocField,
    rewritten: usize,
    line_groups: usize,
    frozen_blocks: usize,
    proof: Proof,
};

const paragraph_role = "prose paragraph of an archive record; the doc's layout is frozen";
const list_item_role = "list item text of an archive record (one item)";

/// One run through gate, call and guard. `after` is the reply only when
/// the status is `rewritten`.
fn voiceRun(ctx: *Ctx, o: DocOptions, system: []const u8, r: Run, para: usize, before: []const u8) backend.Error!DocField {
    const a = ctx.arena;
    var f: DocField = .{ .para = para, .line = r.line, .kind = r.kind, .status = .skipped, .before = before, .after = before, .reasons = &.{} };
    const skip: ?[]const u8 = if (!o.gate.allows(r.kind))
        try std.fmt.allocPrint(a, "policy: {s} not granted for {s}", .{ r.kind.region(), @tagName(o.tone) })
    else if (hasControl(before))
        "control character in the run"
    else if (std.ascii.startsWithIgnoreCase(before, "alt-text:") or std.ascii.startsWithIgnoreCase(before, "alt text:"))
        "alt text stays plain"
    else
        null;
    if (skip) |why| {
        f.reasons = try a.dupe([]const u8, &.{why});
        return f;
    }
    const role = if (r.kind == .paragraph) paragraph_role else list_item_role;
    const user = try userMessage(a, try std.fmt.allocPrint(a, "{s} {d}", .{ @tagName(r.kind), para }), role, before);
    const raw: []const u8 = if (cannedReply(o.canned, before)) |c| blk: {
        ctx.countCall(system, user);
        break :blk c;
    } else if (o.kind == .mock) blk: {
        ctx.countCall(system, user);
        break :blk try mockEmphasis(a, o.tone, before);
    } else backend.complete(ctx, o.kind, .voice, system, user) catch |e| switch (e) {
        error.ToolFailed => {
            f.status = .rejected;
            f.reasons = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "backend error: {s}", .{ctx.err_msg})});
            return f;
        },
        else => return e,
    };
    const reply = cleanReply(raw, before);
    if (std.mem.eql(u8, reply, before)) {
        f.status = .unchanged;
        return f;
    }
    const check = try docGuard(a, o.tone, role, before, reply);
    var reasons: std.ArrayList([]const u8) = .empty;
    try reasons.appendSlice(a, check.hard.items);
    for (check.budget.items) |b| try reasons.append(a, try std.fmt.allocPrint(a, "warning: {s}", .{b}));
    f.reasons = reasons.items;
    f.status = if (check.passes()) .rewritten else .rejected;
    if (check.passes()) f.after = reply;
    return f;
}

/// Voice every policy-granted run of `doc`: one call per run (canned
/// reply, mock emphasis, or `backend.complete(.voice)`), one guard per
/// reply, no retries. A rejected or failed run keeps its original text.
/// The proof is computed but not enforced here: callers write nothing
/// unless `proof.holds()`.
pub fn voiceDoc(ctx: *Ctx, doc: []const u8, o: DocOptions) backend.Error!DocResult {
    const a = ctx.arena;
    const walk = try docWalk(a, doc);
    var needs_call = false;
    for (walk.runs) |r| needs_call = needs_call or (o.gate.allows(r.kind) and cannedReply(o.canned, doc[r.lo..r.hi]) == null);
    if (needs_call and backend.needsKey(o.kind) and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("knap_doc_voice: backend '{s}' needs MODEL_API_KEY (use --backend mock)", .{@tagName(o.kind)});
    const system = if (needs_call or o.canned.len > 0) try systemPrompt(ctx, o.kind, o.tone) else "";

    var fields: std.ArrayList(DocField) = .empty;
    var patched: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var rewritten: usize = 0;
    for (walk.runs, 1..) |r, para| {
        const f = try voiceRun(ctx, o, system, r, para, doc[r.lo..r.hi]);
        try fields.append(a, f);
        if (f.status != .rewritten) continue;
        rewritten += 1;
        try patched.appendSlice(a, doc[copied..r.lo]);
        try patched.appendSlice(a, f.after);
        copied = r.hi;
    }
    try patched.appendSlice(a, doc[copied..]);
    const proof = try prove(a, doc, patched.items);
    return .{
        .doc = patched.items,
        .fields = fields.items,
        .rewritten = rewritten,
        .line_groups = walk.line_groups,
        .frozen_blocks = walk.frozen_blocks,
        .proof = proof,
    };
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
    try testing.expectEqual(@as(usize, 66), lines.len);
    for (lines) |l| {
        const c = try guard(a, parseTone(l.tone).?, l.field_role, l.footnote_abutting, l.input, l.output);
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
                const c = try guard(a, parseTone(tone).?, l.field_role, l.footnote_abutting, l.input, l.output);
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

// The guard's documented scope (#306, docs/tracks/VOICE-SCOPE.md): it
// verifies tokens, not meaning. If a semantic rule ever lands, this test
// should flip and the README/SPEC scope statements change with it.
test "guard scope: plain-word claims and negation flips pass (token-level only)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "the boring database ships every release on schedule";
    for ([_][]const u8{
        "the boring database ships on schedule; vendor recalled units, refunded buyers",
        "the boring database never ships on schedule",
    }) |out| {
        const c = try guard(a, .spicy, "one-line hot take", false, in_, out);
        try testing.expect(c.strict());
    }
    // A fabricated fact-shaped token is still caught.
    const c = try guard(a, .spicy, "one-line hot take", false, in_, "the boring database ships on schedule; vendor recalled 400 units");
    try testing.expect(!c.passes());
}

test "guard W1: insert-only skeleton accepts formatting, rejects swallowed or moved structure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hard = struct {
        fn j(al: Allocator, c: Check) ![]const u8 {
            return std.mem.join(al, "; ", c.hard.items);
        }
    }.j;

    // A footnote marker or wikilink inside emphasis is fine.
    var c = try guard(a, .spicy, "r", false, "the plan[^1] works", "the **plan[^1]** works");
    try testing.expect(c.passes());
    c = try guard(a, .feral, "r", false, "see x", "see ***x***");
    try testing.expect(c.passes());
    c = try guard(a, .spicy, "r", false, "see [[Page]] docs", "see **[[Page]]** docs");
    try testing.expect(c.passes());
    // A code span hiding the footnote marker or the input's own bold fails.
    c = try guard(a, .spicy, "r", false, "the plan[^1] works", "the `plan[^1]` works");
    try testing.expect(std.mem.indexOf(u8, try hard(a, c), "changes inline structure") != null);
    c = try guard(a, .spicy, "r", false, "the **boring** database", "the `**boring**` database");
    try testing.expect(std.mem.indexOf(u8, try hard(a, c), "changes inline structure") != null);
    // A footnote moved inside an added span changes the order.
    c = try guard(a, .feral, "r", false, "plan[^1] and **bold** text", "**plan[^1]** and bold text");
    try testing.expect(std.mem.indexOf(u8, try hard(a, c), "changes inline structure") != null);
    // An unmatched added `**` is a delim token, not formatting.
    c = try guard(a, .feral, "r", false, "x y z", "x **y z");
    try testing.expect(std.mem.indexOf(u8, try hard(a, c), "changes inline structure") != null);
}

test "guard: boris atoms are single protected tokens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A doc carrying the boris surface round-trips byte-identical (feral:
    // its bang budget has room for the embed's literal `!`).
    const doc = "see [[limericks/LIM-0155|L]] ![[mascots/M-0090]] {{include frag/a.md}} <Aside kind=\"tip\"> <Details summary=\"s\">";
    var c = try guard(a, .feral, "r", false, doc, doc);
    try testing.expect(c.strict());

    // Corrupting any atom's interior is a hard drop of that atom.
    c = try guard(a, .spicy, "r", false, "a {{include frag/a.md}} b", "a {{include frag/*a*.md}} b");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops include {{include frag/a.md}}") != null);
    c = try guard(a, .spicy, "r", false, "a <Aside kind=\"tip\"> b", "a <Aside kind=\"*tip*\"> b");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops component <Aside kind=\"tip\">") != null);
    c = try guard(a, .spicy, "r", false, "a </Details> b", "a </ Details> b");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops component </Details>") != null);
    // Inventing an atom is an add.
    c = try guard(a, .spicy, "r", false, "plain text here", "plain text {{include x.md}} here");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds include {{include x.md}}") != null);
    // The canonical-id link target is opaque: renaming inside it drops the
    // whole wikilink, and the embed form counts ![[…]] as one atom.
    c = try guard(a, .spicy, "r", false, "see [[limericks/LIM-0155|L]]", "see [[limericks/lim-0155|L]]");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops wikilink [[limericks/LIM-0155|L]]") != null);
    c = try guard(a, .spicy, "r", false, "see ![[mascots/M-0090]]", "see ![[mascots/m-0090]]");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops embed ![[mascots/M-0090]]") != null);
    // Wrapping atoms in formatting stays legal; splitting them does not.
    c = try guard(a, .feral, "r", false, "see [[limericks/LIM-0155|L]] now", "see **[[limericks/LIM-0155|L]]** now");
    try testing.expect(c.passes());
    c = try guard(a, .feral, "r", false, "see [[limericks/LIM-0155|L]] now", "see [[limericks/**LIM-0155**|L]] now");
    try testing.expect(!c.passes());
}

test "guard W3: strikethrough may only cover words the reply added" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "the boring database that actually ships";
    var c = try guard(a, .feral, "r", false, in_, "the ~~boring~~ database that actually ships");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") != null);
    c = try guard(a, .feral, "r", false, in_, "that ~~barely~~ actually ships, the boring database");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") == null);
    c = try guard(a, .feral, "r", false, in_, "the boring database that ~~not~~ actually ships");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") != null);
    // Inflections share the input's stem too: `shipped` retracts `ships`.
    c = try guard(a, .feral, "r", false, in_, "the boring database that actually ~~shipped~~");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") != null);
    // A strike the input already had is the input's own business.
    c = try guard(a, .feral, "r", false, "it ~~was~~ is broken", "it ~~was~~ is still broken");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") == null);
    // Numbers are facts; even inside a strike they cannot be retracted.
    c = try guard(a, .feral, "r", false, "it handles 50k messages", "it handles ~~50k~~ some messages");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") != null);
    // A `~~` quoted in a code span can't open the strike: pairing must
    // still reach the reply's own `~~boring~~`.
    c = try guard(a, .feral, "r", false, "run `x~~` then the boring database ships", "run `x~~` then the ~~boring~~ database ships");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") != null);
    // And a strike the reply added stays legal past a quoted `~~`.
    c = try guard(a, .feral, "r", false, "it uses `a~~b` markers", "it uses `a~~b` markers, ~~newly~~");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words") == null);
    // A strike around a code span quoting input words still retracts
    // them: the inner is judged on the real text, and the reason names
    // what was struck.
    c = try guard(a, .feral, "r", false, "uses `vacuum` daily", "uses ~~`vacuum`~~ daily");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words: vacuum") != null);
    c = try guard(a, .feral, "r", false, "it handles `50k` messages", "it ~~`50k`~~ messages");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "strikes input words: 50k") != null);
}

test "guard W4: plain-role slots take no added formatting or emoji" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "one-word verdict, rendered bold",
        "deck line, rendered italic; falls back to a stock line via ??",
        "alt text for `screenshot`; falls back to `product`",
        "page heading and frontmatter `title`",
        "frontmatter tags, lowercase kebab-case",
        "ALT TEXT for the screenshot",
        "FRONTMATTER value",
    }) |role| {
        try testing.expect(plainRole(role));
        const c = try guard(a, .feral, role, false, "give a shit", "**give** a shit");
        try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "formatting in a plain slot") != null);
    }
    // "heading" alone is not a plain marker: bottom_line sits "under the
    // 'Verdict' heading" but takes formatting like any prose slot.
    try testing.expect(!plainRole("closing verdict, 1-2 sentences, under the 'Verdict' heading"));
    // Normalized matching: inflected or partial markers are not slots.
    try testing.expect(!plainRole("the verdict, rendered boldly on the page"));
    try testing.expect(!plainRole("image alt (one item)"));
    var c = try guard(a, .feral, "closing verdict, 1-2 sentences, under the 'Verdict' heading", false, "ship it tonight", "ship it **tonight**, honestly");
    try testing.expect(c.passes());
    // Emoji count the same way as delimiters in a plain slot.
    c = try guard(a, .feral, "alt text for `screenshot`", false, "three green checks", "three green checks 🙄");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "formatting in a plain slot") != null);
}

test "guard W5: emoji classes — allowlist, disallowed, symbols, invisibles" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "the boring database that actually ships";
    const has = struct {
        fn f(al: Allocator, c: Check, s: []const u8) !bool {
            return std.mem.indexOf(u8, try std.mem.join(al, "; ", c.hard.items), s) != null;
        }
    }.f;

    // Allowlisted emoji are fine in feral and spicy, a hard failure in
    // mild (mild's emoji budget is zero and its overruns reject).
    var c = try guard(a, .feral, "r", false, in_, in_ ++ " 🔥");
    try testing.expect(c.passes());
    c = try guard(a, .mild, "r", false, in_, in_ ++ " 🔥");
    try testing.expect(!c.passes());
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "mild: 1 emoji, max 0") != null);
    // Emoji outside the named allowlist are disallowed whatever the tone.
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 💩");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1F4A9"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🤡");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1F921"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🫠");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1FAE0"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🥵");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1F975"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " ✨");
    try testing.expect(c.passes());
    // An emoji plus VS16 counts once; a bare VS16 is invisible junk.
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🏛️");
    try testing.expect(c.passes());
    c = try guard(a, .feral, "r", false, in_, in_ ++ " \u{FE0F}x");
    try testing.expect(try has(a, c, "adds invisible character U+FE0F"));
    // ZWJ, skin tones, out-of-band marks, fake bold and non-allowlist
    // dingbats are all hard failures.
    c = try guard(a, .feral, "r", false, in_, in_ ++ " \u{200D}x");
    try testing.expect(try has(a, c, "adds invisible character U+200D"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 👍🏽");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1F3FD"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " ❗");
    try testing.expect(try has(a, c, "adds symbol U+2757"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " ‼");
    try testing.expect(try has(a, c, "adds !!"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 𝐛");
    try testing.expect(try has(a, c, "adds symbol U+1D41B"));
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🖕");
    try testing.expect(try has(a, c, "adds disallowed emoji U+1F595"));
    // An emoji already present in the input stays allowed to keep — but
    // dropping it, or any other non-ASCII character, is a removal.
    c = try guard(a, .feral, "r", false, in_ ++ " 🔥", in_ ++ " 🔥, and hot");
    try testing.expect(c.passes());
    c = try guard(a, .feral, "r", false, in_ ++ " 🔥", in_);
    try testing.expect(try has(a, c, "drops non-ASCII character U+1F525"));
    c = try guard(a, .feral, "r", false, "the café", "the cafe");
    try testing.expect(try has(a, c, "drops non-ASCII character U+00E9"));
    // Ordinary non-ASCII stays ordinary.
    c = try guard(a, .mild, "r", false, in_, "the boring database — that actually ships");
    try testing.expect(c.passes());
}

test "guard W6: code spans quote the input verbatim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try guard(a, .spicy, "r", false, "run quux migrate --to 3 before upgrading", "run `quux migrate --to 3` before upgrading");
    try testing.expect(c.passes());
    // Backticking a rewritten sentence is not a quote.
    c = try guard(a, .feral, "r", false, "the boring database that actually ships", "`the boring database that actually ships, finally`");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "code span text not in the input") != null);
    // An identifier the input never named is invented.
    c = try guard(a, .spicy, "r", false, "the boring database that actually ships", "the boring database that actually ships, unlike `vacuumdb`");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "code span text not in the input") != null);
    // Wrapping the whole input verbatim is markup, not a rewrite.
    c = try guard(a, .feral, "r", false, "run vacuum after every deploy", "`run vacuum after every deploy`");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "code span wraps the whole input") != null);
}

// Entities smuggle `*` and emoji past the markup checks; the zig guard
// only knows decimal (`&#42;`) and named (`&nbsp;`) forms — hex entities
// like `&#x2A;` are still rejected, but as "adds number"/"adds markup
// character", not via this rule (voice.awk's regex does match them).
test "guard: added HTML entities are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "the boring database that actually ships";
    for ([_][]const u8{
        "the &#42;boring&#42; database that actually ships",
        "the boring database that actually ships &#128169;",
        "the boring&nbsp;database that actually ships",
        "the boring &amp; beautiful database that actually ships",
    }) |out| {
        const c = try guard(a, .spicy, "one-line hot take", false, in_, out);
        try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds HTML entity") != null);
    }
    // An entity the input already used is the input's own business, and a
    // bare `&`/truncated entity is no entity at all.
    const c = try guard(a, .spicy, "one-line hot take", false, "fish &amp; chips", "fish &amp; chips, reheated");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds HTML entity") == null);
    try testing.expect(!addsEntity("salt & vinegar", "salt & vinegar please"));
    try testing.expect(!addsEntity(in_, "the boring &amp database that actually ships"));
    try testing.expect(addsEntity(in_, "the &#42;boring&#42; database that actually ships"));
    try testing.expect(addsEntity(in_, "the boring&nbsp;database that actually ships"));
}

test "guard: word cap splits on Unicode whitespace (#334)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Five words joined by NBSP, thin space or ideographic space still
    // count as five — the cap is not evaded by swapping U+0020 out.
    for ([_][]const u8{
        "it \xc2\xa0actually \xc2\xa0ships \xc2\xa0every \xc2\xa0day",
        "it\xe2\x80\x89actually\xe2\x80\x89ships\xe2\x80\x89every\xe2\x80\x89day",
        "it\xe3\x80\x80actually\xe3\x80\x80ships\xe3\x80\x80every\xe3\x80\x80day",
    }) |out| {
        const c = try guard(a, .spicy, "one-word verdict", false, "it ships", out);
        try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "word-limited role, 5 words") != null);
    }
    // And the ASCII baseline still bites.
    const c = try guard(a, .spicy, "one-word verdict", false, "it ships", "it actually ships every day");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "word-limited role, 5 words") != null);
}

test "guard: a code span may quote the input's URL (#334)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The URL token ends at the backtick, so quoting the input's URL in
    // a code span is allowed the way W6 intends.
    var c = try guard(a, .spicy, "r", false, "docs at https://example.com/bench today", "docs at `https://example.com/bench` today");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds url") == null);
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops url") == null);
    // A different URL inside the span is still an invented URL.
    c = try guard(a, .spicy, "r", false, "docs at https://example.com/bench today", "docs at `https://example.com/other` today");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds url https://example.com/other") != null);
    // Trailing .,;:!? is sentence punctuation, not the target — it may
    // change (the documented rule; see urls()).
    c = try guard(a, .spicy, "r", false, "docs at https://example.com/bench today", "docs at https://example.com/bench, today");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "adds url") == null);
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops url") == null);
    // Punctuation mid-URL is part of the target and cannot change.
    c = try guard(a, .spicy, "r", false, "docs at https://example.com/bench?p=1 today", "docs at https://example.com/bench today");
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "drops url https://example.com/bench?p=1") != null);
}

test "guard: length bounds count text, not formatting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "the boring database that actually ships"; // 39 bytes
    // 80 raw bytes, 76 of text: the `**` does not count.
    const styled = "the **BORING** database that actually SHIPS, a whole miracle, put it in a museum";
    try testing.expectEqual(@as(usize, 80), styled.len);
    try testing.expectEqual(@as(usize, 76), textLen(styled));
    var c = try guard(a, .feral, "r", false, in_, styled);
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "too long") == null);
    // 80 text bytes fails against the same bound (max 79).
    const plain80 = in_ ++ " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    try testing.expectEqual(@as(usize, 80), textLen(plain80));
    c = try guard(a, .feral, "r", false, in_, plain80);
    try testing.expect(std.mem.indexOf(u8, try joined(a, c.hard.items), "too long: 80 bytes, max 79") != null);
    // Emoji pad no length either way.
    c = try guard(a, .feral, "r", false, in_, in_ ++ " 🪣");
    try testing.expect(c.passes());
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
    inline for (.{ "verdict", "apparatus", "release-notes", "reading-note", "runbook" }) |id| {
        const sample = try readTest(a, "data/" ++ id ++ ".sample.json");
        var feral_fmt: usize = 0;
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
            // Every template's feral mocks carry at least one formatted reply.
            if (tone == .feral) {
                var orig2 = try std.json.parseFromSliceLeaky(Value, a, sample, .{ .parse_numbers = false });
                var voiced2 = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, r.data, .{}), .{ .parse_numbers = false });
                const shape2 = try std.json.parseFromSliceLeaky(Value, a, try readTest(a, "templates/shapes/" ++ id ++ ".json"), .{});
                const os2 = try collect(a, id, shape2, &orig2);
                const vs2 = try collect(a, id, shape2, &voiced2);
                const nonascii = struct {
                    fn n(s: []const u8) usize {
                        var cnt: usize = 0;
                        for (s) |ch| cnt += @intFromBool(ch >= 0x80);
                        return cnt;
                    }
                }.n;
                for (os2, vs2) |o, v| {
                    const ob = o.ptr.*.string;
                    const vb = v.ptr.*.string;
                    if (std.mem.count(u8, vb, "*") > std.mem.count(u8, ob, "*") or
                        std.mem.count(u8, vb, "~") > std.mem.count(u8, ob, "~") or
                        std.mem.count(u8, vb, "`") > std.mem.count(u8, ob, "`") or
                        std.mem.count(u8, vb, "=") > std.mem.count(u8, ob, "=") or
                        nonascii(vb) > nonascii(ob))
                        feral_fmt += 1;
                }
            }
        }
        try testing.expect(feral_fmt >= 1);
    }
    try testing.expectError(error.ToolFailed, voiceData(&ctx, "verdict", "{}", .spicy, .spark));
    try testing.expect(std.mem.indexOf(u8, ctx.err_msg, "MODEL_API_KEY") != null);
}

test "mock field roles match the shape roles verbatim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "verdict", "apparatus", "release-notes", "reading-note", "runbook" }) |id| {
        var data = try std.json.parseFromSliceLeaky(Value, a, try readTest(a, "data/" ++ id ++ ".sample.json"), .{ .parse_numbers = false });
        const shape = try std.json.parseFromSliceLeaky(Value, a, try readTest(a, "templates/shapes/" ++ id ++ ".json"), .{});
        const slots = try collect(a, id, shape, &data);
        inline for (.{ "mild", "spicy", "feral" }) |tone| {
            var lines: usize = 0;
            for (try parseLines(a, try readTest(a, "prompts/voice/mock/" ++ tone ++ ".jsonl"))) |l| {
                if (!std.mem.eql(u8, l.template, id)) continue;
                lines += 1;
                var found = false;
                for (slots) |s| {
                    if (!std.mem.eql(u8, s.path, l.field)) continue;
                    found = true;
                    testing.expectEqualStrings(s.role, l.field_role) catch {
                        std.debug.print("mock/{s}.jsonl {s} {s}\n", .{ tone, l.template, l.field });
                        return error.TestUnexpectedResult;
                    };
                }
                // Every mock line answers a slot that exists in the sample.
                try testing.expect(found);
            }
            try testing.expect(lines > 0);
        }
    }
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

test "docWalk: prose runs only; verse, fences, components, quotes and includes frozen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        "---\ntitle: T\nid: mascots/M-1\n---\n\n# Head\n\nOne plain paragraph here.  \n\n" ++
        "- item one\n- item two\n  - nested three\n\n" ++
        "Line one  \nline two  \nline three\n\n" ++
        "```\nfenced prose\n\nmore fenced prose\n```\n\n" ++
        "<Aside type=\"note\">\naside prose\n\nmore aside prose\n</Aside>\n\n" ++
        "> quoted prose\n\n{{include snippets/x.md}}\n\n[^1]: a footnote\n\n" ++
        "* * *\n\nTitle\n---\n\n| a | b |\n\n    indented code\n\n<!-- a\n\ncomment -->\n\n" ++
        "1. ordered item\n- > quoted item\n\nLast paragraph.";
    const w = try docWalk(a, doc);
    const want = [_]struct { kind: RunKind, text: []const u8, line: u32 }{
        .{ .kind = .paragraph, .text = "One plain paragraph here.", .line = 8 },
        .{ .kind = .list_item, .text = "item one", .line = 10 },
        .{ .kind = .list_item, .text = "item two", .line = 11 },
        .{ .kind = .list_item, .text = "nested three", .line = 12 },
        .{ .kind = .list_item, .text = "ordered item", .line = 49 },
        .{ .kind = .paragraph, .text = "Last paragraph.", .line = 52 },
    };
    try testing.expectEqual(want.len, w.runs.len);
    for (want, w.runs) |x, r| {
        try testing.expectEqual(x.kind, r.kind);
        try testing.expectEqualStrings(x.text, doc[r.lo..r.hi]);
        try testing.expectEqual(x.line, r.line);
    }
    try testing.expectEqual(@as(usize, 1), w.line_groups);
}

test "docGuard: block markers, edited link targets and dropped markup are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_ = "Mentored by [[limericks/LIM-0155|Patchy]], who taught it **precise** blame pointing.";
    const ok = try docGuard(a, .feral, list_item_role, in_, "Mentored by [[limericks/LIM-0155|Patchy]], who taught it **precise** blame *pointing*.");
    try testing.expect(ok.passes());
    const bad = [_][2][]const u8{
        .{ "# Mentored by [[limericks/LIM-0155|Patchy]], who taught it **precise** blame pointing.", "starts with a block marker" },
        .{ "Mentored by [[limericks/LIM-0156|Patchy]], who taught it **precise** blame pointing.", "drops wikilink" },
        .{ "Mentored by [[limericks/LIM-0155|Patchy]], who taught it precise blame *pointing*.", "drops markup character *" },
        .{ "Mentored by [[limericks/LIM-0155|Patchy]],\n- who taught it **precise** blame pointing.", "control character or line break" },
    };
    for (bad) |b| {
        const c = try docGuard(a, .feral, list_item_role, in_, b[0]);
        const why = try joined(a, c.hard.items);
        if (std.mem.indexOf(u8, why, b[1]) == null) {
            std.debug.print("'{s}' -> '{s}', want '{s}'\n", .{ b[0], why, b[1] });
            return error.TestUnexpectedResult;
        }
    }
    // Atom order is the doc pass's own rule: presence alone isn't enough.
    const two = "See [[a/A-1]] then [[b/B-2]] for more context today.";
    const swapped = try docGuard(a, .feral, paragraph_role, two, "See [[b/B-2]] then [[a/A-1]] for **more** context today.");
    try testing.expect(std.mem.indexOf(u8, try joined(a, swapped.hard.items), "moves or edits a protected atom") != null);
}

test "mockEmphasis: longest free lowercase word, never inside markup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a **reassigned** fault, quietly", try mockEmphasis(a, .feral, "a reassigned fault, quietly"));
    try testing.expectEqualStrings("a *reassigned* fault", try mockEmphasis(a, .mild, "a reassigned fault"));
    try testing.expectEqualStrings("`everything inside` [[links/L-1|everything]] **everything** tiny", try mockEmphasis(a, .feral, "`everything inside` [[links/L-1|everything]] **everything** tiny"));
    // `someone` is cut by an apostrophe, not a word boundary.
    try testing.expectEqualStrings("someone's **widgets**", try mockEmphasis(a, .feral, "someone's widgets"));
    try testing.expectEqualStrings("tiny bits only", try mockEmphasis(a, .feral, "tiny bits only"));
}

test "prove: frontmatter, link and atom drift each fail; formatting-only passes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "---\nid: x/X-1\n---\n\nSee [[a/A-1|A]] and {{include s/x.md}} today.\n";
    try testing.expect((try prove(a, base, "---\nid: x/X-1\n---\n\nSee [[a/A-1|A]] and {{include s/x.md}} **today**.\n")).holds());
    try testing.expect(!(try prove(a, base, "---\nid: x/X-2\n---\n\nSee [[a/A-1|A]] and {{include s/x.md}} today.\n")).frontmatter_equal);
    try testing.expect(!(try prove(a, base, "---\nid: x/X-1\n---\n\nSee [[a/A-2|A]] and {{include s/x.md}} today.\n")).links_equal);
    try testing.expect(!(try prove(a, base, "---\nid: x/X-1\n---\n\nSee [[a/A-1|A]] and {{include s/y.md}} today.\n")).atoms_equal);
    try testing.expect(!(try prove(a, base, "---\nid: x/X-1\n---\n\nSee [[a/A-1|A]] and {{include s/x.md}} today.\n\n- new\n")).structhash_equal);
}
