//! knap-mcp — the dispatcher binary.
//!
//!     knap-mcp                              MCP stdio JSON-RPC server (default)
//!     knap-mcp serve                        same thing, spelled out
//!     knap-mcp templates                    list shipped templates + shapes
//!     knap-mcp validate <id> [-d <file|->]  dry render, diagnostics or ok
//!     knap-mcp render <id> [-d <file|->] [--target <t>] [--out <file>]
//!     knap-mcp repair <id> [-d <file|->] [--backend <b>]
//!     knap-mcp lint <file.knap>             k4o lint passthrough
//!     knap-mcp ingest <file>... [--force]   copy markdown docs into the store
//!     knap-mcp format-check <doc_id|file>   advisory structure lint on a doc
//!     knap-mcp eval [--corpus <seeds.json>] [--backend <b>]
//!     knap-mcp backends [--probe]           backend availability + models
//!     knap-mcp smoke [--backend <b>]        one live call per backend.Task
//!     knap-mcp ask --system f --user f      one raw live completion, as JSON
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
const acp = @import("acp.zig");
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
    .{ .name = "serve", .usage = "serve", .summary = "same thing, spelled out", .run = .{ .custom = cmdServe } },
    .{ .name = "templates", .usage = "templates", .summary = "list shipped templates + shapes", .run = .{ .tool = .{ .tool = "knap_templates" } } },
    .{ .name = "validate", .usage = "validate <id> [-d <file|->]", .summary = "dry render, diagnostics or ok", .run = .{ .tool = .{ .tool = "knap_validate", .key = "template_id" } } },
    .{ .name = "render", .usage = "render <id> [options]", .summary = "render via k4o/dogbed, print doc", .run = .{ .tool = .{ .tool = "knap_render", .key = "template_id" } } },
    .{ .name = "repair", .usage = "repair <id> [options]", .summary = "bounded repair loop (max 4)", .run = .{ .tool = .{ .tool = "knap_repair", .key = "template_id" } } },
    .{ .name = "lint", .usage = "lint <file.knap>", .summary = "k4o lint passthrough", .run = .{ .tool = .{ .tool = "knap_lint", .key = "template_text", .exactly_one = "template file", .read_file = true } } },
    .{ .name = "ingest", .usage = "ingest <file>... [--force]", .summary = "copy existing markdown docs into the store", .run = .{ .custom = @import("tools/ingest.zig").cli } },
    .{ .name = "format-check", .usage = "format-check <doc_id|file>", .summary = "advisory structure lint (warnings only)", .run = .{ .custom = @import("tools/format_check.zig").cli } },
    .{ .name = "voice", .usage = "voice <id> --tone <t>", .summary = "rewrite voice: true values in a tone", .run = .{ .tool = .{ .tool = "knap_voice", .key = "template_id" } } },
    .{ .name = "doc-voice", .usage = "doc-voice <doc> --tone <t>", .summary = "guarded voice pass over a record (dry-run)", .run = .{ .custom = @import("tools/doc_voice.zig").cli } },
    .{ .name = "extract", .usage = "extract <doc_id|file> --template <id>", .summary = "filed record -> template data (+insert fragments)", .run = .{ .custom = @import("tools/extract.zig").cli } },
    .{ .name = "structhash", .usage = "structhash <doc_id|file>...", .summary = "layout skeleton hash, text dropped", .run = .{ .custom = @import("tools/structure_hash.zig").cli } },
    .{ .name = "verify-citation", .usage = "verify-citation <claim>", .summary = "advisory claim vs --evidence check", .run = .{ .tool = .{ .tool = "knap_verify_citation", .key = "claim", .exactly_one = "claim" } } },
    .{ .name = "boris-ask", .usage = "boris-ask <query> [--limit n]", .summary = "ranked snippets from the boris artifact", .run = .{ .tool = .{ .tool = "boris_ask", .key = "query", .exactly_one = "query" } } },
    .{ .name = "boris-check", .usage = "boris-check <claim>", .summary = "yes/no/unknown from boris claim pages", .run = .{ .tool = .{ .tool = "boris_check", .key = "claim", .exactly_one = "claim" } } },
    .{ .name = "publish-check", .usage = "publish-check <doc_id|file> [--as <path>]", .summary = "stage md doc in boris site; exit 1 unless ok", .run = .{ .custom = @import("tools/publish_check.zig").cli } },
    .{ .name = "density", .usage = "density <doc_id|file>", .summary = "formatting-density score (markdown)", .run = .{ .custom = @import("tools/density.zig").cmd } },
    .{ .name = "audit", .usage = "audit <dir> [options]", .summary = "corpus density audit over a tree (read-only)", .run = .{ .custom = @import("tools/audit.zig").cli } },
    .{ .name = "ratchet", .usage = "ratchet <id> [options]", .summary = "values-only density ratchet", .run = .{ .tool = .{ .tool = "knap_ratchet", .key = "template_id" } } },
    .{ .name = "ratchet-eval", .usage = "ratchet-eval [--corpus f]", .summary = "ratchet climb table (eval/ratchet.json)", .run = .{ .custom = @import("ratchet.zig").cmdEval } },
    .{ .name = "eval", .usage = "eval [--corpus f] [--backend k]", .summary = "seeded-breakage convergence", .run = .{ .custom = cmdEval } },
    .{ .name = "backends", .usage = "backends [--probe]", .summary = "backend availability + resolved models", .run = .{ .custom = cmdBackends } },
    .{ .name = "ask", .usage = "ask --system f --user f", .summary = "one raw live completion, as JSON", .run = .{ .custom = @import("ask.zig").cmd } },
    .{ .name = "smoke", .usage = "smoke [--backend k]", .summary = "one live call per task; exit 1 on a bad row", .run = .{ .custom = @import("smoke.zig").cmd } },
    .{ .name = "--help", .usage = "--help | --version", .run = .{ .custom = cmdHelp } },
    .{ .name = "-h", .run = .{ .custom = cmdHelp } },
    .{ .name = "--version", .run = .{ .custom = cmdVersion } },
    .{ .name = "-v", .run = .{ .custom = cmdVersion } },
};

