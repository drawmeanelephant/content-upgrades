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
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"backend":{"type":"string","enum":["mock","spark","wonder","baseten"]},"target":{"type":"string","enum":["markdown","gfm","textile","html"]}},"required":["template_id","data"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const kind = backend.parseKind(common.getStr(args, "backend") orelse "") orelse ctx.backend_kind;
    const target = engine.targetFromName(common.getStr(args, "target") orelse "markdown") orelse
        return ctx.fail("target must be markdown|gfm|textile|html", .{});
    const data = try common.stageData(ctx, try common.requireData(ctx, args));
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
        const doc_id = store.put(ctx, "md", doc) catch null;
        if (doc_id) |id| try out.writer.print(",\"doc_id\":\"{s}\"", .{id});
    }
    try out.writer.writeAll(",\"steps\":[");
    for (outcome.steps, 0..) |s, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"iteration\":{d},\"kind\":", .{s.iteration});
        try std.json.Stringify.value(s.kind, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"detail\":", .{s.line});
        try std.json.Stringify.value(s.detail, .{}, &out.writer);
        try out.writer.print(",\"patch_applied\":{s}}}", .{if (s.patch_applied) "true" else "false"});
    }
    try out.writer.writeAll("],");
    try common.writeDiags(out, outcome.diags);
    try out.writer.writeAll("}");
}
