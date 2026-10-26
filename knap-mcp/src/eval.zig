//! Repair-eval harness — the slide-number factory.
//!
//! A corpus (eval/seeds*.json) holds seeded breakages. Each seed names one
//! template source, data, an error class, and a surgical break:
//!
//!     {"id": "...", "class": "unclosed-if",
//!      "template_id": "verdict"            (shipped template), or
//!      "template": "{% if x %}..."         (inline text), or
//!      "template_path": "templates/x.knap" (corpus-relative file),
//!      "data": {...} | "@path",
//!      "break": {"kind": "none|remove|replace", "find": "...",
//!                "replace": "...", "occurrence": 0}}
//!
//! An optional top-level "classes" array fixes the per-class table order
//! and rejects seeds whose class is not declared (typos would otherwise
//! open a new one-seed class).
//!
//! The harness applies the break, runs the bounded repair loop, and emits a
//! per-seed table, a per-class table, and a JSON report in the store.
//! Corpus semantics live in the JSON, not in CLI flags.
//!
//! Honesty rules:
//!   - A non-control seed that renders clean before repair is a no-op seed.
//!     It is reported and kept out of the convergence denominator, never
//!     counted as converged.
//!   - A control (class "control") must render clean untouched.
//!   - "exact" means the repaired render is byte-identical to the unbroken
//!     template's render. A patch that deletes the broken construct can
//!     converge without being exact.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const repair = @import("repair.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");

const max_input = 16 * 1024 * 1024;
const control_class = "control";

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

const Source = union(enum) {
    template_id: []const u8,
    inline_text: []const u8,
    path: []const u8,
};

const Corpus = struct {
    seeds: []Seed,
    /// Declared class order; empty when the corpus declares none.
    classes: []const []const u8,
};

const Seed = struct {
    id: []const u8,
    class: []const u8,
    source: Source,
    data: std.json.Value, // object literal, or "@path" file ref
    mutation: Mutation,

    fn isControl(s: Seed) bool {
        return std.mem.eql(u8, s.class, control_class);
    }
};

const Mutation = union(enum) {
    none,
    remove: Find,
    replace: FindReplace,
};

const Find = struct { find: []const u8, occurrence: usize };
const FindReplace = struct { find: []const u8, replace: []const u8, occurrence: usize };

const Status = enum {
    converged,
    failed,
    errored,
    noop,
    control_clean,
    control_broken,

    fn label(s: Status) []const u8 {
        return switch (s) {
            .converged => "yes",
            .failed => "NO",
            .errored => "ERROR",
            .noop => "no-op",
            .control_clean => "clean",
            .control_broken => "BROKEN",
        };
    }

    /// Breaks are the convergence denominator: seeds that really failed
    /// to render before repair.
    fn isBreak(s: Status) bool {
        return switch (s) {
            .converged, .failed, .errored => true,
            .noop, .control_clean, .control_broken => false,
        };
    }
};

const Row = struct {
    id: []const u8,
    class: []const u8,
    mutation: []const u8,
    status: Status = .failed,
    iterations: usize = 0,
    residual: usize = 0,
    /// null when there is no unbroken baseline to compare against.
    exact: ?bool = null,
    first_diag: []const u8 = "",
    residual_diag: []const u8 = "",
};

const ClassStat = struct {
    name: []const u8,
    breaks: usize = 0,
    converged: usize = 0,
    /// Iterations summed over converged seeds only.
    iters: usize = 0,
    exact: usize = 0,
    exact_known: usize = 0,
    noop: usize = 0,

    fn add(c: *ClassStat, r: Row) void {
        if (r.status == .noop) c.noop += 1;
        if (!r.status.isBreak()) return;
        c.breaks += 1;
        if (r.status != .converged) return;
        c.converged += 1;
        c.iters += r.iterations;
        if (r.exact) |e| {
            c.exact_known += 1;
            if (e) c.exact += 1;
        }
    }
};

const Summary = struct {
    classes: []ClassStat,
    all: ClassStat,
    controls: usize,
    controls_clean: usize,
};

