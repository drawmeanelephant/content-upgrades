//! Agent Client Protocol client: an ACP agent (`devin acp`, `gemini
//! --acp`, …) as a model backend. ACP is agent↔editor, so knap-mcp plays
//! the editor: it spawns the agent named by `KNAP_ACP_AGENT` and talks
//! newline-delimited JSON-RPC 2.0 over its stdio — the framing `mcp.zig`
//! serves inbound, here run outbound.
//!
//! Lifecycle: one agent subprocess per knap-mcp process, spawned lazily
//! on the first call and respawned only if it dies or `KNAP_ACP_AGENT`
//! changes; one `session/new` per prompt, so repair iterations and voice
//! slots never see each other's turns. The contract is prompt in, text
//! out: the client advertises no fs/terminal capabilities, cancels every
//! `session/request_permission`, refuses every other agent→client request,
//! and keeps only `agent_message_chunk` text for its own session.
//!
//! Settings:
//!
//!   KNAP_ACP_AGENT         the agent's argv, split on whitespace ('…' and
//!                          "…" group); e.g. `devin acp --agent-type
//!                          summarizer`. Keep credentials out of it: argv
//!                          shows up in `ps`.
//!   KNAP_ACP_TIMEOUT       seconds for one session/new + session/prompt
//!                          (default 180, 0 = none)
//!   KNAP_ACP_INIT_TIMEOUT  seconds for spawn + initialize (default 60)
//!   KNAP_ACP_CWD           absolute session cwd (default: process cwd)
//!
//! The agent's stderr is discarded unless KNAP_DEBUG is set — it is the
//! agent's log, and may carry account details.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const backend = @import("backend.zig");
const File = std.Io.File;
const MultiReader = File.MultiReader;

pub const protocol_version = 1;

/// Agents announce their whole command palette in one notification; a
/// line this long is a broken agent, not a big message.
const line_limit = 16 * 1024 * 1024;

/// How long a timed-out turn gets to acknowledge `session/cancel` before
/// the agent is killed.
const cancel_grace_secs = 5;

pub const Error = backend.Error;

/// One finished prompt turn.
pub const Turn = struct {
    /// Concatenated `agent_message_chunk` text for the turn's session.
    text: []const u8,
    /// The `session/prompt` result's `stopReason` (`end_turn`,
    /// `max_tokens`, `max_turn_requests`, `refusal`).
    stop_reason: []const u8,
    /// The result's `usage` object, when the agent reports one.
    usage: ?std.json.Value,
};

/// The running agent. Process-wide: `mcp.zig` copies Ctx per request, so
/// the subprocess can't live there. `multi` points into `buffer` and at
/// itself, hence a fixed global rather than a value that moves. Its
/// memory is process-lifetime too, so it comes from the page allocator,
/// not the Ctx gpa whose leak check runs before the agent is reaped (the
/// agent exits on its own when knap-mcp's end of stdin closes).
const Agent = struct {
    child: std.process.Child,
    stdin: File,
    buffer: MultiReader.Buffer(1),
    multi: MultiReader,
    /// The KNAP_ACP_AGENT it was spawned from, and that line's argv[0]
    /// (the only part error messages name).
    line: []u8,
    name: []u8,
    next_id: i64,
};

var agent: Agent = undefined;
var live = false;
const gpa = std.heap.page_allocator;

/// The configured agent command line, or null when unset.
pub fn agentLine(ctx: *Ctx) ?[]const u8 {
    const v = std.mem.trim(u8, ctx.environ.get("KNAP_ACP_AGENT") orelse "", " \t\r\n");
    return if (v.len == 0) null else v;
}

/// `agentLine`, or a ToolFailed naming the setting.
pub fn requireAgent(ctx: *Ctx) error{ToolFailed}![]const u8 {
    return agentLine(ctx) orelse ctx.fail(
        "backend 'acp' needs KNAP_ACP_AGENT (an ACP agent command, e.g. `devin acp --agent-type summarizer`)",
        .{},
    );
}

/// The agent's argv[0], for status lines and errors.
pub fn agentName(ctx: *Ctx) ?[]const u8 {
    const argv = splitArgv(ctx.arena, agentLine(ctx) orelse return null) catch return null;
    return if (argv.len == 0) null else argv[0];
}

