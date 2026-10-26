//! Repair-eval harness — the slide-number factory.
//!
//! seeds.json holds seeded breakages: each mutates a shipped template
//! through a pinned error class, the bounded repair loop runs, and the
//! harness emits a convergence table ("backend fixes N/M seeded breaks").
//! Works with mock patches so the plumbing is exercised with zero API
//! access; real backend numbers land when MODEL_API_KEY does.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const repair = @import("repair.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");

const max_input = 16 * 1024 * 1024;

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

const Seed = struct {
    id: []const u8,
    template_id: []const u8,
    data: std.json.Value, // object literal, or "@path" file ref
    mutation: Mutation,
};

const Mutation = union(enum) {
    none,
    remove: Find,
    replace: FindReplace,
};

const Find = struct { find: []const u8, occurrence: usize };
const FindReplace = struct { find: []const u8, replace: []const u8, occurrence: usize };

const Row = struct {
    id: []const u8,
    mutation: []const u8,
    converged: bool,
    iterations: usize,
    residual: usize,
};

pub fn run(ctx: *Ctx, corpus_path: []const u8, kind: backend.Kind, w: anytype) !u8 {
    const seeds = try loadSeeds(ctx, corpus_path);

    var rows: std.ArrayList(Row) = .empty;
    var converged: usize = 0;
    var total_iters: usize = 0;

    for (seeds) |seed| {
        const shipped = try tools.templateText(ctx, seed.template_id);
        const broken = try applyMutation(ctx, shipped, seed.mutation);
        const data_path = try resolveData(ctx, seed.data);
        const outcome = repair.run(ctx, .markdown, broken, data_path, kind, repair.default_max_iterations) catch |e| {
            try rows.append(ctx.arena, .{
                .id = seed.id,
                .mutation = @tagName(seed.mutation),
                .converged = false,
                .iterations = 0,
                .residual = 0,
            });
            if (e == error.ToolFailed)
                std.debug.print("knap-mcp eval: seed '{s}' failed: {s}\n", .{ seed.id, ctx.err_msg });
            continue;
        };
        if (outcome.converged) converged += 1;
        total_iters += outcome.iterations;
        try rows.append(ctx.arena, .{
            .id = seed.id,
            .mutation = @tagName(seed.mutation),
            .converged = outcome.converged,
            .iterations = outcome.iterations,
            .residual = outcome.diags.len,
        });
    }

    // Convergence table — stdout is the slide factory's display surface.
    try w.print("backend: {s}   corpus: {s}   max_iters: {d}\n\n", .{ @tagName(kind), corpus_path, repair.default_max_iterations });
    try w.writeAll("| seed | break | converged | iters | residual diags |\n");
    try w.writeAll("|---|---|---|---|---|\n");
    for (rows.items) |r| {
        try w.print("| {s} | {s} | {s} | {d} | {d} |\n", .{
            r.id, r.mutation, if (r.converged) "yes" else "NO", r.iterations, r.residual,
        });
    }
    const mean: f64 = if (rows.items.len == 0) 0 else @as(f64, @floatFromInt(total_iters)) / @as(f64, @floatFromInt(rows.items.len));
    try w.print("\nconverged {d}/{d}   mean iters {d:.2}\n", .{ converged, rows.items.len, mean });

    // JSON report lands in the store — a handle, not a paste.
    var report: std.Io.Writer.Allocating = .init(ctx.arena);
    try report.writer.print("{{\"backend\":\"{s}\",\"corpus\":", .{@tagName(kind)});
    try std.json.Stringify.value(corpus_path, .{}, &report.writer);
    try report.writer.print(",\"converged\":{d},\"total\":{d},\"mean_iters\":{d:.2},\"rows\":[", .{ converged, rows.items.len, mean });
    for (rows.items, 0..) |r, i| {
        if (i > 0) try report.writer.writeAll(",");
        try report.writer.print("{{\"id\":\"{s}\",\"mutation\":\"{s}\",\"converged\":{s},\"iterations\":{d},\"residual\":{d}}}", .{
            r.id, r.mutation, if (r.converged) "true" else "false", r.iterations, r.residual,
        });
    }
    try report.writer.writeAll("]}");
    const doc_id = try store.put(ctx, "eval.json", report.written());
    try w.print("report: knap://docs/{s}\n", .{doc_id});
    return 0;
}

