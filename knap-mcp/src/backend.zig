//! Model backends. The server is a context broker: every call carries the
//! smallest slice that can do the job — for repair, that's the diagnostic
//! plus the template region around it, never the whole template.
//!
//! `mock` returns canned patches so the whole loop is testable with zero
//! API access. `spark`/`wonder`/`baseten` hit OpenAI-compatible endpoints
//! via curl (CLI contracts only, no HTTP client dependency).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const store = @import("store.zig");

pub const Kind = enum { mock, spark, wonder, baseten };

/// What a model call is for. Every task uses the same endpoint and model
/// per backend today; callers pass it so routing can split per task later
/// without touching them.
pub const Task = enum { repair, voice, verify, judge, enrich };

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

pub fn parseKind(name: []const u8) ?Kind {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, 0..) |fname, i| {
        if (std.mem.eql(u8, name, fname)) return @enumFromInt(info.field_values[i]);
    }
    return null;
}

const repair_prefix =
    "You are a surgical patch engine for knap templates. " ++
    "Given a diagnostic and the template region around it, return ONLY " ++
    "the corrected region text — same line count where possible, no " ++
    "explanation, no fences. knap syntax: {{ expr }} output, " ++
    "{% if/elseif/else/endif %}, {% for x in xs %}{% endfor %}, " ++
    "filters via | name or | name:arg.";

/// Returns the replacement region, or null when the backend proposes no
/// change (which the repair loop treats as a non-convergence signal).
/// `first_line` is the 1-based template line the region starts on, so a
/// diagnostic's line/column can be mapped into it.
pub fn repairPatch(ctx: *Ctx, kind: Kind, region: []const u8, first_line: u32, diag: engine.Diag) Error!?[]const u8 {
    return switch (kind) {
        .mock => mockPatch(ctx, region, first_line, diag),
        .spark, .wonder, .baseten => remotePatch(ctx, kind, region, first_line, diag),
    };
}

// --- mock ------------------------------------------------------------------

/// Canned patch table keyed on k4o main's diagnostic detail — enough to
/// prove the loop converges end-to-end with zero API access. Every rule's
/// fix follows from the diagnostic's kind, line and column alone; nothing
/// is keyed on template text it wasn't pointed at. Diagnostics outside the
/// table return null so non-convergence stays exercise-able.
fn mockPatch(ctx: *Ctx, region: []const u8, first_line: u32, diag: engine.Diag) !?[]const u8 {
    const d = diag.detail;
    const contains = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    if (contains(d, "unclosed if block"))
        return try std.fmt.allocPrint(ctx.arena, "{s}{{% endif %}}\n", .{region});
    if (contains(d, "unclosed for block"))
        return try std.fmt.allocPrint(ctx.arena, "{s}{{% endfor %}}\n", .{region});
    if (contains(d, "no filter named") or contains(diag.kind, "unknown filter"))
        return stripUnknownFilter(ctx, region, d);

    const at = offsetOf(region, first_line, diag.line, diag.col) orelse return null;
    // `{{ x | }}`: the column is the token after the bare pipe.
    if (contains(d, "expected a filter name"))
        return dropDanglingPipe(ctx, region, at);
    // `unclosed '{{' tag (missing '}}')`: the tag runs to EOF; the column
    // is its opener. Close it at the end of the opener's line.
    if (std.mem.startsWith(u8, d, "unclosed '{{' tag")) return closeAtLineEnd(ctx, region, at, "{{");
    if (std.mem.startsWith(u8, d, "unclosed '{%' tag")) return closeAtLineEnd(ctx, region, at, "{%");
    // The tag swallowed text up to the column: close it right before.
    if (contains(d, "unexpected text after condition") or contains(d, "unexpected text in output tag"))
        return closeBefore(ctx, region, at, null);
    if (std.mem.startsWith(u8, d, "unexpected text in '{% "))
        return closeBefore(ctx, region, at, quotedKeyword(d) orelse return null);
    // `unexpected '{% endif %}' outside an if block` (also else/elseif/
    // endfor): the column sits right after the keyword. Drop the tag.
    if (std.mem.startsWith(u8, d, "unexpected '{% ")) {
        const kw = quotedKeyword(d) orelse return null;
        if (contains(d, "' outside a"))
            return replaceTag(ctx, region, at, kw, "");
        // A closer for the wrong block: swap in the enclosing block's.
        if (std.mem.eql(u8, kw, "endfor") and contains(d, "inside an if block"))
            return replaceTag(ctx, region, at, kw, "{% endif %}");
        if (std.mem.eql(u8, kw, "endif") and contains(d, "inside a for block"))
            return replaceTag(ctx, region, at, kw, "{% endfor %}");
    }
    return null;
}

