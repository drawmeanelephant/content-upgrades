//! The ratchet loop: values-only density climbing (docs/next-phase-plan.md
//! section 2).
//!
//!   render(data0) -> score
//!   loop: probe every growable slot with a shape-typed stub -> rank by gain
//!         -> ask the backend for ONE value for the best slot
//!         -> schema, inert, verifier gates -> server-side write -> render
//!         -> keep it only if the score rises by epsilon with no new warnings
//!
//! The server picks the slot, never the model: a model choosing which
//! apparatus to add would be the model choosing layout. The model's only
//! controls are the value for the slot it is handed, an enum option the
//! shape enumerates, and declining with null. v1 fills empty top-level
//! scalars and appends to top-level arrays; it never changes a non-empty
//! value, and the best score only goes up.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const density = @import("density.zig");
const formatcheck = @import("formatcheck.zig");
const store = @import("store.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

// --- Constants (plan section 2.7) -------------------------------------------

pub const default_max_iterations = 6;
/// Points; below this a gain is noise.
pub const epsilon: f64 = 1.0;
/// Slots asked per iteration: one retry when the best slot is rejected.
pub const top_k = 2;
/// Hard cost cap on backend calls per run.
pub const max_backend_calls = 10;
pub const max_slice_bytes = 4096;
/// Stub size for a string slot with no `words` annotation.
const default_stub_words = 8;
/// Growth bound for an array slot with no `max_items` annotation.
const default_max_items = 3;
const max_input = 16 * 1024 * 1024;

/// The system prompt for every enrich call; identical on every call so a
/// provider can cache it.
pub const enrich_prefix =
    \\You fill ONE empty field in a JSON data document for a fixed, human-authored template.
    \\You never see the template and you never write markup: no markdown, no HTML, no brackets,
    \\no headings, no pipes. Return ONLY a JSON value matching the schema. No prose, no code fences.
    \\Use only facts in EVIDENCE; copy quotes verbatim. If EVIDENCE cannot support the field, return null.
;

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

// --- Shapes -----------------------------------------------------------------

/// Shape `apparatus` vocabulary: what a slot renders as. `link` is the one
/// addition to the plan's list (a plain URL slot rendered through `link`).
pub const Apparatus = enum { footnote, callout, wikilink, embed, image, link, fragment_link, table, quote, frontmatter, list };

/// Value kinds the ratchet can grow. `object<…>` maps (footnote notes) are
/// `other`: filling them needs a nested write, which v1 does not do.
pub const Kind = enum { string, number, strings, objects, rows, other };

pub const Field = struct {
    name: []const u8,
    kind: Kind,
    optional: bool = false,
    enum_values: []const []const u8 = &.{},
    max_words: ?usize = null,
    /// Field name whose object keys this value must be one of.
    ref: ?[]const u8 = null,
    evidence: bool = false,
    /// http/https URL (image and link slots).
    url: bool = false,
    /// Names a site page (wikilink and embed slots).
    page: bool = false,
    words: usize = default_stub_words,
    /// Item fields of an array<object>.
    sub: []const Field = &.{},
};

pub const Slot = struct {
    field: Field,
    apparatus: Apparatus,
    max_items: usize,
    /// Row width for table slots; 0 means "match the existing rows".
    cells: usize,
    role: []const u8,
    /// The shape entry as JSON, quoted into the enrich slice.
    schema: []const u8,
    /// `name` for scalars, `name[+]` for arrays.
    path: []const u8,

    pub fn isArray(s: Slot) bool {
        return switch (s.field.kind) {
            .strings, .objects, .rows => true,
            else => false,
        };
    }

    pub fn gated(s: Slot) bool {
        if (s.field.evidence) return true;
        for (s.field.sub) |f| if (f.evidence) return true;
        return false;
    }
};

pub const Shape = struct {
    template_id: []const u8,
    slots: []const Slot,
    /// Required top-level string fields: the HEADLINE context of a slice.
    headline: []const []const u8,
};

pub fn loadShape(ctx: *Ctx, path: []const u8) Error!Shape {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(1 << 20)) catch
        return ctx.fail("cannot read shape '{s}'", .{path});
    return parseShape(ctx.arena, bytes) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => ctx.fail("shape '{s}' is not a valid shape descriptor", .{path}),
    };
}

pub fn parseShape(arena: std.mem.Allocator, bytes: []const u8) !Shape {
    const root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{});
    if (root != .object) return error.BadShape;
    const fields = root.object.get("fields") orelse return error.BadShape;
    if (fields != .object) return error.BadShape;
    const id = switch (root.object.get("template_id") orelse Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    var slots: std.ArrayList(Slot) = .empty;
    var headline: std.ArrayList([]const u8) = .empty;
    var it = fields.object.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const spec = e.value_ptr.*;
        if (spec != .object) return error.BadShape;
        const f = try parseField(arena, name, spec.object, default_stub_words);
        if (!f.optional and f.kind == .string) try headline.append(arena, name);

        const app_name = str(spec.object, "apparatus") orelse continue;
        const apparatus = std.meta.stringToEnum(Apparatus, app_name) orelse return error.BadShape;
        const has_max = spec.object.get("max_items") != null;
        // A required field grows only when the shape bounds it.
        if (f.kind == .other or (!f.optional and !has_max)) continue;
        // The slice carries ROLE on its own line; keep it out of SCHEMA.
        var schema = try spec.object.clone(arena);
        _ = schema.orderedRemove("role");
        var slot: Slot = .{
            .field = f,
            .apparatus = apparatus,
            .max_items = int(spec.object, "max_items") orelse default_max_items,
            .cells = int(spec.object, "cells") orelse 0,
            .role = str(spec.object, "role") orelse "",
            .schema = try std.json.Stringify.valueAlloc(arena, Value{ .object = schema }, .{}),
            .path = name,
        };
        if (!slot.isArray()) slot.max_items = 1;
        slot.field.url = apparatus == .image or apparatus == .link;
        slot.field.page = apparatus == .wikilink or apparatus == .embed;
        if (slot.isArray()) slot.path = try std.fmt.allocPrint(arena, "{s}[+]", .{name});
        try slots.append(arena, slot);
    }
    return .{ .template_id = id, .slots = slots.items, .headline = headline.items };
}