pub fn run(ctx: *Ctx, corpus_path: []const u8, kind: backend.Kind, w: anytype) !u8 {
    const corpus_dir = std.fs.path.dirname(corpus_path) orelse ".";
    const corpus = try loadCorpus(ctx, corpus_path);

    var rows: std.ArrayList(Row) = .empty;
    for (corpus.seeds) |seed| try rows.append(ctx.arena, try runSeed(ctx, corpus_dir, seed, kind));
    const sum = try tally(ctx.arena, rows.items, corpus.classes);

    // Convergence tables — stdout is the slide factory's display surface.
    try w.print("backend: {s}   corpus: {s}   max_iters: {d}\n\n", .{ @tagName(kind), corpus_path, repair.default_max_iterations });
    try w.writeAll("| seed | class | break | converged | iters | residual diags | exact |\n");
    try w.writeAll("|---|---|---|---|---|---|---|\n");
    for (rows.items) |r| {
        try w.print("| {s} | {s} | {s} | {s} | {d} | {d} | {s} |\n", .{
            r.id, r.class, r.mutation, r.status.label(), r.iterations, r.residual, exactLabel(r.exact),
        });
    }

    try w.writeAll("\n| class | breaks | converged | rate | mean iters | exact | no-op |\n");
    try w.writeAll("|---|---|---|---|---|---|---|\n");
    for (sum.classes) |c| try writeClassRow(w, c);
    try writeClassRow(w, sum.all);

    const a = sum.all;
    try w.print("\nconverged {d}/{d} breaks   mean iters {d:.2}   exact {d}/{d}   no-op seeds {d}   controls {d}/{d} clean\n", .{
        a.converged, a.breaks, ratio(a.iters, a.converged), a.exact, a.exact_known, a.noop, sum.controls_clean, sum.controls,
    });

    // JSON report lands in the store — a handle, not a paste.
    const doc_id = try store.put(ctx, "eval.json", try reportJson(ctx, corpus_path, kind, rows.items, sum));
    try w.print("report: knap://docs/{s}\n", .{doc_id});
    return 0;
}

fn runSeed(ctx: *Ctx, corpus_dir: []const u8, seed: Seed, kind: backend.Kind) Error!Row {
    const base = try sourceText(ctx, corpus_dir, seed);
    const broken = try applyMutation(ctx, base, seed.mutation);
    const data_path = try resolveData(ctx, corpus_dir, seed.data);
    var row: Row = .{ .id = seed.id, .class = seed.class, .mutation = @tagName(seed.mutation) };

    const outcome = repair.run(ctx, .markdown, broken, data_path, kind, repair.default_max_iterations) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        row.status = if (seed.isControl()) .control_broken else .errored;
        row.residual_diag = if (e == error.ToolFailed) ctx.err_msg else @errorName(e);
        std.debug.print("knap-mcp eval: seed '{s}' failed: {s}\n", .{ seed.id, row.residual_diag });
        return row;
    };
    row.status = statusOf(seed.isControl(), outcome.converged, outcome.iterations);
    row.iterations = outcome.iterations;
    row.residual = outcome.diags.len;
    if (outcome.steps.len > 0) row.first_diag = outcome.steps[0].detail;
    if (outcome.diags.len > 0) row.residual_diag = outcome.diags[0].detail;

    // Every mutated seed's base must render clean, or the break is not the
    // only defect and the row proves nothing.
    if (seed.mutation != .none) {
        const want = try baseRender(ctx, seed.id, base, data_path);
        if (row.status == .converged) {
            if (want) |doc| row.exact = std.mem.eql(u8, doc, outcome.document.?);
        }
    }
    if (row.status == .noop)
        std.debug.print("knap-mcp eval: no-op seed '{s}': break does not fail under this engine\n", .{seed.id});
    if (row.status == .control_broken)
        std.debug.print("knap-mcp eval: control '{s}' does not render clean: {s}\n", .{ seed.id, row.first_diag });
    return row;
}

fn statusOf(control: bool, converged: bool, iterations: usize) Status {
    const clean_before = converged and iterations == 0;
    if (control) return if (clean_before) .control_clean else .control_broken;
    if (clean_before) return .noop;
    return if (converged) .converged else .failed;
}

fn baseRender(ctx: *Ctx, seed_id: []const u8, base: []const u8, data_path: []const u8) Error!?[]const u8 {
    const path = try store.scratchFile(ctx, "knap");
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = base }) catch
        return ctx.fail("cannot stage base template", .{});
    switch (try engine.render(ctx, .markdown, path, data_path)) {
        .ok => |doc| return doc,
        .diags => |d| {
            std.debug.print("knap-mcp eval: seed '{s}' base template does not render clean: {s}\n", .{ seed_id, d[0].detail });
            return null;
        },
    }
}

