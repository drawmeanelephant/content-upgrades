//! The ratchet loop: values-only density climbing (docs/tracks/next-phase-plan.md
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
//!
//! Footnotes are the one paired write: a `notes{+}` slot appends one key
//! to an `object<string,string>` map and, in the same write, sets the empty
//! `ref` field of an existing array element to that key. The server picks
//! the element and the key slug; the model writes only the note text.
//!
//! Block palettes extend "the server picks the slot" to "the server picks
//! the block kind". A `palette` slot is an `array<object>` whose items
//! carry an enum `variant` field; `variants` names the item fields each
//! kind uses, and the template renders each kind with its own
//! `{% if s.kind == "..." %}` branch. Probing expands the slot into one
//! candidate per kind (`sections[+]:steps`, ...) that stubs only that
//! kind's fields, and ranks them with every other slot by stub gain, so
//! the scorer's variety gradient decides which kind a doc gets next. The
//! slice names the server-chosen kind and asks only for its fields; a
//! reply that sets another kind, or fills another kind's fields, is a
//! `schema` rejection. Each iteration probes at most `max_variant_probes`
//! kinds of a palette, in a round-robin window (see that constant).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const density = @import("density.zig");
const formatcheck = @import("formatcheck.zig");
const store = @import("store.zig");
const verifier = @import("verifier.zig");
const borisrag = @import("borisrag.zig");

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
/// Kinds of one palette slot probed per iteration (and per stubCeiling
/// step). A palette costs `min(kinds, max_variant_probes)` probe renders
/// per iteration instead of one; renders are not backend calls, so asks
/// still draw on `max_backend_calls` exactly as any other slot's do.
/// The window is round-robin over the shape's enum order, starting at
/// `iteration * max_variant_probes`: deterministic, starvation-free
/// (every kind is probed within ceil(kinds / 3) iterations), stateless,
/// so stubCeiling replays the same policy. A last-gain order would starve
/// kinds first probed on a short doc, where the length factor shrinks
/// every gain. Three, not two, so consecutive windows overlap on a
/// four-kind palette: the variety gradient, not the cursor, has to choose
/// between a kind already on the page and a new one.
pub const max_variant_probes = 3;
/// Stub size for a string slot with no `words` annotation.
const default_stub_words = 8;
/// Growth bound for an array slot with no `max_items` annotation.
const default_max_items = 3;
/// Fallback `max_words` for a string field with `words` but no
/// `max_words`: `words` sizes the probe stub, not a target length, so the
/// default is a bounded multiple of it. The corpus's own values run to
/// ~5x the stub (a 21-word bullet on a `words: 4` slot) and its no-gain
/// wall to ~13x, so 16 bounds a runaway reply — before this, only the
/// backend's stdout cap did — without re-tuning every expectation.
/// Fields that need real length discipline still set `max_words`
/// (the callouts shape does, at ~2x).
const default_max_words_factor = 16;
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
pub const Apparatus = enum { footnote, callout, wikilink, embed, image, link, fragment_link, table, quote, frontmatter, list, code, palette };

/// Value kinds the ratchet can grow. `keyed` is an `object<string,string>`
/// map (footnote notes) that grows one key at a time through a paired
/// write; it is a slot only when some array<object> item field `ref`s it.
pub const Kind = enum { string, number, strings, objects, rows, keyed, other };

/// Longest server-chosen footnote key, in kebab words and bytes.
const max_key_words = 4;
const max_key_len = 32;

/// A field whose value must be a key of the map `target`: a top-level
/// string or array<string> (`sub == null`), or the item field `sub` of an
/// array<object>.
pub const RefSite = struct {
    field: []const u8,
    sub: ?[]const u8 = null,
    target: []const u8,
    /// The item's first required plain string field: the footnote key is
    /// its kebab form.
    label: ?[]const u8 = null,
};

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
    /// Rendered verbatim inside a fenced code block: the inert rule is
    /// literal-safe and the evidence gate is exact-substring.
    code: bool = false,
    words: usize = default_stub_words,
    /// Item bound of an array item field (palette `items`); top-level
    /// slots keep theirs on `Slot.max_items`.
    max_items: ?usize = null,
    /// Item fields of an array<object>.
    sub: []const Field = &.{},
};

/// One kind of a palette slot: the item fields it uses, led by the variant
/// field narrowed to this kind, all required.
pub const Variant = struct {
    name: []const u8,
    sub: []const Field,
    /// SCHEMA for this kind's slice.
    schema: []const u8,
    /// `name[+]:kind`: the step label and mock key.
    path: []const u8,
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
    /// `name` for scalars, `name[+]` for arrays, `name{+}` for keyed maps.
    path: []const u8,
    /// Keyed slots: the item ref fields a new key can anchor to, in shape
    /// order.
    hosts: []const RefSite = &.{},
    /// Palette slots: the item field naming the kind, and the kinds in
    /// enum order. Never probed or asked as-is, only through `pick`.
    variant: ?[]const u8 = null,
    variants: []const Variant = &.{},
    /// Set on a `pick`ed slot: the server-chosen kind.
    chosen: ?[]const u8 = null,

    /// The palette slot narrowed to kind `k`: its fields, schema and path.
    pub fn pick(s: Slot, k: usize) Slot {
        const v = s.variants[k];
        var p = s;
        p.field.sub = v.sub;
        p.schema = v.schema;
        p.path = v.path;
        p.chosen = v.name;
        p.variants = &.{};
        return p;
    }

    pub fn isArray(s: Slot) bool {
        return switch (s.field.kind) {
            .strings, .objects, .rows => true,
            else => false,
        };
    }

    pub fn gated(s: Slot) bool {
        if (s.field.code) return true;
        if (s.field.evidence) return true;
        for (s.field.sub) |f| if (f.evidence or f.code) return true;
        return false;
    }
};

pub const Shape = struct {
    template_id: []const u8,
    slots: []const Slot,
    /// Required top-level string fields: the HEADLINE context of a slice.
    headline: []const []const u8,
    /// Every `ref` in the shape, for document-level ref integrity.
    refs: []const RefSite = &.{},
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

    const refs = try parseRefs(arena, fields.object);
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
        // A code slot renders one line verbatim inside a fence; only a
        // string (or one string item) can fill it.
        if (apparatus == .code and f.kind != .string and f.kind != .strings) return error.BadShape;
        const has_max = spec.object.get("max_items") != null;
        // A required field grows only when the shape bounds it.
        if (f.kind == .other or (!f.optional and !has_max)) continue;
        var hosts: std.ArrayList(RefSite) = .empty;
        if (f.kind == .keyed) {
            for (refs) |rs| if (rs.sub != null and std.mem.eql(u8, rs.target, name)) try hosts.append(arena, rs);
            // A key nothing can reference only adds an unused footnote.
            if (hosts.items.len == 0) continue;
        }
        // evidenceClaims can only quote strings; on any other slot kind
        // the evidence flag would gate the slot but verify nothing.
        if (f.evidence and f.kind != .string and f.kind != .strings and f.kind != .keyed) return error.BadShape;
        // The slice carries ROLE on its own line; keep it out of SCHEMA.
        // SCHEMA describes the single value expected for one step, not the
        // container array/map around it.
        var schema = try spec.object.clone(arena);
        _ = schema.orderedRemove("role");
        _ = schema.orderedRemove("max_items");
        _ = schema.orderedRemove("variant");
        _ = schema.orderedRemove("variants");
        try schema.put(arena, "type", .{ .string = switch (f.kind) {
            .string, .strings, .keyed => "string",
            .number => "number",
            .objects => "object",
            .rows => "array<string>",
            .other => unreachable,
        } });
        var slot: Slot = .{
            .field = f,
            .apparatus = apparatus,
            .max_items = int(spec.object, "max_items") orelse default_max_items,
            .cells = int(spec.object, "cells") orelse 0,
            .role = str(spec.object, "role") orelse "",
            .schema = try std.json.Stringify.valueAlloc(arena, Value{ .object = schema }, .{}),
            .path = name,
            .hosts = hosts.items,
        };
        if (!slot.isArray() and f.kind != .keyed) slot.max_items = 1;
        slot.field.url = apparatus == .image or apparatus == .link;
        slot.field.page = apparatus == .wikilink or apparatus == .embed;
        slot.field.code = apparatus == .code;
        if (slot.isArray()) slot.path = try std.fmt.allocPrint(arena, "{s}[+]", .{name});
        if (f.kind == .keyed) slot.path = try std.fmt.allocPrint(arena, "{s}{{+}}", .{name});
        if (apparatus == .palette or spec.object.get("variant") != null or spec.object.get("variants") != null) {
            if (apparatus != .palette or f.kind != .objects) return error.BadShape;
            slot.variant = str(spec.object, "variant") orelse return error.BadShape;
            slot.variants = try parseVariants(arena, spec.object, f, slot.path);
        }
        try slots.append(arena, slot);
    }
    return .{ .template_id = id, .slots = slots.items, .headline = headline.items, .refs = refs };
}

