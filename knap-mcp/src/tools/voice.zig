//! knap_voice: rewrite a data object's `voice: true` values in one tone.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const backend = @import("../backend.zig");
const voice = @import("../voice.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_voice",
    .description = "Rewrite the voice: true string values of a shipped template's data in one tone (mild|spicy|feral), one model call per value. A rewrite that drops or adds a fact, markup or a line break keeps the original. Templates and structure never change. Returns the voiced data plus a per-field before/after report.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"tone":{"type":"string","enum":["mild","spicy","feral"]},"backend":{"type":"string","enum":["mock","spark","wonder","baseten"]}},"required":["template_id","data","tone"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const tone_name = try common.requireStr(ctx, args, "tone");
    const tone = voice.parseTone(tone_name) orelse
        return ctx.fail("unknown tone '{s}': tone must be mild|spicy|feral", .{tone_name});
    const kind = if (common.getStr(args, "backend")) |b|
        backend.parseKind(b) orelse return ctx.fail("backend must be mock|spark|wonder|baseten", .{})
    else
        ctx.backend_kind;
    const result = try voice.voiceData(ctx, template_id, try common.requireData(ctx, args), tone, kind);
    try result.write(&out.writer);
}