fn tally(arena: std.mem.Allocator, rows: []const Row, declared: []const []const u8) error{OutOfMemory}!Summary {
    var classes: std.ArrayList(ClassStat) = .empty;
    for (declared) |name| try classes.append(arena, .{ .name = name });
    var all: ClassStat = .{ .name = "all" };
    var controls: usize = 0;
    var controls_clean: usize = 0;
    for (rows) |r| {
        switch (r.status) {
            .control_clean, .control_broken => {
                controls += 1;
                if (r.status == .control_clean) controls_clean += 1;
                continue;
            },
            else => {},
        }
        all.add(r);
        const c = for (classes.items) |*s| {
            if (std.mem.eql(u8, s.name, r.class)) break s;
        } else blk: {
            try classes.append(arena, .{ .name = r.class });
            break :blk &classes.items[classes.items.len - 1];
        };
        c.add(r);
    }
    // Declared-but-unused classes stay out of the table.
    var used: std.ArrayList(ClassStat) = .empty;
    for (classes.items) |c| {
        if (c.breaks > 0 or c.noop > 0) try used.append(arena, c);
    }
    return .{ .classes = used.items, .all = all, .controls = controls, .controls_clean = controls_clean };
}

fn writeClassRow(w: anytype, c: ClassStat) !void {
    try w.print("| {s} | {d} | {d} | ", .{ c.name, c.breaks, c.converged });
    if (c.breaks == 0) try w.writeAll("-") else try w.print("{d:.0}%", .{100.0 * ratio(c.converged, c.breaks)});
    try w.writeAll(" | ");
    if (c.converged == 0) try w.writeAll("-") else try w.print("{d:.2}", .{ratio(c.iters, c.converged)});
    try w.print(" | {d}/{d} | {d} |\n", .{ c.exact, c.exact_known, c.noop });
}

fn ratio(num: usize, den: usize) f64 {
    if (den == 0) return 0;
    return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

fn exactLabel(e: ?bool) []const u8 {
    return if (e) |v| (if (v) "yes" else "no") else "-";
}

fn reportJson(ctx: *Ctx, corpus_path: []const u8, kind: backend.Kind, rows: []const Row, sum: Summary) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &aw.writer;
    const a = sum.all;
    try w.print("{{\"backend\":\"{s}\",\"corpus\":", .{@tagName(kind)});
    try std.json.Stringify.value(corpus_path, .{}, w);
    try w.print(",\"seeds\":{d},\"breaks\":{d},\"converged\":{d},\"mean_iters\":{d:.2},\"exact\":{d},\"exact_known\":{d},\"noop\":{d},\"controls\":{d},\"controls_clean\":{d},\"classes\":[", .{
        rows.len, a.breaks, a.converged, ratio(a.iters, a.converged), a.exact, a.exact_known, a.noop, sum.controls, sum.controls_clean,
    });
    for (sum.classes, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"class\":");
        try std.json.Stringify.value(c.name, .{}, w);
        try w.print(",\"breaks\":{d},\"converged\":{d},\"mean_iters\":{d:.2},\"exact\":{d},\"exact_known\":{d},\"noop\":{d}}}", .{
            c.breaks, c.converged, ratio(c.iters, c.converged), c.exact, c.exact_known, c.noop,
        });
    }
    try w.writeAll("],\"rows\":[");
    for (rows, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(r.id, .{}, w);
        try w.writeAll(",\"class\":");
        try std.json.Stringify.value(r.class, .{}, w);
        try w.print(",\"mutation\":\"{s}\",\"status\":\"{s}\",\"converged\":{s},\"iterations\":{d},\"residual\":{d},\"exact\":{s},\"first_diag\":", .{
            r.mutation,
            @tagName(r.status),
            if (r.status == .converged) "true" else "false",
            r.iterations,
            r.residual,
            if (r.exact) |e| (if (e) "true" else "false") else "null",
        });
        try std.json.Stringify.value(r.first_diag, .{}, w);
        try w.writeAll(",\"residual_diag\":");
        try std.json.Stringify.value(r.residual_diag, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return aw.written();
}

// --- corpus loading ----------------------------------------------------------

fn loadCorpus(ctx: *Ctx, corpus_path: []const u8) Error!Corpus {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, corpus_path, ctx.arena, .limited(max_input)) catch
        return ctx.fail("cannot read corpus '{s}'", .{corpus_path});
    return parseCorpus(ctx, corpus_path, bytes);
}

