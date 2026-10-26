//! boris_ask: ranked snippets from the frozen boris site artifact. Same
//! ranking and snippets as `boris-site/ask.sh -k <limit> <query>`.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const tools = @import("../tools.zig");
const common = @import("common.zig");
const borisrag = @import("../borisrag.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "boris_ask",
    .description = "Ranked snippets from the frozen boris site artifact (search-index.json), best first. No live indexing; ranking matches boris-site/ask.sh.",
    .input_schema =
    \\{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":0,"default":5}},"required":["query"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const query = try common.requireStr(ctx, args, "query");
    const limit = try parseLimit(ctx, args);
    const art = try borisrag.load(ctx);
    const hits = try borisrag.ask(ctx.arena, &art, query, limit, false);
    try borisrag.writeAskJson(&out.writer, query, hits);
}

/// `limit` is an integer over MCP and a string from the CLI flag.
fn parseLimit(ctx: *Ctx, args: ?ObjectMap) tools.Error!usize {
    const v = (args orelse return borisrag.default_limit).get("limit") orelse return borisrag.default_limit;
    const n: ?i64 = switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and f >= 0 and f < 1e15) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
    if (n) |i| {
        if (i >= 0) return @intCast(i);
    }
    return ctx.fail("limit must be a non-negative integer", .{});
}
