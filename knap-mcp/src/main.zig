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
//! Subcommands are rows in `commands`: a registry tool (argv becomes its
//! arguments object) or a custom fn. Adding a subcommand is one row.
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

const Command = struct {
    name: []const u8,
    /// Syntax shown in --help after "knap-mcp "; null hides the row.
    usage: ?[]const u8 = null,
    summary: []const u8 = "",
    run: union(enum) {
        tool: ToolCommand,
        custom: *const fn (ctx: *Ctx, args: [][]const u8) anyerror!u8,
    },
};

/// A subcommand that runs a registry tool through the same dispatcher MCP
/// uses. The arguments object gets `data` (default {}), every `tool_flags`
/// option that was given, and the first positional under `key`.
const ToolCommand = struct {
    tool: []const u8,
    /// Arguments key the first positional fills; null takes none.
    key: ?[]const u8 = null,
    /// Set when the command takes exactly one positional: names it in the
    /// usage error ("<cmd> needs exactly one <what>"), and tool failures
    /// also print the usage line. Otherwise a non-null `key` needs at
    /// least one positional.
    exactly_one: ?[]const u8 = null,
    /// The positional is a file path; its contents fill `key`.
    read_file: bool = false,
};

const commands = [_]Command{
    .{ .name = "templates", .usage = "templates", .summary = "list shipped templates + shapes", .run = .{ .tool = .{ .tool = "knap_templates" } } },
    .{ .name = "validate", .usage = "validate <id> [-d <file|->]", .summary = "dry render, diagnostics or ok", .run = .{ .tool = .{ .tool = "knap_validate", .key = "template_id" } } },
    .{ .name = "render", .usage = "render <id> [options]", .summary = "render via k4o/dogbed, print doc", .run = .{ .tool = .{ .tool = "knap_render", .key = "template_id" } } },
    .{ .name = "repair", .usage = "repair <id> [options]", .summary = "bounded repair loop (max 4)", .run = .{ .tool = .{ .tool = "knap_repair", .key = "template_id" } } },
    .{ .name = "lint", .usage = "lint <file.knap>", .summary = "k4o lint passthrough", .run = .{ .tool = .{ .tool = "knap_lint", .key = "template_text", .exactly_one = "template file", .read_file = true } } },
    .{ .name = "format-check", .usage = "format-check <doc_id>", .summary = "advisory structure lint (warnings only)", .run = .{ .tool = .{ .tool = "knap_format_check", .key = "doc_id", .exactly_one = "doc_id" } } },
    .{ .name = "voice", .usage = "voice <id> --tone <t>", .summary = "rewrite voice: true values in a tone", .run = .{ .tool = .{ .tool = "knap_voice", .key = "template_id" } } },
    .{ .name = "structhash", .usage = "structhash <doc_id|file>...", .summary = "layout skeleton hash, text dropped", .run = .{ .custom = @import("tools/structure_hash.zig").cli } },
    .{ .name = "verify-citation", .usage = "verify-citation <claim>", .summary = "advisory claim vs --evidence check", .run = .{ .tool = .{ .tool = "knap_verify_citation", .key = "claim", .exactly_one = "claim" } } },
    .{ .name = "boris-ask", .usage = "boris-ask <query> [--limit n]", .summary = "ranked snippets from the boris artifact", .run = .{ .tool = .{ .tool = "boris_ask", .key = "query", .exactly_one = "query" } } },
    .{ .name = "boris-check", .usage = "boris-check <claim>", .summary = "yes/no/unknown from boris claim pages", .run = .{ .tool = .{ .tool = "boris_check", .key = "claim", .exactly_one = "claim" } } },
    .{ .name = "eval", .usage = "eval [--corpus f] [--backend k]", .summary = "seeded-breakage convergence", .run = .{ .custom = cmdEval } },
    .{ .name = "backends", .usage = "backends", .summary = "backend availability", .run = .{ .custom = cmdBackends } },
    .{ .name = "--help", .usage = "--help | --version", .run = .{ .custom = cmdHelp } },
    .{ .name = "-h", .run = .{ .custom = cmdHelp } },
    .{ .name = "--version", .run = .{ .custom = cmdVersion } },
    .{ .name = "-v", .run = .{ .custom = cmdVersion } },
};

/// `--<name> <v>` / `--<name>=<v>` options passed to tools as same-named
/// string arguments.
const tool_flags = [_][]const u8{ "target", "backend", "tone", "evidence", "verifier", "limit" };

const usage_head =
    \\knap-mcp — AI can't do layout. So we don't let it.
    \\
    \\Usage:
    \\
;