/// Byte offset in `region` of the diagnostic's 1-based line and column.
/// k4o counts columns in codepoints. Null when it falls outside.
fn offsetOf(region: []const u8, first_line: u32, line: u32, col: u32) ?usize {
    if (line < first_line or col == 0) return null;
    var i: usize = 0;
    var cur = first_line;
    while (cur < line) : (cur += 1) {
        i = (std.mem.indexOfScalarPos(u8, region, i, '\n') orelse return null) + 1;
    }
    var n: u32 = 1;
    while (n < col) : (n += 1) {
        if (i >= region.len or region[i] == '\n') return null;
        i += std.unicode.utf8ByteSequenceLength(region[i]) catch 1;
    }
    return @min(i, region.len);
}

/// `'{% endif %}'` (or `{% elseif %}` etc.) in a detail → `endif`.
fn quotedKeyword(detail: []const u8) ?[]const u8 {
    const open = "'{% ";
    const a = (std.mem.indexOf(u8, detail, open) orelse return null) + open.len;
    const b = std.mem.indexOfPos(u8, detail, a, " %}'") orelse return null;
    return detail[a..b];
}

fn splice(ctx: *Ctx, region: []const u8, from: usize, to: usize, with: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ region[0..from], with, region[to..] });
}

fn closerFor(opener: []const u8) []const u8 {
    return if (std.mem.eql(u8, opener, "{{")) "}}" else "%}";
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The tag at `at` opens with `opener` and never closes: append ` }}` /
/// ` %}` after the line's last non-space byte. If that swallows trailing
/// text (`{{ name!` → `{{ name! }}`), k4o's next diagnostic points at it
/// and `closeBefore` moves the closer.
fn closeAtLineEnd(ctx: *Ctx, region: []const u8, at: usize, opener: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, region[at..], opener)) return null;
    const eol = std.mem.indexOfScalarPos(u8, region, at, '\n') orelse region.len;
    const end = at + std.mem.trimEnd(u8, region[at..eol], " \t\r").len;
    if (std.mem.indexOf(u8, region[at + 2 .. end], closerFor(opener)) != null) return null;
    return try splice(ctx, region, end, end, if (opener[1] == '{') " }}" else " %}");
}

/// The nearest `{{`/`{%` before `at` holds text it can't parse at `at`:
/// close it right after the text it legitimately holds. If the tag's
/// closer sits later on the same line (and no other tag opens first), it
/// moves there; otherwise the tag was never closed and one is inserted.
/// `keyword`, when given, must lead the tag.
fn closeBefore(ctx: *Ctx, region: []const u8, at: usize, keyword: ?[]const u8) !?[]const u8 {
    const before = region[0..at];
    const out_tag = std.mem.lastIndexOf(u8, before, "{{");
    const logic_tag = std.mem.lastIndexOf(u8, before, "{%");
    if (out_tag == null and logic_tag == null) return null;
    const open = @max(out_tag orelse 0, logic_tag orelse 0);
    const opener = region[open .. open + 2];
    const closer = closerFor(opener);
    if (std.mem.indexOf(u8, region[open + 2 .. at], closer) != null) return null;
    if (keyword) |kw| {
        const body = std.mem.trimStart(u8, region[open + 2 .. at], " ");
        if (!std.mem.startsWith(u8, body, kw)) return null;
        if (body.len > kw.len and isIdent(body[kw.len])) return null;
    }
    // Byte range of an existing closer to drop, with the spaces before it.
    var drop: [2]usize = .{ at, at };
    if (std.mem.indexOfPos(u8, region, at, closer)) |c| {
        const next_out = std.mem.indexOfPos(u8, region, at, "{{") orelse region.len;
        const next_logic = std.mem.indexOfPos(u8, region, at, "{%") orelse region.len;
        if (c < @min(next_out, next_logic)) {
            const eol = std.mem.indexOfScalarPos(u8, region, at, '\n') orelse region.len;
            if (c > eol) return null;
            drop = .{ std.mem.trimEnd(u8, region[0..c], " \t").len, c + 2 };
        }
    }
    const end = open + std.mem.trimEnd(u8, region[open..at], " \t\r\n").len;
    return try std.fmt.allocPrint(ctx.arena, "{s} {s}{s}{s}", .{
        region[0..end], closer, region[end..drop[0]], region[drop[1]..],
    });
}