fn parseCorpus(ctx: *Ctx, corpus_path: []const u8, bytes: []const u8) Error!Corpus {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, bytes, .{}) catch
        return ctx.fail("corpus '{s}' is not valid JSON", .{corpus_path});
    const root = switch (parsed) {
        .object => |o| o,
        else => return ctx.fail("corpus root must be an object", .{}),
    };
    const arr = switch (root.get("seeds") orelse return ctx.fail("corpus needs a 'seeds' array", .{})) {
        .array => |a| a,
        else => return ctx.fail("corpus 'seeds' must be an array", .{}),
    };

    var classes: std.ArrayList([]const u8) = .empty;
    if (root.get("classes")) |cv| {
        const list = switch (cv) {
            .array => |a| a,
            else => return ctx.fail("corpus 'classes' must be an array of strings", .{}),
        };
        for (list.items) |item| switch (item) {
            .string => |s| try classes.append(ctx.arena, s),
            else => return ctx.fail("corpus 'classes' must be an array of strings", .{}),
        };
    }

    var seeds: std.ArrayList(Seed) = .empty;
    for (arr.items) |item| {
        const seed = try parseSeed(ctx, item);
        for (seeds.items) |prev| {
            if (std.mem.eql(u8, prev.id, seed.id))
                return ctx.fail("duplicate seed id '{s}'", .{seed.id});
        }
        if (classes.items.len > 0 and !seed.isControl() and !contains(classes.items, seed.class))
            return ctx.fail("seed '{s}' uses undeclared class '{s}'", .{ seed.id, seed.class });
        try seeds.append(ctx.arena, seed);
    }
    return .{ .seeds = seeds.items, .classes = classes.items };
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn parseSeed(ctx: *Ctx, item: std.json.Value) Error!Seed {
    const obj = switch (item) {
        .object => |o| o,
        else => return ctx.fail("each seed must be an object", .{}),
    };
    const id = strOf(obj, "id") orelse "seed";
    const mutation = try parseMutation(ctx, obj.get("break"));
    return .{
        .id = id,
        // Unbroken, unlabeled seeds are controls; a pre-broken template
        // (break "none") must name its class explicitly.
        .class = strOf(obj, "class") orelse if (mutation == .none) control_class else "unclassified",
        .source = try parseSource(ctx, obj, id),
        .data = obj.get("data") orelse .{ .object = .empty },
        .mutation = mutation,
    };
}

fn parseSource(ctx: *Ctx, obj: std.json.ObjectMap, id: []const u8) Error!Source {
    const by_id = strOf(obj, "template_id");
    const by_text = strOf(obj, "template");
    const by_path = strOf(obj, "template_path");
    const n = @as(u8, @intFromBool(by_id != null)) + @intFromBool(by_text != null) + @intFromBool(by_path != null);
    if (n != 1)
        return ctx.fail("seed '{s}' needs exactly one of template_id, template, template_path", .{id});
    if (by_id) |v| return .{ .template_id = v };
    if (by_text) |v| return .{ .inline_text = v };
    return .{ .path = by_path.? };
}

fn parseMutation(ctx: *Ctx, v: ?std.json.Value) Error!Mutation {
    const obj = switch (v orelse return .none) {
        .object => |o| o,
        else => return ctx.fail("seed 'break' must be an object", .{}),
    };
    const kind = strOf(obj, "kind") orelse "none";
    const occ_v = obj.get("occurrence") orelse std.json.Value{ .integer = 0 };
    const occ: usize = switch (occ_v) {
        .integer => |n| @intCast(@max(0, n)),
        else => 0,
    };
    if (std.mem.eql(u8, kind, "none")) return .none;
    const find = strOf(obj, "find") orelse return ctx.fail("break needs 'find'", .{});
    if (std.mem.eql(u8, kind, "remove")) return .{ .remove = .{ .find = find, .occurrence = occ } };
    if (std.mem.eql(u8, kind, "replace")) {
        const rep = strOf(obj, "replace") orelse return ctx.fail("break 'replace' needs 'replace'", .{});
        return .{ .replace = .{ .find = find, .replace = rep, .occurrence = occ } };
    }
    return ctx.fail("unknown break kind '{s}'", .{kind});
}

