//! knap_validate: dry render through the engine, diagnostics or ok.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_validate",
    .description = "Dry render: template + data through the engine, diagnostics or ok. No model call.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"}},"required":["template_id","data"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const data = try common.stageData(ctx, try common.requireData(ctx, args));
    const tpl = try common.templatePath(ctx, template_id);

    switch (try engine.render(ctx, .markdown, tpl, data)) {
        .ok => try out.writer.writeAll("{\"ok\":true,\"diagnostics\":[]}"),
        .diags => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try common.writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}