/// `{{ x | }}` → `{{ x }}`: drop the last pipe before `at` inside the tag.
fn dropDanglingPipe(ctx: *Ctx, region: []const u8, at: usize) !?[]const u8 {
    const pipe = std.mem.lastIndexOfScalar(u8, region[0..at], '|') orelse return null;
    const open = std.mem.lastIndexOf(u8, region[0..pipe], "{{") orelse return null;
    if (std.mem.indexOf(u8, region[open..pipe], "}}") != null) return null;
    const keep = std.mem.trimEnd(u8, region[0..pipe], " \t").len;
    return try splice(ctx, region, keep, pipe + 1, "");
}

/// Swap the `{% keyword ... %}` tag around `at` for `with`. Removing a tag
/// that stands alone on its line removes the line.
fn replaceTag(ctx: *Ctx, region: []const u8, at: usize, keyword: []const u8, with: []const u8) !?[]const u8 {
    const open = std.mem.lastIndexOf(u8, region[0..@min(at + 1, region.len)], "{%") orelse return null;
    const body = std.mem.trimStart(u8, region[open + 2 ..], " ");
    if (!std.mem.startsWith(u8, body, keyword)) return null;
    if (body.len > keyword.len and isIdent(body[keyword.len])) return null;
    const end = (std.mem.indexOfPos(u8, region, open, "%}") orelse return null) + 2;
    if (with.len == 0) {
        const bol = if (std.mem.lastIndexOfScalar(u8, region[0..open], '\n')) |n| n + 1 else 0;
        const eol = std.mem.indexOfScalarPos(u8, region, end, '\n') orelse region.len;
        const blank = struct {
            fn f(s: []const u8) bool {
                return std.mem.trim(u8, s, " \t\r").len == 0;
            }
        }.f;
        if (blank(region[bol..open]) and blank(region[end..eol]))
            return try splice(ctx, region, bol, @min(eol + 1, region.len), "");
    }
    return try splice(ctx, region, open, end, with);
}

/// `no filter named "head2"` → drop `| head2` (and its `:arg`, if any)
/// from the region. The conservative mock fix is removing the bad filter,
/// not inventing one.
fn stripUnknownFilter(ctx: *Ctx, region: []const u8, detail: []const u8) !?[]const u8 {
    const q1 = std.mem.indexOfScalar(u8, detail, '"') orelse return null;
    const rest = detail[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..q2];
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, region, pos, '|')) |pipe| : (pos = pipe + 1) {
        var i = pipe + 1;
        while (i < region.len and region[i] == ' ') i += 1;
        if (!std.mem.startsWith(u8, region[i..], name)) continue;
        i += name.len;
        if (i < region.len and isIdent(region[i])) continue;
        if (i < region.len and region[i] == ':') i = skipArgs(region, i + 1);
        const keep = std.mem.trimEnd(u8, region[0..pipe], " \t").len;
        return try splice(ctx, region, keep, i, "");
    }
    return null;
}

/// End of a filter argument list starting at `i`: quoted strings, `(...)`
/// tuples and bare tokens, comma-separated.
fn skipArgs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and s[i] == ' ') i += 1;
    while (i < s.len) {
        switch (s[i]) {
            '"' => i = (std.mem.indexOfScalarPos(u8, s, i + 1, '"') orelse s.len - 1) + 1,
            '(' => i = (std.mem.indexOfScalarPos(u8, s, i + 1, ')') orelse s.len - 1) + 1,
            else => while (i < s.len and !std.mem.containsAtLeastScalar(u8, " ,|}\n", 1, s[i])) : (i += 1) {},
        }
        if (i < s.len and s[i] == ',') i += 1 else break;
    }
    return i;
}

// --- remote (OpenAI-compatible, via curl) -----------------------------------

fn remotePatch(ctx: *Ctx, kind: Kind, region: []const u8, first_line: u32, diag: engine.Diag) Error!?[]const u8 {
    var user: std.Io.Writer.Allocating = .init(ctx.arena);
    try user.writer.print(
        "diagnostic: {s} at line {d}, column {d}: {s}\n\nregion (starts at line {d}):\n{s}\n",
        .{ diag.kind, diag.line, diag.col, diag.detail, first_line, region },
    );

    const body = try complete(ctx, kind, .repair, repair_prefix, user.written());
    return if (body.len == 0) null else body;
}