fn sourceText(ctx: *Ctx, corpus_dir: []const u8, seed: Seed) Error![]const u8 {
    switch (seed.source) {
        .template_id => |id| return tools.templateText(ctx, id),
        .inline_text => |t| return t,
        .path => |rel| {
            const path = try resolveCorpusPath(ctx, corpus_dir, rel) orelse
                return ctx.fail("seed '{s}': template_path '{s}' not found", .{ seed.id, rel });
            return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(max_input)) catch
                return ctx.fail("seed '{s}': cannot read '{s}'", .{ seed.id, path });
        },
    }
}

fn applyMutation(ctx: *Ctx, text: []const u8, m: Mutation) Error![]const u8 {
    const spec: FindReplace = switch (m) {
        .none => return text,
        .remove => |f| .{ .find = f.find, .replace = "", .occurrence = f.occurrence },
        .replace => |f| f,
    };
    // Nth occurrence only — mutations must be surgical to stay legible.
    const p = findNth(text, spec.find, spec.occurrence) orelse
        return ctx.fail("break target '{s}' occurrence {d} not found", .{ spec.find, spec.occurrence });
    return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ text[0..p], spec.replace, text[p + spec.find.len ..] });
}

fn findNth(text: []const u8, needle: []const u8, n: usize) ?usize {
    if (needle.len == 0) return null;
    var at: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, needle)) |hit| {
        if (seen == n) return hit;
        seen += 1;
        at = hit + needle.len;
    }
    return null;
}

/// Corpus paths resolve against the corpus file's directory, then cwd,
/// then the project root (parent of templates_dir), so a corpus is
/// portable across working directories.
fn resolveCorpusPath(ctx: *Ctx, corpus_dir: []const u8, rel: []const u8) Error!?[]const u8 {
    if (std.fs.path.isAbsolute(rel)) {
        std.Io.Dir.access(.cwd(), ctx.io, rel, .{}) catch return null;
        return rel;
    }
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ corpus_dir, rel }),
        rel,
        try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.project_root, rel }),
    };
    for (candidates) |c| {
        std.Io.Dir.access(.cwd(), ctx.io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// "@path" resolves a data file via resolveCorpusPath; an inline value is
/// staged to a scratch file for the engine.
fn resolveData(ctx: *Ctx, corpus_dir: []const u8, v: std.json.Value) Error![]const u8 {
    switch (v) {
        .string => |s| {
            if (!std.mem.startsWith(u8, s, "@"))
                return ctx.fail("data string must be an '@path' file ref", .{});
            return try resolveCorpusPath(ctx, corpus_dir, s[1..]) orelse
                ctx.fail("data file '{s}' not found", .{s[1..]});
        },
        else => {
            const json = std.json.Stringify.valueAlloc(ctx.arena, v, .{}) catch return error.OutOfMemory;
            const path = try store.scratchFile(ctx, "json");
            std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = json }) catch
                return ctx.fail("cannot stage seed data", .{});
            return path;
        },
    }
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// --- tests -------------------------------------------------------------------

fn testCtx(arena: std.mem.Allocator) Ctx {
    return .{
        .arena = arena,
        .gpa = arena,
        .io = undefined,
        .environ = undefined,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
}

test "statusOf separates no-op seeds and controls from real breaks" {
    try std.testing.expectEqual(Status.noop, statusOf(false, true, 0));
    try std.testing.expectEqual(Status.converged, statusOf(false, true, 1));
    try std.testing.expectEqual(Status.failed, statusOf(false, false, 1));
    try std.testing.expectEqual(Status.control_clean, statusOf(true, true, 0));
    try std.testing.expectEqual(Status.control_broken, statusOf(true, true, 2));
    try std.testing.expectEqual(Status.control_broken, statusOf(true, false, 1));
}

test "findNth picks the requested occurrence" {
    try std.testing.expectEqual(@as(?usize, 0), findNth("ab ab ab", "ab", 0));
    try std.testing.expectEqual(@as(?usize, 6), findNth("ab ab ab", "ab", 2));
    try std.testing.expectEqual(@as(?usize, null), findNth("ab ab ab", "ab", 3));
    try std.testing.expectEqual(@as(?usize, null), findNth("ab", "", 0));
}

test "tally keeps no-op seeds and controls out of the denominator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = [_]Row{
        .{ .id = "a", .class = "unclosed-if", .mutation = "remove", .status = .converged, .iterations = 1, .exact = true },
        .{ .id = "b", .class = "unclosed-if", .mutation = "remove", .status = .converged, .iterations = 3, .exact = false },
        .{ .id = "c", .class = "unclosed-if", .mutation = "remove", .status = .noop },
        .{ .id = "d", .class = "orphan-endif", .mutation = "remove", .status = .failed, .iterations = 1 },
        .{ .id = "e", .class = "orphan-endif", .mutation = "none", .status = .converged, .iterations = 1 },
        .{ .id = "f", .class = "control", .mutation = "none", .status = .control_clean },
    };
    const s = try tally(arena_state.allocator(), &rows, &.{});
    try std.testing.expectEqual(@as(usize, 2), s.classes.len);
    try std.testing.expectEqual(@as(usize, 4), s.all.breaks);
    try std.testing.expectEqual(@as(usize, 3), s.all.converged);
    try std.testing.expectEqual(@as(usize, 5), s.all.iters);
    try std.testing.expectEqual(@as(usize, 1), s.all.exact);
    try std.testing.expectEqual(@as(usize, 2), s.all.exact_known);
    try std.testing.expectEqual(@as(usize, 1), s.all.noop);
    try std.testing.expectEqual(@as(usize, 1), s.controls_clean);
    try std.testing.expectEqualStrings("unclosed-if", s.classes[0].name);
    try std.testing.expectEqual(@as(usize, 2), s.classes[0].breaks);
    try std.testing.expectEqual(@as(usize, 2), s.classes[1].breaks);
    try std.testing.expectEqual(@as(usize, 1), s.classes[1].converged);

    // Declared order wins; declared-but-unused classes are dropped.
    const d = try tally(arena_state.allocator(), &rows, &.{ "orphan-endif", "unused", "unclosed-if" });
    try std.testing.expectEqual(@as(usize, 2), d.classes.len);
    try std.testing.expectEqualStrings("orphan-endif", d.classes[0].name);
    try std.testing.expectEqualStrings("unclosed-if", d.classes[1].name);
}

