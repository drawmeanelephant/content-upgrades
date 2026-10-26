//! Tool surface. Handlers write a JSON result object into `out`; both the
//! MCP `tools/call` path and the CLI subcommands go through `dispatch`.
//! The server is a dispatcher only — no engine logic lives here.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const repair = @import("repair.zig");
const store = @import("store.zig");
const formatcheck = @import("formatcheck.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

const Handler = *const fn (ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    run: Handler,
};

pub const all = [_]Tool{
    .{
        .name = "knap_templates",
        .description = "List shipped templates with their JSON shape descriptors.",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
        .run = templatesList,
    },
    .{
        .name = "knap_validate",
        .description = "Dry render: template + data through the engine, diagnostics or ok. No model call.",
        .input_schema =
        \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"}},"required":["template_id","data"]}
        ,
        .run = validate,
    },
    .{
        .name = "knap_render",
        .description = "Render to markdown|gfm|textile via k4o, or html via dogbed. Returns a doc_id handle.",
        .input_schema =
        \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"target":{"type":"string","enum":["markdown","gfm","textile","html"]}},"required":["template_id","data","target"]}
        ,
        .run = render,
    },
    .{
        .name = "knap_repair",
        .description = "Bounded repair loop over shipped templates: render -> diag -> region patch -> re-render, max 4.",
        .input_schema =
        \\{"type":"object","properties":{"template_id":{"type":"string"},"data":{"type":"object"},"backend":{"type":"string","enum":["mock","spark","wonder","baseten"]},"target":{"type":"string","enum":["markdown","gfm","textile","html"]}},"required":["template_id","data"]}
        ,
        .run = repairTool,
    },
    .{
        .name = "knap_lint",
        .description = "k4o education-grade lint on a shipped template (template_id) or raw template_text.",
        .input_schema =
        \\{"type":"object","properties":{"template_id":{"type":"string"},"template_text":{"type":"string"}}}
        ,
        .run = lint,
    },
    .{
        .name = "knap_format_check",
        .description = "Advisory structure lint over a rendered doc (doc_id handle): headings, footnotes, callouts, raw URLs, fences. Warnings only, never blocks.",
        .input_schema =
        \\{"type":"object","properties":{"doc_id":{"type":"string"}},"required":["doc_id"]}
        ,
        .run = formatCheck,
    },
};

/// tools/call dispatcher. Result JSON lands in `out`.
pub fn dispatch(ctx: *Ctx, name: []const u8, args: ?ObjectMap, out: *Allocating) Error!void {
    for (&all) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t.run(ctx, args, out);
    }
    return ctx.fail("unknown tool '{s}'", .{name});
}

/// tools/list payload: {"tools":[...]}.
pub fn listJson(w: *Allocating) !void {
    try w.writer.writeAll("{\"tools\":[");
    for (&all, 0..) |*t, i| {
        if (i > 0) try w.writer.writeAll(",");
        try w.writer.print("{{\"name\":", .{});
        try std.json.Stringify.value(t.name, .{}, &w.writer);
        try w.writer.print(",\"description\":", .{});
        try std.json.Stringify.value(t.description, .{}, &w.writer);
        try w.writer.print(",\"inputSchema\":{s}}}", .{t.input_schema});
    }
    try w.writer.writeAll("]}");
}

// --- helpers ---------------------------------------------------------------

fn getStr(args: ?ObjectMap, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    return switch (a.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn requireStr(ctx: *Ctx, args: ?ObjectMap, key: []const u8) Error![]const u8 {
    return getStr(args, key) orelse ctx.fail("missing required argument '{s}'", .{key});
}

fn requireData(ctx: *Ctx, args: ?ObjectMap) Error![]const u8 {
    const a = args orelse return ctx.fail("missing arguments", .{});
    const v = a.get("data") orelse return ctx.fail("missing required argument 'data'", .{});
    return std.json.Stringify.valueAlloc(ctx.arena, v, .{}) catch return error.OutOfMemory;
}

/// Shipped template path from its id (template_id never crosses the
/// server boundary as text — callers can only name shipped templates).
pub fn templatePath(ctx: *Ctx, template_id: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, template_id, "/\\") != null or
        std.mem.indexOf(u8, template_id, "..") != null)
        return ctx.fail("invalid template_id '{s}'", .{template_id});
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.knap", .{ ctx.templates_dir, template_id });
    std.Io.Dir.access(.cwd(), ctx.io, path, .{}) catch
        return ctx.fail("unknown template '{s}'", .{template_id});
    return path;
}

pub fn templateText(ctx: *Ctx, template_id: []const u8) Error![]const u8 {
    const path = try templatePath(ctx, template_id);
    return std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(4 * 1024 * 1024)) catch
        return ctx.fail("cannot read template '{s}'", .{template_id});
}

