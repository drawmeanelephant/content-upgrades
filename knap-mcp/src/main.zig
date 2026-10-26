//! knap-mcp — the dispatcher binary.
//!
//!     knap-mcp                              MCP stdio JSON-RPC server (default)
//!     knap-mcp serve                        same thing, spelled out
//!     knap-mcp templates                    list shipped templates + shapes
//!     knap-mcp validate <id> [-d <file|->]  dry render, diagnostics or ok
//!     knap-mcp render <id> [-d <file|->] [--target <t>] [--out <file>]
//!     knap-mcp repair <id> [-d <file|->] [--backend <b>]
//!     knap-mcp lint <file.knap>             k4o lint passthrough
//!     knap-mcp format-check <doc_id>        advisory structure lint on a doc
//!     knap-mcp eval [--corpus <seeds.json>] [--backend <b>]
//!     knap-mcp backends                     backend availability
//!     knap-mcp --help | --version
//!
//! Exit codes: 0 = success, 1 = any error. Diagnostics and usage go to
//! stderr; documents and JSON results go to stdout.

const std = @import("std");
const build_options = @import("build_options");
const ctx_mod = @import("ctx.zig");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const backend = @import("backend.zig");
const eval_mod = @import("eval.zig");
const store = @import("store.zig");

const Ctx = ctx_mod.Ctx;

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\knap-mcp — AI can't do layout. So we don't let it.
    \\
    \\Usage:
    \\  knap-mcp                              MCP stdio JSON-RPC server
    \\  knap-mcp serve                        same thing, spelled out
    \\  knap-mcp templates                    list shipped templates + shapes
    \\  knap-mcp validate <id> [-d <file|->]  dry render, diagnostics or ok
    \\  knap-mcp render <id> [options]        render via k4o/dogbed, print doc
    \\  knap-mcp repair <id> [options]        bounded repair loop (max 4)
    \\  knap-mcp lint <file.knap>             k4o lint passthrough
    \\  knap-mcp format-check <doc_id>        advisory structure lint (warnings only)
    \\  knap-mcp eval [--corpus f] [--backend k]  seeded-breakage convergence
    \\  knap-mcp backends                     backend availability
    \\  knap-mcp --help | --version
    \\
    \\Options:
    \\  -d, --data <file|->     JSON data file; - reads stdin (default {})
    \\  --target <t>            markdown (default) | gfm | textile | html
    \\  --backend <b>           mock (default) | spark | wonder | baseten
    \\  --corpus <file>         seeded-breakage corpus (default eval/seeds.json)
    \\  --out <file>            write rendered doc to file instead of stdout
    \\
    \\Environment:
    \\  KNAP_K4O_PATH / KNAP_DOGBED_PATH   engine binaries (default: PATH)
    \\  KNAP_TEMPLATES_DIR                 shipped template dir (default ./templates)
    \\  KNAP_MCP_HOME                      artifact store dir (default .knap-mcp)
    \\  KNAP_BACKEND                       default backend kind
    \\  MODEL_API_KEY                      enables spark/wonder/baseten
    \\  KNAP_BASETEN_URL                   baseten endpoint override
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args: std.ArrayList([]const u8) = .empty;
    const alloc = init.arena.allocator();
    var it = try init.minimal.args.iterateAllocator(alloc);
    defer it.deinit();
    _ = it.next(); // program name
    while (it.next()) |arg| try args.append(alloc, arg);

    var ctx = ctx_mod.Ctx.init(init) catch |e| {
        report("init failed: {s}", .{@errorName(e)});
        return 1;
    };

    const argv = args.items;
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "serve"))
        return mcp.serve(init, &ctx);

    const cmd = argv[0];
    const rest = argv[1..];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printStdout(init, usage_text);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        var buf: [64]u8 = undefined;
        try printStdout(init, try std.fmt.bufPrint(&buf, "knap-mcp {s}\n", .{build_options.version}));
        return 0;
    }
    if (std.mem.eql(u8, cmd, "templates")) return cliTool(&ctx, "knap_templates", rest);
    if (std.mem.eql(u8, cmd, "validate")) return cliTool(&ctx, "knap_validate", rest);
    if (std.mem.eql(u8, cmd, "render")) return cliTool(&ctx, "knap_render", rest);
    if (std.mem.eql(u8, cmd, "repair")) return cliTool(&ctx, "knap_repair", rest);
    if (std.mem.eql(u8, cmd, "lint")) return cmdLint(&ctx, rest);
    if (std.mem.eql(u8, cmd, "format-check")) return cmdFormatCheck(&ctx, rest);
    if (std.mem.eql(u8, cmd, "eval")) return cmdEval(&ctx, rest);
    if (std.mem.eql(u8, cmd, "backends")) return cmdBackends(&ctx);
    return usage(&ctx, "unknown command");
}