fn parseField(arena: std.mem.Allocator, name: []const u8, spec: ObjectMap, inherit_words: usize) !Field {
    const ty = str(spec, "type") orelse "string";
    var f: Field = .{
        .name = name,
        .kind = kindOf(ty),
        .optional = boolean(spec, "optional"),
        .max_words = int(spec, "max_words"),
        .ref = str(spec, "ref"),
        .evidence = boolean(spec, "evidence"),
        .words = int(spec, "words") orelse inherit_words,
    };
    if (spec.get("enum")) |ev| {
        if (ev != .array) return error.BadShape;
        const vals = try arena.alloc([]const u8, ev.array.items.len);
        for (ev.array.items, vals) |v, *out| {
            if (v != .string) return error.BadShape;
            out.* = v.string;
        }
        f.enum_values = vals;
    }
    if (spec.get("fields")) |sv| {
        if (sv != .object) return error.BadShape;
        var subs: std.ArrayList(Field) = .empty;
        var it = sv.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) return error.BadShape;
            try subs.append(arena, try parseField(arena, e.key_ptr.*, e.value_ptr.object, f.words));
        }
        f.sub = subs.items;
    }
    return f;
}

fn kindOf(ty: []const u8) Kind {
    const map = [_]struct { []const u8, Kind }{
        .{ "string", .string },
        .{ "number", .number },
        .{ "array<string>", .strings },
        .{ "array<object>", .objects },
        .{ "array<array<string>>", .rows },
    };
    for (map) |m| if (std.mem.eql(u8, ty, m[0])) return m[1];
    return .other;
}

fn str(o: ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(o: ObjectMap, key: []const u8) ?usize {
    return switch (o.get(key) orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn boolean(o: ObjectMap, key: []const u8) bool {
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

// --- Data slots -------------------------------------------------------------

fn isEmpty(v: ?Value) bool {
    return switch (v orelse return true) {
        .null => true,
        .string => |s| std.mem.trim(u8, s, " \t\r\n").len == 0,
        .array => |a| a.items.len == 0,
        .object => |o| o.count() == 0,
        else => false,
    };
}

/// An empty scalar, or an array below `max_items`. A present value of the
/// wrong type never grows.
pub fn canGrow(data: ObjectMap, s: Slot) bool {
    const v = data.get(s.field.name);
    if (!s.isArray()) return isEmpty(v);
    return switch (v orelse return true) {
        .null => true,
        .array => |a| a.items.len < s.max_items,
        else => false,
    };
}

/// A copy of `data` with `value` set on (or appended to) the slot. The
/// original is never touched, so `best` stays intact.
pub fn withValue(arena: std.mem.Allocator, data: ObjectMap, s: Slot, value: Value) !ObjectMap {
    var m = try data.clone(arena);
    if (!s.isArray()) {
        try m.put(arena, s.field.name, value);
        return m;
    }
    var arr = std.json.Array.init(arena);
    if (data.get(s.field.name)) |old| {
        if (old == .array) try arr.appendSlice(old.array.items);
    }
    try arr.append(value);
    try m.put(arena, s.field.name, .{ .array = arr });
    return m;
}

fn rowWidth(data: ObjectMap, s: Slot) usize {
    if (data.get(s.field.name)) |v| {
        if (v == .array and v.array.items.len > 0 and v.array.items[0] == .array)
            return v.array.items[0].array.items.len;
    }
    return s.cells;
}

/// Shape-typed placeholder for probing. Never shipped.
pub fn stub(arena: std.mem.Allocator, data: ObjectMap, s: Slot) !Value {
    switch (s.field.kind) {
        .number => return .{ .integer = 1 },
        .string, .strings => return .{ .string = try stubText(arena, s.field) },
        .objects => {
            var o: ObjectMap = .empty;
            for (s.field.sub) |f| {
                if (f.optional) continue;
                try o.put(arena, f.name, .{ .string = try stubText(arena, f) });
            }
            return .{ .object = o };
        },
        .rows => {
            var row = std.json.Array.init(arena);
            const n = @max(rowWidth(data, s), 1);
            for (0..n) |_| try row.append(.{ .string = try stubText(arena, s.field) });
            return .{ .array = row };
        },
        .other => unreachable,
    }
}

fn stubText(arena: std.mem.Allocator, f: Field) ![]const u8 {
    if (f.enum_values.len > 0) return f.enum_values[0];
    if (f.url) return "https://example.com/probe";
    if (f.page) return "Probe page";
    const n = @max(1, @min(f.words, f.max_words orelse f.words));
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (0..n) |i| try aw.writer.writeAll(if (i == 0) "probe" else " probe");
    return aw.written();
}

fn filled(data: ObjectMap, slots: []const Slot) usize {
    var n: usize = 0;
    for (slots) |s| {
        if (!isEmpty(data.get(s.field.name))) n += 1;
    }
    return n;
}

// --- Guards (plan section 2.6) ----------------------------------------------

/// Type, enum, max_words, URL scheme, item shape, and `ref` integrity.
/// Returns the rejection detail, or null when the value fits.
pub fn checkSchema(arena: std.mem.Allocator, s: Slot, value: Value, data: ObjectMap) !?[]const u8 {
    switch (s.field.kind) {
        .string, .strings => return checkString(arena, s.field, value),
        .number => return switch (value) {
            .integer, .float => null,
            else => "expected a number",
        },
        .objects => {
            if (value != .object) return "expected an object";
            var it = value.object.iterator();
            while (it.next()) |e| {
                for (s.field.sub) |f| {
                    if (std.mem.eql(u8, f.name, e.key_ptr.*)) break;
                } else return try std.fmt.allocPrint(arena, "unknown field '{s}'", .{e.key_ptr.*});
            }
            for (s.field.sub) |f| {
                const v = value.object.get(f.name) orelse {
                    if (f.optional) continue;
                    return try std.fmt.allocPrint(arena, "missing field '{s}'", .{f.name});
                };
                if (try checkString(arena, f, v)) |why|
                    return try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.name, why });
                if (f.ref) |ref| {
                    const keys = data.get(ref);
                    const ok = keys != null and keys.? == .object and keys.?.object.get(v.string) != null;
                    if (!ok) return try std.fmt.allocPrint(arena, "ref: {s} '{s}' is not a key in '{s}'", .{ f.name, v.string, ref });
                }
            }
            return null;
        },
        .rows => {
            if (value != .array) return "expected a row (array of strings)";
            const want = rowWidth(data, s);
            if (want > 0 and value.array.items.len != want)
                return try std.fmt.allocPrint(arena, "row has {d} cells, table has {d}", .{ value.array.items.len, want });
            if (value.array.items.len == 0) return "empty row";
            const cell: Field = .{ .name = "cell", .kind = .string };
            for (value.array.items) |c| {
                if (try checkString(arena, cell, c)) |why| return why;
            }
            return null;
        },
        .other => return "slot type not fillable",
    }
}

fn checkString(arena: std.mem.Allocator, f: Field, v: Value) !?[]const u8 {
    if (v != .string) return "expected a string";
    const s = std.mem.trim(u8, v.string, " \t\r\n");
    if (s.len == 0) return "empty string";
    if (f.enum_values.len > 0) {
        for (f.enum_values) |e| {
            if (std.mem.eql(u8, e, s)) break;
        } else return try std.fmt.allocPrint(arena, "enum: '{s}' is not one of {s}", .{ s, try std.mem.join(arena, "|", f.enum_values) });
    }
    if (f.max_words) |m| {
        const n = countWords(s);
        if (n > m) return try std.fmt.allocPrint(arena, "max_words: {d} > {d}", .{ n, m });
    }
    if (f.url) {
        const scheme = std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
        if (!scheme or std.mem.indexOfAny(u8, s, " \t") != null) return "url: needs an http/https URL";
    }
    return null;
}

fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |_| n += 1;
    return n;
}

/// Markup a value must never carry. The plan's list, plus the inline
/// styling runs and newlines: any of them lets a value raise its own score
/// or reshape the block it lands in, which is the model touching layout.
const inert_tokens = [_][]const u8{ "![[", "[[", "[^", "](", "> [!", "```", "{{", "{%", "**", "__", "~~", "==", "`", "|" };

/// The first contract violation in any string inside `value`, or null.
pub fn inertViolation(value: Value) ?[]const u8 {
    switch (value) {
        .string => |s| return inertString(s),
        .array => |a| for (a.items) |v| {
            if (inertViolation(v)) |why| return why;
        },
        .object => |o| for (o.values()) |v| {
            if (inertViolation(v)) |why| return why;
        },
        else => {},
    }
    return null;
}

fn inertString(s: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return "newline";
    for (inert_tokens) |t| {
        if (std.mem.indexOf(u8, s, t) != null) return t;
    }
    for (s, 0..) |c, i| {
        if (c != '<' or i + 1 >= s.len) continue;
        const n = s[i + 1];
        if (std.ascii.isAlphabetic(n) or n == '/' or n == '!') return "<tag";
    }
    const t = std.mem.trimStart(u8, s, " \t");
    if (t.len == 0) return null;
    switch (t[0]) {
        '#' => return "# heading",
        '>' => return "> quote",
        '-', '*', '+' => if (t.len > 1 and t[1] == ' ') return "list marker",
        else => {},
    }
    var d: usize = 0;
    while (d < t.len and std.ascii.isDigit(t[d])) d += 1;
    if (d > 0 and d + 1 < t.len and (t[d] == '.' or t[d] == ')') and t[d + 1] == ' ') return "list marker";
    return null;
}

/// Evidence quotes from `data.sources[*]` (objects with `quote` or `text`,
/// or bare strings).
pub fn dataEvidence(arena: std.mem.Allocator, data: ObjectMap) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const src = data.get("sources") orelse return out.items;
    if (src != .array) return out.items;
    for (src.array.items) |item| switch (item) {
        .string => |s| try out.append(arena, s),
        .object => |o| if (str(o, "quote") orelse str(o, "text")) |q| try out.append(arena, q),
        else => {},
    };
    return out.items;
}

