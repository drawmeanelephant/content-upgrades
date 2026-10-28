//! boris_check: answer a claim yes / no / unknown from the frozen boris
//! site's claim pages (verdict tag, negation polarity, term coverage).

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const tools = @import("../tools.zig");
const common = @import("common.zig");
const borisrag = @import("../borisrag.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "boris_check",
    .description = "Check a claim against the frozen boris site's claim pages. Returns answer yes|no|unknown, the matched claim (title, verdict, cited sources with URLs), polarity and term coverage; below 0.5 coverage the answer is unknown. Filed publish exports carry no claim pages, so the answer there is always unknown.",
    .input_schema =
    \\{"type":"object","properties":{"claim":{"type":"string"}},"required":["claim"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const claim = try common.requireStr(ctx, args, "claim");
    const art = try borisrag.load(ctx);
    const verdict = try borisrag.check(ctx.arena, &art, claim);
    try borisrag.writeCheckJson(&out.writer, claim, verdict, art.shape);
}