/// A palette's kinds, in the variant field's enum order. `variants` keys
/// and the enum must match exactly, every listed field must be an item
/// field other than the variant itself, and an item field the shape marks
/// required must be listed by every kind. Anything else is BadShape.
fn parseVariants(arena: std.mem.Allocator, spec: ObjectMap, f: Field, path: []const u8) ![]const Variant {
    const vname = str(spec, "variant") orelse return error.BadShape;
    const vv = spec.get("variants") orelse return error.BadShape;
    if (vv != .object) return error.BadShape;
    const vf = subField(f, vname) orelse return error.BadShape;
    if (vf.kind != .string or vf.optional or vf.enum_values.len == 0) return error.BadShape;
    for (vf.enum_values, 0..) |e, i| {
        for (vf.enum_values[0..i]) |p| if (std.mem.eql(u8, p, e)) return error.BadShape;
    }
    for (vv.object.keys()) |k| {
        for (vf.enum_values) |e| {
            if (std.mem.eql(u8, e, k)) break;
        } else return error.BadShape;
    }
    const item_specs = spec.get("fields").?.object;
    const out = try arena.alloc(Variant, vf.enum_values.len);
    for (vf.enum_values, out) |kind, *o| {
        const list = vv.object.get(kind) orelse return error.BadShape;
        if (list != .array) return error.BadShape;
        var narrowed = vf;
        narrowed.enum_values = try arena.dupe([]const u8, &.{kind});
        var subs: std.ArrayList(Field) = .empty;
        try subs.append(arena, narrowed);
        var kind_enum = std.json.Array.init(arena);
        try kind_enum.append(.{ .string = kind });
        var vspec = try item_specs.get(vname).?.object.clone(arena);
        try vspec.put(arena, "enum", .{ .array = kind_enum });
        var fields: ObjectMap = .empty;
        try fields.put(arena, vname, .{ .object = vspec });
        for (list.array.items) |lv| {
            if (lv != .string or std.mem.eql(u8, lv.string, vname)) return error.BadShape;
            for (subs.items) |seen| if (std.mem.eql(u8, seen.name, lv.string)) return error.BadShape;
            var sf = subField(f, lv.string) orelse return error.BadShape;
            sf.optional = false;
            try subs.append(arena, sf);
            var fs = try item_specs.get(lv.string).?.object.clone(arena);
            _ = fs.orderedRemove("optional");
            try fields.put(arena, lv.string, .{ .object = fs });
        }
        for (f.sub) |sf| {
            if (sf.optional) continue;
            for (subs.items) |u| {
                if (std.mem.eql(u8, u.name, sf.name)) break;
            } else return error.BadShape;
        }
        var schema = try spec.clone(arena);
        for ([_][]const u8{ "role", "max_items", "variant", "variants", "apparatus", "optional" }) |k| _ = schema.orderedRemove(k);
        try schema.put(arena, "type", .{ .string = "object" });
        try schema.put(arena, "fields", .{ .object = fields });
        o.* = .{
            .name = kind,
            .sub = subs.items,
            .schema = try std.json.Stringify.valueAlloc(arena, Value{ .object = schema }, .{}),
            .path = try std.fmt.allocPrint(arena, "{s}:{s}", .{ path, kind }),
        };
    }
    return out;
}

fn subField(f: Field, name: []const u8) ?Field {
    for (f.sub) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// Every `ref` annotation, top-level and array<object> item fields, in
/// shape order.
fn parseRefs(arena: std.mem.Allocator, fields: ObjectMap) ![]const RefSite {
    var out: std.ArrayList(RefSite) = .empty;
    var it = fields.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) return error.BadShape;
        const spec = e.value_ptr.object;
        if (str(spec, "ref")) |t| try out.append(arena, .{ .field = e.key_ptr.*, .target = t });
        const sv = spec.get("fields") orelse continue;
        if (sv != .object) return error.BadShape;
        if (!std.mem.eql(u8, str(spec, "type") orelse "", "array<object>")) continue;
        var label: ?[]const u8 = null;
        for (sv.object.keys(), sv.object.values()) |k, v| {
            if (v != .object) return error.BadShape;
            const plain = std.mem.eql(u8, str(v.object, "type") orelse "string", "string");
            if (plain and !boolean(v.object, "optional") and str(v.object, "ref") == null) {
                label = k;
                break;
            }
        }
        for (sv.object.keys(), sv.object.values()) |k, v| {
            const t = str(v.object, "ref") orelse continue;
            try out.append(arena, .{ .field = e.key_ptr.*, .sub = k, .target = t, .label = label });
        }
    }
    return out.items;
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
        .max_items = int(spec, "max_items"),
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
            var sf = try parseField(arena, e.key_ptr.*, e.value_ptr.object, f.words);
            // Only a string sub-field can carry a quotable claim.
            if (sf.evidence and sf.kind != .string) return error.BadShape;
            // An item field rendered in a fence (a palette's `code` kind)
            // takes the code slot's rules: string kinds only.
            sf.code = std.mem.eql(u8, str(e.value_ptr.object, "apparatus") orelse "", "code");
            if (sf.code and sf.kind != .string and sf.kind != .strings) return error.BadShape;
            try subs.append(arena, sf);
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
        .{ "object<string,string>", .keyed },
        .{ "object<string>", .keyed },
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
    if (s.field.kind == .keyed) {
        const n: usize = switch (v orelse @as(Value, .null)) {
            .null => 0,
            .object => |o| o.count(),
            else => return false,
        };
        return n < s.max_items and anchor(data, s) != null;
    }
    if (!s.isArray()) return isEmpty(v);
    return switch (v orelse return true) {
        .null => true,
        .array => |a| a.items.len < s.max_items,
        else => false,
    };
}

/// Where a keyed slot's next key attaches: an existing array element and
/// its empty ref field.
pub const Anchor = struct {
    site: RefSite,
    index: usize,
    item: ObjectMap,
};

/// The first element, in shape order then data order, whose ref field into
/// the slot's map is empty. The server's choice, never the model's.
pub fn anchor(data: ObjectMap, s: Slot) ?Anchor {
    for (s.hosts) |h| {
        const arr = data.get(h.field) orelse continue;
        if (arr != .array) continue;
        for (arr.array.items, 0..) |item, i| {
            if (item != .object) continue;
            if (isEmpty(item.object.get(h.sub.?))) return .{ .site = h, .index = i, .item = item.object };
        }
    }
    return null;
}

/// The key a new note gets: the anchor's label field in kebab case (at most
/// `max_key_words` words and `max_key_len` bytes, so k4o's `kebab` leaves
/// it unchanged), made unique against the map's keys. `note` when the
/// label has no ASCII word.
pub fn noteKey(arena: std.mem.Allocator, at: Anchor, keys: ObjectMap) ![]const u8 {
    const label = if (at.site.label) |l| str(at.item, l) orelse "" else "";
    var aw: std.Io.Writer.Allocating = .init(arena);
    var words: usize = 0;
    var i: usize = 0;
    while (words < max_key_words) {
        while (i < label.len and !std.ascii.isAlphanumeric(label[i])) i += 1;
        const start = i;
        while (i < label.len and std.ascii.isAlphanumeric(label[i])) i += 1;
        if (i == start or aw.written().len + (i - start) + 1 > max_key_len) break;
        if (words > 0) try aw.writer.writeByte('-');
        for (label[start..i]) |c| try aw.writer.writeByte(std.ascii.toLower(c));
        words += 1;
    }
    const base = if (words == 0) "note" else aw.written();
    if (keys.get(base) == null) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const k = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
        if (keys.get(k) == null) return k;
    }
}

/// `field[i].sub=key` for the write a keyed slot would make on `data`.
fn anchorLabel(arena: std.mem.Allocator, data: ObjectMap, s: Slot) ![]const u8 {
    const at = anchor(data, s) orelse return "";
    return std.fmt.allocPrint(arena, "{s}[{d}].{s}={s}", .{ at.site.field, at.index, at.site.sub.?, try noteKey(arena, at, keysOf(data, s)) });
}

fn keysOf(data: ObjectMap, s: Slot) ObjectMap {
    const v = data.get(s.field.name) orelse return .empty;
    return if (v == .object) v.object else .empty;
}