/// Heuristic verifier (layer 4): every evidence-flagged string in the value
/// must be a whitespace-normalized verbatim substring of one evidence item.
/// Private until lane M2's `verifier.checkCitation` lands on main.
pub fn checkEvidence(arena: std.mem.Allocator, s: Slot, value: Value, evidence: []const []const u8) !?[]const u8 {
    var claims: std.ArrayList([]const u8) = .empty;
    if (s.field.evidence and value == .string) try claims.append(arena, value.string);
    if (value == .object) for (s.field.sub) |f| {
        if (!f.evidence) continue;
        if (value.object.get(f.name)) |v| if (v == .string) try claims.append(arena, v.string);
    };
    for (claims.items) |claim| {
        if (evidence.len == 0) return "no-evidence";
        const want = try normalize(arena, claim);
        for (evidence) |e| {
            if (std.mem.indexOf(u8, try normalize(arena, e), want) != null) break;
        } else return "not-verbatim";
    }
    return null;
}

fn normalize(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var first = true;
    while (it.next()) |w| {
        if (!first) try aw.writer.writeByte(' ');
        try aw.writer.writeAll(w);
        first = false;
    }
    return aw.written();
}

/// Every format_check rule fires no more often than it already did.
fn warnsSubset(new: []const formatcheck.Warning, old: []const formatcheck.Warning) bool {
    for (new) |w| {
        var n_new: usize = 0;
        var n_old: usize = 0;
        for (new) |x| n_new += @intFromBool(std.mem.eql(u8, x.rule, w.rule));
        for (old) |x| n_old += @intFromBool(std.mem.eql(u8, x.rule, w.rule));
        if (n_new > n_old) return false;
    }
    return true;
}

// --- Backend replies ---------------------------------------------------------

pub const Reply = union(enum) {
    declined,
    value: Value,
    /// Not JSON; the detail says why.
    bad: []const u8,
};

/// Trim, strip one code fence, parse. `null` is the model declining.
pub fn parseReply(arena: std.mem.Allocator, text: []const u8) Reply {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
        t = t[nl..];
        if (std.mem.lastIndexOf(u8, t, "```")) |end| t = t[0..end];
        t = std.mem.trim(u8, t, " \t\r\n");
    }
    const v = std.json.parseFromSliceLeaky(Value, arena, t, .{}) catch return .{ .bad = "reply is not JSON" };
    return if (v == .null) .declined else .{ .value = v };
}

// --- The loop (plan section 2.4) ---------------------------------------------

pub const Reason = enum {
    ok,
    schema,
    inert,
    render,
    verifier,
    no_gain,
    new_warnings,
    declined,

    pub fn label(r: Reason) []const u8 {
        return switch (r) {
            .no_gain => "no-gain",
            .new_warnings => "new-warnings",
            else => @tagName(r),
        };
    }
};

pub const Stop = enum { ceiling, plateau, stalled, max_iterations, budget };

pub const Step = struct {
    iteration: usize,
    slot: []const u8,
    probe_gain: f64,
    gain: f64 = 0,
    accepted: bool = false,
    reason: Reason = .ok,
    detail: []const u8 = "",
};

pub const Options = struct {
    max_iterations: usize = default_max_iterations,
    epsilon: f64 = epsilon,
    tone: ?[]const u8 = null,
    /// Mock backend table: slot path -> array of canned values, used in
    /// order. A slot with no (or no more) values declines.
    mock: ObjectMap = .empty,
};

pub const Outcome = union(enum) {
    /// The starting data does not render: a data error, not the ratchet's.
    start_failed: []engine.Diag,
    done: Result,
};

