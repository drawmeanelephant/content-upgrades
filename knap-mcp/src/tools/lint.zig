//! knap_lint: k4o lint on a shipped template or raw template text.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const engine = @import("../engine.zig");
const store = @import("../store.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_lint",
    .description = "k4o education-grade lint on a shipped template (template_id) or raw template_text.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"template_text":{"type":"string"}}}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    var tpl: []const u8 = undefined;
    if (common.getStr(args, "template_id")) |id| {
        tpl = try common.templatePath(ctx, id);
    } else if (common.getStr(args, "template_text")) |text| {
        tpl = try store.scratchFile(ctx, "knap");
        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = tpl, .data = text }) catch
            return ctx.fail("cannot stage template_text", .{});
    } else return ctx.fail("provide template_id or template_text", .{});

    switch (try engine.lint(ctx, tpl)) {
        .ok => |findings| {
            try out.writer.writeAll("{\"ok\":");
            // k4o lint: exit 0 = clean, else findings text on stdout.
            const clean = std.mem.indexOf(u8, findings, "clean") != null;
            try out.writer.writeAll(if (clean) "true" else "false");
            try out.writer.writeAll(",\"findings\":");
            try std.json.Stringify.value(findings, .{}, &out.writer);
            try out.writer.writeAll("}");
        },
        .diags => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try common.writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}