/// A copy of `data` with `value` set on (or appended to) the slot. The
/// original is never touched, so `best` stays intact. A keyed slot is the
/// paired write: the new key and the anchor's ref land together, so the
/// ref always resolves.
pub fn withValue(arena: std.mem.Allocator, data: ObjectMap, s: Slot, value: Value) !ObjectMap {
    var m = try data.clone(arena);
    if (s.field.kind == .keyed) {
        // Callers only write slots canGrow accepted.
        const at = anchor(data, s) orelse unreachable;
        var keys = try keysOf(data, s).clone(arena);
        const key = try noteKey(arena, at, keys);
        try keys.put(arena, key, value);
        var item = try at.item.clone(arena);
        try item.put(arena, at.site.sub.?, .{ .string = key });
        var arr = std.json.Array.init(arena);
        try arr.appendSlice(data.get(at.site.field).?.array.items);
        arr.items[at.index] = .{ .object = item };
        try m.put(arena, at.site.field, .{ .array = arr });
        try m.put(arena, s.field.name, .{ .object = keys });
        return m;
    }
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
        .string, .strings, .keyed => return .{ .string = try stubText(arena, s.field) },
        .objects => {
            var o: ObjectMap = .empty;
            for (s.field.sub) |f| {
                if (f.optional) continue;
                // A picked kind stubs its fields typed (a list kind gets a
                // full list); the narrowed variant field stubs to the kind.
                try o.put(arena, f.name, if (s.chosen != null) try subStub(arena, f) else .{ .string = try stubText(arena, f) });
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

fn subStub(arena: std.mem.Allocator, f: Field) !Value {
    switch (f.kind) {
        .number => return .{ .integer = 1 },
        .strings => {
            var arr = std.json.Array.init(arena);
            for (0..f.max_items orelse default_max_items) |_| try arr.append(.{ .string = try stubText(arena, f) });
            return .{ .array = arr };
        },
        else => return .{ .string = try stubText(arena, f) },
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

/// Type, enum, max_words (explicit, else `words` times
/// `default_max_words_factor`), URL scheme, item shape, and `ref`
/// integrity. Returns the rejection detail, or null when the value fits.
pub fn checkSchema(arena: std.mem.Allocator, s: Slot, value: Value, data: ObjectMap) !?[]const u8 {
    switch (s.field.kind) {
        .string, .strings, .keyed => {
            if (try checkString(arena, s.field, value)) |why| return why;
            if (s.field.ref) |ref| {
                const keys = data.get(ref);
                const ok = keys != null and keys.? == .object and keys.?.object.get(value.string) != null;
                if (!ok) return try std.fmt.allocPrint(arena, "ref: {s} '{s}' is not a key in '{s}'", .{ s.field.name, value.string, ref });
            }
            return null;
        },
        .number => return switch (value) {
            .integer, .float => null,
            else => "expected a number",
        },
        .objects => {
            if (s.chosen) |k| if (try checkVariant(arena, s.variant.?, k, s.field.sub, value)) |why| return why;
            return checkObject(arena, s.field.sub, value, data);
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

/// A picked palette item keeps the server's kind and only that kind's
/// fields: the model choosing a kind would be the model choosing layout.
fn checkVariant(arena: std.mem.Allocator, variant: []const u8, kind: []const u8, sub: []const Field, value: Value) !?[]const u8 {
    if (value != .object) return null;
    if (value.object.get(variant)) |kv| {
        if (kv != .string or !std.mem.eql(u8, std.mem.trim(u8, kv.string, " \t\r\n"), kind))
            return try std.fmt.allocPrint(arena, "variant: {s} must be '{s}', the server's pick", .{ variant, kind });
    }
    for (value.object.keys()) |k| {
        for (sub) |f| {
            if (std.mem.eql(u8, f.name, k)) break;
        } else return try std.fmt.allocPrint(arena, "variant: field '{s}' is not used by {s} '{s}'", .{ k, variant, kind });
    }
    return null;
}

fn checkObject(arena: std.mem.Allocator, sub: []const Field, value: Value, data: ObjectMap) error{OutOfMemory}!?[]const u8 {
    if (value != .object) return "expected an object";
    var it = value.object.iterator();
    while (it.next()) |e| {
        for (sub) |f| {
            if (std.mem.eql(u8, f.name, e.key_ptr.*)) break;
        } else return try std.fmt.allocPrint(arena, "unknown field '{s}'", .{e.key_ptr.*});
    }
    for (sub) |f| {
        const v = value.object.get(f.name) orelse {
            if (f.optional) continue;
            return try std.fmt.allocPrint(arena, "missing field '{s}'", .{f.name});
        };
        switch (f.kind) {
            .string => {
                if (try checkString(arena, f, v)) |why|
                    return try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.name, why });
                if (f.ref) |ref| {
                    const keys = data.get(ref);
                    const ok = keys != null and keys.? == .object and keys.?.object.get(v.string) != null;
                    if (!ok) return try std.fmt.allocPrint(arena, "ref: {s} '{s}' is not a key in '{s}'", .{ f.name, v.string, ref });
                }
            },
            .number => switch (v) {
                .integer, .float => {},
                else => return try std.fmt.allocPrint(arena, "{s}: expected a number", .{f.name}),
            },
            .strings => {
                if (v != .array) return try std.fmt.allocPrint(arena, "{s}: expected an array", .{f.name});
                if (f.max_items) |cap| if (v.array.items.len > cap)
                    return try std.fmt.allocPrint(arena, "{s}: max_items: {d} > {d}", .{ f.name, v.array.items.len, cap });
                for (v.array.items) |item| {
                    if (try checkString(arena, f, item)) |why|
                        return try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.name, why });
                }
            },
            .objects => {
                if (v != .array) return try std.fmt.allocPrint(arena, "{s}: expected an array", .{f.name});
                for (v.array.items) |item| {
                    if (try checkObject(arena, f.sub, item, data)) |why|
                        return try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.name, why });
                }
            },
            else => return try std.fmt.allocPrint(arena, "{s}: unsupported field type", .{f.name}),
        }
    }
    return null;
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
    const word_cap = f.max_words orelse f.words *| default_max_words_factor;
    const n = countWords(s);
    if (n > word_cap) return try std.fmt.allocPrint(arena, "max_words: {d} > {d}", .{ n, word_cap });
    if (f.url) {
        const scheme = std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
        if (!scheme or std.mem.indexOfAny(u8, s, " \t") != null) return "url: needs an http/https URL";
    }
    return null;
}

/// Document-level `ref` integrity: every non-empty ref names a key of its
/// map, and every key of a referenced map is named by some ref (format_check's
/// `unresolved-footnote` / `unused-footnote`, caught before the render).
/// Returns the first stray, or null.
pub fn refCheck(arena: std.mem.Allocator, shape: Shape, data: ObjectMap) !?[]const u8 {
    for (shape.refs) |rs| {
        const v = data.get(rs.field) orelse continue;
        const items: []const Value = switch (v) {
            .array => |a| a.items,
            else => @as(*const [1]Value, &v),
        };
        for (items, 0..) |item, i| {
            const key = refValue(rs, item) orelse continue;
            if (keyIn(data, rs.target, key)) continue;
            const path = if (v != .array)
                rs.field
            else if (rs.sub) |sub|
                try std.fmt.allocPrint(arena, "{s}[{d}].{s}", .{ rs.field, i, sub })
            else
                try std.fmt.allocPrint(arena, "{s}[{d}]", .{ rs.field, i });
            return try std.fmt.allocPrint(arena, "ref: {s} '{s}' is not a key in '{s}'", .{ path, key, rs.target });
        }
    }
    for (shape.refs, 0..) |rs, n| {
        const seen = for (shape.refs[0..n]) |p| {
            if (std.mem.eql(u8, p.target, rs.target)) break true;
        } else false;
        if (seen) continue;
        const map = data.get(rs.target) orelse continue;
        if (map != .object) continue;
        keys: for (map.object.keys()) |k| {
            for (shape.refs) |q| {
                if (!std.mem.eql(u8, q.target, rs.target)) continue;
                const v = data.get(q.field) orelse continue;
                const items: []const Value = switch (v) {
                    .array => |a| a.items,
                    else => @as(*const [1]Value, &v),
                };
                for (items) |item| if (std.mem.eql(u8, refValue(q, item) orelse continue, k)) continue :keys;
            }
            return try std.fmt.allocPrint(arena, "ref: '{s}' key '{s}' is never referenced", .{ rs.target, k });
        }
    }
    return null;
}

/// The non-empty ref a field value (or one array item) carries.
fn refValue(rs: RefSite, item: Value) ?[]const u8 {
    const v = if (rs.sub) |sub| switch (item) {
        .object => |o| o.get(sub) orelse return null,
        else => return null,
    } else item;
    if (v != .string or std.mem.trim(u8, v.string, " \t\r\n").len == 0) return null;
    return v.string;
}

fn keyIn(data: ObjectMap, map: []const u8, key: []const u8) bool {
    const m = data.get(map) orelse return false;
    return m == .object and m.object.get(key) != null;
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

/// A `*` or `_` that can open an emphasis run: a word character on its
/// right and a non-word boundary (or the string start) on its left. The
/// token list covers the paired forms (`**`, `__`); this catches the lone
/// delimiters, which still style runs (`_a_ _b_ …`) and so are not inert.
/// Requiring a non-word left edge keeps intraword underscores legal —
/// `snake_case` cannot open emphasis, so values like `wal_dir` pass — and
/// keeps a `*` with no word to its right (`2 * 3`) plain math.
fn opensEmphasis(s: []const u8, i: usize) bool {
    const c = s[i];
    if (c != '*' and c != '_') return false;
    if (i + 1 >= s.len or !std.ascii.isAlphanumeric(s[i + 1])) return false;
    return i == 0 or !std.ascii.isAlphanumeric(s[i - 1]);
}

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
    for (s, 0..) |_, i| {
        if (opensEmphasis(s, i)) return if (s[i] == '*') "*emphasis" else "_emphasis";
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

/// What can still break out of a fenced code block: a newline, a closing
/// fence, or template syntax. Everything the prose rule rejects — pipes,
/// backticks, emphasis openers, `<tag`, leading `#`/`>`/`- ` — is literal
/// inside a fence, so the code rule rejects nothing else.
const code_inert_tokens = [_][]const u8{ "```", "~~~", "{{", "{%" };

fn codeInert(s: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return "newline";
    for (code_inert_tokens) |t| {
        if (std.mem.indexOf(u8, s, t) != null) return t;
    }
    return null;
}

/// inertViolation for a code field: the literal-safe rule, applied to
/// every string in the value.
fn codeViolation(value: Value) ?[]const u8 {
    switch (value) {
        .string => |s| return codeInert(s),
        .array => |a| for (a.items) |v| {
            if (codeViolation(v)) |why| return why;
        },
        .object => |o| for (o.values()) |v| {
            if (codeViolation(v)) |why| return why;
        },
        else => {},
    }
    return null;
}

/// The inert rule for a slot's value: the code rule for a code slot and
/// for code item fields (a palette's `code` kind), the prose rule for
/// everything else.
fn slotViolation(s: Slot, value: Value) ?[]const u8 {
    if (s.field.code) return codeViolation(value);
    if (value != .object) return inertViolation(value);
    for (value.object.keys(), value.object.values()) |k, v| {
        const code = if (subField(s.field, k)) |f| f.code else false;
        if (if (code) codeViolation(v) else inertViolation(v)) |why| return why;
    }
    return null;
}

/// The first code item field in `value` that is not verbatim in evidence.
fn codeFieldMiss(s: Slot, value: Value, evidence: []const []const u8) ?[]const u8 {
    if (value != .object) return null;
    for (s.field.sub) |f| {
        if (!f.code) continue;
        if (value.object.get(f.name)) |v| if (!codeVerbatim(v, evidence)) return f.name;
    }
    return null;
}

/// The code evidence gate: a command is a quote, so only an exact
/// substring of an evidence item is safe — no model judgement, no
/// `verifier.checkCitation`. Every string in the value must pass.
fn codeVerbatim(value: Value, evidence: []const []const u8) bool {
    return switch (value) {
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t\r\n");
            for (evidence) |e| {
                if (std.mem.indexOf(u8, e, t) != null) break :blk true;
            }
            break :blk false;
        },
        .array => |a| blk: {
            for (a.items) |v| {
                if (!codeVerbatim(v, evidence)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
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

/// Evidence quotes from `boris_ask` hits on `subject ?? title`: the top
/// snippets, best first. Null when the data names neither.
pub fn borisEvidence(arena: std.mem.Allocator, art: *const borisrag.Artifact, data: ObjectMap) !?[]const []const u8 {
    const query = str(data, "subject") orelse str(data, "title") orelse return null;
    const hits = try borisrag.ask(arena, art, query, borisrag.default_limit, false);
    var out: std.ArrayList([]const u8) = .empty;
    for (hits) |h| try out.append(arena, h.snippet);
    return out.items;
}

/// The evidence-flagged strings in a value: the value itself for an
/// evidence scalar or item, else the item fields marked `evidence`.
fn evidenceClaims(arena: std.mem.Allocator, s: Slot, value: Value) ![]const []const u8 {
    var claims: std.ArrayList([]const u8) = .empty;
    if (s.field.evidence and value == .string) try claims.append(arena, value.string);
    if (value == .object) for (s.field.sub) |f| {
        if (!f.evidence) continue;
        if (value.object.get(f.name)) |v| if (v == .string) try claims.append(arena, v.string);
    };
    return claims.items;
}

/// Verifier gate (layer 4, lane M2's `verifier.checkCitation`): every
/// evidence-flagged string must come back `entails`; with the heuristic
/// that means a verbatim quote of one evidence item. Returns the rejection
/// detail (`<label>: <reason>`), or null.
pub fn checkEvidence(ctx: *Ctx, kind: verifier.Kind, s: Slot, value: Value, evidence: []const []const u8) !?[]const u8 {
    for (try evidenceClaims(ctx.arena, s, value)) |claim| {
        const c = try verifier.checkCitation(ctx, kind, claim, evidence);
        if (c.label != .entails) return try std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ @tagName(c.label), c.reason });
    }
    return null;
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
    /// The reply was not JSON at all — a parse failure, not a value that
    /// violated the schema.
    parse,
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
    /// 1-based, the same counter Result.iterations reports.
    iteration: usize,
    slot: []const u8,
    probe_gain: f64,
    gain: f64 = 0,
    accepted: bool = false,
    reason: Reason = .ok,
    detail: []const u8 = "",
};

/// Where evidence-gated slots' quotes come from: `data` reads
/// `data.sources`, `boris` is `boris_ask` snippets for `subject ?? title`.
pub const Evidence = enum { data, boris };

pub const Options = struct {
    max_iterations: usize = default_max_iterations,
    epsilon: f64 = epsilon,
    tone: ?[]const u8 = null,
    /// Gate for `evidence` slots; `none` skips it.
    verifier: verifier.Kind = .heuristic,
    /// Evidence pool for gated slots and the enrich slice.
    evidence: Evidence = .data,
    /// Mock backend table: slot path -> array of canned values, used in
    /// order. A slot with no (or no more) values declines.
    mock: ObjectMap = .empty,
    /// Backend-call budget; `max_backend_calls` is also the ceiling a
    /// ratchet-eval case may set.
    max_calls: usize = max_backend_calls,
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
        defer std.Io.Dir.deleteFile(.cwd(), r.ctx.io, path) catch {};
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
        // Built even on mock so the call counts what a live backend would
        // receive.
        const slice = try buildSlice(a, s, r.shape, best, r.evidence, r.opts.tone);
        if (r.kind == .mock) {
            r.ctx.countCall(enrich_prefix, slice);
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
        if (r.ctx.environ.get("KNAP_DEBUG") != null) std.debug.print("ratchet slice ({d} bytes):\n{s}", .{ slice.len, slice });
        return parseReply(a, try backend.complete(r.ctx, r.kind, .enrich, enrich_prefix, slice));
    }
};

/// A probe candidate: a slot, and for a palette slot the kind it stubs.
const Cand = struct {
    slot: usize,
    variant: ?usize = null,
    gain: f64,

    /// The slot this candidate fills: the palette narrowed to its kind.
    fn of(c: Cand, slots: []const Slot) Slot {
        return if (c.variant) |k| slots[c.slot].pick(k) else slots[c.slot];
    }
};

fn candLess(_: void, x: Cand, y: Cand) bool {
    if (x.gain != y.gain) return x.gain > y.gain;
    if (x.slot != y.slot) return x.slot < y.slot;
    return (x.variant orelse 0) < (y.variant orelse 0);
}

/// Probes a slot gets per step: one, or a palette's window width.
fn probeCount(s: Slot) usize {
    return if (s.variants.len == 0) 1 else @min(s.variants.len, max_variant_probes);
}

/// The `j`th palette kind probed at `step`: a round-robin window of
/// `probeCount` kinds over the enum order. Null for a plain slot.
fn windowKind(s: Slot, step: usize, j: usize) ?usize {
    if (s.variants.len == 0) return null;
    return (step * max_variant_probes + j) % s.variants.len;
}

const Probe = struct { cand: Cand, best: Best };

/// One stub render per growable slot, or per windowed kind of a palette
/// slot, in shape order. Shared by stubCeiling and the loop so the
/// ceiling is the loop's own probe policy.
fn probeAll(r: *Run, base: Best, step: usize) Error![]const Probe {
    const a = r.ctx.arena;
    var out: std.ArrayList(Probe) = .empty;
    for (r.shape.slots, 0..) |s, i| {
        if (!canGrow(base.data, s)) continue;
        for (0..probeCount(s)) |j| {
            var c: Cand = .{ .slot = i, .variant = windowKind(s, step, j), .gain = 0 };
            const ps = c.of(r.shape.slots);
            switch (try r.render(try withValue(a, base.data, ps, try stub(a, base.data, ps)))) {
                .ok => |p| {
                    c.gain = p.score - base.score;
                    try out.append(a, .{ .cand = c, .best = p });
                },
                .diag => {},
            }
        }
    }
    return out.items;
}

/// Rank the probes best-first and keep the ones worth a backend call: at
/// most `top_k`, and none with gain below `eps` — a sub-ε candidate can
/// never be accepted, so asking it only burns a call.
fn askSlice(cands: []Cand, eps: f64) []Cand {
    std.mem.sort(Cand, cands, {}, candLess);
    var n = @min(top_k, cands.len);
    while (n > 0 and cands[n - 1].gain < eps) n -= 1;
    return cands[0..n];
}

/// The template's own ceiling: the same greedy probe policy with stub
/// values, for at most `max_iterations` steps. The plan's "stub every slot
/// at once" overshoots into the curves' overload decay (reading-note's
/// all-stub render scores 47 against a reachable 70), which would stop the
/// loop early.
fn stubCeiling(r: *Run, start: Best, opts: Options) Error!f64 {
    var cur = start;
    for (0..opts.max_iterations) |step| {
        var next: ?Best = null;
        for (try probeAll(r, cur, step)) |p| {
            if (p.best.score - cur.score >= opts.epsilon and (next == null or p.best.score > next.?.score)) next = p.best;
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
    if (backend.needsKey(kind) and ctx.environ.get("MODEL_API_KEY") == null)
        return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    const a = ctx.arena;
    const t0 = std.Io.Timestamp.now(ctx.io, .awake);
    var r: Run = .{ .ctx = ctx, .kind = kind, .tpl = tpl_path, .shape = shape, .opts = opts, .evidence = switch (opts.evidence) {
        .data => try dataEvidence(a, data0),
        .boris => blk: {
            const art = try borisrag.load(ctx);
            break :blk try borisEvidence(a, &art, data0) orelse
                return ctx.fail("evidence \"boris\" needs a 'subject' or 'title' string in data", .{});
        },
    } };
    const slots = shape.slots;

    var best = switch (try r.render(data0)) {
        .ok => |b| b,
        .diag => {
            const path = try store.scratchFile(ctx, "json");
            defer std.Io.Dir.deleteFile(.cwd(), ctx.io, path) catch {};
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
        for (try probeAll(&r, best, iter)) |p| try cands.append(a, p.cand);
        const ask = askSlice(cands.items, eps);
        if (ask.len == 0) {
            stop = .plateau;
            break;
        }

        iterations = iter + 1;
        var accepted = false;
        for (ask) |c| {
            if (calls >= opts.max_calls) {
                stop = .budget;
                break :outer;
            }
            const s = c.of(slots);
            var step: Step = .{ .iteration = iter + 1, .slot = s.path, .probe_gain = c.gain };
            const reply = try r.ask(s, best.data);
            calls += 1;
            judge: switch (reply) {
                .declined => step.reason = .declined,
                .bad => |why| {
                    step.reason = .parse;
                    step.detail = why;
                },
                .value => |raw_v| {
                    const v = switch (s.field.kind) {
                        .strings, .objects => if (raw_v == .array and raw_v.array.items.len == 1) raw_v.array.items[0] else raw_v,
                        .rows => if (raw_v == .array and raw_v.array.items.len == 1 and raw_v.array.items[0] == .array) raw_v.array.items[0] else raw_v,
                        else => raw_v,
                    };
                    if (try checkSchema(a, s, v, best.data)) |why| {
                        step.reason = .schema;
                        step.detail = why;
                        break :judge;
                    }
                    if (slotViolation(s, v)) |tok| {
                        step.reason = .inert;
                        step.detail = tok;
                        break :judge;
                    }
                    // A code slot's gate is exact and always on; the
                    // model verifier could wave a paraphrased command
                    // through as entails.
                    if (s.field.code) {
                        if (!codeVerbatim(v, r.evidence)) {
                            step.reason = .verifier;
                            step.detail = "code: not verbatim in evidence";
                            break :judge;
                        }
                    } else if (codeFieldMiss(s, v, r.evidence)) |name| {
                        step.reason = .verifier;
                        step.detail = try std.fmt.allocPrint(a, "code: {s} not verbatim in evidence", .{name});
                        break :judge;
                    } else if (s.gated() and opts.verifier != .none) if (try checkEvidence(ctx, opts.verifier, s, v, r.evidence)) |why| {
                        step.reason = .verifier;
                        step.detail = why;
                        break :judge;
                    };
                    const next = try withValue(a, best.data, s, v);
                    // Never make a ref-clean document dirty.
                    if ((try refCheck(a, shape, best.data)) == null) if (try refCheck(a, shape, next)) |why| {
                        step.reason = .schema;
                        step.detail = why;
                        break :judge;
                    };
                    const cand = switch (try r.render(next)) {
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
                        if (s.field.kind == .keyed) step.detail = try anchorLabel(a, best.data, s);
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
    const mode = if (s.isArray())
        "append one item"
    else if (s.field.kind == .keyed)
        "write one note; the server picks its key and anchor"
    else
        "fill this empty field";
    try w.print("FIELD: {s}   ({s})\nSCHEMA: {s}\n", .{ s.path, mode, s.schema });
    // The cached prefix bans pipes; a code slot gets a per-slot override.
    if (s.field.code) try w.writeAll("This value is rendered verbatim inside a code block: copy the command exactly from EVIDENCE, one line, no backtick fences. Pipes and symbols are fine here.\n");
    // A palette item: the server picked the kind; SCHEMA lists only its
    // fields.
    if (s.chosen) |k| try w.print("KIND: {s}   (chosen by the server: set \"{s}\" to \"{s}\" and fill only the fields in SCHEMA)\n", .{ k, s.variant.?, k });
    for (s.field.sub) |f| if (f.code) try w.print("Field '{s}' is rendered verbatim inside a code block: copy the command exactly from EVIDENCE, one line, no backtick fences. Pipes and symbols are fine here.\n", .{f.name});
    try w.print("ROLE: {s}\n", .{s.role});
    if (tone) |t| try w.print("TONE: {s}\n", .{t});

    var head: ObjectMap = .empty;
    for (shape.headline) |k| {
        const v = data.get(k) orelse continue;
        if (v == .string and v.string.len <= 400) try head.put(arena, k, v);
    }
    try w.writeAll("HEADLINE: ");
    try std.json.Stringify.value(Value{ .object = head }, .{}, w);
    try w.writeAll("\n");

    if (s.isArray() or s.field.kind == .keyed) {
        if (data.get(s.field.name)) |sib| {
            const text = try std.json.Stringify.valueAlloc(arena, sib, .{});
            if (aw.written().len + text.len + 64 < max_slice_bytes) try w.print("SIBLINGS: {s}\n", .{text});
        }
    }
    // The element the note is about; the model sees it but cannot move it.
    if (s.field.kind == .keyed) if (anchor(data, s)) |at| {
        const text = try std.json.Stringify.valueAlloc(arena, Value{ .object = at.item }, .{});
        if (aw.written().len + text.len + 64 < max_slice_bytes) try w.print("ANCHOR: {s}[{d}] {s}\n", .{ at.site.field, at.index, text });
    };

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
    /// Kept raw: a non-object expect is a malformed expectation and
    /// checkExpect fails the case on it.
    expect: ?Value,
    max_iterations: usize,
    max_calls: usize,
};

const Row = struct {
    id: []const u8,
    result: ?Result = null,
    err: []const u8 = "",
    check: []const u8 = "ok",
    max_iterations: usize = 0,
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
        var row: Row = .{ .id = c.id, .max_iterations = c.max_iterations };
        const shape = try loadShape(ctx, c.shape);
        const outcome = run(ctx, kind, c.tpl, shape, c.data, .{ .mock = c.mock, .max_iterations = c.max_iterations, .max_calls = c.max_calls }) catch |e| {
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

    try w.print("backend: {s}   corpus: {s}   scorer: {s}   eps: {d:.1}   top_k: {d}   max_calls: {d}\n\n", .{
        @tagName(kind), corpus_path, density.version, epsilon, top_k, max_backend_calls,
    });
    try w.writeAll("| case | start | final | gain | ceiling | iters | cap | calls | accepted | parse | schema | inert | render | verifier | no-gain | warn | declined | renders | ms | stop | check |\n");
    try w.writeAll("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|---|\n");
    var runs: usize = 0;
    var renders: usize = 0;
    var ms: f64 = 0;
    for (rows.items) |row| {
        const r = row.result orelse {
            try w.print("| {s} | - | - | - | - | - | {d} | - | - | - | - | - | - | - | - | - | - | - | - | {s}: {s} |\n", .{ row.id, row.max_iterations, row.check, row.err });
            continue;
        };
        runs += 1;
        renders += r.renders;
        ms += r.ms;
        const rj = r.rejections;
        try w.print("| {s} | {d:.1} | {d:.1} | {d:.1} | {d:.1}", .{ row.id, r.start, r.final, r.final - r.start, r.ceiling });
        try w.print(" | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d:.0} | {s} | {s} |\n", .{
            r.iterations,          row.max_iterations, r.calls,         r.accepted(),      rj.get(.parse),
            rj.get(.schema),       rj.get(.inert),     rj.get(.render), rj.get(.verifier), rj.get(.no_gain),
            rj.get(.new_warnings), rj.get(.declined),  r.renders,       r.ms,              @tagName(r.stop),
            row.check,
        });
    }
    if (runs > 0) {
        const n: f64 = @floatFromInt(runs);
        try w.print("\nprobe cost: {d} renders in {d} runs ({d:.1} renders/run), {d:.0} ms/run mean wall\n", .{
            renders, runs, @as(f64, @floatFromInt(renders)) / n, ms / n,
        });
    }
    try w.print("calls: {d}  mean slice: {d} B  max: {d} B  prefix: {d} B\n", .{
        ctx.calls, ctx.meanSlice(), ctx.slice_bytes_max, ctx.prefix_bytes,
    });
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
    const expect = o.get("expect");
    // Same bound the MCP tool and CLI enforce (0-20).
    const iters: usize = if (o.get("max_iterations")) |v| switch (v) {
        .integer => |x| if (x >= 0 and x <= 20) @intCast(x) else return ctx.fail("case '{s}': max_iterations must be 0-20", .{id}),
        else => return ctx.fail("case '{s}': max_iterations must be an integer 0-20", .{id}),
    } else default_max_iterations;
    // A tighter call budget than the hard cap, never a looser one.
    const calls: usize = if (o.get("max_calls")) |v| switch (v) {
        .integer => |x| if (x >= 0 and x <= max_backend_calls) @intCast(x) else return ctx.fail("case '{s}': max_calls must be 0-{d}", .{ id, max_backend_calls }),
        else => return ctx.fail("case '{s}': max_calls must be an integer 0-{d}", .{ id, max_backend_calls }),
    } else max_backend_calls;
    return .{ .id = id, .tpl = tpl, .shape = shape, .data = data, .mock = mock, .expect = expect, .max_iterations = iters, .max_calls = calls };
}

/// `{"min_gain": n, "stop": "plateau", "min_accepted": n,
///   "reject": {"<reason>": n}}`: every key present must hold, and a key
///   present but malformed fails the case — a typo must not weaken the
///   gate.
fn checkExpect(arena: std.mem.Allocator, r: Result, expect: ?Value) !?[]const u8 {
    const raw = expect orelse return null;
    const e = switch (raw) {
        .object => |o| o,
        else => return "FAIL: expect must be an object",
    };
    if (e.get("min_gain")) |v| {
        const want: f64 = switch (v) {
            .integer => |x| @floatFromInt(x),
            .float => |x| x,
            else => return "FAIL: min_gain must be a number",
        };
        if (r.final - r.start < want) return try std.fmt.allocPrint(arena, "FAIL: gain {d:.1} < {d:.1}", .{ r.final - r.start, want });
    }
    if (e.get("stop")) |v| {
        const want = switch (v) {
            .string => |s| s,
            else => return "FAIL: stop must be a string",
        };
        if (!std.mem.eql(u8, want, @tagName(r.stop))) return try std.fmt.allocPrint(arena, "FAIL: stop {s}, want {s}", .{ @tagName(r.stop), want });
    }
    if (e.get("min_accepted")) |v| {
        const want: usize = switch (v) {
            .integer => |x| if (x >= 0) @intCast(x) else return "FAIL: min_accepted must be a non-negative integer",
            else => return "FAIL: min_accepted must be an integer",
        };
        if (r.accepted() < want) return try std.fmt.allocPrint(arena, "FAIL: accepted {d} < {d}", .{ r.accepted(), want });
    }
    if (e.get("reject")) |rv| {
        if (rv != .object) return "FAIL: reject must be an object";
        var it = rv.object.iterator();
        while (it.next()) |kv| {
            const reason = for (std.enums.values(Reason)) |x| {
                if (std.mem.eql(u8, x.label(), kv.key_ptr.*)) break x;
            } else return try std.fmt.allocPrint(arena, "FAIL: unknown reason '{s}'", .{kv.key_ptr.*});
            const want: usize = switch (kv.value_ptr.*) {
                .integer => |x| if (x > 0) @intCast(x) else return try std.fmt.allocPrint(arena, "FAIL: reject '{s}' count must be a positive integer", .{kv.key_ptr.*}),
                else => return try std.fmt.allocPrint(arena, "FAIL: reject '{s}' count must be a positive integer", .{kv.key_ptr.*}),
            };
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
    // voiceonly (no apparatus), body (required, no max_items) and title
    // are not slots; notes is keyed because quotes[].note refs it.
    try testing.expectEqualStrings("cover author pull tags[+] quotes[+] grid[+] notes{+} ", paths.items);
    try testing.expectEqual(@as(usize, 1), slotNamed(sh, "notes{+}").hosts.len);
    try testing.expectEqualStrings("text", slotNamed(sh, "notes{+}").hosts[0].label.?);
    try testing.expect(slotNamed(sh, "cover").field.url);
    try testing.expect(slotNamed(sh, "author").field.page);
    try testing.expect(slotNamed(sh, "quotes[+]").gated());
    try testing.expectEqual(@as(usize, 1), sh.headline.len);
}

test "slots: code apparatus marks string slots and rejects other kinds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "cmd":{"type":"string","optional":true,"apparatus":"code"},
        \\ "cmds":{"type":"array<string>","optional":true,"apparatus":"code","max_items":2}}}
    );
    try testing.expect(slotNamed(sh, "cmd").field.code);
    try testing.expect(slotNamed(sh, "cmds[+]").field.code);
    // Code slots are always evidence-gated; the flag is not needed.
    try testing.expect(slotNamed(sh, "cmd").gated());
    try testing.expectError(error.BadShape, parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "n":{"type":"number","optional":true,"apparatus":"code"}}}
    ));
    try testing.expectError(error.BadShape, parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "objs":{"type":"array<object>","optional":true,"apparatus":"code","max_items":2,"fields":{"x":{"type":"string"}}}}}
    ));
}

test "codeInert: literal-safe inside a fence" {
    const good = [_][]const u8{ "a | b", "SELECT * FROM t", "# x", "`x`", "a > b && c < d", "- ls -la", "x = *p + _y" };
    for (good) |g| try testing.expect(codeInert(g) == null);
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "```sh acmedb snapshot list```", "```" },
        .{ "~~~sh", "~~~" },
        .{ "acmedb snapshot list\nrm -rf /", "newline" },
        .{ "a\rb", "newline" },
        .{ "{{ x }}", "{{" },
        .{ "{% if %}", "{%" },
    };
    for (bad) |b| try testing.expectEqualStrings(b[1], codeInert(b[0]).?);
}

test "code gate: verbatim substring of evidence, trim-insensitive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ev = [_][]const u8{"Run acmedb snapshot list | head -5 to see the newest snapshots."};
    try testing.expect(codeVerbatim(.{ .string = "acmedb snapshot list | head -5" }, &ev));
    try testing.expect(codeVerbatim(.{ .string = "  acmedb snapshot list | head -5  " }, &ev));
    try testing.expect(!codeVerbatim(.{ .string = "acmedb snapshots list | head" }, &ev));
    try testing.expect(!codeVerbatim(.{ .string = "acmedb snapshot list | head -6" }, &ev));
    // An array<string> item must pass too, and one bad item fails the value.
    var ok_items = std.json.Array.init(a);
    try ok_items.append(.{ .string = "acmedb snapshot list | head -5" });
    try ok_items.append(.{ .string = "Run acmedb" });
    try testing.expect(codeVerbatim(.{ .array = ok_items }, &ev));
    var bad_items = std.json.Array.init(a);
    try bad_items.append(.{ .string = "acmedb snapshot list | head -5" });
    try bad_items.append(.{ .string = "rm -rf /" });
    try testing.expect(!codeVerbatim(.{ .array = bad_items }, &ev));
}

const palette_shape =
    \\{"template_id":"p","fields":{
    \\ "title":{"type":"string"},
    \\ "pull":{"type":"string","optional":true,"apparatus":"quote","evidence":true},
    \\ "sections":{"type":"array<object>","optional":true,"apparatus":"palette","max_items":3,"role":"a block",
    \\  "variant":"kind","variants":{"steps":["title","items"],"code":["command"],"quote":["text"],"rule":[]},
    \\  "fields":{
    \\   "kind":{"type":"string","enum":["steps","code","quote","rule"]},
    \\   "title":{"type":"string","optional":true,"words":3},
    \\   "items":{"type":"array<string>","optional":true,"max_items":2,"words":2},
    \\   "command":{"type":"string","optional":true,"apparatus":"code"},
    \\   "text":{"type":"string","optional":true,"evidence":true}}}}}
;

test "palette: kinds parse in enum order, each narrowed to its own fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sh = try parseShape(arena.allocator(), palette_shape);
    const s = slotNamed(sh, "sections[+]");
    try testing.expectEqualStrings("kind", s.variant.?);
    try testing.expectEqual(@as(usize, 4), s.variants.len);
    const steps = s.pick(0);
    try testing.expectEqualStrings("sections[+]:steps", steps.path);
    try testing.expectEqualStrings("steps", steps.chosen.?);
    try testing.expectEqual(@as(usize, 3), steps.field.sub.len);
    try testing.expectEqualStrings("steps", steps.field.sub[0].enum_values[0]);
    for (steps.field.sub) |f| try testing.expect(!f.optional);
    try testing.expectEqual(@as(usize, 0), steps.variants.len);
    try testing.expect(s.pick(1).gated());
    try testing.expect(s.pick(1).field.sub[1].code);
    // The kind's SCHEMA names only its own fields and its own kind.
    try testing.expect(std.mem.indexOf(u8, steps.schema, "\"enum\":[\"steps\"]") != null);
    try testing.expect(std.mem.indexOf(u8, steps.schema, "command") == null);
    try testing.expect(std.mem.indexOf(u8, steps.schema, "variants") == null);
    try testing.expectEqual(@as(usize, 1), s.pick(3).field.sub.len);
}

test "palette: parseShape rejects a malformed palette" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        // a variants key outside the enum
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":[],"b":[],"c":[]},"fields":{"k":{"type":"string","enum":["a","b"]}}}}}
        ,
        // an enum value with no variants entry
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":[]},"fields":{"k":{"type":"string","enum":["a","b"]}}}}}
        ,
        // a listed field that does not exist
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":["x"]},"fields":{"k":{"type":"string","enum":["a"]}}}}}
        ,
        // the variant field listed as a kind's field
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":["k"]},"fields":{"k":{"type":"string","enum":["a"]}}}}}
        ,
        // variant names a field with no enum
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":[]},"fields":{"k":{"type":"string"}}}}}
        ,
        // a palette with no variant
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","fields":{"k":{"type":"string","enum":["a"]}}}}}
        ,
        // variants on a non-palette slot
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"list","variant":"k","variants":{"a":[]},"fields":{"k":{"type":"string","enum":["a"]}}}}}
        ,
        // a required item field some kind leaves out
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":["t"],"b":[]},"fields":{"k":{"type":"string","enum":["a","b"]},"t":{"type":"string"}}}}}
        ,
        // a code item field on a number
        \\{"fields":{"s":{"type":"array<object>","optional":true,"apparatus":"palette","variant":"k","variants":{"a":["n"]},"fields":{"k":{"type":"string","enum":["a"]},"n":{"type":"number","optional":true,"apparatus":"code"}}}}}
        ,
    };
    for (bad) |b| try testing.expectError(error.BadShape, parseShape(a, b));
}