test "parseCorpus accepts all three template sources and defaults classes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator());
    const corpus = try parseCorpus(&ctx, "t.json",
        \\{"seeds": [
        \\  {"id": "a", "template_id": "verdict"},
        \\  {"id": "b", "template": "{% if x %}y", "class": "unclosed-if"},
        \\  {"id": "c", "template_path": "templates/x.knap",
        \\   "break": {"kind": "remove", "find": "}}"}}
        \\]}
    );
    const seeds = corpus.seeds;
    try std.testing.expectEqual(@as(usize, 3), seeds.len);
    try std.testing.expectEqual(@as(usize, 0), corpus.classes.len);
    try std.testing.expectEqualStrings("verdict", seeds[0].source.template_id);
    try std.testing.expect(seeds[0].isControl());
    try std.testing.expectEqualStrings("{% if x %}y", seeds[1].source.inline_text);
    try std.testing.expectEqualStrings("unclosed-if", seeds[1].class);
    try std.testing.expectEqualStrings("templates/x.knap", seeds[2].source.path);
    try std.testing.expectEqualStrings("unclassified", seeds[2].class);
}

test "parseCorpus rejects ambiguous sources and duplicate ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator());
    try std.testing.expectError(error.ToolFailed, parseCorpus(&ctx, "t.json",
        \\{"seeds": [{"id": "a", "template_id": "verdict", "template": "x"}]}
    ));
    try std.testing.expectError(error.ToolFailed, parseCorpus(&ctx, "t.json",
        \\{"seeds": [{"id": "a"}]}
    ));
    try std.testing.expectError(error.ToolFailed, parseCorpus(&ctx, "t.json",
        \\{"seeds": [{"id": "a", "template": "x"}, {"id": "a", "template": "y"}]}
    ));
}

test "parseCorpus rejects classes the corpus does not declare" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator());
    const ok = try parseCorpus(&ctx, "t.json",
        \\{"classes": ["unclosed-if"], "seeds": [
        \\  {"id": "a", "template": "x"},
        \\  {"id": "b", "template": "{% if x %}", "class": "unclosed-if"}]}
    );
    try std.testing.expectEqual(@as(usize, 2), ok.seeds.len);
    try std.testing.expectError(error.ToolFailed, parseCorpus(&ctx, "t.json",
        \\{"classes": ["unclosed-if"], "seeds": [
        \\  {"id": "b", "template": "{% if x %}", "class": "unclosed-iff"}]}
    ));
}
