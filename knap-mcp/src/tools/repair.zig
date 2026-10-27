//! knap_repair: bounded repair loop over a shipped template.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const repair = @import("../repair.zig");
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_repair",
    .description = "Bounded repair loop over shipped templates: render -> diag -> region patch -> re-render, max 4.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"backend":{"type":"string","enum":["mock","spark","wonder","baseten"]},"target":{"type":"string","enum":["markdown","oliver","html"]}},"required":["template_id","data"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const kind = if (common.getStr(args, "backend")) |b|
        backend.parseKind(b) orelse return ctx.fail("unknown backend '{s}'", .{b})
    else
        ctx.backend_kind;
    const target = engine.targetFromName(common.getStr(args, "target") orelse "markdown") orelse
        return ctx.fail("target must be " ++ engine.target_names, .{});
    const data = try common.stageData(ctx, try common.requireData(ctx, args));
    defer std.Io.Dir.deleteFile(.cwd(), ctx.io, data) catch {};
    const text = try common.templateText(ctx, template_id);

    const outcome = try repair.run(ctx, target, text, data, kind, repair.default_max_iterations);
    try writeOutcome(ctx, outcome, out);
}

/// Shared by the MCP tool and the eval harness.
pub fn writeOutcome(ctx: *Ctx, outcome: repair.Outcome, out: *Allocating) !void {
    try out.writer.print("{{\"converged\":{s},\"iterations\":{d}", .{
        if (outcome.converged) "true" else "false", outcome.iterations,
    });
    if (outcome.document) |doc| {
        const doc_id = store.put(ctx, engine.extension(outcome.target), doc) catch null;
        if (doc_id) |id| try out.writer.print(",\"doc_id\":\"{s}\"", .{id});
    }
    try out.writer.writeAll(",\"steps\":[");
    for (outcome.steps, 0..) |s, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"iteration\":{d},\"kind\":", .{s.iteration});
        try std.json.Stringify.value(s.kind, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"detail\":", .{s.line});
        try std.json.Stringify.value(s.detail, .{}, &out.writer);
        try out.writer.print(",\"patch_applied\":{s},\"region_start\":{d},\"region_end\":{d},\"region\":", .{
            if (s.patch_applied) "true" else "false", s.region_start, s.region_end,
        });
        try std.json.Stringify.value(s.region, .{}, &out.writer);
        try out.writer.writeAll(",\"patch\":");
        try std.json.Stringify.value(s.patch, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("],");
    try common.writeDiags(out, outcome.diags);
    try out.writer.writeAll("}");
}

test "writeOutcome steps carry the region and patch the backend saw" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();

    var steps = [_]repair.Step{
        .{
            .iteration = 0,
            .kind = "syntax error",
            .line = 29,
            .detail = "unclosed if block (missing '{% endif %}')",
            .patch_applied = true,
            .region_start = 29,
            .region_end = 30,
            .region = "{% if winner %}\n- {{ winner }}\n",
            .patch = "{% if winner %}\n- {{ winner }}\n{% endif %}\n",
        },
        .{
            .iteration = 1,
            .kind = "syntax error",
            .line = 3,
            .detail = "backend error: curl: connection refused",
            .patch_applied = false,
            .region_start = 1,
            .region_end = 5,
            .region = "a\nb\nc\nd\ne\n",
            .patch = null,
        },
    };
    const outcome: repair.Outcome = .{
        .target = .markdown,
        .converged = true,
        .iterations = 1,
        .template = "",
        .document = null,
        .diags = &.{},
        .steps = &steps,
    };
    var out: Allocating = .init(ctx.arena);
    try writeOutcome(&ctx, outcome, &out);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, out.written(), .{});
    const emitted = v.object.get("steps").?.array.items;
    try std.testing.expectEqual(2, emitted.len);
    const s0 = emitted[0].object;
    try std.testing.expectEqual(29, s0.get("region_start").?.integer);
    try std.testing.expectEqual(30, s0.get("region_end").?.integer);
    try std.testing.expectEqualStrings("{% if winner %}\n- {{ winner }}\n", s0.get("region").?.string);
    try std.testing.expectEqualStrings("{% if winner %}\n- {{ winner }}\n{% endif %}\n", s0.get("patch").?.string);
    try std.testing.expect(emitted[1].object.get("patch").? == .null);
}

test "run rejects an unknown backend instead of silently using the default" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();
    ctx.err_msg = "";
    const args = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena,
        \\{"template_id":"verdict","backend":"bogus"}
    , .{});
    var out: Allocating = .init(ctx.arena);
    try std.testing.expectError(error.ToolFailed, run(&ctx, args.object, &out));
    try std.testing.expectEqualStrings("unknown backend 'bogus'", ctx.err_msg);
}