test "palette: a picked stub sets the kind and stubs only its fields, typed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, palette_shape);
    const s = slotNamed(sh, "sections[+]");
    const d = try testData(a, "{}");
    const st = try stub(a, d, s.pick(0));
    try testing.expectEqualStrings("steps", st.object.get("kind").?.string);
    try testing.expectEqual(@as(usize, 2), st.object.get("items").?.array.items.len);
    try testing.expectEqual(@as(usize, 3), st.object.count());
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, s.pick(0), st, d));
    const q = try stub(a, d, s.pick(2));
    try testing.expectEqual(@as(usize, 2), q.object.count());
    try testing.expect(q.object.get("text") != null);
}

test "palette: a reply that swaps the kind or fills another kind's fields is schema" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, palette_shape);
    const steps = slotNamed(sh, "sections[+]").pick(0);
    const d = try testData(a, "{}");
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "{\"kind\":\"steps\",\"title\":\"Do it\",\"items\":[\"one\",\"two\"]}", null },
        .{ "{\"kind\":\"code\",\"title\":\"Do it\",\"items\":[\"one\"]}", "variant: kind must be 'steps', the server's pick" },
        .{ "{\"kind\":3,\"title\":\"Do it\",\"items\":[\"one\"]}", "variant: kind must be 'steps', the server's pick" },
        .{ "{\"kind\":\"steps\",\"title\":\"Do it\",\"items\":[\"one\"],\"command\":\"ls\"}", "variant: field 'command' is not used by kind 'steps'" },
        .{ "{\"title\":\"Do it\",\"items\":[\"one\"]}", "missing field 'kind'" },
        .{ "{\"kind\":\"steps\",\"items\":[\"one\"]}", "missing field 'title'" },
        .{ "{\"kind\":\"steps\",\"title\":\"Do it\",\"items\":[\"a\",\"b\",\"c\"]}", "items: max_items: 3 > 2" },
    };
    for (cases) |c| {
        const why = try checkSchema(a, steps, .{ .object = try testData(a, c[0]) }, d);
        if (c[1]) |want| try testing.expectEqualStrings(want, why.?) else try testing.expectEqual(@as(?[]const u8, null), why);
    }
}