const usage_tail =
    \\
    \\Options:
    \\  -d, --data <file|->     JSON data file; - reads stdin (default {})
    \\  --target <t>            markdown (default) | oliver | html
    \\  --backend <b>           mock (default) | spark | wonder | baseten
    \\  --tone <t>              voice tone: mild | spicy | feral
    \\  --corpus <file>         seeded-breakage corpus (default eval/seeds.json)
    \\  --out <file>            write rendered doc to file instead of stdout
    \\  --explain, --strict     structhash: print tokens; keep link targets
    \\  --evidence <text>       evidence quote for verify-citation
    \\  --verifier <v>          heuristic (default) | none | decision
    \\  --limit <n>             boris-ask hits (default 5)
    \\
    \\Environment:
    \\  KNAP_K4O_PATH / KNAP_DOGBED_PATH   engine binaries (default: PATH)
    \\  KNAP_TEMPLATES_DIR                 shipped template dir (default ./templates)
    \\  KNAP_MCP_HOME                      artifact store dir (default .knap-mcp)
    \\  KNAP_BACKEND                       default backend kind
    \\  MODEL_API_KEY                      enables spark/wonder/baseten
    \\  KNAP_BASETEN_URL                   baseten endpoint override
    \\  KNAP_BORIS_SITE                    boris site dir (default <templates>/../../boris-site)
    \\
;

const usage_text = blk: {
    var s: []const u8 = usage_head ++
        usageLine("", "MCP stdio JSON-RPC server") ++
        usageLine("serve", "same thing, spelled out");
    for (commands) |c| {
        if (c.usage) |u| s = s ++ usageLine(u, c.summary);
    }
    break :blk s ++ usage_tail;
};

fn usageLine(comptime syntax: []const u8, comptime summary: []const u8) []const u8 {
    const width = 27;
    if (summary.len == 0) return "  knap-mcp " ++ syntax ++ "\n";
    const pad: [width -| syntax.len]u8 = @splat(' ');
    return "  knap-mcp " ++ syntax ++ pad ++ "  " ++ summary ++ "\n";
}

pub fn main(init: std.process.Init) !u8 {
    comptime checkTables();
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

    for (&commands) |*c| {
        if (!std.mem.eql(u8, c.name, argv[0])) continue;
        return switch (c.run) {
            .tool => |t| runTool(&ctx, c.name, t, argv[1..]),
            .custom => |f| f(&ctx, argv[1..]),
        };
    }
    return usage(&ctx, "unknown command");
}

/// Build-time guard for the shared one-line tables: tool and command names
/// are unique, and every tool row names a registered tool.
fn checkTables() void {
    @setEvalBranchQuota(100_000);
    for (tools.all, 0..) |a, i| {
        for (tools.all[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) @compileError("duplicate tool '" ++ a.name ++ "'");
        }
    }
    for (commands, 0..) |c, i| {
        for (commands[i + 1 ..]) |other| {
            if (std.mem.eql(u8, c.name, other.name)) @compileError("duplicate command '" ++ c.name ++ "'");
        }
        switch (c.run) {
            .tool => |t| for (tools.all) |reg| {
                if (std.mem.eql(u8, reg.name, t.tool)) break;
            } else @compileError("command '" ++ c.name ++ "' names unregistered tool '" ++ t.tool ++ "'"),
            .custom => {},
        }
    }
}

// --- CLI plumbing ------------------------------------------------------------

const Opts = struct {
    data: ?std.json.Value = null,
    /// Values of `tool_flags`, by index.
    flags: [tool_flags.len]?[]const u8 = @splat(null),
    corpus: []const u8 = "eval/seeds.json",
    out: ?[]const u8 = null,
    positional: std.ArrayList([]const u8) = .empty,

    fn flag(o: *const Opts, name: []const u8) ?[]const u8 {
        for (tool_flags, o.flags) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }
};

fn parseOpts(ctx: *Ctx, args: [][]const u8) !Opts {
    var o: Opts = .{};
    var i: usize = 0;
    next: while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--data")) {
            i += 1;
            if (i >= args.len) return ctx.fail("missing value for --data", .{});
            o.data = try readData(ctx, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--data=") or std.mem.startsWith(u8, a, "-d=")) {
            o.data = try readData(ctx, a[std.mem.indexOfScalar(u8, a, '=').? + 1 ..]);
            continue;
        }
        inline for (tool_flags, 0..) |name, f| {
            if (try optValue(ctx, args, &i, "--" ++ name)) |v| {
                o.flags[f] = v;
                continue :next;
            }
        }
        if (try optValue(ctx, args, &i, "--corpus")) |v| {
            o.corpus = v;
        } else if (try optValue(ctx, args, &i, "--out")) |v| {
            o.out = v;
        } else if (a.len > 1 and a[0] == '-') {
            return ctx.fail("unknown option '{s}'", .{a});
        } else {
            try o.positional.append(ctx.arena, a);
        }
    }
    return o;
}

/// Value of `--opt <v>` (consumes the next arg) or `--opt=<v>`; null when
/// args[i] is a different option.
fn optValue(ctx: *Ctx, args: [][]const u8, i: *usize, comptime opt: []const u8) !?[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, opt)) {
        i.* += 1;
        if (i.* >= args.len) return ctx.fail("missing value for " ++ opt, .{});
        return args[i.*];
    }
    if (std.mem.startsWith(u8, a, opt ++ "=")) return a[opt.len + 1 ..];
    return null;
}