// --- CLI plumbing ------------------------------------------------------------

const Opts = struct {
    data: ?std.json.Value = null,
    target: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    corpus: []const u8 = "eval/seeds.json",
    out: ?[]const u8 = null,
    positional: std.ArrayList([]const u8) = .empty,
};

fn parseOpts(ctx: *Ctx, args: [][]const u8) !Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--data")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --data", .{});
            o.data = try readData(ctx, args[i]);
        } else if (std.mem.startsWith(u8, a, "--data=") or std.mem.startsWith(u8, a, "-d=")) {
            o.data = try readData(ctx, a[std.mem.indexOfScalar(u8, a, '=').? + 1 ..]);
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --target", .{});
            o.target = args[i];
        } else if (std.mem.startsWith(u8, a, "--target=")) {
            o.target = a["--target=".len..];
        } else if (std.mem.eql(u8, a, "--backend")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --backend", .{});
            o.backend = args[i];
        } else if (std.mem.startsWith(u8, a, "--backend=")) {
            o.backend = a["--backend=".len..];
        } else if (std.mem.eql(u8, a, "--corpus")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --corpus", .{});
            o.corpus = args[i];
        } else if (std.mem.startsWith(u8, a, "--corpus=")) {
            o.corpus = a["--corpus=".len..];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --out", .{});
            o.out = args[i];
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            o.out = a["--out=".len..];
        } else if (a.len > 1 and a[0] == '-') {
            return ctx.fail("unknown option '{s}'", .{a});
        } else {
            try o.positional.append(ctx.arena, a);
        }
    }
    return o;
}

/// `-` reads all of stdin; anything else is a file path of JSON.
fn readData(ctx: *Ctx, path: []const u8) !std.json.Value {
    const bytes = if (std.mem.eql(u8, path, "-")) blk: {
        var buf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(ctx.io, &buf);
        var aw: std.Io.Writer.Allocating = .init(ctx.arena);
        _ = r.interface.streamRemaining(&aw.writer) catch
            return ctx.fail("cannot read stdin", .{});
        break :blk aw.written();
    } else std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(max_input)) catch
        return ctx.fail("cannot read data file '{s}'", .{path});

    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, bytes, .{}) catch
        return ctx.fail("'{s}' is not valid JSON", .{path});
    switch (v) {
        .object => return v,
        else => return ctx.fail("data must be a JSON object", .{}),
    }
}

/// Build the synthesized arguments object a tool handler expects and run
/// it through the same dispatcher MCP uses — one code path, two surfaces.
fn cliTool(ctx: *Ctx, comptime name: []const u8, args: [][]const u8) !u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    if (o.positional.items.len == 0 and !std.mem.eql(u8, name, "knap_templates"))
        return usageWith(ctx, "missing template_id");

    var a: std.json.ObjectMap = .empty;
    if (o.positional.items.len > 0)
        try a.put(ctx.arena, "template_id", .{ .string = o.positional.items[0] });
    try a.put(ctx.arena, "data", o.data orelse .{ .object = .empty });
    if (o.target) |t| try a.put(ctx.arena, "target", .{ .string = t });
    if (o.backend) |b| try a.put(ctx.arena, "backend", .{ .string = b });

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    tools.dispatch(ctx, name, a, &out) catch {
        report("{s}", .{if (ctx.err_msg.len > 0) ctx.err_msg else "tool failed"});
        return 1;
    };

    // render --out <file>: the JSON result carries the doc_id; the file
    // form is for vhs/CLI demos — copy the artifact bytes back out.
    if (o.out) |path| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, out.written(), .{}) catch null;
        if (parsed) |v| {
            if (v == .object) {
                if (v.object.get("doc_id")) |id_v| {
                    if (id_v == .string) {
                        if (store.read(ctx, id_v.string) catch null) |bytes| {
                            std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = bytes }) catch
                                return fail(ctx, "cannot write --out file");
                        }
                    }
                }
            }
        }
    }

    var obuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &obuf);
    w.interface.writeAll(out.written()) catch return 1;
    w.interface.writeAll("\n") catch return 1;
    w.flush() catch return 1;
    return 0;
}