/// What the agent selected for a session, as it reports it.
pub const Selection = struct {
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

/// Start the agent if needed and open one session without prompting it,
/// so no tokens are spent. Returns the model and effort the agent picked.
/// Agents can fall back to a default model without saying so
/// (`opencode acp` uses `flint-40b-free` unless configured), so a live
/// run checks this before it starts.
pub fn probe(ctx: *Ctx) Error!Selection {
    try ensure(ctx, try requireAgent(ctx));
    _, const sel = try newSession(ctx, ctx.deadline(ctx.envSecs("KNAP_ACP_TIMEOUT", 180)));
    return sel;
}

/// Run one prompt turn in a fresh session on the (lazily started) agent.
pub fn prompt(ctx: *Ctx, text: []const u8) Error!Turn {
    try ensure(ctx, try requireAgent(ctx));
    const deadline = ctx.deadline(ctx.envSecs("KNAP_ACP_TIMEOUT", 180));
    const sid, _ = try newSession(ctx, deadline);

    var params: std.Io.Writer.Allocating = .init(ctx.arena);
    try params.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(sid, .{}, &params.writer);
    try params.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, &params.writer);
    try params.writer.writeAll("}]}");
    var reply: std.Io.Writer.Allocating = .init(ctx.arena);
    const result = try call(ctx, "session/prompt", params.written(), deadline, .{ .sid = sid, .out = &reply.writer });
    const stop = str(get(result, "stopReason")) orelse "";
    if (std.mem.eql(u8, stop, "cancelled")) return ctx.fail("acp agent '{s}' cancelled the turn", .{agent.name});
    return .{ .text = reply.written(), .stop_reason = stop, .usage = get(result, "usage") };
}

/// `session/new` on the running agent: the session id, and the selection
/// it reports.
fn newSession(ctx: *Ctx, deadline: std.Io.Timeout) Error!struct { []const u8, Selection } {
    var params: std.Io.Writer.Allocating = .init(ctx.arena);
    try params.writer.writeAll("{\"cwd\":");
    try std.json.Stringify.value(try sessionCwd(ctx), .{}, &params.writer);
    try params.writer.writeAll(",\"mcpServers\":[]}");
    const session = try call(ctx, "session/new", params.written(), deadline, null);
    const sid = str(get(session, "sessionId")) orelse return gone(ctx, "answered session/new without a sessionId");
    return .{ sid, selection(session) };
}

/// The model and effort from a `session/new` result: the `configOptions`
/// entries in category `model` / `thought_level`, else the older
/// `models.currentModelId`.
fn selection(session: std.json.Value) Selection {
    var sel: Selection = .{};
    if (get(session, "configOptions")) |opts| if (opts == .array) for (opts.array.items) |o| {
        const category = str(get(o, "category")) orelse str(get(o, "id")) orelse continue;
        const current = str(get(o, "currentValue")) orelse continue;
        if (std.mem.eql(u8, category, "model")) sel.model = current;
        if (std.mem.eql(u8, category, "thought_level")) sel.effort = current;
    };
    if (sel.model == null) sel.model = str(get(get(session, "models") orelse .null, "currentModelId"));
    return sel;
}

/// Stop the agent subprocess, if one is running.
pub fn shutdown(io: std.Io) void {
    if (!live) return;
    live = false;
    agent.multi.deinit();
    agent.stdin.close(io);
    agent.child.kill(io);
    gpa.free(agent.line);
    gpa.free(agent.name);
}

/// Start the agent for `line` unless it is already running.
fn ensure(ctx: *Ctx, line: []const u8) Error!void {
    if (live and std.mem.eql(u8, agent.line, line)) return;
    shutdown(ctx.io);
    const argv = splitArgv(ctx.arena, line) catch
        return ctx.fail("KNAP_ACP_AGENT has an unbalanced quote", .{});
    if (argv.len == 0) return ctx.fail("KNAP_ACP_AGENT names no command", .{});
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = if (ctx.environ.get("KNAP_DEBUG") != null) .inherit else .ignore,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("cannot start acp agent '{s}': {s}", .{ argv[0], @errorName(e) }),
    };
    const name = gpa.dupe(u8, argv[0]) catch |e| {
        child.kill(ctx.io);
        return e;
    };
    const owned = gpa.dupe(u8, line) catch |e| {
        gpa.free(name);
        child.kill(ctx.io);
        return e;
    };
    agent = .{
        .child = child,
        .stdin = child.stdin.?,
        .buffer = undefined,
        .multi = undefined,
        .line = owned,
        .name = name,
        .next_id = 0,
    };
    agent.child.stdin = null;
    agent.multi.init(gpa, ctx.io, agent.buffer.toStreams(), &.{agent.child.stdout.?});
    live = true;
    errdefer shutdown(ctx.io);

    const init_params = "{\"protocolVersion\":" ++ std.fmt.comptimePrint("{d}", .{protocol_version}) ++
        ",\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false}" ++
        ",\"clientInfo\":{\"name\":\"knap-mcp\",\"version\":\"" ++ @import("build_options").version ++ "\"}}";
    const result = try call(ctx, "initialize", init_params, ctx.deadline(ctx.envSecs("KNAP_ACP_INIT_TIMEOUT", 60)), null);
    const v = get(result, "protocolVersion") orelse std.json.Value.null;
    if (v != .integer or v.integer != protocol_version)
        return gone(ctx, "speaks an unsupported ACP protocolVersion");
}