/// `--<name> <v>` / `--<name>=<v>` options passed to tools as same-named
/// string arguments.
const tool_flags = [_][]const u8{ "target", "backend", "tone", "evidence", "verifier", "limit", "max-iters", "as" };

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
    \\  --backend <b>           mock (default) | spark | wonder | baseten | acp | compat
    \\  --tone <t>              voice tone: mild | spicy | feral
    \\  --corpus <file>         seeded-breakage corpus (default eval/seeds.json)
    \\  --out <file>            write rendered doc to file instead of stdout
    \\  --explain, --strict, --ignore-formatting  structhash: print tokens; keep link targets; drop inline formatting
    \\  --evidence <v>          verify-citation quote | ratchet source: data | boris
    \\  --verifier <v>          heuristic (default) | none | decision
    \\  --limit <n>             boris-ask hits (default 5)
    \\  --max-iters <n>         ratchet iteration cap (default 6)
    \\  --force                 ingest: admit non-markdown extensions
    \\  --glob <p>              audit file glob (default **/*.md)
    \\  --per-dir | --per-glob <name=glob,...>   audit rollup grouping
    \\  --below <s|band>        audit: list docs whose total is under s (a policy band.min wins)
    \\  --jsonl <file>          audit: per-doc rows to file (default stdout)
    \\  --policy <file> | --no-policy   audit: collection policy (default $KNAP_POLICY, else knap-policy.json in or above <dir>)
    \\  --as <path>             publish-check: staged source path (raw profile)
    \\  --dry-run | --apply --out <file>   doc-voice: dry-run (default) or write the patched doc to --out (never into content/)
    \\  --report <file>         doc-voice: report JSON to file; stdout then carries the patched doc
    \\  --replies <jsonl>       doc-voice: canned {"input","output"} replies, tried before the backend
    \\  --probe                 backends: GET /models per live backend, acp handshake
    \\  -h, --help              this text; <command> -h shows that command's usage
    \\
    \\Environment:
    \\  KNAP_K4O_PATH / KNAP_DOGBED_PATH   engine binaries (default: PATH)
    \\  KNAP_TEMPLATES_DIR                 shipped template dir (default <exe>/../../templates)
    \\  KNAP_MCP_HOME                      artifact store dir (default ./.knap-mcp in the server cwd)
    \\  KNAP_BACKEND                       default backend kind
    \\  MODEL_API_KEY                      enables spark/wonder/baseten
    \\  KNAP_<KIND>_URL                    chat endpoint (KIND = SPARK|WONDER|BASETEN|COMPAT)
    \\  KNAP_<KIND>_MODEL                  model id override per backend
    \\  KNAP_<KIND>_MODELS_URL             model-list URL (default: _URL-derived)
    \\  KNAP_<KIND>_TEMPERATURE            0..2 or 'omit'; else KNAP_TEMPERATURE, else 0
    \\  KNAP_COMPAT_URL / KNAP_COMPAT_MODEL  compat endpoint + model (both required)
    \\  KNAP_COMPAT_KEY                    compat bearer token (optional)
    \\  KNAP_TEMPERATURE                   shared temperature fallback
    \\  KNAP_ACP_AGENT                     backend acp: agent command (e.g. 'devin acp --agent-type summarizer')
    \\  KNAP_ACP_TIMEOUT / KNAP_ACP_INIT_TIMEOUT   acp call / spawn+init caps, seconds
    \\  KNAP_ACP_CWD                       acp session cwd (default: process cwd)
    \\  KNAP_BORIS_SITE                    boris site dir (default <templates>/../../boris-site)
    \\  KNAP_BORIS_ARTIFACT                artifact dir override for boris-ask/check (frozen pair or publish exports)
    \\  KNAP_BORIS_PATH                    boris binary for publish-check (default: PATH)
    \\  KNAP_BORIS_STAGING                 publish-check staging profile (frozen|raw); overrides <site>/knap-site.json
    \\  KNAP_BORIS_THEME                   publish-check theme root for boris validate (default: knap-site.json or themes/boris)
    \\  KNAP_ENGINE_TIMEOUT                engine subprocess cap, seconds (default 60, 0 off)
    \\  KNAP_CURL_TIMEOUT                  live-backend curl cap, seconds (default 60)
    \\  KNAP_CURL_CONNECT_TIMEOUT          live-backend connect cap, seconds (default 10)
    \\  KNAP_BORIS_TIMEOUT                 boris subprocess cap, seconds (default 60)
    \\  KNAP_STORE_MAX_ARTIFACTS           artifact retention cap (default 256, 0 unbounded)
    \\
;

const usage_text = blk: {
    var s: []const u8 = usage_head ++
        usageLine("", "MCP stdio JSON-RPC server");
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
    // A lazily spawned acp agent must not outlive this process: shutdown
    // closes its stdin, gives a short grace, then kills and reaps it.
    // Idempotent — serve() defers its own call too.
    defer acp.shutdown(init.io);

    const argv = args.items;
    if (argv.len == 0) return mcp.serve(&ctx);

    for (&commands) |*c| {
        if (!std.mem.eql(u8, c.name, argv[0])) continue;
        for (argv[1..]) |a| {
            if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help"))
                return cmdUsage(&ctx, c);
        }
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

/// Schema property name for a `tool_flags` entry: the arguments object
/// keeps the CLI spelling, schemas use snake_case (`--max-iters` fills
/// `max_iterations`; every other flag's name is already its property).
fn flagProp(flag: []const u8) []const u8 {
    return if (std.mem.eql(u8, flag, "max-iters")) "max_iterations" else flag;
}

/// True when a tool's input_schema declares `prop` in its properties.
fn schemaHasProp(schema: []const u8, prop: []const u8) bool {
    const needle_max = 64;
    var buf: [needle_max]u8 = undefined;
    // The needle is '"' + prop + '":{'. Callers only pass flagProp of a
    // tool_flags entry, so a flag name too long for buf fails the build.
    comptime {
        for (tool_flags) |flag| {
            if (flagProp(flag).len + 4 > needle_max)
                @compileError("tool_flags entry '" ++ flag ++ "' overflows schemaHasProp's buffer");
        }
    }
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":{{", .{prop}) catch return false;
    return std.mem.indexOf(u8, schema, needle) != null;
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

    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, bytes, .{
        .parse_numbers = false,
    }) catch
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
    // A shared flag the tool's schema doesn't declare is a user error, not
    // an argument the handler would silently drop.
    const schema = for (&tools.all) |*reg| {
        if (std.mem.eql(u8, reg.name, t.tool)) break reg.input_schema;
    } else "";
    for (o.flags, 0..) |v, i| {
        if (v != null and !schemaHasProp(schema, flagProp(tool_flags[i])))
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "{s}: unused option '--{s}'", .{ cmd, tool_flags[i] }));
    }
    const pos = o.positional.items;
    if (t.exactly_one) |what| {
        if (pos.len != 1)
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "{s} needs exactly one {s}", .{ cmd, what }));
    } else if (t.key) |key| {
        if (pos.len == 0)
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "missing {s}", .{key}));
        if (pos.len > 1)
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "{s}: unexpected argument '{s}'", .{ cmd, pos[1] }));
    } else if (pos.len != 0) {
        return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "{s}: unexpected argument '{s}'", .{ cmd, pos[0] }));
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
    if (o.positional.items.len != 0)
        return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "eval: unexpected argument '{s}'", .{o.positional.items[0]}));
    for (tool_flags, o.flags) |name, v| {
        if (v != null and !std.mem.eql(u8, name, "backend"))
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "eval: unused option '--{s}'", .{name}));
    }
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
    try ctx.writeTokens(&w.interface);
    w.flush() catch return 1;
    return code;
}

fn cmdBackends(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    var probe = false;
    for (args) |a| {
        if (!std.mem.eql(u8, a, "--probe"))
            return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "backends: unknown option '{s}'", .{a}));
        probe = true;
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    try w.interface.print("{s: <10} {s: <32} {s}\n", .{ "backend", "model", "status" });
    try w.interface.print("{s: <10} {s: <32} {s}\n", .{ "mock", "-", backend.statusLine(ctx, .mock) });
    for ([_]backend.Kind{ .spark, .wonder, .baseten, .compat }) |k| {
        ctx.err_msg = "";
        const ep = backend.endpoint(ctx, k) catch {
            try w.interface.print("{s: <10} {s}\n", .{ @tagName(k), ctx.err_msg });
            continue;
        };
        try w.interface.print("{s: <10} {s: <32} {s}\n", .{ @tagName(k), ep.model, backend.statusLine(ctx, k) });
        if (!probe) continue;
        ctx.err_msg = "";
        const ids = backend.listModels(ctx, k) catch {
            try w.interface.print("  probe: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "failed"});
            continue;
        };
        try w.interface.print("  probe: {d} model(s)", .{ids.len});
        for (ids) |id| try w.interface.print(" {s}", .{id});
        try w.interface.writeAll("\n");
    }
    try w.interface.print("{s: <10} {s: <32} {s}\n", .{ "acp", "-", backend.statusLine(ctx, .acp) });
    if (probe and acp.agentLine(ctx) != null) {
        ctx.err_msg = "";
        if (acp.probe(ctx)) |sel| {
            try w.interface.print("  probe: model {s}, effort {s} (agent-reported, no prompt sent)\n", .{ sel.model orelse "unreported", sel.effort orelse "-" });
        } else |_| try w.interface.print("  probe: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "failed"});
    }
    try w.interface.print("default    {s} (KNAP_BACKEND)\n", .{@tagName(ctx.backend_kind)});
    try w.flush();
    return 0;
}

/// `serve` reads MCP requests on stdin and takes no arguments at all —
/// a stray flag or positional used to sail through unnoticed.
fn cmdServe(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    if (args.len != 0)
        return usageWith(ctx, try std.fmt.allocPrint(ctx.arena, "serve: unexpected argument '{s}'", .{args[0]}));
    return mcp.serve(ctx);
}

fn cmdHelp(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    _ = args;
    try printStdout(ctx, usage_text);
    return 0;
}

/// `<command> -h|--help`: the command's usage row plus the shared
/// options block. Rows with no usage fall back to the full help.
fn cmdUsage(ctx: *Ctx, c: *const Command) !u8 {
    const u = c.usage orelse return cmdHelp(ctx, &.{});
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    try out.writer.print("knap-mcp {s}", .{u});
    if (c.summary.len > 0) try out.writer.print("   {s}", .{c.summary});
    try out.writer.writeAll("\n" ++ usage_tail);
    try printStdout(ctx, out.written());
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

test "tool_flags checked against tool input_schema" {
    const render = for (&tools.all) |*t| {
        if (std.mem.eql(u8, t.name, "knap_render")) break t.input_schema;
    } else unreachable;
    try std.testing.expect(schemaHasProp(render, flagProp("target")));
    try std.testing.expect(!schemaHasProp(render, flagProp("backend")));
    try std.testing.expect(!schemaHasProp(render, flagProp("tone")));

    const ratchet = for (&tools.all) |*t| {
        if (std.mem.eql(u8, t.name, "knap_ratchet")) break t.input_schema;
    } else unreachable;
    // --max-iters is spelled max_iterations in the schema.
    try std.testing.expect(schemaHasProp(ratchet, flagProp("max-iters")));
    try std.testing.expect(schemaHasProp(ratchet, flagProp("verifier")));
    try std.testing.expect(!schemaHasProp(ratchet, flagProp("limit")));
    try std.testing.expect(!schemaHasProp(ratchet, flagProp("target")));

    const publish_check = for (&tools.all) |*t| {
        if (std.mem.eql(u8, t.name, "knap_publish_check")) break t.input_schema;
    } else unreachable;
    try std.testing.expect(schemaHasProp(publish_check, flagProp("as")));
    try std.testing.expect(!schemaHasProp(publish_check, flagProp("target")));
}

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map, tmp: *std.testing.TmpDir) !Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = std.testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = "templates",
        .store_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]}),
        .project_root = ".",
    };
}

test "custom commands reject surplus arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    var surplus = [_][]const u8{ "bogus-1", "bogus-2" };
    for (&commands) |*c| {
        const f = switch (c.run) {
            .custom => |f| f,
            .tool => continue,
        };
        // -h/--help/-v/--version are meta rows that print and exit 0.
        if (std.mem.startsWith(u8, c.name, "-")) continue;
        try std.testing.expect(try f(&ctx, surplus[0..]) != 0);
    }
}

test "structhash positionals are all hashed, not dropped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    const cli = @import("tools/structure_hash.zig").cli;
    const f1 = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/one.md", .{tmp.sub_path});
    const f2 = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/two.md", .{tmp.sub_path});
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = f1, .data = "# A\n\nx\n" });
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = f2, .data = "# B\n\n## C\n" });
    var both = [_][]const u8{ f1, f2 };
    try std.testing.expectEqual(@as(u8, 0), try cli(&ctx, both[0..]));
    var second_bad = [_][]const u8{ f1, "no-such-doc-or-file" };
    try std.testing.expectEqual(@as(u8, 1), try cli(&ctx, second_bad[0..]));
}

// Test discovery: `zig build test` only runs tests in files listed here,
// one line per file under src/.
test {
    _ = @import("ask.zig");
    _ = @import("backend.zig");
    _ = @import("boris.zig");
    _ = @import("borisrag.zig");
    _ = @import("ctx.zig");
    _ = @import("density.zig");
    _ = @import("engine.zig");
    _ = @import("eval.zig");
    _ = @import("formatcheck.zig");
    _ = @import("frontmatter.zig");
    _ = @import("mcp.zig");
    _ = @import("policy.zig");
    _ = @import("ratchet.zig");
    _ = @import("repair.zig");
    _ = @import("smoke.zig");
    _ = @import("store.zig");
    _ = @import("structhash.zig");
    _ = @import("tools.zig");
    _ = @import("tools/audit.zig");
    _ = @import("tools/boris_ask.zig");
    _ = @import("tools/boris_check.zig");
    _ = @import("tools/common.zig");
    _ = @import("tools/density.zig");
    _ = @import("tools/doc_voice.zig");
    _ = @import("tools/extract.zig");
    _ = @import("tools/format_check.zig");
    _ = @import("tools/ingest.zig");
    _ = @import("tools/lint.zig");
    _ = @import("tools/publish_check.zig");
    _ = @import("tools/ratchet.zig");
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
