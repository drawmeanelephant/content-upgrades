//! The bounded repair loop.
//!
//!   draft -> render -> [ok]            -> done
//!                   -> [diag] -> region(diag.line +/- N) -> backend patch
//!                            -> render -> iter<max ? loop : best-effort+diags
//!
//! Patch-per-diagnostic, first error only — errors cascade, so don't batch.
//! Non-convergence is a feature: it returns best-effort + diagnostics.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const backend = @import("backend.zig");
const store = @import("store.zig");

pub const default_max_iterations = 4;
pub const region_context_lines = 2;

pub const Step = struct {
    iteration: usize,
    kind: []const u8,
    line: u32,
    detail: []const u8,
    patch_applied: bool,
};

pub const Outcome = struct {
    target: engine.Target,
    converged: bool,
    iterations: usize,
    /// Final working copy of the template (the patched text, never the
    /// shipped file).
    template: []const u8,
    /// Rendered document when converged, else null.
    document: ?[]const u8,
    diags: []engine.Diag,
    steps: []Step,
};

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

/// `template_text` is the starting working copy — the tool path passes the
/// shipped template, the eval harness passes a seeded breakage.
pub fn run(
    ctx: *Ctx,
    target: engine.Target,
    template_text: []const u8,
    data_path: []const u8,
    kind: backend.Kind,
    max_iterations: usize,
) Error!Outcome {
    var steps: std.ArrayList(Step) = .empty;
    var current = template_text;
    var diags: []engine.Diag = &.{};

    var iter: usize = 0;
    while (iter < max_iterations) : (iter += 1) {
        const tpl_path = try store.scratchFile(ctx, "knap");
        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = tpl_path, .data = current }) catch
            return ctx.fail("cannot stage working template", .{});

        switch (try engine.render(ctx, target, tpl_path, data_path)) {
            .ok => |doc| return .{
                .target = target,
                .converged = true,
                .iterations = iter,
                .template = current,
                .document = doc,
                .diags = &.{},
                .steps = steps.items,
            },
            .diags => |found| {
                diags = found;
                const first = found[0];
                if (ctx.environ.get("KNAP_DEBUG") != null)
                    std.debug.print("repair iter {d}: {s}@{d} {s}\n", .{ iter, first.kind, first.line, first.detail });
                // Unclosed-block fixes land at the end of the construct —
                // the region reaches to EOF so the patch can close it.
                const unclosed = std.mem.indexOf(u8, first.detail, "unclosed") != null;
                const context: usize = if (unclosed) 0 else region_context_lines;
                const bounds = if (unclosed)
                    [2]usize{ regionBounds(current, first.line, 0)[0], current.len }
                else
                    regionBounds(current, first.line, context);
                const region = current[bounds[0]..bounds[1]];
                const patch = try backend.repairPatch(ctx, kind, region, firstLine(first.line, context), first);
                const applied = patch != null and !std.mem.eql(u8, patch.?, region);
                try steps.append(ctx.arena, .{
                    .iteration = iter,
                    .kind = first.kind,
                    .line = first.line,
                    .detail = first.detail,
                    .patch_applied = applied,
                });
                if (!applied) break;
                current = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{
                    current[0..bounds[0]], patch.?, current[bounds[1]..],
                });
            },
        }
    }

    return .{
        .target = target,
        .converged = false,
        .iterations = steps.items.len,
        .template = current,
        .document = null,
        .diags = diags,
        .steps = steps.items,
    };
}

/// The 1-based line `regionBounds(_, line, context)` starts on.
fn firstLine(line: u32, context: usize) u32 {
    const ctx32: u32 = @intCast(context);
    return if (line > ctx32) line - ctx32 else 1;
}

/// Byte range covering `context` lines above and below `line` (1-based),
/// clamped to the text. The patch replaces exactly this slice — surgical,
/// never whole-document.
fn regionBounds(text: []const u8, line: u32, context: usize) [2]usize {
    const ctx32: u32 = @intCast(context);
    const lo: u32 = if (line > ctx32) line - ctx32 else 1;
    const hi: u32 = line + ctx32;
    var start: usize = 0;
    var cur: u32 = 1;
    var i: usize = 0;
    while (cur < lo and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            cur += 1;
            start = i + 1;
        }
    }
    const want = hi - lo + 1;
    var seen: u32 = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            seen += 1;
            if (seen == want) {
                i += 1;
                break;
            }
        }
    }
    return .{ start, @min(i, text.len) };
}

test "regionBounds centers on the diagnostic line" {
    const text = "a\nb\nc\nd\ne\nf\ng\n";
    const b = regionBounds(text, 4, 1);
    try std.testing.expectEqualStrings("c\nd\ne\n", text[b[0]..b[1]]);
}

test "regionBounds clamps at edges" {
    const text = "a\nb\nc\n";
    const b = regionBounds(text, 1, 2);
    try std.testing.expectEqualStrings("a\nb\nc\n", text[b[0]..b[1]]);
}