/// The session's working directory: KNAP_ACP_CWD, else the process cwd.
/// ACP requires an absolute path.
fn sessionCwd(ctx: *Ctx) Error![]const u8 {
    if (ctx.environ.get("KNAP_ACP_CWD")) |c| {
        if (!std.fs.path.isAbsolute(c)) return ctx.fail("KNAP_ACP_CWD must be an absolute path", .{});
        return c;
    }
    return std.process.currentPathAlloc(ctx.io, ctx.arena) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => ctx.fail("cannot resolve the acp session cwd: {s}", .{@errorName(e)}),
    };
}

/// Where a turn's message chunks go.
const Sink = struct { sid: []const u8, out: *std.Io.Writer };

/// Send one request and pump the agent's output until its response
/// arrives, answering agent→client requests and collecting `sink`'s
/// chunks on the way. A prompt that outlives `deadline` is cancelled; any
/// other timeout, and an agent that dies or breaks framing, stops the
/// subprocess so the next call starts a fresh one.
fn call(ctx: *Ctx, comptime method: []const u8, params: []const u8, deadline: std.Io.Timeout, sink: ?Sink) Error!std.json.Value {
    agent.next_id += 1;
    const id = agent.next_id;
    try send(ctx, try std.fmt.allocPrint(ctx.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"" ++ method ++ "\",\"params\":{s}}}\n", .{ id, params }));
    var timeout = deadline;
    var cancelled = false;
    while (true) {
        const line = nextLine(ctx, timeout) catch |e| switch (e) {
            error.Timeout => {
                if (sink == null) return gone(ctx, "timed out on " ++ method);
                if (cancelled) return gone(ctx, "ignored session/cancel; agent stopped");
                cancelled = true;
                timeout = ctx.deadline(cancel_grace_secs);
                try notifyCancel(ctx, sink.?.sid);
                continue;
            },
            else => |err| return err,
        };
        const msg = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, line, .{}) catch
            return gone(ctx, "wrote a line that is not JSON");
        if (msg != .object) return gone(ctx, "wrote a JSON-RPC message that is not an object");
        const msg_id = get(msg, "id");
        if (str(get(msg, "method"))) |m| {
            if (msg_id) |req| try answerRequest(ctx, req, m) else if (sink) |s| try collect(msg, s);
            continue;
        }
        const rid = msg_id orelse continue;
        if (rid != .integer or rid.integer != id) continue; // a stale reply
        if (cancelled) return ctx.fail("acp agent '{s}' timed out; turn cancelled", .{agent.name});
        if (get(msg, "error")) |err| {
            const text = str(get(err, "message")) orelse "unknown error";
            const code = get(err, "code") orelse std.json.Value.null;
            const hint = if (code == .integer and code.integer == -32000) " (authenticate the agent first)" else "";
            return ctx.fail("acp agent '{s}' failed " ++ method ++ ": {s}{s}", .{ agent.name, backend.brief(text), hint });
        }
        return get(msg, "result") orelse std.json.Value.null;
    }
}

/// Permission requests are cancelled; every other agent→client method
/// (fs, terminal, vendor extensions) is refused — knap-mcp advertised
/// none of them.
fn answerRequest(ctx: *Ctx, id: std.json.Value, method: []const u8) Error!void {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &out.writer);
    try out.writer.writeAll(if (std.mem.eql(u8, method, "session/request_permission"))
        ",\"result\":{\"outcome\":{\"outcome\":\"cancelled\"}}}\n"
    else
        ",\"error\":{\"code\":-32601,\"message\":\"knap-mcp grants no client capabilities\"}}\n");
    try send(ctx, out.written());
}

