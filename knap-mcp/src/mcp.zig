//! MCP stdio transport: newline-delimited JSON-RPC 2.0.
//!
//! One request per line, one response per line. Notifications carry no
//! `id` and get no reply. All payloads are written through an Allocating
//! buffer then emitted as a single line so partial writes can't interleave.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const tools = @import("tools.zig");
const store = @import("store.zig");

const protocol_version = "2025-06-18";

const Allocating = std.Io.Writer.Allocating;

pub fn serve(init: std.process.Init, ctx: *Ctx) !u8 {
    var in_buf: [4 * 1024 * 1024]u8 = undefined;
    var r = std.Io.File.stdin().reader(init.io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    while (true) {
        const line = r.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => return 1,
            error.StreamTooLong => {
                try sendError(&w, null, -32700, "message exceeds 4MiB line limit");
                continue;
            },
        } orelse break; // EOF
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        _ = arena_state.reset(.{ .retain_with_limit = 1 << 20 });
        const arena = arena_state.allocator();
        // Rebind ctx's arena to the per-request arena: handlers may
        // allocate freely, all freed at loop bottom.
        var req_ctx = ctx.*;
        req_ctx.arena = arena;
        req_ctx.err_msg = "";

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch {
            try sendError(&w, null, -32700, "parse error");
            continue;
        };
        if (parsed != .object) {
            try sendError(&w, null, -32600, "invalid request");
            continue;
        }

        const obj = parsed.object;
        const id = obj.get("id");
        const method = switch (obj.get("method") orelse .null) {
            .string => |m| m,
            else => {
                try sendError(&w, id, -32600, "invalid request: missing method");
                continue;
            },
        };
        const params = obj.get("params");

        // Notifications: method namespaced under notifications/, or no id.
        if (id == null or std.mem.startsWith(u8, method, "notifications/")) continue;

        var body: Allocating = .init(arena);
        dispatch(&req_ctx, method, params, &body) catch |e| {
            if (e == error.MethodNotFound) {
                try sendError(&w, id, -32601, "method not found");
            } else if (e == error.ToolFailed) {
                try sendError(&w, id, -32602, if (req_ctx.err_msg.len > 0) req_ctx.err_msg else "tool failed");
            } else {
                try sendError(&w, id, -32603, @errorName(e));
            }
            continue;
        };
        try writeResponse(&w, id.?, body.written(), "result");
    }
    try w.flush();
    return 0;
}

fn dispatch(ctx: *Ctx, method: []const u8, params: ?std.json.Value, out: *Allocating) !void {
    if (std.mem.eql(u8, method, "initialize")) {
        try out.writer.writeAll("{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{\"tools\":{},\"resources\":{}},\"serverInfo\":{\"name\":\"knap-mcp\",\"version\":");
        try std.json.Stringify.value(@import("build_options").version, .{}, &out.writer);
        try out.writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, method, "ping")) {
        try out.writer.writeAll("{}");
        return;
    }
    if (std.mem.eql(u8, method, "tools/list")) return tools.listJson(out);
    if (std.mem.eql(u8, method, "tools/call")) return toolsCall(ctx, params, out);
    if (std.mem.eql(u8, method, "resources/list")) return resourcesList(ctx, out);
    if (std.mem.eql(u8, method, "resources/read")) return resourcesRead(ctx, params, out);
    return error.MethodNotFound;
}

fn toolsCall(ctx: *Ctx, params: ?std.json.Value, out: *Allocating) !void {
    const p = params orelse return ctx.fail("tools/call needs params", .{});
    const obj = switch (p) {
        .object => |o| o,
        else => return ctx.fail("tools/call params must be an object", .{}),
    };
    const name = switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => return ctx.fail("tools/call needs params.name", .{}),
    };
    const arg_obj: ?std.json.ObjectMap = switch (obj.get("arguments") orelse .null) {
        .object => |o| o,
        else => null,
    };

    var payload: Allocating = .init(ctx.arena);
    tools.dispatch(ctx, name, arg_obj, &payload) catch |e| {
        // Tool errors are protocol-level successes carrying isError:true —
        // the client model must see the diagnostic, not a transport fault.
        const msg = if (ctx.err_msg.len > 0) ctx.err_msg else @errorName(e);
        try out.writer.writeAll("{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(msg, .{}, &out.writer);
        try out.writer.writeAll("}]}");
        return;
    };
    try out.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(payload.written(), .{}, &out.writer);
    try out.writer.writeAll("}]}");
}

