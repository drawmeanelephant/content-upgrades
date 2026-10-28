//! knap_render: render a shipped template to a stored doc_id handle.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_render",
    .description = "Render to markdown|oliver via k4o, or html via dogbed. Returns a doc_id handle.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"target":{"type":"string","enum":["markdown","oliver","html"]}},"required":["template_id","data","target"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const target = engine.targetFromName(common.getStr(args, "target") orelse "markdown") orelse
        return ctx.fail("target must be " ++ engine.target_names, .{});
    const data_json = try common.requireData(ctx, args);
    if (target == .html) {
        if (common.htmlDataViolation(args.?.get("data").?)) |why|
            return ctx.fail("html target: data {s}", .{why});
    }
    const data = try common.stageData(ctx, data_json);
    const tpl = try common.templatePath(ctx, template_id);

    switch (try engine.render(ctx, target, tpl, data)) {
        .ok => |doc| {
            const doc_id = store.put(ctx, engine.extension(target), doc) catch
                return ctx.fail("artifact store write failed", .{});
            try out.writer.print("{{\"ok\":true,\"doc_id\":\"{s}\",\"target\":\"{s}\",\"bytes\":{d}}}", .{
                doc_id, @tagName(target), doc.len,
            });
        },
        .diags => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try common.writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}