/// Keep `agent_message_chunk` text for the sink's session; thoughts,
/// tool calls, plans and other sessions' updates are dropped.
fn collect(msg: std.json.Value, sink: Sink) Error!void {
    if (!std.mem.eql(u8, str(get(msg, "method")) orelse "", "session/update")) return;
    const params = get(msg, "params") orelse return;
    if (!std.mem.eql(u8, str(get(params, "sessionId")) orelse "", sink.sid)) return;
    const update = get(params, "update") orelse return;
    if (!std.mem.eql(u8, str(get(update, "sessionUpdate")) orelse "", "agent_message_chunk")) return;
    const content = get(update, "content") orelse return;
    if (!std.mem.eql(u8, str(get(content, "type")) orelse "", "text")) return;
    try sink.out.writeAll(str(get(content, "text")) orelse "");
}

fn notifyCancel(ctx: *Ctx, sid: []const u8) Error!void {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":");
    try std.json.Stringify.value(sid, .{}, &out.writer);
    try out.writer.writeAll("}}\n");
    try send(ctx, out.written());
}

fn send(ctx: *Ctx, line: []const u8) Error!void {
    agent.stdin.writeStreamingAll(ctx.io, line) catch return gone(ctx, "closed its input");
}

/// The next newline-terminated message from the agent, copied out of the
/// read buffer.
fn nextLine(ctx: *Ctx, timeout: std.Io.Timeout) (Error || error{Timeout})![]const u8 {
    const r = agent.multi.reader(0);
    while (true) {
        if (std.mem.indexOfScalar(u8, r.buffered(), '\n')) |n| {
            const line = try ctx.arena.dupe(u8, std.mem.trim(u8, r.buffered()[0..n], " \t\r"));
            r.toss(n + 1);
            if (line.len == 0) continue;
            return line;
        }
        if (r.bufferedLen() > line_limit) return gone(ctx, "wrote a line over the 16 MiB limit");
        if (agent.multi.streams.contexts()[0].err != null) return gone(ctx, "exited");
        agent.multi.fill(64, timeout) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            else => return gone(ctx, "exited"),
        };
    }
}

/// The agent is unusable: stop it (the next call respawns) and fail.
fn gone(ctx: *Ctx, comptime what: []const u8) error{ToolFailed} {
    const err = ctx.fail("acp agent '{s}' " ++ what, .{agent.name});
    shutdown(ctx.io);
    return err;
}

/// Split an agent command line on whitespace; '…' and "…" group words.
fn splitArgv(arena: std.mem.Allocator, line: []const u8) error{ OutOfMemory, UnbalancedQuote }![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    for (line) |c| {
        if (quote) |q| {
            if (c == q) quote = null else try word.append(arena, c);
        } else if (c == '\'' or c == '"') {
            quote = c;
            in_word = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (in_word) try argv.append(arena, try word.toOwnedSlice(arena));
            in_word = false;
        } else {
            try word.append(arena, c);
            in_word = true;
        }
    }
    if (quote != null) return error.UnbalancedQuote;
    if (in_word) try argv.append(arena, try word.toOwnedSlice(arena));
    return argv.items;
}

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "splitArgv splits on whitespace and groups quotes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try splitArgv(a, "  devin acp --agent-type summarizer ");
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("devin", argv[0]);
    try testing.expectEqualStrings("summarizer", argv[3]);
    const quoted = try splitArgv(a, "sh '/tmp/a b/agent.sh' \"x y\"z ''");
    try testing.expectEqual(@as(usize, 4), quoted.len);
    try testing.expectEqualStrings("/tmp/a b/agent.sh", quoted[1]);
    try testing.expectEqualStrings("x yz", quoted[2]);
    try testing.expectEqualStrings("", quoted[3]);
    try testing.expectError(error.UnbalancedQuote, splitArgv(a, "sh 'oops"));
    try testing.expectEqual(@as(usize, 0), (try splitArgv(a, " \t")).len);
}