/// Write `data` JSON to a scratch file; engines take --data <file>.
fn stageData(ctx: *Ctx, data_json: []const u8) Error![]const u8 {
    const path = try store.scratchFile(ctx, "json");
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = data_json }) catch
        return ctx.fail("cannot stage data file", .{});
    return path;
}

fn writeDiags(out: *Allocating, diags: []engine.Diag) !void {
    try out.writer.writeAll("\"diagnostics\":[");
    for (diags, 0..) |d, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"kind\":", .{});
        try std.json.Stringify.value(d.kind, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"column\":{d},\"detail\":", .{ d.line, d.col });
        try std.json.Stringify.value(d.detail, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");
}

// --- handlers ----------------------------------------------------------------

fn templatesList(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    _ = args;
    try out.writer.writeAll("{\"templates\":[");
    var d = std.Io.Dir.openDir(.cwd(), ctx.io, ctx.templates_dir, .{ .iterate = true }) catch
        return ctx.fail("templates dir '{s}' not readable", .{ctx.templates_dir});
    defer d.close(ctx.io);
    var it = d.iterate();
    var i: usize = 0;
    while (it.next(ctx.io) catch return ctx.fail("templates dir iterate failed", .{})) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".knap")) continue;
        // entry.name aliases the iterator's buffer — dupe before use.
        const name = try ctx.arena.dupe(u8, entry.name);
        const id = name[0 .. name.len - ".knap".len];
        if (i > 0) try out.writer.writeAll(",");
        i += 1;
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, &out.writer);
        // Per-template shape doc, fetched on demand per SPEC (slim catalog,
        // shape on request — here we inline it since it's small).
        const shape_path = try std.fmt.allocPrint(ctx.arena, "{s}/shapes/{s}.json", .{ ctx.templates_dir, id });
        if (std.Io.Dir.readFileAlloc(.cwd(), ctx.io, shape_path, ctx.arena, .limited(1 << 20)) catch null) |shape| {
            try out.writer.print(",\"shape\":{s}", .{shape});
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
}

fn validate(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    const template_id = try requireStr(ctx, args, "template_id");
    const data = try stageData(ctx, try requireData(ctx, args));
    const tpl = try templatePath(ctx, template_id);

    switch (try engine.render(ctx, .markdown, tpl, data)) {
        .ok => try out.writer.writeAll("{\"ok\":true,\"diagnostics\":[]}"),
        .diags => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}

fn render(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    const template_id = try requireStr(ctx, args, "template_id");
    const target = engine.targetFromName(getStr(args, "target") orelse "markdown") orelse
        return ctx.fail("target must be markdown|gfm|textile|html", .{});
    const data = try stageData(ctx, try requireData(ctx, args));
    const tpl = try templatePath(ctx, template_id);

    switch (try engine.render(ctx, target, tpl, data)) {
        .ok => |doc| {
            const ext: []const u8 = switch (target) {
                .html => "html",
                .textile => "textile",
                else => "md",
            };
            const doc_id = store.put(ctx, ext, doc) catch
                return ctx.fail("artifact store write failed", .{});
            try out.writer.print("{{\"ok\":true,\"doc_id\":\"{s}\",\"target\":\"{s}\",\"bytes\":{d}}}", .{
                doc_id, @tagName(target), doc.len,
            });
        },
        .diags => |diags| {
            try out.writer.writeAll("{\"ok\":false,");
            try writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}

fn repairTool(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    const template_id = try requireStr(ctx, args, "template_id");
    const kind = backend.parseKind(getStr(args, "backend") orelse "") orelse ctx.backend_kind;
    const target = engine.targetFromName(getStr(args, "target") orelse "markdown") orelse
        return ctx.fail("target must be markdown|gfm|textile|html", .{});
    const data = try stageData(ctx, try requireData(ctx, args));
    const text = try templateText(ctx, template_id);

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
    try writeDiags(out, outcome.diags);
    try out.writer.writeAll("}");
}

fn formatCheck(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    const doc_id = try requireStr(ctx, args, "doc_id");
    const doc = (store.read(ctx, doc_id) catch null) orelse
        return ctx.fail("no such doc '{s}'", .{doc_id});
    const warnings = try formatcheck.check(ctx.arena, doc);
    try out.writer.writeAll("{\"ok\":true,\"warnings\":[");
    for (warnings, 0..) |w, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"rule\":");
        try std.json.Stringify.value(w.rule, .{}, &out.writer);
        try out.writer.print(",\"line\":{d},\"detail\":", .{w.line});
        try std.json.Stringify.value(w.detail, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
}

fn lint(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) Error!void {
    var tpl: []const u8 = undefined;
    if (getStr(args, "template_id")) |id| {
        tpl = try templatePath(ctx, id);
    } else if (getStr(args, "template_text")) |text| {
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
            try writeDiags(out, diags);
            try out.writer.writeAll("}");
        },
    }
}
