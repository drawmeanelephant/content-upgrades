//! Engine dispatch. k4o and dogbed are pinned external binaries invoked
//! by path/env override — never vendored, never reimplemented. The server
//! trusts their contract: buffered output, diagnostics on stderr, exit 1.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;

pub const Config = struct {
    k4o: []const u8,
    dogbed: []const u8,
};

/// `markdown` is k4o's CommonMark, `oliver` its Oliver-targeted variant
/// (still markdown; `comment` and table delimiters differ), `html` goes
/// through dogbed.
pub const Target = enum { markdown, oliver, html };

/// For schemas, help and error strings.
pub const target_names = "markdown|oliver|html";

/// Artifact extension for a rendered doc. Oliver docs are markdown files
/// (oliver reads them with `--from markdown`).
pub fn extension(target: Target) []const u8 {
    return switch (target) {
        .markdown, .oliver => "md",
        .html => "html",
    };
}

pub const Diag = struct {
    kind: []const u8 = "error",
    line: u32 = 0,
    col: u32 = 0,
    detail: []const u8 = "",
};

pub const Outcome = union(enum) {
    ok: []const u8,
    diags: []Diag,
};

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

/// `k4o render <tpl> --data <data> --format <fmt>` for markdown/oliver,
/// `dogbed render <tpl> --data <data>` for html.
pub fn render(ctx: *Ctx, target: Target, template_path: []const u8, data_path: []const u8) Error!Outcome {
    const argv: []const []const u8 = switch (target) {
        .html => &.{ ctx.engines.dogbed, "render", template_path, "--data", data_path },
        .markdown, .oliver => &.{
            ctx.engines.k4o, "render", template_path, "--data", data_path, "--format", @tagName(target),
        },
    };
    const result = try runEngine(ctx, argv, .limited(64 * 1024 * 1024));
    return finishRun(ctx, result);
}

/// `k4o lint` outcome plus the process exit code, so handlers can key
/// "clean" off the exit status rather than a substring of the output.
pub const LintResult = struct {
    outcome: Outcome,
    /// 0 = clean, 1 = findings on stdout; `maxInt(u8)` when k4o did not
    /// exit normally.
    exit_code: u8,
};

/// `k4o lint <tpl>` — exit 0 means clean, findings arrive on stdout with
/// a nonzero exit.
pub fn lint(ctx: *Ctx, template_path: []const u8) Error!LintResult {
    const result = try runEngine(ctx, &.{ ctx.engines.k4o, "lint", template_path }, .limited(16 * 1024 * 1024));
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => std.math.maxInt(u8),
    };
    if (exit_code == 0) return .{ .outcome = .{ .ok = result.stdout }, .exit_code = exit_code };
    // Lint findings go to stdout on exit 1; real failures go to stderr.
    if (result.stdout.len > 0) return .{ .outcome = .{ .ok = result.stdout }, .exit_code = exit_code };
    return .{ .outcome = .{ .diags = try parseDiags(ctx, result.stderr) }, .exit_code = exit_code };
}

/// `std.process.run` under a hard deadline — `KNAP_ENGINE_TIMEOUT`
/// seconds, default 60, 0 disables. A timed-out engine is killed and
/// surfaces as a normal tool error, never a hung server.
fn runEngine(ctx: *Ctx, argv: []const []const u8, stdout_limit: std.Io.Limit) Error!std.process.RunResult {
    const secs = ctx.envSecs("KNAP_ENGINE_TIMEOUT", 60);
    return std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = ctx.deadline(secs),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return ctx.fail("engine '{s}' timed out after {d}s", .{ argv[0], secs }),
        else => return ctx.fail("engine not runnable: '{s}' ({s})", .{ argv[0], @errorName(e) }),
    };
}

fn finishRun(ctx: *Ctx, result: std.process.RunResult) Error!Outcome {
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return .{ .ok = result.stdout };
            const diags = try parseDiags(ctx, result.stderr);
            if (diags.len == 0)
                return ctx.fail("engine exited {d} with no diagnostics", .{code});
            return .{ .diags = diags };
        },
        else => return ctx.fail("engine terminated abnormally", .{}),
    }
}

/// Engine stderr contract: `<prog>: <kind> at line <L>, column <C>: <detail>`
/// per line. Anything unparseable degrades to a generic diag so repair
/// always has something to point at.
pub fn parseDiags(ctx: *Ctx, stderr: []const u8) ![]Diag {
    var out: std.ArrayList(Diag) = .empty;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        try out.append(ctx.arena, parseDiagLine(trimmed) orelse .{
            .detail = trimmed,
        });
    }
    return out.items;
}

fn parseDiagLine(line: []const u8) ?Diag {
    // Strip the "prog: " prefix if present.
    var s = line;
    if (std.mem.indexOf(u8, s, ": ")) |i| {
        if (std.mem.indexOfScalar(u8, s[0..i], '/') == null and
            std.mem.indexOfScalar(u8, s[0..i], ' ') == null)
            s = s[i + 2 ..];
    }
    const marker = " at line ";
    const mi = std.mem.indexOf(u8, s, marker) orelse return null;
    const kind = s[0..mi];
    const rest = s[mi + marker.len ..];
    const comma = std.mem.indexOf(u8, rest, ", column ") orelse return null;
    const line_n = std.fmt.parseInt(u32, rest[0..comma], 10) catch return null;
    const after = rest[comma + ", column ".len ..];
    const colon = std.mem.indexOf(u8, after, ": ") orelse return null;
    const col_n = std.fmt.parseInt(u32, after[0..colon], 10) catch return null;
    return .{ .kind = kind, .line = line_n, .col = col_n, .detail = after[colon + 2 ..] };
}

pub fn targetFromName(name: []const u8) ?Target {
    const info = @typeInfo(Target).@"enum";
    inline for (info.field_names, 0..) |fname, i| {
        if (std.mem.eql(u8, name, fname)) return @enumFromInt(info.field_values[i]);
    }
    return null;
}

test "targets are markdown, oliver, html" {
    try std.testing.expectEqual(Target.oliver, targetFromName("oliver").?);
    try std.testing.expectEqual(@as(?Target, null), targetFromName("latex"));
    try std.testing.expectEqualStrings("md", extension(.oliver));
    try std.testing.expectEqualStrings("html", extension(.html));
}

test "parseDiags reads k4o main's stderr shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = undefined;
    ctx.arena = arena.allocator();
    const diags = try parseDiags(&ctx, "k4o: syntax error at line 3, column 14: unclosed '{{' tag (missing '}}')\n");
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("syntax error", diags[0].kind);
    try std.testing.expectEqual(@as(u32, 3), diags[0].line);
    try std.testing.expectEqual(@as(u32, 14), diags[0].col);
    try std.testing.expectEqualStrings("unclosed '{{' tag (missing '}}')", diags[0].detail);
}