/// A Ctx wired to the fake ACP agent (`acp_fake_agent.sh`) in `mode`.
pub const FakeAgent = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    script: []const u8,

    pub fn init(f: *FakeAgent) !void {
        f.arena = .init(testing.allocator);
        const a = f.arena.allocator();
        f.env = .init(a);
        f.tmp = std.testing.tmpDir(.{});
        f.script = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/fake-acp.sh", .{f.tmp.sub_path[0..]});
        try std.Io.Dir.writeFile(.cwd(), testing.io, .{ .sub_path = f.script, .data = @embedFile("acp_fake_agent.sh") });
        try f.env.put("KNAP_ACP_INIT_TIMEOUT", "10");
        try f.env.put("KNAP_ACP_TIMEOUT", "10");
    }

    pub fn deinit(f: *FakeAgent) void {
        shutdown(testing.io);
        f.tmp.cleanup();
        f.arena.deinit();
    }

    pub fn ctx(f: *FakeAgent, mode: []const u8) !Ctx {
        const a = f.arena.allocator();
        try f.env.put("KNAP_ACP_AGENT", try std.fmt.allocPrint(a, "/bin/sh '{s}' {s}", .{ f.script, mode }));
        var c: Ctx = undefined;
        c.arena = a;
        c.io = testing.io;
        c.environ = &f.env;
        c.err_msg = "";
        c.calls = 0;
        c.slice_bytes_total = 0;
        c.slice_bytes_max = 0;
        c.prefix_bytes = 0;
        c.prompt_tokens = 0;
        c.completion_tokens = 0;
        c.total_tokens = 0;
        c.reasoning_tokens = 0;
        return c;
    }
};

test "prompt collects only its session's message chunks and refuses capabilities" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("ok");
    const t1 = try prompt(&ctx, "system\n\nuser \"quoted\"\n");
    try testing.expectEqualStrings("reply from s1", t1.text);
    try testing.expectEqualStrings("end_turn", t1.stop_reason);
    try testing.expectEqual(@as(i64, 43), get(t1.usage.?, "totalTokens").?.integer);
    // Same subprocess (the session counter kept counting), fresh session.
    const pid = agent.child.id;
    const t2 = try prompt(&ctx, "again");
    try testing.expectEqualStrings("reply from s2", t2.text);
    try testing.expectEqual(pid, agent.child.id);
}

test "probe reports the agent's selection without prompting" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("echo");
    const sel = try probe(&ctx);
    try testing.expectEqualStrings("fake-model-1", sel.model.?);
    try testing.expectEqualStrings("low", sel.effort.?);
    // The probe's agent is reused, and a prompt after it gets a new session.
    const pid = agent.child.id;
    const t = try prompt(&ctx, "say knap-smoke-verify");
    try testing.expectEqualStrings("knap-smoke-verify", t.text);
    try testing.expectEqual(pid, agent.child.id);
    ctx = try f.ctx("legacy");
    const old = try probe(&ctx);
    try testing.expectEqualStrings("fake-legacy", old.model.?);
    try testing.expect(old.effort == null);
}

test "a changed KNAP_ACP_AGENT respawns the agent" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("ok");
    _ = try prompt(&ctx, "x");
    ctx = try f.ctx("maxtok");
    const t = try prompt(&ctx, "x");
    try testing.expectEqualStrings("{% if a", t.text);
    try testing.expectEqualStrings("max_tokens", t.stop_reason);
}

test "a hung turn is cancelled at the deadline and the agent survives" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("KNAP_ACP_TIMEOUT", "1");
    var ctx = try f.ctx("hang");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expectEqualStrings("acp agent '/bin/sh' timed out; turn cancelled", ctx.err_msg);
    try testing.expect(live);
}

test "an agent that ignores session/cancel is stopped" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("KNAP_ACP_TIMEOUT", "1");
    var ctx = try f.ctx("mute");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expectEqualStrings("acp agent '/bin/sh' ignored session/cancel; agent stopped", ctx.err_msg);
    try testing.expect(!live);
}

test "agent failures are ToolFailed with a bounded message" {
    var f: FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("crash");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expectEqualStrings("acp agent '/bin/sh' exited", ctx.err_msg);
    try testing.expect(!live);
    ctx = try f.ctx("auth");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expectEqualStrings("acp agent '/bin/sh' failed session/new: Authentication required (authenticate the agent first)", ctx.err_msg);
    ctx = try f.ctx("v2");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expectEqualStrings("acp agent '/bin/sh' speaks an unsupported ACP protocolVersion", ctx.err_msg);
    try f.env.put("KNAP_ACP_AGENT", "/nonexistent/acp-agent --flag secret");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expect(std.mem.startsWith(u8, ctx.err_msg, "cannot start acp agent '/nonexistent/acp-agent': "));
    try testing.expect(std.mem.indexOf(u8, ctx.err_msg, "secret") == null);
    try f.env.put("KNAP_ACP_AGENT", " ");
    try testing.expectError(error.ToolFailed, prompt(&ctx, "x"));
    try testing.expect(std.mem.startsWith(u8, ctx.err_msg, "backend 'acp' needs KNAP_ACP_AGENT"));
}