/// `-` reads all of stdin; anything else is a file path of JSON.
fn readData(ctx: *Ctx, path: []const u8) !std.json.Value {
    const bytes = if (std.mem.eql(u8, path, "-")) blk: {
        var buf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().readerStreaming(ctx.io, &buf);
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
fn runTool(ctx: *Ctx, cmd: []const u8, t: ToolCommand, args: [][]const u8) !u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    const pos = o.positional.items;
    if (t.exactly_one) |what| {
        if (pos.len != 1)
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "{s} needs exactly one {s}", .{ cmd, what }));
    } else if (t.key) |key| {
        if (pos.len == 0)
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "missing {s}", .{key}));
    }

    var a: std.json.ObjectMap = .empty;
    if (t.key) |key| {
        const value = if (t.read_file)
            std.Io.Dir.readFileAlloc(.cwd(), ctx.io, pos[0], ctx.arena, .limited(max_input)) catch
                return fail(ctx, "cannot read file")
        else
            pos[0];
        try a.put(ctx.arena, key, .{ .string = value });
    }
    try a.put(ctx.arena, "data", o.data orelse .{ .object = .empty });
    for (tool_flags, o.flags) |name, v| {
        if (v) |s| try a.put(ctx.arena, name, .{ .string = s });
    }

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    tools.dispatch(ctx, t.tool, a, &out) catch {
        if (t.exactly_one != null) return usageErr(ctx);
        report("{s}", .{if (ctx.err_msg.len > 0) ctx.err_msg else "tool failed"});
        return 1;
    };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, out.written(), .{}) catch null;
    const result: ?std.json.ObjectMap = if (parsed) |v| (if (v == .object) v.object else null) else null;

    // render --out <file>: the JSON result carries the doc_id; the file
    // form is for vhs/CLI demos — copy the artifact bytes back out.
    if (o.out) |path| {
        if (result) |r| {
            if (r.get("doc_id")) |id_v| {
                if (id_v == .string) {
                    if (store.read(ctx, id_v.string) catch null) |bytes| {
                        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = bytes }) catch
                            return fail(ctx, "cannot write --out file");
                    }
                }
            }
        }
    }

    var obuf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &obuf);
    w.interface.writeAll(out.written()) catch return 1;
    w.interface.writeAll("\n") catch return 1;
    w.flush() catch return 1;
    // `{"ok":false,...}` (a render or validate with diagnostics) is an
    // error: the JSON still goes to stdout, the exit code says so.
    const ok = if (result) |r| r.get("ok") else null;
    return if (ok != null and ok.? == .bool and !ok.?.bool) 1 else 0;
}

fn cmdEval(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    const o = parseOpts(ctx, args) catch return usageErr(ctx);
    const kind = if (o.flag("backend")) |b|
        backend.parseKind(b) orelse return fail(ctx, "unknown backend")
    else
        ctx.backend_kind;
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    const code = eval_mod.run(ctx, o.corpus, kind, &w.interface) catch {
        w.flush() catch {};
        return fail(ctx, if (ctx.err_msg.len > 0) ctx.err_msg else "eval failed");
    };
    w.flush() catch return 1;
    return code;
}

fn cmdBackends(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    _ = args;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
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

fn cmdHelp(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    _ = args;
    try printStdout(ctx, usage_text);
    return 0;
}

fn cmdVersion(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    _ = args;
    var buf: [64]u8 = undefined;
    try printStdout(ctx, try std.fmt.bufPrint(&buf, "knap-mcp {s}\n", .{build_options.version}));
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

fn printStdout(ctx: *Ctx, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    try w.interface.writeAll(text);
    try w.flush();
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("knap-mcp: " ++ fmt ++ "\n", args);
}

// Test discovery: `zig build test` only runs tests in files listed here,
// one line per file under src/.
test {
    _ = @import("backend.zig");
    _ = @import("borisrag.zig");
    _ = @import("ctx.zig");
    _ = @import("density.zig");
    _ = @import("engine.zig");
    _ = @import("eval.zig");
    _ = @import("formatcheck.zig");
    _ = @import("mcp.zig");
    _ = @import("repair.zig");
    _ = @import("store.zig");
    _ = @import("structhash.zig");
    _ = @import("tools.zig");
    _ = @import("tools/boris_ask.zig");
    _ = @import("tools/boris_check.zig");
    _ = @import("tools/common.zig");
    _ = @import("tools/format_check.zig");
    _ = @import("tools/lint.zig");
    _ = @import("tools/render.zig");
    _ = @import("tools/repair.zig");
    _ = @import("tools/structure_hash.zig");
    _ = @import("tools/templates.zig");
    _ = @import("tools/validate.zig");
    _ = @import("tools/verify_citation.zig");
    _ = @import("tools/voice.zig");
    _ = @import("verifier.zig");
    _ = @import("voice.zig");
}