pub const Result = struct {
    data: ObjectMap,
    doc: []const u8,
    start: f64,
    final: f64,
    /// Best score the probe policy reaches with stub values (`stubCeiling`).
    ceiling: f64,
    iterations: usize,
    calls: usize,
    /// k4o renders: the start, the ceiling climb, probes, and candidates.
    renders: usize,
    /// The part of `renders` spent on the ceiling climb.
    ceiling_renders: usize,
    ms: f64,
    stop: Stop,
    slots: usize,
    fill_start: usize,
    fill_final: usize,
    steps: []const Step,
    rejections: std.EnumArray(Reason, usize),

    pub fn converged(r: Result) bool {
        return r.stop == .ceiling or r.stop == .plateau;
    }

    pub fn accepted(r: Result) usize {
        return r.rejections.get(.ok);
    }
};

const Best = struct {
    data: ObjectMap,
    doc: []const u8,
    score: f64,
    warns: []const formatcheck.Warning,
};

const Rendered = union(enum) {
    ok: Best,
    diag: []const u8,
};

const Run = struct {
    ctx: *Ctx,
    kind: backend.Kind,
    tpl: []const u8,
    shape: Shape,
    opts: Options,
    evidence: []const []const u8,
    renders: usize = 0,
    mock_used: std.StringHashMapUnmanaged(usize) = .empty,

    fn render(r: *Run, data: ObjectMap) Error!Rendered {
        const a = r.ctx.arena;
        const json = try std.json.Stringify.valueAlloc(a, Value{ .object = data }, .{});
        const path = try store.scratchFile(r.ctx, "json");
        std.Io.Dir.writeFile(.cwd(), r.ctx.io, .{ .sub_path = path, .data = json }) catch
            return r.ctx.fail("cannot stage data file", .{});
        r.renders += 1;
        switch (try engine.render(r.ctx, .markdown, r.tpl, path)) {
            .ok => |doc| {
                const sc = try density.score(a, doc);
                return .{ .ok = .{ .data = data, .doc = doc, .score = sc.total, .warns = sc.warnings } };
            },
            .diags => |d| return .{ .diag = if (d.len > 0) d[0].detail else "render failed" },
        }
    }

    fn ask(r: *Run, s: Slot, best: ObjectMap) Error!Reply {
        const a = r.ctx.arena;
        if (r.kind == .mock) {
            const list = r.opts.mock.get(s.path) orelse return .declined;
            if (list != .array) return .declined;
            const used = try r.mock_used.getOrPut(a, s.path);
            if (!used.found_existing) used.value_ptr.* = 0;
            const i = used.value_ptr.*;
            used.value_ptr.* += 1;
            if (i >= list.array.items.len) return .declined;
            // Through text and back, so mock replies take the live parse path.
            return parseReply(a, try std.json.Stringify.valueAlloc(a, list.array.items[i], .{}));
        }
        const slice = try buildSlice(a, s, r.shape, best, r.evidence, r.opts.tone);
        if (r.ctx.environ.get("KNAP_DEBUG") != null) std.debug.print("ratchet slice ({d} bytes):\n{s}", .{ slice.len, slice });
        return parseReply(a, try backend.complete(r.ctx, r.kind, .enrich, enrich_prefix, slice));
    }
};

const Cand = struct { slot: usize, gain: f64 };

fn candLess(_: void, x: Cand, y: Cand) bool {
    if (x.gain != y.gain) return x.gain > y.gain;
    return x.slot < y.slot;
}

/// The template's own ceiling: the same greedy probe policy with stub
/// values, for at most `max_iterations` steps. The plan's "stub every slot
/// at once" overshoots into the curves' overload decay (reading-note's
/// all-stub render scores 47 against a reachable 70), which would stop the
/// loop early.
fn stubCeiling(r: *Run, start: Best, opts: Options) Error!f64 {
    const a = r.ctx.arena;
    var cur = start;
    for (0..opts.max_iterations) |_| {
        var next: ?Best = null;
        for (r.shape.slots) |s| {
            if (!canGrow(cur.data, s)) continue;
            switch (try r.render(try withValue(a, cur.data, s, try stub(a, cur.data, s)))) {
                .ok => |p| if (p.score - cur.score >= opts.epsilon and (next == null or p.score > next.?.score)) {
                    next = p;
                },
                .diag => {},
            }
        }
        cur = next orelse break;
    }
    return cur.score;
}

/// Run the ratchet on `data0` against the template at `tpl_path`.
pub fn run(
    ctx: *Ctx,
    kind: backend.Kind,
    tpl_path: []const u8,
    shape: Shape,
    data0: ObjectMap,
    opts: Options,
) Error!Outcome {
    if (kind != .mock and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    const a = ctx.arena;
    const t0 = std.Io.Timestamp.now(ctx.io, .awake);
    var r: Run = .{ .ctx = ctx, .kind = kind, .tpl = tpl_path, .shape = shape, .opts = opts, .evidence = try dataEvidence(a, data0) };
    const slots = shape.slots;

    var best = switch (try r.render(data0)) {
        .ok => |b| b,
        .diag => {
            const path = try store.scratchFile(ctx, "json");
            std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(a, Value{ .object = data0 }, .{}) }) catch
                return ctx.fail("cannot stage data file", .{});
            return switch (try engine.render(ctx, .markdown, tpl_path, path)) {
                .diags => |d| .{ .start_failed = d },
                .ok => ctx.fail("start render was flaky", .{}),
            };
        },
    };
    const start = best.score;

    const ceiling = try stubCeiling(&r, best, opts);
    const ceiling_renders = r.renders - 1;

    var steps: std.ArrayList(Step) = .empty;
    var rejections: std.EnumArray(Reason, usize) = .initFill(0);
    var calls: usize = 0;
    var iterations: usize = 0;
    var stop: ?Stop = null;
    const eps = opts.epsilon;

    outer: for (0..opts.max_iterations) |iter| {
        if (ceiling - best.score < eps) {
            stop = .ceiling;
            break;
        }
        var cands: std.ArrayList(Cand) = .empty;
        for (slots, 0..) |s, i| {
            if (!canGrow(best.data, s)) continue;
            switch (try r.render(try withValue(a, best.data, s, try stub(a, best.data, s)))) {
                .ok => |p| try cands.append(a, .{ .slot = i, .gain = p.score - best.score }),
                .diag => {},
            }
        }
        std.mem.sort(Cand, cands.items, {}, candLess);
        if (cands.items.len == 0 or cands.items[0].gain < eps) {
            stop = .plateau;
            break;
        }

        iterations = iter + 1;
        var accepted = false;
        for (cands.items[0..@min(top_k, cands.items.len)]) |c| {
            if (calls == max_backend_calls) {
                stop = .budget;
                break :outer;
            }
            const s = slots[c.slot];
            var step: Step = .{ .iteration = iter, .slot = s.path, .probe_gain = c.gain };
            const reply = try r.ask(s, best.data);
            calls += 1;
            judge: switch (reply) {
                .declined => step.reason = .declined,
                .bad => |why| {
                    step.reason = .schema;
                    step.detail = why;
                },
                .value => |v| {
                    if (try checkSchema(a, s, v, best.data)) |why| {
                        step.reason = .schema;
                        step.detail = why;
                        break :judge;
                    }
                    if (inertViolation(v)) |tok| {
                        step.reason = .inert;
                        step.detail = tok;
                        break :judge;
                    }
                    if (s.gated()) if (try checkEvidence(a, s, v, r.evidence)) |why| {
                        step.reason = .verifier;
                        step.detail = why;
                        break :judge;
                    };
                    const cand = switch (try r.render(try withValue(a, best.data, s, v))) {
                        .ok => |b| b,
                        .diag => |d| {
                            step.reason = .render;
                            step.detail = d;
                            break :judge;
                        },
                    };
                    step.gain = cand.score - best.score;
                    if (step.gain < eps) {
                        step.reason = .no_gain;
                    } else if (!warnsSubset(cand.warns, best.warns)) {
                        step.reason = .new_warnings;
                    } else {
                        step.accepted = true;
                        best = cand;
                    }
                },
            }
            rejections.getPtr(step.reason).* += 1;
            try steps.append(a, step);
            if (step.accepted) {
                accepted = true;
                break;
            }
        }
        if (!accepted) {
            stop = .stalled;
            break;
        }
    }

    const ns = t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).toNanoseconds();
    return .{ .done = .{
        .data = best.data,
        .doc = best.doc,
        .start = start,
        .final = best.score,
        .ceiling = ceiling,
        .iterations = iterations,
        .calls = calls,
        .renders = r.renders,
        .ceiling_renders = ceiling_renders,
        .ms = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms,
        .stop = stop orelse .max_iterations,
        .slots = slots.len,
        .fill_start = filled(data0, slots),
        .fill_final = filled(best.data, slots),
        .steps = steps.items,
        .rejections = rejections,
    } };
}