/// One chat completion on a live backend: resolves the endpoint and model
/// for `kind`, needs MODEL_API_KEY, returns the first choice's content.
/// `mock` has no endpoint; callers keep their own canned path for it.
pub fn complete(ctx: *Ctx, kind: Kind, task: Task, system: []const u8, user: []const u8) Error![]const u8 {
    if (kind == .mock)
        return ctx.fail("backend 'mock' has no live completion (task '{s}')", .{@tagName(task)});
    const key = ctx.environ.get("MODEL_API_KEY") orelse
        return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    const url = switch (kind) {
        .baseten => ctx.environ.get("KNAP_BASETEN_URL") orelse
            "https://api.baseten.co/v1/chat/completions",
        else => "https://api.meta.ai/v1/chat/completions",
    };
    const model: []const u8 = switch (kind) {
        .spark => "muse-spark-1.3",
        .wonder => "muse-wonder-1.0",
        .baseten => "meta-models/muse-spark-open-1026",
        .mock => unreachable,
    };
    return chatCompletion(ctx, url, key, model, system, user);
}

/// POST an OpenAI-compatible chat completion through curl; return the
/// first choice's message content. Errors in the transport or a missing
/// choices field both surface as ToolFailed with the raw reply attached.
fn chatCompletion(
    ctx: *Ctx,
    url: []const u8,
    key: []const u8,
    model: []const u8,
    system: []const u8,
    user_msg: []const u8,
) Error![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(ctx.arena);
    try payload.writer.print("{{\"model\":", .{});
    try std.json.Stringify.value(model, .{}, &payload.writer);
    try payload.writer.print(",\"messages\":[{{\"role\":\"system\",\"content\":", .{});
    try std.json.Stringify.value(system, .{}, &payload.writer);
    try payload.writer.print("}},{{\"role\":\"user\",\"content\":", .{});
    try std.json.Stringify.value(user_msg, .{}, &payload.writer);
    try payload.writer.print("}}],\"temperature\":0}}", .{});

    // Body and auth header go through owner-only scratch files, not argv,
    // so neither the prompt nor the key shows up in `ps`.
    const body_path = try store.scratchFile(ctx, "json");
    const auth_path = try store.scratchFile(ctx, "header");
    defer for ([_][]const u8{ body_path, auth_path }) |p|
        std.Io.Dir.deleteFile(.cwd(), ctx.io, p) catch {};
    const Permissions = std.Io.File.Permissions;
    const private: std.Io.Dir.CreateFileOptions = .{
        .permissions = if (@hasDecl(Permissions, "fromMode")) Permissions.fromMode(0o600) else .default_file,
    };
    const auth = try std.fmt.allocPrint(ctx.arena, "Authorization: Bearer {s}\n", .{key});
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = auth_path, .data = auth, .flags = private }) catch
        return ctx.fail("cannot stage backend auth header", .{});
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = body_path, .data = payload.written(), .flags = private }) catch
        return ctx.fail("cannot stage backend request body", .{});
    const auth_arg = try std.fmt.allocPrint(ctx.arena, "@{s}", .{auth_path});
    const body_arg = try std.fmt.allocPrint(ctx.arena, "@{s}", .{body_path});

    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{
            "curl",          "-sS", "-f", "-X", "POST", url,
            "-H",            auth_arg,
            "-H",            "Content-Type: application/json",
            "--data-binary", body_arg,
        },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |e| return ctx.fail("curl failed: {s}", .{@errorName(e)});

    switch (result.term) {
        .exited => |code| if (code != 0)
            return ctx.fail("backend http {d}: {s}", .{ code, result.stderr }),
        else => return ctx.fail("curl terminated abnormally", .{}),
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{}) catch
        return ctx.fail("backend returned non-JSON", .{});
    const choices = getPath(parsed, &.{ "choices" }) orelse
        return ctx.fail("backend reply has no choices", .{});
    switch (choices) {
        .array => |arr| {
            if (arr.items.len == 0) return ctx.fail("backend reply has empty choices", .{});
            const content = getPath(arr.items[0], &.{ "message", "content" }) orelse
                return ctx.fail("backend reply has no message.content", .{});
            switch (content) {
                .string => |s| return s,
                else => return ctx.fail("backend message.content is not a string", .{}),
            }
        },
        else => return ctx.fail("backend choices is not an array", .{}),
    }
}

