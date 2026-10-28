//! knap_ratchet: values-only density ratchet over a shipped template
//! (src/ratchet.zig). Stores the best data and doc as artifacts.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const backend = @import("../backend.zig");
const ratchet = @import("../ratchet.zig");
const store = @import("../store.zig");
const verifier = @import("../verifier.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_ratchet",
    .description = "Values-only density ratchet: the server probes which empty data slot raises the density score most, asks the backend for ONE value for that slot, and keeps it only if schema, markup and evidence checks pass and the markdown score rises. Never changes a non-empty value or the template. Returns data_id and doc_id handles.",
    .input_schema =
    \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"backend":{"type":"string","enum":["mock","spark","wonder","baseten","acp","compat"]},"max_iterations":{"type":"integer","minimum":0,"maximum":20},"epsilon":{"type":"number"},"tone":{"type":"string"},"evidence":{"type":"string","enum":["data","boris","record"]},"verifier":{"type":"string","enum":["heuristic","none","decision"]}},"required":["template_id","data"]}
    ,
    .run = run,
};

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const template_id = try common.requireStr(ctx, args, "template_id");
    const kind = if (common.getStr(args, "backend")) |b|
        backend.parseKind(b) orelse return ctx.fail("unknown backend '{s}'", .{b})
    else
        ctx.backend_kind;
    const evidence = common.getStr(args, "evidence") orelse "data";
    const evidence_kind: ratchet.Evidence = if (std.mem.eql(u8, evidence, "data"))
        .data
    else if (std.mem.eql(u8, evidence, "boris"))
        .boris
    else if (std.mem.eql(u8, evidence, "record"))
        .record
    else
        return ctx.fail("evidence '{s}' must be \"data\", \"boris\" or \"record\"", .{evidence});
    const a = args orelse return ctx.fail("missing arguments", .{});
    const data = switch (a.get("data") orelse return ctx.fail("missing required argument 'data'", .{})) {
        .object => |o| o,
        else => return ctx.fail("data must be a JSON object", .{}),
    };

    var opts: ratchet.Options = .{ .tone = common.getStr(args, "tone"), .evidence = evidence_kind };
    if (common.getStr(args, "verifier")) |v| opts.verifier = verifier.parseKind(v) orelse
        return ctx.fail("verifier must be heuristic|none|decision", .{});
    if (a.get("max_iterations")) |v| opts.max_iterations = switch (v) {
        .integer => |i| if (i >= 0 and i <= 20) @intCast(i) else return ctx.fail("max_iterations must be 0-20", .{}),
        else => return ctx.fail("max_iterations must be an integer", .{}),
    };
    if (common.getStr(args, "max-iters")) |s| opts.max_iterations = std.fmt.parseInt(u8, s, 10) catch
        return ctx.fail("--max-iters must be a number 0-20", .{});
    if (opts.max_iterations > 20) return ctx.fail("max_iterations must be 0-20", .{});
    if (a.get("epsilon")) |v| opts.epsilon = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return ctx.fail("epsilon must be a number", .{}),
    };
    if (!(opts.epsilon > 0)) return ctx.fail("epsilon must be positive", .{});

    const tpl = try common.templatePath(ctx, template_id);
    const shape = try ratchet.loadShape(ctx, try std.fmt.allocPrint(ctx.arena, "{s}/shapes/{s}.json", .{ ctx.templates_dir, template_id }));
    if (kind == .mock) opts.mock = try ratchet.loadMock(ctx, try ratchet.mockPath(ctx), template_id);

    switch (try ratchet.run(ctx, kind, tpl, shape, data, opts)) {
        .start_failed => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try common.writeDiags(out, diags);
            try out.writer.writeAll(",\"hint\":\"data error; the ratchet needs a valid starting render\"}");
        },
        .done => |r| {
            const data_json = try std.json.Stringify.valueAlloc(ctx.arena, std.json.Value{ .object = r.data }, .{});
            const data_id = store.put(ctx, "json", data_json) catch return ctx.fail("artifact store write failed", .{});
            const doc_id = store.put(ctx, "md", r.doc) catch return ctx.fail("artifact store write failed", .{});
            try ratchet.writeResult(r, data_id, doc_id, &out.writer);
        },
    }
}
