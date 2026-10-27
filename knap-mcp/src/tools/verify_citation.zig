//! knap_verify_citation: advisory claim-against-evidence check through the
//! verifier slot. Never on the render path; its score is not a
//! conformance metric.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const backend = @import("../backend.zig");
const verifier = @import("../verifier.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_verify_citation",
    .description = "Advisory check of a claim against evidence quotes: entails | neutral | contradicts | unknown. heuristic (default) is verbatim match plus word overlap, not NLI; decision asks a model and falls back to heuristic.",
    .input_schema =
    \\{"type":"object","properties":{"claim":{"type":"string"},"evidence":{"anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"verifier":{"type":"string","enum":["none","heuristic","decision"]},"backend":{"type":"string","enum":["mock","spark","wonder","baseten","acp","compat"]}},"required":["claim","evidence"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const claim = try common.requireStr(ctx, args, "claim");
    const evidence = try evidenceArg(ctx, args);
    const kind = verifier.parseKind(common.getStr(args, "verifier") orelse "heuristic") orelse
        return ctx.fail("verifier must be none|heuristic|decision", .{});
    // The backend override must not touch the shared ctx: a per-request
    // copy carries it into the verifier instead.
    var req_ctx = ctx.*;
    if (common.getStr(args, "backend")) |b|
        req_ctx.backend_kind = backend.parseKind(b) orelse return ctx.fail("unknown backend '{s}'", .{b});

    const c = try verifier.checkCitation(&req_ctx, kind, claim, evidence);
    try out.writer.print("{{\"verifier\":\"{s}\",\"label\":\"{s}\",\"score\":{d:.2},\"reason\":", .{
        @tagName(kind), @tagName(c.label), c.score,
    });
    try std.json.Stringify.value(c.reason, .{}, &out.writer);
    try out.writer.writeAll(",\"matched\":");
    try std.json.Stringify.value(c.matched, .{}, &out.writer);
    try out.writer.writeAll("}");
}

/// `evidence` is an array of strings, or one string (the CLI flag form).
fn evidenceArg(ctx: *Ctx, args: ?ObjectMap) tools.Error![]const []const u8 {
    const v = (args orelse return ctx.fail("missing arguments", .{})).get("evidence") orelse
        return ctx.fail("missing required argument 'evidence'", .{});
    switch (v) {
        .string => |s| {
            const one = try ctx.arena.alloc([]const u8, 1);
            one[0] = s;
            return one;
        },
        .array => |arr| {
            const items = try ctx.arena.alloc([]const u8, arr.items.len);
            for (arr.items, items) |e, *dst| dst.* = switch (e) {
                .string => |s| s,
                else => return ctx.fail("evidence items must be strings", .{}),
            };
            return items;
        },
        else => return ctx.fail("evidence must be a string or an array of strings", .{}),
    }
}

test "knap_verify_citation: array and string evidence, bad verifier" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx: Ctx = .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = &env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = ".knap-mcp",
        .project_root = ".",
    };
    const call = struct {
        fn f(c: *Ctx, json: []const u8) ![]const u8 {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, json, .{});
            var out: Allocating = .init(c.arena);
            try run(c, v.object, &out);
            return out.written();
        }
    }.f;
    try std.testing.expectEqualStrings(
        \\{"verifier":"heuristic","label":"entails","score":1.00,"reason":"verbatim quote of evidence[1]","matched":"Point-in-time snapshots are coming soon."}
    , try call(&ctx,
        \\{"claim":"Point-in-time snapshots are coming soon.","evidence":["x","Point-in-time snapshots are coming soon."]}
    ));
    try std.testing.expectEqualStrings(
        \\{"verifier":"none","label":"unknown","score":0.00,"reason":"verifier disabled","matched":null}
    , try call(&ctx,
        \\{"claim":"a b","evidence":"a b","verifier":"none"}
    ));
    // A backend override applies to this call only — the shared ctx keeps
    // the process default.
    try std.testing.expectEqualStrings(
        \\{"verifier":"decision","label":"entails","score":1.00,"reason":"decision verifier unavailable (no MODEL_API_KEY); heuristic: verbatim quote of evidence[0]","matched":"Snapshots are coming soon."}
    , try call(&ctx,
        \\{"claim":"Snapshots are coming soon.","evidence":"Snapshots are coming soon.","verifier":"decision","backend":"spark"}
    ));
    try std.testing.expect(ctx.backend_kind == .mock);
    try std.testing.expectError(error.ToolFailed, call(&ctx,
        \\{"claim":"a","evidence":["a"],"verifier":"nli"}
    ));
    try std.testing.expectError(error.ToolFailed, call(&ctx,
        \\{"claim":"a","evidence":[1]}
    ));
}