/// The enrich user message: the one slot, its schema and role, the page's
/// headline values, existing siblings, and as much evidence as fits under
/// `max_slice_bytes`.
pub fn buildSlice(
    arena: std.mem.Allocator,
    s: Slot,
    shape: Shape,
    data: ObjectMap,
    evidence: []const []const u8,
    tone: ?[]const u8,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("FIELD: {s}   ({s})\nSCHEMA: {s}\nROLE: {s}\n", .{
        s.path, if (s.isArray()) "append one item" else "fill this empty field", s.schema, s.role,
    });
    if (tone) |t| try w.print("TONE: {s}\n", .{t});

    var head: ObjectMap = .empty;
    for (shape.headline) |k| {
        const v = data.get(k) orelse continue;
        if (v == .string and v.string.len <= 160) try head.put(arena, k, v);
    }
    try w.writeAll("HEADLINE: ");
    try std.json.Stringify.value(Value{ .object = head }, .{}, w);
    try w.writeAll("\n");

    if (s.isArray()) {
        if (data.get(s.field.name)) |sib| {
            const text = try std.json.Stringify.valueAlloc(arena, sib, .{});
            if (aw.written().len + text.len + 64 < max_slice_bytes) try w.print("SIBLINGS: {s}\n", .{text});
        }
    }

    try w.writeAll("EVIDENCE: [");
    var n: usize = 0;
    for (evidence) |e| {
        const q = try std.json.Stringify.valueAlloc(arena, e, .{});
        if (aw.written().len + q.len + 3 > max_slice_bytes) break;
        if (n > 0) try w.writeAll(",");
        try w.writeAll(q);
        n += 1;
    }
    try w.writeAll("]\n");
    return aw.written();
}

// --- Output (plan section 2.8) -----------------------------------------------

pub fn writeResult(r: Result, data_id: []const u8, doc_id: []const u8, w: *std.Io.Writer) !void {
    try w.print("{{\"ok\":true,\"converged\":{s},\"stop\":\"{s}\",\"iterations\":{d},\"calls\":{d},\"renders\":{d},\"ceiling_renders\":{d},\"ms\":{d:.1}", .{
        if (r.converged()) "true" else "false", @tagName(r.stop), r.iterations, r.calls, r.renders, r.ceiling_renders, r.ms,
    });
    try w.print(",\"score\":{{\"scorer\":\"{s}\",\"start\":{d:.1},\"final\":{d:.1},\"ceiling\":{d:.1}", .{ density.version, r.start, r.final, r.ceiling });
    try w.print("}},\"slot_fill\":{{\"start\":\"{d}/{d}\",\"final\":\"{d}/{d}\"}}", .{ r.fill_start, r.slots, r.fill_final, r.slots });
    try w.print(",\"data_id\":\"{s}\",\"doc_id\":\"{s}\",\"rejections\":{{", .{ data_id, doc_id });
    var first = true;
    for (std.enums.values(Reason)) |reason| {
        if (reason == .ok) continue;
        try w.print("{s}\"{s}\":{d}", .{ if (first) "" else ",", reason.label(), r.rejections.get(reason) });
        first = false;
    }
    try w.writeAll("},\"steps\":[");
    for (r.steps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"iteration\":{d},\"slot\":", .{s.iteration});
        try std.json.Stringify.value(s.slot, .{}, w);
        try w.print(",\"probe_gain\":{d:.1},\"gain\":{d:.1},\"accepted\":{s},\"reason\":\"{s}\"", .{
            s.probe_gain, s.gain, if (s.accepted) "true" else "false", s.reason.label(),
        });
        if (s.detail.len > 0) {
            try w.writeAll(",\"detail\":");
            try std.json.Stringify.value(s.detail, .{}, w);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Mock table for a template from `eval/ratchet-mock.json`
/// (`{"templates":{"<template_id>":{"<slot path>":[values...]}}}`).
/// A missing file or template gives an empty table: every call declines.
pub fn loadMock(ctx: *Ctx, path: []const u8, template_id: []const u8) Error!ObjectMap {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(max_input)) catch return .empty;
    const root = std.json.parseFromSliceLeaky(Value, ctx.arena, bytes, .{}) catch
        return ctx.fail("mock table '{s}' is not valid JSON", .{path});
    if (root != .object) return .empty;
    const tpls = root.object.get("templates") orelse return .empty;
    if (tpls != .object) return .empty;
    const t = tpls.object.get(template_id) orelse return .empty;
    return if (t == .object) t.object else .empty;
}

pub fn mockPath(ctx: *Ctx) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}/eval/ratchet-mock.json", .{ctx.project_root});
}

// --- ratchet-eval ------------------------------------------------------------

const Case = struct {
    id: []const u8,
    tpl: []const u8,
    shape: []const u8,
    data: ObjectMap,
    mock: ObjectMap,
    expect: ?ObjectMap,
    max_iterations: usize,
};