test "palette: code item fields take the code rules, the rest the prose rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, palette_shape);
    const s = slotNamed(sh, "sections[+]");
    const code = s.pick(1);
    try testing.expectEqual(@as(?[]const u8, null), slotViolation(code, .{ .object = try testData(a, "{\"kind\":\"code\",\"command\":\"a | b\"}") }));
    try testing.expectEqualStrings("```", slotViolation(code, .{ .object = try testData(a, "{\"kind\":\"code\",\"command\":\"```sh\"}") }).?);
    try testing.expectEqualStrings("|", slotViolation(s.pick(0), .{ .object = try testData(a, "{\"kind\":\"steps\",\"title\":\"a | b\",\"items\":[]}") }).?);
    const ev = [_][]const u8{"Run acmedb snapshot list | head -5 to see the newest snapshots."};
    try testing.expectEqual(@as(?[]const u8, null), codeFieldMiss(code, .{ .object = try testData(a, "{\"command\":\"acmedb snapshot list | head -5\"}") }, &ev));
    try testing.expectEqualStrings("command", codeFieldMiss(code, .{ .object = try testData(a, "{\"command\":\"acmedb snapshots list\"}") }, &ev).?);
}

test "palette: a round-robin window of max_variant_probes kinds per step" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sh = try parseShape(arena.allocator(), palette_shape);
    const s = slotNamed(sh, "sections[+]");
    try testing.expectEqual(@as(usize, max_variant_probes), probeCount(s));
    const want = [_][3]usize{ .{ 0, 1, 2 }, .{ 3, 0, 1 }, .{ 2, 3, 0 }, .{ 1, 2, 3 } };
    for (want, 0..) |w, step| {
        for (w, 0..) |k, j| try testing.expectEqual(@as(?usize, k), windowKind(s, step, j));
    }
    // Plain slots probe once, with no kind.
    try testing.expectEqual(@as(usize, 1), probeCount(slotNamed(sh, "pull")));
    try testing.expectEqual(@as(?usize, null), windowKind(slotNamed(sh, "pull"), 5, 0));
}