fn getPath(v: std.json.Value, comptime keys: []const []const u8) ?std.json.Value {
    var cur = v;
    for (keys) |k| {
        switch (cur) {
            .object => |o| cur = o.get(k) orelse return null,
            else => return null,
        }
    }
    return cur;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Run one mock patch over `region` (starting at line 1) for a k4o diag.
fn expectMock(region: []const u8, line: u32, col: u32, detail: []const u8, want: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();
    const got = try mockPatch(&ctx, region, 1, .{ .kind = "syntax error", .line = line, .col = col, .detail = detail });
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

test "mock closes an output tag that runs to EOF, no extra newline" {
    try expectMock("A\n{{ x\nB\n", 2, 1, "unclosed '{{' tag (missing '}}')", "A\n{{ x }}\nB\n");
    try expectMock("{{ x |", 1, 1, "unclosed '{{' tag (missing '}}')", "{{ x | }}");
}

test "mock closes an output tag before the text it swallowed" {
    try expectMock("{{ fm | yaml\n---\n{% endif %}\n", 2, 1, "unexpected text after condition", "{{ fm | yaml }}\n---\n{% endif %}\n");
    // Multi-byte text before the column: k4o counts codepoints.
    try expectMock("- {{ x — {{ y }}\n", 1, 10, "unexpected text after condition", "- {{ x — }} {{ y }}\n");
    // The closer swallowed trailing text: move it back to the column.
    try expectMock("Hello, {{ name! }}\n", 1, 15, "unexpected text after condition", "Hello, {{ name }}!\n");
    try expectMock("See {{ n | link:\"u\" for more. }}", 1, 21, "unexpected text after condition", "See {{ n | link:\"u\" }} for more.");
}

test "mock drops a dangling pipe, no extra newline" {
    try expectMock("a {{ x | }} b\n", 1, 10, "expected a filter name after '|'", "a {{ x }} b\n");
    try expectMock("{{ x | bold | }}", 1, 15, "expected a filter name after '|'", "{{ x | bold }}");
}

test "mock closes an unclosed logic tag" {
    try expectMock("{% endif\n\nB\n", 1, 1, "unclosed '{%' tag (missing '%}')", "{% endif %}\n\nB\n");
    try expectMock("A\n{% endif\n\n{% if y %}\n", 4, 1, "unexpected text in '{% endif %}'", "A\n{% endif %}\n\n{% if y %}\n");
    try expectMock("{% if a\n\n{% if y %}\n", 3, 1, "unexpected text in '{% endif %}'", null);
}

test "mock drops an orphan closer at the reported column" {
    try expectMock("A\n {% endif %}\nB\n", 2, 10, "unexpected '{% endif %}' outside an if block", "A\nB\n");
    try expectMock("A {% endfor %} B", 1, 10, "unexpected '{% endfor %}' outside a for block", "A  B");
    try expectMock("{% elseif x %}\nB\n", 1, 10, "unexpected '{% elseif %}' outside an if block", "B\n");
}

test "mock swaps a mismatched closer for the enclosing block's" {
    try expectMock("{% if a %}\nA\n{% endfor %}\n", 3, 10, "unexpected '{% endfor %}' inside an if block", "{% if a %}\nA\n{% endif %}\n");
    try expectMock("{% for a in b %}\n{% endif %}\n", 2, 9, "unexpected '{% endif %}' inside a for block", "{% for a in b %}\n{% endfor %}\n");
    try expectMock("{% for a in b %}\n{% else %}\n", 2, 8, "unexpected '{% else %}' inside a for block", null);
}

test "mock strips an unknown filter with its argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();
    const d: engine.Diag = .{ .kind = "unknown filter", .line = 1, .col = 10, .detail = "no filter named \"url\"" };
    try testing.expectEqualStrings("See {{ name }} now", (try mockPatch(&ctx, "See {{ name | url:\"https://e.com/\" }} now", 1, d)).?);
    const d2: engine.Diag = .{ .kind = "unknown filter", .line = 1, .col = 10, .detail = "no filter named \"head2\"" };
    try testing.expectEqualStrings("{{ t | head22 }}{{ t }}", (try mockPatch(&ctx, "{{ t | head22 }}{{ t | head2 }}", 1, d2)).?);
}