const Row = struct {
    id: []const u8,
    result: ?Result = null,
    err: []const u8 = "",
    check: []const u8 = "ok",
};

/// `knap-mcp ratchet-eval [--corpus eval/ratchet.json] [--backend b]`:
/// one row per case, then the probe-cost summary. Exits 1 when any case
/// misses its `expect` block or errors.
pub fn cmdEval(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var corpus: []const u8 = "eval/ratchet.json";
    var kind = ctx.backend_kind;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const val = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--corpus")) {
            corpus = val;
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--corpus=")) {
            corpus = a["--corpus=".len..];
        } else if (std.mem.eql(u8, a, "--backend") or std.mem.startsWith(u8, a, "--backend=")) {
            const name = if (std.mem.indexOfScalar(u8, a, '=')) |eq| a[eq + 1 ..] else blk: {
                i += 1;
                break :blk val;
            };
            kind = backend.parseKind(name) orelse {
                std.debug.print("knap-mcp: unknown backend '{s}'\n", .{name});
                return 1;
            };
        } else {
            std.debug.print("knap-mcp: unknown option '{s}'\nusage: knap-mcp ratchet-eval [--corpus f] [--backend b]\n", .{a});
            return 1;
        }
    }

    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(ctx.io, &buf);
    const code = evalRun(ctx, corpus, kind, &fw.interface) catch |e| {
        fw.interface.flush() catch {};
        if (e == error.OutOfMemory) return e;
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else @errorName(e)});
        return 1;
    };
    try fw.interface.flush();
    return code;
}

pub fn evalRun(ctx: *Ctx, corpus_path: []const u8, kind: backend.Kind, w: *std.Io.Writer) Error!u8 {
    const a = ctx.arena;
    const dir = std.fs.path.dirname(corpus_path) orelse ".";
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, corpus_path, a, .limited(max_input)) catch
        return ctx.fail("cannot read corpus '{s}'", .{corpus_path});
    const root = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch
        return ctx.fail("corpus '{s}' is not valid JSON", .{corpus_path});
    if (root != .object) return ctx.fail("corpus root must be an object", .{});
    const cases_v = root.object.get("cases") orelse return ctx.fail("corpus needs a 'cases' array", .{});
    if (cases_v != .array) return ctx.fail("corpus 'cases' must be an array", .{});
    const mock_file = try resolve(ctx, dir, str(root.object, "mock") orelse "ratchet-mock.json");

    var rows: std.ArrayList(Row) = .empty;
    var failed = false;
    for (cases_v.array.items) |cv| {
        const c = try parseCase(ctx, dir, cv, mock_file);
        var row: Row = .{ .id = c.id };
        const shape = try loadShape(ctx, c.shape);
        const outcome = run(ctx, kind, c.tpl, shape, c.data, .{ .mock = c.mock, .max_iterations = c.max_iterations }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            row.err = if (e == error.ToolFailed) ctx.err_msg else @errorName(e);
            row.check = "ERROR";
            failed = true;
            try rows.append(a, row);
            continue;
        };
        switch (outcome) {
            .start_failed => |d| {
                row.err = d[0].detail;
                row.check = "ERROR: start render failed";
                failed = true;
            },
            .done => |res| {
                row.result = res;
                if (try checkExpect(a, res, c.expect)) |why| {
                    row.check = why;
                    failed = true;
                }
            },
        }
        try rows.append(a, row);
    }

    try w.print("backend: {s}   corpus: {s}   scorer: {s}   max_iters: {d}   eps: {d:.1}   top_k: {d}   max_calls: {d}\n\n", .{
        @tagName(kind), corpus_path, density.version, default_max_iterations, epsilon, top_k, max_backend_calls,
    });
    try w.writeAll("| case | start | final | gain | ceiling | iters | calls | accepted | schema | inert | render | verifier | no-gain | warn | declined | renders | ms | stop | check |\n");
    try w.writeAll("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|---|\n");
    var runs: usize = 0;
    var renders: usize = 0;
    var ms: f64 = 0;
    for (rows.items) |row| {
        const r = row.result orelse {
            try w.print("| {s} | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - | {s}: {s} |\n", .{ row.id, row.check, row.err });
            continue;
        };
        runs += 1;
        renders += r.renders;
        ms += r.ms;
        const rj = r.rejections;
        try w.print("| {s} | {d:.1} | {d:.1} | {d:.1} | {d:.1}", .{ row.id, r.start, r.final, r.final - r.start, r.ceiling });
        try w.print(" | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d:.0} | {s} | {s} |\n", .{
            r.iterations,    r.calls,           r.accepted(),     rj.get(.schema),       rj.get(.inert),
            rj.get(.render), rj.get(.verifier), rj.get(.no_gain), rj.get(.new_warnings), rj.get(.declined),
            r.renders,       r.ms,              @tagName(r.stop), row.check,
        });
    }
    if (runs > 0) {
        const n: f64 = @floatFromInt(runs);
        try w.print("\nprobe cost: {d} renders in {d} runs ({d:.1} renders/run), {d:.0} ms/run mean wall\n", .{
            renders, runs, @as(f64, @floatFromInt(renders)) / n, ms / n,
        });
    }
    // Per-case JSON (steps included) lands in the store: a handle, not a paste.
    var rep: std.Io.Writer.Allocating = .init(a);
    try rep.writer.print("{{\"backend\":\"{s}\",\"corpus\":", .{@tagName(kind)});
    try std.json.Stringify.value(corpus_path, .{}, &rep.writer);
    try rep.writer.writeAll(",\"cases\":[");
    for (rows.items, 0..) |row, n| {
        if (n > 0) try rep.writer.writeAll(",");
        try rep.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(row.id, .{}, &rep.writer);
        try rep.writer.writeAll(",\"check\":");
        try std.json.Stringify.value(row.check, .{}, &rep.writer);
        try rep.writer.writeAll(",\"result\":");
        if (row.result) |res| try writeResult(res, "", "", &rep.writer) else try rep.writer.writeAll("null");
        try rep.writer.writeAll("}");
    }
    try rep.writer.writeAll("]}");
    const report_id = try store.put(ctx, "ratchet.json", rep.written());
    try w.print("{s}\nreport: knap://docs/{s}\n", .{ if (failed) "FAIL: a case missed its expectations" else "all expectations met", report_id });
    return @intFromBool(failed);
}