test "palette: the slice names the server's kind and asks only for its fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, palette_shape);
    const s = slotNamed(sh, "sections[+]");
    const d = try testData(a, "{\"title\":\"T\"}");
    const slice = try buildSlice(a, s.pick(1), sh, d, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, slice, "FIELD: sections[+]:code   (append one item)") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "KIND: code   (chosen by the server: set \"kind\" to \"code\"") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "Field 'command' is rendered verbatim inside a code block") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "\"items\"") == null);
    // A plain slot's slice carries no KIND line.
    try testing.expect(std.mem.indexOf(u8, try buildSlice(a, slotNamed(sh, "pull"), sh, d, &.{}, null), "KIND:") == null);
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

    // With no `max_words` the cap is `words` x default_max_words_factor
    // (author: 3 x 16); an explicit `max_words` always wins.
    const wall = comptime blk: {
        var s: []const u8 = "";
        for (0..3 * default_max_words_factor + 2) |_| s = s ++ "word ";
        break :blk s;
    };
    try testing.expectEqualStrings("max_words: 50 > 48", (try checkSchema(a, slotNamed(sh, "author"), .{ .string = wall }, d)).?);
    const sh2 = try parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "s":{"type":"string","optional":true,"apparatus":"list","max_items":2,"words":2,"max_words":3}}}
    );
    try testing.expectEqualStrings("max_words: 4 > 3", (try checkSchema(a, slotNamed(sh2, "s"), .{ .string = "one two three four" }, d)).?);
}