fn loadSeeds(ctx: *Ctx, corpus_path: []const u8) Error![]Seed {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, corpus_path, ctx.arena, .limited(max_input)) catch
        return ctx.fail("cannot read corpus '{s}'", .{corpus_path});
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

    var seeds: std.ArrayList(Seed) = .empty;
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return ctx.fail("each seed must be an object", .{}),
        };
        seeds.append(ctx.arena, .{
            .id = strOf(ctx, obj, "id") orelse "seed",
            .template_id = strOf(ctx, obj, "template_id") orelse return ctx.fail("seed needs template_id", .{}),
            .data = obj.get("data") orelse .{ .object = .empty },
            .mutation = try parseMutation(ctx, obj.get("break")),
        }) catch return error.OutOfMemory;
    }
    return seeds.items;
}

fn parseMutation(ctx: *Ctx, v: ?std.json.Value) Error!Mutation {
    const obj = switch (v orelse return .none) {
        .object => |o| o,
        else => return ctx.fail("seed 'break' must be an object", .{}),
    };
    const kind = strOf(ctx, obj, "kind") orelse "none";
    const occ_v = obj.get("occurrence") orelse std.json.Value{ .integer = 0 };
    const occ: usize = switch (occ_v) {
        .integer => |n| @intCast(@max(0, n)),
        else => 0,
    };
    if (std.mem.eql(u8, kind, "none")) return .none;
    const find = strOf(ctx, obj, "find") orelse return ctx.fail("break needs 'find'", .{});
    if (std.mem.eql(u8, kind, "remove")) return .{ .remove = .{ .find = find, .occurrence = occ } };
    if (std.mem.eql(u8, kind, "replace")) {
        const rep = strOf(ctx, obj, "replace") orelse return ctx.fail("break 'replace' needs 'replace'", .{});
        return .{ .replace = .{ .find = find, .replace = rep, .occurrence = occ } };
    }
    return ctx.fail("unknown break kind '{s}'", .{kind});
}

fn applyMutation(ctx: *Ctx, text: []const u8, m: Mutation) Error![]const u8 {
    const spec: FindReplace = switch (m) {
        .none => return text,
        .remove => |f| .{ .find = f.find, .replace = "", .occurrence = f.occurrence },
        .replace => |f| f,
    };
    // Nth occurrence only — mutations must be surgical to stay legible.
    var at: usize = 0;
    var seen: usize = 0;
    var pos: ?usize = null;
    while (std.mem.indexOfPos(u8, text, at, spec.find)) |hit| {
        if (seen == spec.occurrence) {
            pos = hit;
            break;
        }
        seen += 1;
        at = hit + spec.find.len;
    }
    const p = pos orelse return ctx.fail("break target '{s}' occurrence {d} not found", .{ spec.find, spec.occurrence });
    return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ text[0..p], spec.replace, text[p + spec.find.len ..] });
}

/// "@path" resolves a data file relative to cwd, falling back to the
/// project root (parent of templates_dir) so the corpus is portable.
fn resolveData(ctx: *Ctx, v: std.json.Value) Error![]const u8 {
    switch (v) {
        .string => |s| {
            if (!std.mem.startsWith(u8, s, "@"))
                return ctx.fail("data string must be an '@path' file ref", .{});
            const rel = s[1..];
            const candidates = [_][]const u8{
                rel,
                try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.project_root, rel }),
            };
            for (candidates) |c| {
                std.Io.Dir.access(.cwd(), ctx.io, c, .{}) catch continue;
                return c;
            }
            return ctx.fail("data file '{s}' not found", .{rel});
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

fn strOf(ctx: *Ctx, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    _ = ctx;
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