fn parseCase(ctx: *Ctx, dir: []const u8, cv: Value, mock_file: []const u8) Error!Case {
    if (cv != .object) return ctx.fail("each case must be an object", .{});
    const o = cv.object;
    const id = str(o, "id") orelse return ctx.fail("case needs an 'id'", .{});
    var tpl: []const u8 = undefined;
    var shape: []const u8 = undefined;
    if (str(o, "template_id")) |tid| {
        if (std.mem.indexOfAny(u8, tid, "/\\") != null or std.mem.indexOf(u8, tid, "..") != null)
            return ctx.fail("case '{s}': invalid template_id", .{id});
        tpl = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.knap", .{ ctx.templates_dir, tid });
        shape = try std.fmt.allocPrint(ctx.arena, "{s}/shapes/{s}.json", .{ ctx.templates_dir, tid });
    } else {
        tpl = try resolve(ctx, dir, str(o, "template_path") orelse return ctx.fail("case '{s}' needs template_id or template_path", .{id}));
        shape = try resolve(ctx, dir, str(o, "shape_path") orelse return ctx.fail("case '{s}' needs shape_path", .{id}));
    }

    const data: ObjectMap = switch (o.get("data") orelse return ctx.fail("case '{s}' needs 'data'", .{id})) {
        .object => |d| d,
        .string => |ref| blk: {
            if (ref.len < 2 or ref[0] != '@') return ctx.fail("case '{s}': data string must be '@path'", .{id});
            const p = try resolve(ctx, dir, ref[1..]);
            const b = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, p, ctx.arena, .limited(max_input)) catch
                return ctx.fail("case '{s}': cannot read '{s}'", .{ id, p });
            const v = std.json.parseFromSliceLeaky(Value, ctx.arena, b, .{}) catch
                return ctx.fail("case '{s}': '{s}' is not valid JSON", .{ id, p });
            if (v != .object) return ctx.fail("case '{s}': data must be an object", .{id});
            break :blk v.object;
        },
        else => return ctx.fail("case '{s}': data must be an object or '@path'", .{id}),
    };

    // Per-case mock values replace the shared table's, path by path.
    const sh = try loadShape(ctx, shape);
    var mock = try (try loadMock(ctx, mock_file, sh.template_id)).clone(ctx.arena);
    if (o.get("mock")) |mv| {
        if (mv != .object) return ctx.fail("case '{s}': mock must be an object", .{id});
        var it = mv.object.iterator();
        while (it.next()) |e| try mock.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
    }
    const expect: ?ObjectMap = if (o.get("expect")) |ev| (if (ev == .object) ev.object else null) else null;
    const iters = int(o, "max_iterations") orelse default_max_iterations;
    return .{ .id = id, .tpl = tpl, .shape = shape, .data = data, .mock = mock, .expect = expect, .max_iterations = iters };
}

/// `{"min_gain": n, "stop": "plateau", "min_accepted": n,
///   "reject": {"<reason>": n}}`: every key present must hold.
fn checkExpect(arena: std.mem.Allocator, r: Result, expect: ?ObjectMap) !?[]const u8 {
    const e = expect orelse return null;
    if (e.get("min_gain")) |v| {
        const want: f64 = switch (v) {
            .integer => |x| @floatFromInt(x),
            .float => |x| x,
            else => 0,
        };
        if (r.final - r.start < want) return try std.fmt.allocPrint(arena, "FAIL: gain {d:.1} < {d:.1}", .{ r.final - r.start, want });
    }
    if (str(e, "stop")) |want| {
        if (!std.mem.eql(u8, want, @tagName(r.stop))) return try std.fmt.allocPrint(arena, "FAIL: stop {s}, want {s}", .{ @tagName(r.stop), want });
    }
    if (int(e, "min_accepted")) |want| {
        if (r.accepted() < want) return try std.fmt.allocPrint(arena, "FAIL: accepted {d} < {d}", .{ r.accepted(), want });
    }
    if (e.get("reject")) |rv| {
        if (rv != .object) return "FAIL: reject must be an object";
        var it = rv.object.iterator();
        while (it.next()) |kv| {
            const reason = for (std.enums.values(Reason)) |x| {
                if (std.mem.eql(u8, x.label(), kv.key_ptr.*)) break x;
            } else return try std.fmt.allocPrint(arena, "FAIL: unknown reason '{s}'", .{kv.key_ptr.*});
            const want: usize = if (kv.value_ptr.* == .integer and kv.value_ptr.integer > 0) @intCast(kv.value_ptr.integer) else 1;
            if (r.rejections.get(reason) < want)
                return try std.fmt.allocPrint(arena, "FAIL: {s} {d} < {d}", .{ reason.label(), r.rejections.get(reason), want });
        }
    }
    return null;
}

/// `rel` against the corpus dir, then the cwd, then the project root.
fn resolve(ctx: *Ctx, dir: []const u8, rel: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return rel;
    const candidates = [_][]const u8{
        try std.fs.path.join(ctx.arena, &.{ dir, rel }),
        rel,
        try std.fs.path.join(ctx.arena, &.{ ctx.project_root, rel }),
    };
    for (candidates) |p| {
        std.Io.Dir.access(.cwd(), ctx.io, p, .{}) catch continue;
        return p;
    }
    return candidates[0];
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

const test_shape =
    \\{"template_id":"t","fields":{
    \\ "title":{"type":"string","role":"heading"},
    \\ "cover":{"type":"string","optional":true,"apparatus":"image"},
    \\ "author":{"type":"string","optional":true,"apparatus":"wikilink","words":3},
    \\ "pull":{"type":"string","optional":true,"apparatus":"quote","evidence":true},
    \\ "tags":{"type":"array<string>","optional":true,"apparatus":"frontmatter","max_items":2},
    \\ "quotes":{"type":"array<object>","apparatus":"quote","max_items":3,"fields":{
    \\   "text":{"type":"string","evidence":true},
    \\   "kind":{"type":"string","enum":["warning","tip"]},
    \\   "note":{"type":"string","optional":true,"ref":"notes"}}},
    \\ "grid":{"type":"array<array<string>>","optional":true,"apparatus":"table","cells":2},
    \\ "notes":{"type":"object<string,string>","optional":true,"apparatus":"footnote"},
    \\ "voiceonly":{"type":"string","optional":true,"voice":true},
    \\ "body":{"type":"array<string>","role":"required, unbounded","apparatus":"list"}}}
;

fn testData(a: std.mem.Allocator, json: []const u8) !ObjectMap {
    return (try std.json.parseFromSliceLeaky(Value, a, json, .{})).object;
}

fn slotNamed(sh: Shape, path: []const u8) Slot {
    for (sh.slots) |s| if (std.mem.eql(u8, s.path, path)) return s;
    @panic("no slot");
}

test "slots: apparatus-annotated, growable kinds, required only with max_items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sh = try parseShape(arena.allocator(), test_shape);
    var paths: std.ArrayList(u8) = .empty;
    for (sh.slots) |s| {
        try paths.appendSlice(arena.allocator(), s.path);
        try paths.append(arena.allocator(), ' ');
    }
    // notes (object map), voiceonly (no apparatus), body (required, no
    // max_items) and title are not slots.
    try testing.expectEqualStrings("cover author pull tags[+] quotes[+] grid[+] ", paths.items);
    try testing.expect(slotNamed(sh, "cover").field.url);
    try testing.expect(slotNamed(sh, "author").field.page);
    try testing.expect(slotNamed(sh, "quotes[+]").gated());
    try testing.expectEqual(@as(usize, 1), sh.headline.len);
}