test "schema check: ref integrity applies to scalar and array<string> slots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "note":{"type":"string","optional":true,"apparatus":"footnote","ref":"notes"},
        \\ "refs":{"type":"array<string>","optional":true,"apparatus":"list","max_items":2,"ref":"notes"},
        \\ "notes":{"type":"object<string,string>","optional":true}}}
    );
    const d = try testData(a, "{\"notes\":{\"n1\":\"a note\"}}");
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, slotNamed(sh, "note"), .{ .string = "n1" }, d));
    try testing.expectEqualStrings("ref: note 'n9' is not a key in 'notes'", (try checkSchema(a, slotNamed(sh, "note"), .{ .string = "n9" }, d)).?);
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, slotNamed(sh, "refs[+]"), .{ .string = "n1" }, d));
    try testing.expect((try checkSchema(a, slotNamed(sh, "refs[+]"), .{ .string = "n9" }, d)) != null);
}

test "parseShape rejects evidence on slots that cannot carry a claim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadShape, parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "grid":{"type":"array<array<string>>","optional":true,"apparatus":"table","cells":2,"evidence":true}}}
    ));
    try testing.expectError(error.BadShape, parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "objs":{"type":"array<object>","optional":true,"apparatus":"list","max_items":2,"evidence":true,"fields":{"x":{"type":"string"}}}}}
    ));
    try testing.expectError(error.BadShape, parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "objs":{"type":"array<object>","optional":true,"apparatus":"list","max_items":2,"fields":{"n":{"type":"number","evidence":true}}}}}
    ));
    // evidence on a keyed map nothing refs (not a slot) stays legal.
    _ = try parseShape(a,
        \\{"template_id":"t","fields":{
        \\ "notes":{"type":"object<string,string>","optional":true,"apparatus":"footnote","evidence":true}}}
    );
}

test "keyed slot: paired write sets one key and the anchor's ref together" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const s = slotNamed(sh, "notes{+}");
    // No element to anchor to: the map cannot grow.
    try testing.expect(!canGrow(try testData(a, "{}"), s));
    const d = try testData(a,
        \\{"quotes":[{"text":"Has one","kind":"tip","note":"has-one"},{"text":"Beware of first-hand ideas!","kind":"tip"}],"notes":{"has-one":"x"}}
    );
    try testing.expect(canGrow(d, s));
    try testing.expectEqual(@as(?[]const u8, null), try refCheck(a, sh, d));
    const d2 = try withValue(a, d, s, .{ .string = "A note." });
    try testing.expectEqualStrings("beware-of-first-hand", d2.get("quotes").?.array.items[1].object.get("note").?.string);
    try testing.expectEqualStrings("A note.", d2.get("notes").?.object.get("beware-of-first-hand").?.string);
    try testing.expectEqual(@as(?[]const u8, null), try refCheck(a, sh, d2));
    // `data` is untouched and every anchor is now taken.
    try testing.expect(d.get("quotes").?.array.items[1].object.get("note") == null);
    try testing.expectEqual(@as(usize, 1), d.get("notes").?.object.count());
    try testing.expect(!canGrow(d2, s));
    try testing.expectEqual(@as(?[]const u8, null), try checkSchema(a, s, .{ .string = "A note." }, d));
    try testing.expectEqualStrings("expected a string", (try checkSchema(a, s, .{ .object = try testData(a, "{\"key\":\"k\"}") }, d)).?);
}

test "noteKey: kebab label, bounded, unique, fallback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const site: RefSite = .{ .field = "h", .sub = "note", .target = "notes", .label = "name" };
    const at = struct {
        fn f(arena2: std.mem.Allocator, s: RefSite, name: []const u8) !Anchor {
            var item: ObjectMap = .empty;
            try item.put(arena2, "name", .{ .string = name });
            return .{ .site = s, .index = 0, .item = item };
        }
    }.f;
    const keys = try testData(a, "{\"acmedb-doctor\":\"x\",\"acmedb-doctor-2\":\"y\"}");
    try testing.expectEqualStrings("point-in-time-snapshots", try noteKey(a, try at(a, site, "Point-in-time snapshots, finally"), .empty));
    try testing.expectEqualStrings("acmedb-doctor-3", try noteKey(a, try at(a, site, "acmedb doctor"), keys));
    try testing.expectEqualStrings("note", try noteKey(a, try at(a, site, "¿¡…!?"), .empty));
    const long = try noteKey(a, try at(a, site, "Supercalifragilistic expialidocious extraordinarily"), .empty);
    try testing.expect(long.len <= max_key_len);
}

test "refCheck: dangling refs and unreferenced keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const dangling = try testData(a,
        \\{"quotes":[{"text":"t","kind":"tip","note":"n9"}],"notes":{"n1":"x"}}
    );
    try testing.expectEqualStrings("ref: quotes[0].note 'n9' is not a key in 'notes'", (try refCheck(a, sh, dangling)).?);
    const unused = try testData(a,
        \\{"quotes":[{"text":"t","kind":"tip","note":"n1"}],"notes":{"n1":"x","n2":"y"}}
    );
    try testing.expectEqualStrings("ref: 'notes' key 'n2' is never referenced", (try refCheck(a, sh, unused)).?);
}