/// `lint <file.knap>` takes a path, not a template_id — passthrough.
fn cmdLint(ctx: *Ctx, args: [][]const u8) !u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    if (o.positional.items.len != 1) return usageWith(ctx, "lint needs exactly one template file");
    var a: std.json.ObjectMap = .empty;
    const text = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, o.positional.items[0], ctx.arena, .limited(max_input)) catch
        return fail(ctx, "cannot read file");
    try a.put(ctx.arena, "template_text", .{ .string = text });
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    tools.dispatch(ctx, "knap_lint", a, &out) catch return usageErr(ctx);
    var obuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &obuf);
    w.interface.writeAll(out.written()) catch return 1;
    w.interface.writeAll("\n") catch return 1;
    w.flush() catch return 1;
    return 0;
}

/// `format-check <doc_id>` takes an artifact handle, not a template_id.
fn cmdFormatCheck(ctx: *Ctx, args: [][]const u8) !u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    if (o.positional.items.len != 1) return usageWith(ctx, "format-check needs exactly one doc_id");
    var a: std.json.ObjectMap = .empty;
    try a.put(ctx.arena, "doc_id", .{ .string = o.positional.items[0] });
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    tools.dispatch(ctx, "knap_format_check", a, &out) catch return usageErr(ctx);
    var obuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &obuf);
    w.interface.writeAll(out.written()) catch return 1;
    w.interface.writeAll("\n") catch return 1;
    w.flush() catch return 1;
    return 0;
}

fn cmdEval(ctx: *Ctx, args: [][]const u8) !u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    const kind = if (o.backend) |b|
        backend.parseKind(b) orelse return fail(ctx, "unknown backend")
    else
        ctx.backend_kind;
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    const code = eval_mod.run(ctx, o.corpus, kind, &w.interface) catch {
        w.flush() catch {};
        return fail(ctx, if (ctx.err_msg.len > 0) ctx.err_msg else "eval failed");
    };
    w.flush() catch return 1;
    return code;
}

fn cmdBackends(ctx: *Ctx) !u8 {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &buf);
    const has_key = ctx.environ.get("MODEL_API_KEY") != null;
    try w.interface.writeAll("backend    status\n");
    try w.interface.writeAll("mock       always available (canned patches)\n");
    inline for ([_]backend.Kind{ .spark, .wonder, .baseten }) |k| {
        try w.interface.print("{s: <10} {s}\n", .{
            @tagName(k),
            if (has_key) "MODEL_API_KEY set — live calls enabled" else "needs MODEL_API_KEY",
        });
    }
    try w.interface.print("default    {s} (KNAP_BACKEND)\n", .{@tagName(ctx.backend_kind)});
    try w.flush();
    return 0;
}

fn fail(ctx: *Ctx, msg: []const u8) u8 {
    report("{s}", .{msg});
    _ = ctx;
    return 1;
}

fn usageErr(ctx: *Ctx) u8 {
    report("{s}", .{ctx.err_msg});
    report("usage: knap-mcp <command> [options]  (see --help)", .{});
    return 1;
}

fn usageWith(ctx: *Ctx, msg: []const u8) u8 {
    ctx.err_msg = msg;
    return usageErr(ctx);
}

fn usage(ctx: *Ctx, msg: []const u8) u8 {
    _ = ctx;
    report("{s}", .{msg});
    report("usage: knap-mcp <command> [options]  (see --help)", .{});
    return 1;
}

fn printStdout(init: std.process.Init, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll(text);
    try w.flush();
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("knap-mcp: " ++ fmt ++ "\n", args);
}