test "canGrow and withValue never touch a non-empty value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const d = try testData(a,
        \\{"title":"T","cover":"","author":"Ann","tags":["a"]}
    );
    try testing.expect(canGrow(d, slotNamed(sh, "cover")));
    try testing.expect(!canGrow(d, slotNamed(sh, "author")));
    try testing.expect(canGrow(d, slotNamed(sh, "tags[+]")));
    const d2 = try withValue(a, d, slotNamed(sh, "tags[+]"), .{ .string = "b" });
    try testing.expect(!canGrow(d2, slotNamed(sh, "tags[+]")));
    try testing.expectEqual(@as(usize, 1), d.get("tags").?.array.items.len);
    try testing.expectEqual(@as(usize, 2), d2.get("tags").?.array.items.len);
}

test "stubs are shape-typed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const d = try testData(a, "{}");
    try testing.expectEqualStrings("https://example.com/probe", (try stub(a, d, slotNamed(sh, "cover"))).string);
    try testing.expectEqualStrings("Probe page", (try stub(a, d, slotNamed(sh, "author"))).string);
    const q = try stub(a, d, slotNamed(sh, "quotes[+]"));
    try testing.expectEqualStrings("warning", q.object.get("kind").?.string);
    try testing.expect(q.object.get("note") == null);
    try testing.expectEqual(@as(usize, 2), (try stub(a, d, slotNamed(sh, "grid[+]"))).array.items.len);
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, slotNamed(sh, "quotes[+]"), q, d));
}

test "schema check: enum, url, unknown and missing fields, ref, row width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const d = try testData(a,
        \\{"notes":{"n1":"a note"},"grid":[["a","b"]]}
    );
    const q = slotNamed(sh, "quotes[+]");
    const ok = try testData(a,
        \\{"text":"x","kind":"tip","note":"n1"}
    );
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, q, .{ .object = ok }, d));
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"text\":\"x\",\"kind\":\"danger\"}", "kind: enum: 'danger' is not one of warning|tip" },
        .{ "{\"text\":\"x\",\"kind\":\"tip\",\"extra\":\"y\"}", "unknown field 'extra'" },
        .{ "{\"kind\":\"tip\"}", "missing field 'text'" },
        .{ "{\"text\":\"x\",\"kind\":\"tip\",\"note\":\"n9\"}", "ref: note 'n9' is not a key in 'notes'" },
    };
    for (cases) |c| {
        const why = (try checkSchema(a, q, .{ .object = try testData(a, c[0]) }, d)).?;
        try testing.expectEqualStrings(c[1], why);
    }
    try testing.expectEqualStrings("url: needs an http/https URL", (try checkSchema(a, slotNamed(sh, "cover"), .{ .string = "ftp://x" }, d)).?);
    const row = try std.json.parseFromSliceLeaky(Value, a, "[\"a\",\"b\",\"c\"]", .{});
    try testing.expectEqualStrings("row has 3 cells, table has 2", (try checkSchema(a, slotNamed(sh, "grid[+]"), row, d)).?);
    try testing.expectEqualStrings("expected a string", (try checkSchema(a, slotNamed(sh, "author"), .{ .integer = 3 }, d)).?);
}

test "isInert rejects markup anywhere in a value" {
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "see [[Page]]", "[[" },
        .{ "![[Embed]]", "![[" },
        .{ "a claim[^1]", "[^" },
        .{ "[x](http://y)", "](" },
        .{ "> [!tip] hi", "> [!" },
        .{ "# Heading", "# heading" },
        .{ "| a | b |", "|" },
        .{ "```zig", "```" },
        .{ "<b>bold</b>", "<tag" },
        .{ "{{ x }}", "{{" },
        .{ "{% if %}", "{%" },
        .{ "very **bold**", "**" },
        .{ "two\nparagraphs", "newline" },
        .{ "- a list", "list marker" },
        .{ "1. first", "list marker" },
    };
    for (bad) |b| try testing.expectEqualStrings(b[1], inertString(b[0]).?);
    const good = [_][]const u8{ "Plain prose, with commas.", "3 < 4 and 5 > 2", "1.9.x", "C# is fine-ish" };
    for (good) |g| try testing.expect(inertString(g) == null);
}

test "verifier: whitespace-normalized verbatim substrings only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const ev = [_][]const u8{"The Machine is much,  but it is\nnot everything. Men made it."};
    const pull = slotNamed(sh, "pull");
    try testing.expectEqual(@as(?[]const u8, null), try checkEvidence(a, pull, .{ .string = "The Machine is much, but it is not everything." }, &ev));
    try testing.expectEqualStrings("not-verbatim", (try checkEvidence(a, pull, .{ .string = "The Machine is a lot, but not everything." }, &ev)).?);
    try testing.expectEqualStrings("no-evidence", (try checkEvidence(a, pull, .{ .string = "x" }, &.{})).?);
}

test "parseReply strips fences and treats null as declining" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parseReply(a, " null ") == .declined);
    try testing.expectEqualStrings("hi", parseReply(a, "```json\n\"hi\"\n```").value.string);
    try testing.expect(parseReply(a, "Sure! here you go") == .bad);
}

test "slice stays under the byte cap with large evidence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const d = try testData(a, "{\"title\":\"T\"}");
    const big: [200]u8 = @splat('x');
    const ev: [64][]const u8 = @splat(&big);
    const slice = try buildSlice(a, slotNamed(sh, "pull"), sh, d, &ev, "spicy");
    try testing.expect(slice.len <= max_slice_bytes);
    try testing.expect(std.mem.indexOf(u8, slice, "FIELD: pull") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "HEADLINE: {\"title\":\"T\"}") != null);
}

test "warnsSubset compares rule counts, not lines" {
    const W = formatcheck.Warning;
    const old = [_]W{.{ .rule = "raw-url-count", .line = 3, .detail = "" }};
    const moved = [_]W{.{ .rule = "raw-url-count", .line = 9, .detail = "" }};
    const more = [_]W{ .{ .rule = "raw-url-count", .line = 9, .detail = "" }, .{ .rule = "skipped-heading", .line = 1, .detail = "" } };
    try testing.expect(warnsSubset(&moved, &old));
    try testing.expect(!warnsSubset(&more, &old));
}