test "slice for a keyed slot names the anchor, not the key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const d = try testData(a, "{\"title\":\"T\",\"quotes\":[{\"text\":\"Beware!\",\"kind\":\"tip\"}]}");
    const slice = try buildSlice(a, slotNamed(sh, "notes{+}"), sh, d, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, slice, "FIELD: notes{+}   (write one note;") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "ANCHOR: quotes[0] {\"text\":\"Beware!\",\"kind\":\"tip\"}") != null);
    try testing.expect(std.mem.indexOf(u8, slice, "beware") == null);
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
        .{ "single *styled* run", "*emphasis" },
        .{ "_a_ _b_ _c_", "_emphasis" },
        .{ "two\nparagraphs", "newline" },
        .{ "- a list", "list marker" },
        .{ "1. first", "list marker" },
    };
    for (bad) |b| try testing.expectEqualStrings(b[1], inertString(b[0]).?);
    const good = [_][]const u8{ "Plain prose, with commas.", "3 < 4 and 5 > 2", "1.9.x", "C# is fine-ish", "wal_dir and storage.wal_path", "2 * 3 = 6", "a*b" };
    for (good) |g| try testing.expect(inertString(g) == null);
}

test "verifier gate: claims come from evidence-flagged strings; only verbatim entails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const item = try testData(a,
        \\{"text":"The Machine is much, but it is not everything.","kind":"tip"}
    );
    const claims = try evidenceClaims(a, slotNamed(sh, "quotes[+]"), .{ .object = item });
    try testing.expectEqual(@as(usize, 1), claims.len);
    try testing.expectEqual(@as(usize, 1), (try evidenceClaims(a, slotNamed(sh, "pull"), .{ .string = "x" })).len);
    try testing.expectEqual(@as(usize, 0), (try evidenceClaims(a, slotNamed(sh, "author"), .{ .string = "x" })).len);
    const ev = [_][]const u8{"The Machine is much,  but it is\nnot everything. Men made it."};
    try testing.expectEqual(verifier.Label.entails, (try verifier.heuristic(a, claims[0], &ev)).label);
    try testing.expect((try verifier.heuristic(a, "The Machine is a lot, but not everything.", &ev)).label != .entails);
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

test "checkExpect fails the case on malformed expectation blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r: Result = .{
        .data = .empty,
        .doc = "",
        .start = 0,
        .final = 0,
        .ceiling = 0,
        .iterations = 0,
        .calls = 0,
        .renders = 0,
        .ceiling_renders = 0,
        .ms = 0,
        .stop = .plateau,
        .slots = 0,
        .fill_start = 0,
        .fill_final = 0,
        .steps = &.{},
        .rejections = .initFill(0),
    };
    const f = struct {
        fn f(arena2: std.mem.Allocator, json: []const u8) !?Value {
            return try std.json.parseFromSliceLeaky(Value, arena2, json, .{});
        }
    }.f;
    // A malformed key fails the case instead of silently passing.
    try testing.expectEqualStrings("FAIL: expect must be an object", (try checkExpect(a, r, try f(a, "5"))).?);
    try testing.expectEqualStrings("FAIL: min_gain must be a number", (try checkExpect(a, r, try f(a, "{\"min_gain\":\"lots\"}"))).?);
    try testing.expectEqualStrings("FAIL: stop must be a string", (try checkExpect(a, r, try f(a, "{\"stop\":3}"))).?);
    try testing.expect((try checkExpect(a, r, try f(a, "{\"min_accepted\":-1}"))) != null);
    try testing.expect((try checkExpect(a, r, try f(a, "{\"reject\":{\"schema\":0}}"))) != null);
    try testing.expect((try checkExpect(a, r, try f(a, "{\"reject\":{\"schema\":\"x\"}}"))) != null);
    // Well-formed expectations still evaluate.
    try testing.expectEqual(@as(?[]const u8, null), try checkExpect(a, r, try f(a, "{\"stop\":\"plateau\"}")));
    try testing.expectEqual(@as(?[]const u8, null), try checkExpect(a, r, null));
}

test "warnsSubset compares rule counts, not lines" {
    const W = formatcheck.Warning;
    const old = [_]W{.{ .rule = "raw-url-count", .line = 3, .detail = "" }};
    const moved = [_]W{.{ .rule = "raw-url-count", .line = 9, .detail = "" }};
    const more = [_]W{ .{ .rule = "raw-url-count", .line = 9, .detail = "" }, .{ .rule = "skipped-heading", .line = 1, .detail = "" } };
    try testing.expect(warnsSubset(&moved, &old));
    try testing.expect(!warnsSubset(&more, &old));
}

test "ask slice drops sub-epsilon probes so no backend call is spent on them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sh = try parseShape(a, test_shape);
    const pull_i = for (sh.slots, 0..) |s, i| {
        if (std.mem.eql(u8, s.path, "pull")) break i;
    } else unreachable;
    const tags_i = for (sh.slots, 0..) |s, i| {
        if (std.mem.eql(u8, s.path, "tags[+]")) break i;
    } else unreachable;

    // The issue's case: the second of the top_k probes sits below eps, so
    // the ask slice drops it rather than spending a retry call on it.
    var cands = [_]Cand{
        .{ .slot = pull_i, .gain = epsilon - 0.01 },
        .{ .slot = tags_i, .gain = 3 * epsilon },
    };
    const ask = askSlice(&cands, epsilon);
    try testing.expectEqual(@as(usize, 1), ask.len);
    try testing.expectEqual(tags_i, ask[0].slot);

    // Boundary: gain == eps still earns a call (the accept rule is
    // gain >= eps), and the input is ranked best-first.
    var edge = [_]Cand{
        .{ .slot = pull_i, .gain = epsilon },
        .{ .slot = tags_i, .gain = 3 * epsilon },
    };
    const ask2 = askSlice(&edge, epsilon);
    try testing.expectEqual(@as(usize, 2), ask2.len);
    try testing.expectEqual(tags_i, ask2[0].slot);
    try testing.expectEqual(pull_i, ask2[1].slot);

    // top_k caps the slice even when every probe clears eps.
    var capped = [_]Cand{
        .{ .slot = pull_i, .gain = 3 * epsilon },
        .{ .slot = tags_i, .gain = 5 * epsilon },
        .{ .slot = 0, .gain = 9 * epsilon },
    };
    const ask3 = askSlice(&capped, epsilon);
    try testing.expectEqual(@as(usize, top_k), ask3.len);
    try testing.expectEqual(@as(usize, 0), ask3[0].slot);
    try testing.expectEqual(tags_i, ask3[1].slot);
    var none: [0]Cand = .{};
    try testing.expectEqual(@as(usize, 0), askSlice(&none, epsilon).len);

    // The same drive the run loop uses: r.ask is the only backend-call
    // site, and mock_used records every call spent on a slot.
    var env: std.process.Environ.Map = .init(a);
    var io_state: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_state.deinit();
    var ctx: Ctx = .{
        .arena = a,
        .gpa = a,
        .io = io_state.io(),
        .environ = &env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
    var r: Run = .{
        .ctx = &ctx,
        .kind = .mock,
        .tpl = "",
        .shape = sh,
        .opts = .{ .mock = try testData(a, "{\"pull\":[\"p\"],\"tags[+]\":[\"t\"]}") },
        .evidence = &.{},
    };
    var calls: usize = 0;
    for (ask) |c| {
        _ = try r.ask(sh.slots[c.slot], try testData(a, "{}"));
        calls += 1;
    }
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expect(r.mock_used.get("pull") == null);
    try testing.expectEqual(@as(usize, 1), r.mock_used.get("tags[+]").?);
}

const boris_fixture_search =
    \\{"format":"boris-rendered-search-index","schema_version":1,"documents":[
    \\ {"path":"claims/backups.html","title":"AcmeDB has managed backups","sections":[
    \\  {"level":1,"heading":"AcmeDB has managed backups","fragment":"h","text":"","code":""},
    \\  {"level":2,"heading":"Claim","fragment":"claim","text":"AcmeDB takes a snapshot every hour and keeps thirty days of them.","code":""}]}]}
;

const boris_fixture_completion =
    \\{"format":"boris-completion-index","schema_version":1,"entities":[
    \\ {"id":"claims/backups","title":"AcmeDB has managed backups","tags":["claim","supported"],"relations":[]}]}
;

test "boris evidence: snippets gate a slot; verbatim accepted, paraphrase rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    const art = try borisrag.parse(a, boris_fixture_search, boris_fixture_completion, &msg);
    const ev = (try borisEvidence(a, &art, try testData(a,
        \\{"title":"acmedb backups"}
    ))).?;
    try testing.expect(ev.len > 0);

    var env: std.process.Environ.Map = .init(a);
    var ctx: Ctx = .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = &env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
    const pull = slotNamed(try parseShape(a, test_shape), "pull");
    // A verbatim snippet entails; a paraphrase of it does not.
    try testing.expectEqual(@as(?[]const u8, null), try checkEvidence(&ctx, .heuristic, pull, .{ .string = ev[0] }, ev));
    const paraphrase = "Snapshots of AcmeDB run every hour with thirty days kept.";
    try testing.expect((try checkEvidence(&ctx, .heuristic, pull, .{ .string = paraphrase }, ev)) != null);
    // subject beats title as the query.
    const subj = (try borisEvidence(a, &art, try testData(a,
        \\{"subject":"acmedb backups","title":"zz nothing matches this"}
    ))).?;
    try testing.expect(subj.len > 0);
}