fn resourcesList(ctx: *Ctx, out: *Allocating) !void {
    try out.writer.writeAll("{\"resources\":[");
    var first = true;

    var d = std.Io.Dir.openDir(.cwd(), ctx.io, ctx.templates_dir, .{ .iterate = true }) catch null;
    if (d) |*dir| {
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".knap")) continue;
            const id = entry.name[0 .. entry.name.len - 5];
            if (!first) try out.writer.writeAll(",");
            first = false;
            try out.writer.print("{{\"uri\":\"knap://templates/{s}\",\"name\":\"{s}\",\"mimeType\":\"text/plain\"}}", .{ id, id });
        }
    }

    const artifacts = store.list(ctx) catch &.{};
    for (artifacts) |a| {
        if (!first) try out.writer.writeAll(",");
        first = false;
        try out.writer.print("{{\"uri\":\"knap://docs/{s}\",\"name\":\"{s}.{s}\",\"mimeType\":\"{s}\"}}", .{ a.doc_id, a.doc_id, a.extension, mimeFor(a.extension) });
    }
    try out.writer.writeAll("]}");
}

fn resourcesRead(ctx: *Ctx, params: ?std.json.Value, out: *Allocating) !void {
    const p = params orelse return ctx.fail("resources/read needs params", .{});
    const obj = switch (p) {
        .object => |o| o,
        else => return ctx.fail("resources/read params must be an object", .{}),
    };
    const uri = switch (obj.get("uri") orelse .null) {
        .string => |s| s,
        else => return ctx.fail("resources/read needs params.uri", .{}),
    };

    if (std.mem.startsWith(u8, uri, "knap://templates/")) {
        const id = uri["knap://templates/".len..];
        const text = try tools.templateText(ctx, id);
        try writeContents(out, uri, "text/plain", text);
        return;
    }
    if (std.mem.startsWith(u8, uri, "knap://docs/")) {
        const id = uri["knap://docs/".len..];
        const text = (store.read(ctx, id) catch null) orelse
            return ctx.fail("no such doc '{s}'", .{id});
        try writeContents(out, uri, mimeFor(docExtension(ctx, id)), text);
        return;
    }
    return ctx.fail("unknown resource uri '{s}'", .{uri});
}

/// Rendered docs are `md` (markdown and oliver targets) or `html`; eval
/// reports are `json`. Anything else stays text/plain.
fn mimeFor(ext: []const u8) []const u8 {
    if (std.mem.eql(u8, ext, "md")) return "text/markdown";
    if (std.mem.eql(u8, ext, "html")) return "text/html";
    if (std.mem.eql(u8, ext, "json")) return "application/json";
    return "text/plain";
}

fn docExtension(ctx: *Ctx, doc_id: []const u8) []const u8 {
    const artifacts = store.list(ctx) catch return "";
    for (artifacts) |a| if (std.mem.eql(u8, a.doc_id, doc_id)) return a.extension;
    return "";
}

fn writeContents(out: *Allocating, uri: []const u8, mime: []const u8, text: []const u8) !void {
    try out.writer.writeAll("{\"contents\":[{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    try out.writer.print(",\"mimeType\":\"{s}\",\"text\":", .{mime});
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeAll("}]}");
}

fn sendError(w: anytype, id: ?std.json.Value, code: i32, msg: []const u8) !void {
    try w.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |v| try std.json.Stringify.value(v, .{}, &w.interface) else try w.interface.writeAll("null");
    try w.interface.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(msg, .{}, &w.interface);
    try w.interface.writeAll("}}\n");
    try w.flush();
}

fn writeResponse(w: anytype, id: std.json.Value, body: []const u8, comptime field: []const u8) !void {
    try w.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &w.interface);
    try w.interface.print(",\"{s}\":{s}}}\n", .{ field, body });
    try w.flush();
}
