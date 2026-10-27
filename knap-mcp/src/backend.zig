//! Model backends. The server is a context broker: every call carries the
//! smallest slice that can do the job — for repair, that's the diagnostic
//! plus the template region around it, never the whole template.
//!
//! `mock` returns canned patches so the whole loop is testable with zero
//! API access. `spark`/`wonder`/`baseten`/`compat` hit OpenAI-compatible
//! endpoints via curl (CLI contracts only, no HTTP client dependency) —
//! `compat` is the generic one: `KNAP_COMPAT_URL`/`_MODEL` required,
//! `KNAP_COMPAT_KEY` optional. `acp` drives a local Agent Client Protocol
//! agent over stdio (`acp.zig`).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const engine = @import("engine.zig");
const store = @import("store.zig");
const acp = @import("acp.zig");

pub const Kind = enum { mock, spark, wonder, baseten, acp, compat };

/// What a model call is for. Every task uses the same endpoint and model
/// per backend today; callers pass it so routing can split per task later
/// without touching them.
pub const Task = enum { repair, voice, verify, judge, enrich };

pub const Error = error{ ToolFailed, OutOfMemory, WriteFailed } || std.process.RunError;

pub fn parseKind(name: []const u8) ?Kind {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, 0..) |fname, i| {
        if (std.mem.eql(u8, name, fname)) return @fromBackingInt(@intCast(info.field_values[i]));
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
    // Mock counts the slice a live call would carry so eval numbers
    // measure the real context economy.
    if (kind == .mock) ctx.countCall(repair_prefix, try repairUser(ctx, region, first_line, diag));
    return switch (kind) {
        .mock => mockPatch(ctx, region, first_line, diag),
        .spark, .wonder, .baseten, .compat, .acp => remotePatch(ctx, kind, region, first_line, diag),
    };
}

/// Whether `kind` needs MODEL_API_KEY in the environment. `mock` is
/// canned, `acp` runs a local agent subprocess, and `compat` takes an
/// optional KNAP_COMPAT_KEY instead — none of them see MODEL_API_KEY.
pub fn needsKey(kind: Kind) bool {
    return switch (kind) {
        .mock, .acp, .compat => false,
        .spark, .wonder, .baseten => true,
    };
}

/// One line for `knap-mcp backends`: what `kind` needs, and whether this
/// environment has it. Nothing is probed.
pub fn statusLine(ctx: *Ctx, kind: Kind) []const u8 {
    return switch (kind) {
        .mock => "always available (canned patches)",
        .spark, .wonder, .baseten => if (ctx.environ.get("MODEL_API_KEY") != null)
            "MODEL_API_KEY set — live calls enabled"
        else
            "needs MODEL_API_KEY",
        .acp => if (acp.agentName(ctx)) |name|
            std.fmt.allocPrint(ctx.arena, "KNAP_ACP_AGENT set — live calls via '{s}'", .{name}) catch "KNAP_ACP_AGENT set"
        else
            "needs KNAP_ACP_AGENT (e.g. `devin acp --agent-type summarizer`)",
        .compat => compat: {
            if (envFor(ctx, kind, "URL") == null) break :compat "needs KNAP_COMPAT_URL (any OpenAI-compatible endpoint)";
            if (envFor(ctx, kind, "MODEL") == null) break :compat "needs KNAP_COMPAT_MODEL";
            break :compat if (envFor(ctx, kind, "KEY") != null)
                "KNAP_COMPAT_KEY set — live calls enabled"
            else
                "no KNAP_COMPAT_KEY — unauthenticated calls";
        },
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
        return if (hasUnclosedBlock(region, "if", "endif"))
            try std.fmt.allocPrint(ctx.arena, "{s}{{% endif %}}\n", .{region})
        else
            null;
    if (contains(d, "unclosed for block"))
        return if (hasUnclosedBlock(region, "for", "endfor"))
            try std.fmt.allocPrint(ctx.arena, "{s}{{% endfor %}}\n", .{region})
        else
            null;
    if (contains(d, "no filter named") or contains(diag.kind, "unknown filter"))
        return stripUnknownFilter(ctx, region, first_line, diag);

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

/// True while `region` holds more `{% open_kw %}` tags than `{% close_kw %}`
/// ones — the unclosed-block fix only applies when an opener is genuinely
/// unmatched; a substring in text must not append a closer.
fn hasUnclosedBlock(region: []const u8, comptime open_kw: []const u8, comptime close_kw: []const u8) bool {
    var depth: i64 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, region, pos, "{%")) |t| {
        const end = std.mem.indexOfPos(u8, region, t + 2, "%}") orelse break;
        const body = std.mem.trim(u8, region[t + 2 .. end], " \t");
        if (startsKw(body, open_kw)) {
            depth += 1;
        } else if (startsKw(body, close_kw)) {
            depth -= 1;
        }
        pos = end + 2;
    }
    return depth > 0;
}

/// `body` leads with the `{%` keyword `kw` (`"if a"` / `"endif"`, never
/// `"ifdef"` or `"endifx"`).
fn startsKw(body: []const u8, kw: []const u8) bool {
    return std.mem.startsWith(u8, body, kw) and
        (body.len == kw.len or !isIdent(body[kw.len]));
}

/// Filter names the pinned k4o registers — `filters.entries` at
/// aeba163 (each module's `names`: markup, text, numbers, dates,
/// collections, extensions, advanced, html). The blocked host-only names
/// (`html_to_json`, `remove_html`) are left out: renaming a typo to one
/// of those only swaps the diagnostic for an unfixable one.
const known_filters = [_][]const u8{
    "h1",            "h2",            "h3",            "h4",
    "h5",            "h6",            "bold",          "italic",
    "code",          "code_block",    "blockquote",    "list",
    "link",          "image",         "hr",            "hard_break",
    "escape_md",     "fragment_link", "embed",         "camel",
    "capitalize",    "kebab",         "lower",         "pascal",
    "snake",         "title",         "uncamel",       "upper",
    "trim",          "truncate",      "truncatewords", "indent",
    "unescape",      "safe_name",     "encode_uri",    "decode_uri",
    "calc",          "number_format", "round",         "date",
    "date_modify",   "duration",      "compact",       "first",
    "join",          "last",          "length",        "merge",
    "nth",           "object",        "parse_json",    "reverse",
    "slice",         "sort",          "split",         "sum",
    "unique",        "where",         "callout",       "wikilink",
    "footnote",      "strike",        "table",         "table_pretty",
    "highlight",     "math",          "math_block",    "comment",
    "map",           "template",      "replace",       "yaml",
    "yaml_property", "remove_attr",   "strip_attr",    "remove_tags",
    "replace_tags",  "strip_tags",    "strip_md",      "stripmd",
};

/// The registered filter `name` most plausibly mistyped, or null when no
/// candidate qualifies or the best distance is tied. Two shapes count as
/// the same edit distance 1 typo: Levenshtein distance ≤ 2, and one
/// contiguous run of ≤ 3 extra characters — the seeded corruptions
/// stretch a name (`h2` → `head2`, `wikilink` → `wiki_link`) rather than
/// shuffle it. Candidates must share the first letter: the corruptions
/// never change it, and a different initial is a different word (`url`
/// is not `hr`). A tie means the typo is ambiguous (`hr2` could be `hr`
/// or `h2`) and the filter is stripped.
fn bestFilterMatch(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var best: ?[]const u8 = null;
    var best_d: usize = 3; // accept distances 1 and 2
    var tied = false;
    for (known_filters) |k| {
        if (k[0] != name[0]) continue;
        var d = levenshtein(name, k);
        if (singleRunDiff(name, k)) |run| {
            if (run <= 3) d = @min(d, 1);
        }
        if (d < best_d) {
            best = k;
            best_d = d;
            tied = false;
        } else if (d == best_d) {
            tied = true;
        }
    }
    return if (tied) null else best;
}

/// Ordinary Levenshtein distance; names are short, so a 64-entry row is
/// ample and anything longer just reports "too far".
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 63 or b.len > 63) return a.len + b.len;
    var prev: [64]usize = undefined;
    var cur: [64]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        cur[0] = i;
        for (b, 1..) |cb, j| {
            cur[j] = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + @intFromBool(ca != cb));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// `a` is `b` with one contiguous run of characters inserted or removed:
/// returns the run's length (`head2`/`h2` → 3, `wiki_link`/`wikilink` →
/// 1), or null when the difference is more than one run.
fn singleRunDiff(a: []const u8, b: []const u8) ?usize {
    const lo, const hi = if (a.len <= b.len) .{ a, b } else .{ b, a };
    var p: usize = 0;
    while (p < lo.len and lo[p] == hi[p]) p += 1;
    var s: usize = 0;
    while (s < lo.len - p and lo[lo.len - 1 - s] == hi[hi.len - 1 - s]) s += 1;
    return if (p + s == lo.len) hi.len - lo.len else null;
}

/// `no filter named "head2"` → rename `| head2` to the registered filter
/// it most plausibly mistyped (`| h2`), or drop the filter (and its
/// `:arg`, if any) from the `{{ }}` tag the diagnostic points at when no
/// candidate qualifies — an earlier tag may legitimately use the same
/// name.
fn stripUnknownFilter(ctx: *Ctx, region: []const u8, first_line: u32, diag: engine.Diag) !?[]const u8 {
    const detail = diag.detail;
    const q1 = std.mem.indexOfScalar(u8, detail, '"') orelse return null;
    const rest = detail[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..q2];
    const at = offsetOf(region, first_line, diag.line, diag.col) orelse return null;
    const rename = bestFilterMatch(name);
    // The filter lives in the `{{` tag still open at `at`.
    const open = std.mem.lastIndexOf(u8, region[0..@min(at, region.len)], "{{") orelse return null;
    if (std.mem.indexOf(u8, region[open..at], "}}") != null) return null;
    const limit = std.mem.indexOfPos(u8, region, open, "}}") orelse region.len;
    var pos = open;
    while (std.mem.indexOfScalarPos(u8, region, pos, '|')) |pipe| : (pos = pipe + 1) {
        if (pipe >= limit) return null;
        var i = pipe + 1;
        while (i < region.len and region[i] == ' ') i += 1;
        if (!std.mem.startsWith(u8, region[i..], name)) continue;
        const name_at = i;
        i += name.len;
        if (i < region.len and isIdent(region[i])) continue;
        // A rename keeps the `:` argument list where it stands.
        if (rename) |r| return try splice(ctx, region, name_at, i, r);
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

/// The repair user message a live call carries: the diagnostic, then the
/// region around it. The mock path counts it as the slice it would send.
fn repairUser(ctx: *Ctx, region: []const u8, first_line: u32, diag: engine.Diag) Error![]const u8 {
    var user: std.Io.Writer.Allocating = .init(ctx.arena);
    try user.writer.print(
        "diagnostic: {s} at line {d}, column {d}: {s}\n\nregion (starts at line {d}):\n{s}\n",
        .{ diag.kind, diag.line, diag.col, diag.detail, first_line, region },
    );
    return user.written();
}

fn remotePatch(ctx: *Ctx, kind: Kind, region: []const u8, first_line: u32, diag: engine.Diag) Error!?[]const u8 {
    const reply = try completeReply(ctx, kind, .repair, repair_prefix, try repairUser(ctx, region, first_line, diag));
    // A region cut off at the token cap can still validate with template
    // lines silently dropped; treat it as no proposal.
    if (reply.truncated()) return null;
    const patch = sanitizePatch(reply.content) orelse return null;
    // The model trims the region's final newline about half the time;
    // without it the splice glues the next template line onto this one.
    if (std.mem.endsWith(u8, region, "\n") and !std.mem.endsWith(u8, patch, "\n"))
        return try std.fmt.allocPrint(ctx.arena, "{s}\n", .{patch});
    return patch;
}

/// A live model wraps its answer in fences, prose, or a whole-document
/// rewrite about as often as it obeys "region only". Strip one
/// surrounding code fence and reject a reply that still looks fenced or
/// echoes the prompt — the loop degrades to non-convergence instead of
/// splicing garbage into the template.
fn sanitizePatch(body: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return null;
        s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, s, "```")) s = std.mem.trimEnd(u8, s[0 .. s.len - 3], " \t\r\n");
    }
    if (s.len == 0) return null;
    if (std.mem.indexOf(u8, s, "```") != null) return null;
    if (std.mem.indexOf(u8, s, "region (starts at line") != null) return null;
    return s;
}

/// Where a live backend's calls go. Each field resolves from the
/// environment before the built-in default, so the real ids `GET
/// /v1/models` reports are a config change, not a code change:
///
///   KNAP_<KIND>_URL          chat-completions endpoint
///   KNAP_<KIND>_MODEL        model id
///   KNAP_<KIND>_MODELS_URL   model list (default: URL with
///                            `/chat/completions` → `/models`)
///   KNAP_<KIND>_TEMPERATURE  number in [0, 2], or `omit`; falls back to
///                            KNAP_TEMPERATURE, then 0
///
/// `<KIND>` is SPARK, WONDER, BASETEN or COMPAT. KNAP_BASETEN_URL predates
/// the scheme and keeps its meaning. For `compat` there is no built-in:
/// KNAP_COMPAT_URL and KNAP_COMPAT_MODEL are required.
pub const Endpoint = struct {
    url: []const u8,
    model: []const u8,
    models_url: ?[]const u8,
    /// null: the request carries no `temperature` field at all.
    temperature: ?f64,
};

/// The built-in ids are the plan's best guess (next-phase-plan §3) and
/// are UNCONFIRMED until the live smoke (#89) runs `GET /v1/models`.
fn defaultEndpoint(kind: Kind) struct { url: []const u8, model: []const u8 } {
    return switch (kind) {
        .spark => .{ .url = "https://api.meta.ai/v1/chat/completions", .model = "muse-spark-1.3" },
        .wonder => .{ .url = "https://api.meta.ai/v1/chat/completions", .model = "muse-wonder-1.0" },
        .baseten => .{ .url = "https://api.baseten.co/v1/chat/completions", .model = "meta-models/muse-spark-open-1026" },
        .mock, .acp, .compat => .{ .url = "", .model = "" },
    };
}

/// `KNAP_<KIND>_<suffix>`, built at compile time.
fn envName(comptime kind: Kind, comptime suffix: []const u8) []const u8 {
    comptime {
        var upper: [@tagName(kind).len]u8 = undefined;
        _ = std.ascii.upperString(&upper, @tagName(kind));
        const name = "KNAP_" ++ upper ++ "_" ++ suffix;
        return name;
    }
}

/// The non-empty value of `KNAP_<KIND>_<suffix>`, or null.
fn envFor(ctx: *Ctx, kind: Kind, comptime suffix: []const u8) ?[]const u8 {
    const v = switch (kind) {
        inline else => |k| ctx.environ.get(comptime envName(k, suffix)),
    } orelse return null;
    const t = std.mem.trim(u8, v, " \t\r\n");
    return if (t.len == 0) null else t;
}

/// Resolve `kind`'s endpoint, model and sampling settings. A malformed
/// temperature fails here, before any request is staged.
pub fn endpoint(ctx: *Ctx, kind: Kind) error{ToolFailed}!Endpoint {
    if (kind == .mock or kind == .acp) return ctx.fail("backend '{s}' has no endpoint", .{@tagName(kind)});
    const d = defaultEndpoint(kind);
    const url = envFor(ctx, kind, "URL") orelse d.url;
    const model = envFor(ctx, kind, "MODEL") orelse d.model;
    if (kind == .compat) {
        if (url.len == 0) return ctx.fail("backend 'compat' needs KNAP_COMPAT_URL", .{});
        if (model.len == 0) return ctx.fail("backend 'compat' needs KNAP_COMPAT_MODEL", .{});
    }
    return .{
        .url = url,
        .model = model,
        .models_url = envFor(ctx, kind, "MODELS_URL") orelse modelsUrlFrom(ctx.arena, url),
        .temperature = try temperatureFor(ctx, kind),
    };
}

/// `…/v1/chat/completions` → `…/v1/models`; null for any other shape.
fn modelsUrlFrom(arena: std.mem.Allocator, chat_url: []const u8) ?[]const u8 {
    const tail = "/chat/completions";
    const u = std.mem.trimEnd(u8, chat_url, "/");
    if (!std.mem.endsWith(u8, u, tail)) return null;
    return std.fmt.allocPrint(arena, "{s}/models", .{u[0 .. u.len - tail.len]}) catch null;
}

/// Reasoning models may reject `temperature: 0`, so it is a setting, not
/// an assumption: `omit` (or `none`) drops the field. Anything else must
/// be a finite number in [0, 2]; it is re-printed, never passed through,
/// so the request body stays valid JSON.
fn temperatureFor(ctx: *Ctx, kind: Kind) error{ToolFailed}!?f64 {
    const raw = envFor(ctx, kind, "TEMPERATURE") orelse
        std.mem.trim(u8, ctx.environ.get("KNAP_TEMPERATURE") orelse "", " \t\r\n");
    if (raw.len == 0) return 0;
    if (std.ascii.eqlIgnoreCase(raw, "omit") or std.ascii.eqlIgnoreCase(raw, "none")) return null;
    const v = std.fmt.parseFloat(f64, raw) catch
        return ctx.fail("temperature '{s}' is not a number or 'omit'", .{raw});
    if (!(v >= 0 and v <= 2)) return ctx.fail("temperature '{s}' is outside [0, 2]", .{raw});
    return v;
}

/// Token counts from a reply's `usage`, when the provider meters them.
/// Absent fields stay null: the numbers card shows tokens only when they
/// were actually reported, never estimated.
pub const Usage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    /// Hidden reasoning tokens, when the provider breaks them out.
    reasoning_tokens: ?u64 = null,

    pub fn metered(u: Usage) bool {
        return u.prompt_tokens != null or u.completion_tokens != null or u.total_tokens != null;
    }
};

/// One parsed chat completion. `content` is the answer only — reasoning
/// that arrived in a separate field, a reasoning part, or a leading
/// `<think>` block is moved to `reasoning`, so JSON-only callers parse
/// the answer and nothing else.
pub const Reply = struct {
    content: []const u8,
    reasoning: ?[]const u8 = null,
    finish_reason: ?[]const u8 = null,
    usage: Usage = .{},

    /// The provider stopped at its token cap; the answer is cut off.
    pub fn truncated(r: Reply) bool {
        const f = r.finish_reason orelse return false;
        return std.mem.eql(u8, f, "length") or std.mem.eql(u8, f, "max_tokens");
    }
};

/// One chat completion on a live backend: resolves the endpoint and model
/// for `kind`, needs MODEL_API_KEY, returns the first choice's content.
/// `mock` has no endpoint; callers keep their own canned path for it.
pub fn complete(ctx: *Ctx, kind: Kind, task: Task, system: []const u8, user: []const u8) Error![]const u8 {
    return (try completeReply(ctx, kind, task, system, user)).content;
}

/// `complete`, keeping the reasoning, finish reason and token usage.
pub fn completeReply(ctx: *Ctx, kind: Kind, task: Task, system: []const u8, user: []const u8) Error!Reply {
    if (kind == .mock)
        return ctx.fail("backend 'mock' has no live completion (task '{s}')", .{@tagName(task)});
    if (kind == .acp) return acpReply(ctx, task, system, user);
    const key = try apiKey(ctx, kind);
    const ep = try endpoint(ctx, kind);
    ctx.countCall(system, user);
    const reply = try chatCompletion(ctx, ep, key, system, user);
    ctx.countUsage(reply.usage);
    if (ctx.environ.get("KNAP_DEBUG") != null) {
        const u = reply.usage;
        std.debug.print("knap-mcp: {s}/{s} model={s} finish={s} usage prompt={?d} completion={?d} total={?d} reasoning={?d}\n", .{
            @tagName(kind),  @tagName(task),      ep.model,       reply.finish_reason orelse "-",
            u.prompt_tokens, u.completion_tokens, u.total_tokens, u.reasoning_tokens,
        });
    }
    return reply;
}

/// One ACP turn as a Reply. ACP prompts have no system role, so the
/// system prefix leads the one text block. The agent's text goes through
/// the same `<think>` split as an HTTP reply, and every caller's own
/// scrubber after that. `stopReason` stands in for `finish_reason`:
/// `max_tokens` reads as truncated, and a `refusal` is no answer.
fn acpReply(ctx: *Ctx, task: Task, system: []const u8, user: []const u8) Error!Reply {
    _ = try acp.requireAgent(ctx);
    ctx.countCall(system, user);
    const turn = try acp.prompt(ctx, try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ system, user }));
    var reasoning: std.Io.Writer.Allocating = .init(ctx.arena);
    const answer = if (std.mem.eql(u8, turn.stop_reason, "refusal")) "" else try splitThink(&reasoning.writer, turn.text);
    const r = reasoning.written();
    const reply: Reply = .{
        .content = answer,
        .reasoning = if (r.len > 0) r else null,
        .finish_reason = if (turn.stop_reason.len > 0) turn.stop_reason else null,
        .usage = parseUsage(turn.usage),
    };
    if (ctx.environ.get("KNAP_DEBUG") != null) {
        const u = reply.usage;
        std.debug.print("knap-mcp: acp/{s} agent={s} stop={s} usage prompt={?d} completion={?d} total={?d} reasoning={?d}\n", .{
            @tagName(task),     acp.agentName(ctx) orelse "-", reply.finish_reason orelse "-",
            u.prompt_tokens,    u.completion_tokens,           u.total_tokens,
            u.reasoning_tokens,
        });
    }
    return reply;
}

/// The bearer token for `kind`. `compat` reads only KNAP_COMPAT_KEY and
/// treats it as optional: "" means no Authorization header is sent, which
/// is what local proxies (CLIProxyAPI, ollama, llama.cpp) expect.
/// MODEL_API_KEY is never consulted for compat.
fn apiKey(ctx: *Ctx, kind: Kind) error{ToolFailed}![]const u8 {
    if (kind == .compat) return envFor(ctx, kind, "KEY") orelse "";
    const key = ctx.environ.get("MODEL_API_KEY") orelse "";
    if (key.len == 0) return ctx.fail("backend '{s}' needs MODEL_API_KEY", .{@tagName(kind)});
    return key;
}

/// The model ids `kind`'s provider serves (`GET /v1/models`), so the
/// smoke can confirm the KNAP_<KIND>_MODEL to set.
pub fn listModels(ctx: *Ctx, kind: Kind) Error![]const []const u8 {
    if (kind == .mock or kind == .acp) return ctx.fail("backend '{s}' has no model list", .{@tagName(kind)});
    const key = try apiKey(ctx, kind);
    const ep = try endpoint(ctx, kind);
    const url = ep.models_url orelse
        return ctx.fail("cannot derive a models URL from '{s}'; set {s}", .{ ep.url, switch (kind) {
            inline else => |k| comptime envName(k, "MODELS_URL"),
        } });
    warnProjectTreeStore(ctx);
    const r = try curl(ctx, url, key, null);
    if (r.exit != 0) return httpFail(ctx, r);
    return parseModelIds(ctx, r.body);
}

/// Model ids from a model-list reply. OpenAI's shape is `{"data":[{"id":
/// …}]}`; `{"models":[…]}`, a bare array, string items and `name` in place
/// of `id` are accepted too, since the providers' shape is unconfirmed.
fn parseModelIds(ctx: *Ctx, body: []const u8) Error![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, body, .{}) catch
        return ctx.fail("backend model list is not JSON", .{});
    const list = switch (parsed) {
        .array => parsed,
        else => getPath(parsed, &.{"data"}) orelse getPath(parsed, &.{"models"}) orelse
            return ctx.fail("backend model list has no data array", .{}),
    };
    if (list != .array) return ctx.fail("backend model list has no data array", .{});
    var ids: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        const id = switch (item) {
            .string => |s| s,
            else => str(getPath(item, &.{"id"})) orelse str(getPath(item, &.{"name"})) orelse continue,
        };
        try ids.append(ctx.arena, id);
    }
    return ids.items;
}

/// The chat-completions request body. `temperature` null leaves the
/// field out.
fn requestBody(arena: std.mem.Allocator, model: []const u8, system: []const u8, user_msg: []const u8, temperature: ?f64) Error![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(arena);
    try payload.writer.print("{{\"model\":", .{});
    try std.json.Stringify.value(model, .{}, &payload.writer);
    try payload.writer.print(",\"messages\":[{{\"role\":\"system\",\"content\":", .{});
    try std.json.Stringify.value(system, .{}, &payload.writer);
    try payload.writer.print("}},{{\"role\":\"user\",\"content\":", .{});
    try std.json.Stringify.value(user_msg, .{}, &payload.writer);
    try payload.writer.writeAll("}]");
    if (temperature) |t| try payload.writer.print(",\"temperature\":{d}", .{t});
    try payload.writer.writeAll("}");
    return payload.written();
}

/// POST an OpenAI-compatible chat completion through curl and parse the
/// first choice. A 400/422 that names `temperature` is retried once
/// without the field — reasoning models may refuse any explicit value.
fn chatCompletion(ctx: *Ctx, ep: Endpoint, key: []const u8, system: []const u8, user_msg: []const u8) Error!Reply {
    warnProjectTreeStore(ctx);
    var temperature = ep.temperature;
    while (true) {
        const r = try curl(ctx, ep.url, key, try requestBody(ctx.arena, ep.model, system, user_msg, temperature));
        if (r.exit == 0) return parseReply(ctx, r.body);
        if (temperature != null and rejectsTemperature(r)) {
            std.debug.print("knap-mcp: model '{s}' rejected temperature; retrying without it (set KNAP_TEMPERATURE=omit to skip)\n", .{ep.model});
            temperature = null;
            continue;
        }
        return httpFail(ctx, r);
    }
}

fn rejectsTemperature(r: Http) bool {
    return (r.status == 400 or r.status == 422) and std.mem.indexOf(u8, r.body, "temperature") != null;
}

/// One finished curl call: exit code, HTTP status (0 when none came
/// back), body with the status line split off, and stderr.
const Http = struct { exit: u8, status: u32, body: []const u8, stderr: []const u8 };

fn httpFail(ctx: *Ctx, r: Http) error{ToolFailed} {
    if (r.status >= 400)
        return ctx.fail("backend http {d}: {s}", .{ r.status, brief(if (r.body.len > 0) r.body else r.stderr) });
    return ctx.fail("backend request failed (curl exit {d}): {s}", .{ r.exit, brief(r.stderr) });
}

/// One authenticated request through curl: a POST of `payload` when
/// given, else a GET.
fn curl(ctx: *Ctx, url: []const u8, key: []const u8, payload: ?[]const u8) Error!Http {
    var argv: std.ArrayList([]const u8) = .empty;
    const total_secs = ctx.envSecs("KNAP_CURL_TIMEOUT", 60);
    // `-m`/`--connect-timeout` bound the call curl-side (`KNAP_CURL_TIMEOUT`
    // default 60s, `KNAP_CURL_CONNECT_TIMEOUT` default 10s); the process
    // deadline adds 15s of slack as a backstop in case curl itself wedges.
    // `-w` appends the HTTP status after the body so `--fail-with-body`
    // can keep the provider's error payload.
    try argv.appendSlice(ctx.arena, &.{
        "curl", "-sS",                                                   "--fail-with-body",  "-X",                                                                                      if (payload != null) "POST" else "GET", url,
        "-m",   try std.fmt.allocPrint(ctx.arena, "{d}", .{total_secs}), "--connect-timeout", try std.fmt.allocPrint(ctx.arena, "{d}", .{ctx.envSecs("KNAP_CURL_CONNECT_TIMEOUT", 10)}), "-K",                                   "-",
        "-w",   "\n%{http_code}",
    });

    // The request body goes through an owner-only scratch file, not argv,
    // so the prompt doesn't show up in `ps`. The API key never touches
    // disk: curl reads it as a `-K -` config stream on stdin.
    var body_path: ?[]const u8 = null;
    defer if (body_path) |p| std.Io.Dir.deleteFile(.cwd(), ctx.io, p) catch {};
    if (payload) |data| {
        const path = try store.scratchFile(ctx, "json");
        body_path = path;
        const Permissions = std.Io.File.Permissions;
        const private: std.Io.Dir.CreateFileOptions = .{
            .permissions = if (@hasDecl(Permissions, "fromMode")) Permissions.fromMode(0o600) else .default_file,
        };
        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = data, .flags = private }) catch
            return ctx.fail("cannot stage backend request body", .{});
        try argv.appendSlice(ctx.arena, &.{
            "-H",            "Content-Type: application/json",
            "--data-binary", try std.fmt.allocPrint(ctx.arena, "@{s}", .{path}),
        });
    }

    const config = try authConfig(ctx.arena, key);
    const result = try runCurl(ctx, argv.items, config, if (total_secs == 0) .none else ctx.deadline(total_secs + 15));
    const exit = switch (result.term) {
        .exited => |code| code,
        else => return ctx.fail("curl terminated abnormally", .{}),
    };
    const body, const status = splitStatus(result.stdout);
    return .{ .exit = exit, .status = status, .body = body, .stderr = result.stderr };
}

/// The curl `-K -` config stream: just the Authorization header, or empty
/// when `key` is "" — an empty `Bearer ` token is worse than no header
/// (some proxies reject it outright).
fn authConfig(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (key.len == 0) return "";
    return std.fmt.allocPrint(arena, "header = \"Authorization: Bearer {s}\"\n", .{key});
}

/// `-w` appends "\n<status>" after the body; split them back apart.
fn splitStatus(out: []const u8) struct { []const u8, u32 } {
    const i = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return .{ out, 0 };
    const s = std.fmt.parseInt(u32, std.mem.trim(u8, out[i + 1 ..], " \r"), 10) catch 0;
    return if (s > 0) .{ out[0..i], s } else .{ out, 0 };
}

/// Parse a chat-completion reply defensively. Structural breakage (not
/// JSON, an `error` object, no choices, content of an unknown type) is a
/// ToolFailed, which every caller degrades (repair to non-convergence,
/// voice to a rejected field). An empty or reasoning-only answer is not:
/// it comes back as empty content, and callers already treat that as
/// "no proposal". Accepted shapes, since the providers' are unconfirmed:
///
///   - `message.content` as a string, null, or an array of parts —
///     strings, `{"type":"text"|"output_text","text":…}` (`text` may be
///     `{"value":…}`), reasoning parts (`reasoning`/`thinking`), others
///     (images, refusals) skipped;
///   - reasoning in `message.reasoning_content` or `message.reasoning`,
///     or a leading `<think>…</think>` block in the content;
///   - a legacy `choices[0].text`;
///   - `usage` with OpenAI (`prompt_tokens`/`completion_tokens`) or
///     `input_tokens`/`output_tokens` names, plus `*_tokens_details.
///     reasoning_tokens`.
fn parseReply(ctx: *Ctx, body: []const u8) Error!Reply {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, body, .{}) catch
        return ctx.fail("backend returned non-JSON", .{});
    const choices = getPath(parsed, &.{"choices"}) orelse {
        if (getPath(parsed, &.{"error"})) |e| {
            const msg = str(getPath(e, &.{"message"})) orelse str(e) orelse brief(body);
            return ctx.fail("backend error: {s}", .{brief(msg)});
        }
        return ctx.fail("backend reply has no choices", .{});
    };
    if (choices != .array) return ctx.fail("backend choices is not an array", .{});
    if (choices.array.items.len == 0) return ctx.fail("backend reply has empty choices", .{});
    const first = choices.array.items[0];

    var content: std.Io.Writer.Allocating = .init(ctx.arena);
    var reasoning: std.Io.Writer.Allocating = .init(ctx.arena);
    if (getPath(first, &.{"message"})) |msg| {
        switch (getPath(msg, &.{"content"}) orelse std.json.Value.null) {
            .null => {},
            .string => |s| try content.writer.writeAll(s),
            .array => |parts| for (parts.items) |part| try appendPart(&content.writer, &reasoning.writer, part),
            else => return ctx.fail("backend message.content is not a string or parts array", .{}),
        }
        inline for (.{ "reasoning_content", "reasoning" }) |field| {
            if (str(getPath(msg, &.{field}))) |r| try reasoning.writer.writeAll(r);
        }
    } else if (str(getPath(first, &.{"text"}))) |t| {
        try content.writer.writeAll(t);
    } else return ctx.fail("backend reply has no message.content", .{});

    const answer = try splitThink(&reasoning.writer, content.written());
    const r = reasoning.written();
    return .{
        .content = answer,
        .reasoning = if (r.len > 0) r else null,
        .finish_reason = str(getPath(first, &.{"finish_reason"})) orelse str(getPath(first, &.{"stop_reason"})),
        .usage = parseUsage(getPath(parsed, &.{"usage"})),
    };
}

/// One `message.content` part: answer text to `content`, reasoning to
/// `reasoning`, anything else dropped.
fn appendPart(content: *std.Io.Writer, reasoning: *std.Io.Writer, part: std.json.Value) !void {
    switch (part) {
        .string => |s| return content.writeAll(s),
        .object => {},
        else => return,
    }
    const ty = str(getPath(part, &.{"type"})) orelse "text";
    const text = str(getPath(part, &.{"text"})) orelse str(getPath(part, &.{ "text", "value" }));
    if (std.mem.eql(u8, ty, "text") or std.mem.eql(u8, ty, "output_text")) {
        if (text) |t| try content.writeAll(t);
    } else if (std.mem.eql(u8, ty, "reasoning") or std.mem.eql(u8, ty, "thinking")) {
        if (text orelse str(getPath(part, &.{"thinking"})) orelse str(getPath(part, &.{"reasoning"}))) |t|
            try reasoning.writeAll(t);
    }
}

/// Move a leading `<think>…</think>` block into `reasoning` and return
/// the answer after it. An unclosed block is all reasoning: no answer.
fn splitThink(reasoning: *std.Io.Writer, content: []const u8) ![]const u8 {
    const open = "<think>";
    const close = "</think>";
    const s = std.mem.trimStart(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, s, open)) return content;
    const end = std.mem.indexOf(u8, s, close) orelse {
        try reasoning.writeAll(s[open.len..]);
        return "";
    };
    try reasoning.writeAll(std.mem.trim(u8, s[open.len..end], " \t\r\n"));
    return std.mem.trimStart(u8, s[end + close.len ..], " \t\r\n");
}

fn parseUsage(v: ?std.json.Value) Usage {
    const u = v orelse return .{};
    return .{
        .prompt_tokens = tokens(getPath(u, &.{"prompt_tokens"})) orelse tokens(getPath(u, &.{"input_tokens"})) orelse
            tokens(getPath(u, &.{"inputTokens"})),
        .completion_tokens = tokens(getPath(u, &.{"completion_tokens"})) orelse tokens(getPath(u, &.{"output_tokens"})) orelse
            tokens(getPath(u, &.{"outputTokens"})),
        .total_tokens = tokens(getPath(u, &.{"total_tokens"})) orelse tokens(getPath(u, &.{"totalTokens"})),
        .reasoning_tokens = tokens(getPath(u, &.{ "completion_tokens_details", "reasoning_tokens" })) orelse
            tokens(getPath(u, &.{ "output_tokens_details", "reasoning_tokens" })) orelse
            tokens(getPath(u, &.{"thoughtTokens"})),
    };
}

/// A non-negative whole token count, however the provider encoded it.
fn tokens(v: ?std.json.Value) ?u64 {
    return switch (v orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0 and f < 1e15 and @floor(f) == f) @intFromFloat(f) else null,
        .number_string, .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// `std.process.run` plus a stdin payload (the curl `-K -` config stream)
/// and an absolute-deadline timeout; on timeout the child is killed and a
/// ToolFailed surfaces instead of a hung server.
fn runCurl(
    ctx: *Ctx,
    argv: []const []const u8,
    stdin_data: []const u8,
    timeout: std.Io.Timeout,
) Error!std.process.RunResult {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("curl failed: {s}", .{@errorName(e)}),
    };
    defer child.kill(ctx.io);

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(ctx.io, stdin_data) catch {};
        stdin.close(ctx.io);
        child.stdin = null;
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(ctx.arena, ctx.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);
    while (multi.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > 8 * 1024 * 1024 or
            stderr_reader.buffered().len > 64 * 1024)
            return ctx.fail("curl output exceeded limit", .{});
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return ctx.fail("curl timed out; the backend is unreachable or hung", .{}),
        else => |e| return ctx.fail("curl read failed: {s}", .{@errorName(e)}),
    }
    multi.checkAnyError() catch |e| return ctx.fail("curl read failed: {s}", .{@errorName(e)});
    const term = child.wait(ctx.io) catch |e| return ctx.fail("curl wait failed: {s}", .{@errorName(e)});
    return .{
        .term = term,
        .stdout = try multi.toOwnedSlice(0),
        .stderr = try multi.toOwnedSlice(1),
    };
}

/// Tool errors carry a bounded slice of provider/curl output — a hostile
/// endpoint can't bloat every response it trips. The cut never splits a
/// UTF-8 codepoint.
pub fn brief(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    var end = @min(t.len, 300);
    while (end > 0 and end < t.len and (t[end] & 0xC0) == 0x80) end -= 1;
    return t[0..end];
}

/// Live calls stage non-secret scratch files under store_dir; warn once
/// when that's the project tree (KNAP_MCP_HOME unset or relative) so a
/// file stranded by a crash can't be committed by accident.
fn warnProjectTreeStore(ctx: *Ctx) void {
    if (ctx.store_warned or std.fs.path.isAbsolute(ctx.store_dir)) return;
    ctx.store_warned = true;
    std.debug.print(
        "knap-mcp: warning: store dir '{s}' is inside the project tree; set KNAP_MCP_HOME to a private dir for live backends\n",
        .{ctx.store_dir},
    );
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
}

test "mock renames an unknown filter to its unique registry match" {
    // The seeded corruption `| h2` → `| head2`: one inserted run of 3.
    try expectMock("{{ t | head2 }}\n", 1, 8, "no filter named \"head2\"", "{{ t | h2 }}\n");
    // Same shape, one inserted character.
    try expectMock("{{ x | wiki_link }}\n", 1, 8, "no filter named \"wiki_link\"", "{{ x | wikilink }}\n");
    // An ordinary typo within Levenshtein 2.
    try expectMock("{{ t | h20 }}\n", 1, 8, "no filter named \"h20\"", "{{ t | h2 }}\n");
    // Only the tag holding the diagnostic column gets the rename.
    try expectMock("{{ t | head22 }}{{ t | head2 }}", 1, 24, "no filter named \"head2\"", "{{ t | head22 }}{{ t | h2 }}");
}

test "mock strips an unknown filter with no unique match" {
    // Ambiguous: `hr2` is one run away from both `hr` and `h2`.
    try expectMock("{{ t | hr2 }}\n", 1, 8, "no filter named \"hr2\"", "{{ t }}\n");
    // `url` is a different word, not a typo of `hr` — a candidate must
    // share the first letter.
    try expectMock("{{ t | url }}\n", 1, 8, "no filter named \"url\"", "{{ t }}\n");
    // Far off every registered name.
    try expectMock("{{ t | monospace }}\n", 1, 8, "no filter named \"monospace\"", "{{ t }}\n");
}

test "mock strips the unknown filter at the diagnostic position, not the first match" {
    // The same name in an earlier tag stays put; only the tag holding the
    // diagnostic column loses its filter.
    try expectMock("{{ a | badname }}{{ b | badname }}", 1, 22, "no filter named \"badname\"", "{{ a | badname }}{{ b }}");
    try expectMock("{{ a | badname }}{{ b | badname }}", 1, 8, "no filter named \"badname\"", "{{ a }}{{ b | badname }}");
    // A column outside every output tag gets no patch.
    try expectMock("{{ a | badname }}", 1, 1, "no filter named \"badname\"", null);
}

test "mock only closes an if/for when the region has an unmatched opener" {
    try expectMock("{% if a %}\nA\n", 1, 1, "unclosed if block", "{% if a %}\nA\n{% endif %}\n");
    try expectMock("{% for x in ys %}\n", 1, 1, "unclosed for block", "{% for x in ys %}\n{% endfor %}\n");
    // A closer for a different block leaves the if unmatched.
    try expectMock("{% if a %}\n{% endfor %}\n", 1, 1, "unclosed if block", "{% if a %}\n{% endfor %}\n{% endif %}\n");
    // Substring-in-detail drift alone must not append a closer.
    try expectMock("A\nB\n", 1, 1, "unclosed if block", null);
    try expectMock("{% if a %}\n{% endif %}\n", 1, 1, "unclosed if block", null);
    try expectMock("A\n", 1, 1, "unclosed for block", null);
}

test "sanitizePatch strips fences and rejects prose or echoed prompts" {
    try testing.expectEqualStrings("{{ x }}", sanitizePatch("```\n{{ x }}\n```").?);
    try testing.expectEqualStrings("{{ x }}", sanitizePatch("```knap\n{{ x }}\n```").?);
    try testing.expectEqualStrings("{{ x }}", sanitizePatch("  {{ x }}  \n\n").?);
    try testing.expectEqual(@as(?[]const u8, null), sanitizePatch(""));
    try testing.expectEqual(@as(?[]const u8, null), sanitizePatch("prose\n```\n{{ x }}\n```\nmore"));
    try testing.expectEqual(@as(?[]const u8, null), sanitizePatch("region (starts at line 4):\n{{ x }}"));
}

test "brief trims and caps provider noise on a codepoint boundary" {
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    try testing.expectEqual(@as(usize, 300), brief(&long).len);
    try testing.expectEqualStrings("hi", brief("  hi\n"));
    // 2 + 110*3 bytes; the 300-byte cap would split an em dash, so the
    // cut backs off to 299.
    var em: std.ArrayList(u8) = .empty;
    defer em.deinit(testing.allocator);
    try em.appendSlice(testing.allocator, "ab");
    for (0..110) |_| try em.appendSlice(testing.allocator, "—");
    try testing.expectEqual(@as(usize, 299), brief(em.items).len);
}

// --- live reply shapes -----------------------------------------------------
//
// Fixtures for the parsers above. None is captured from muse-spark,
// muse-wonder or Baseten yet: MODEL_API_KEY is pending (#85), so each is
// modeled on a public OpenAI-compatible shape and labelled with what it
// assumes. Replace them with real captures from the #89 smoke.

fn testCtx(arena: std.mem.Allocator, env: *std.process.Environ.Map) Ctx {
    var ctx: Ctx = undefined;
    ctx.arena = arena;
    ctx.environ = env;
    ctx.err_msg = "";
    return ctx;
}

fn expectReplyFails(body: []const u8, msg: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    try testing.expectError(error.ToolFailed, parseReply(&ctx, body));
    try testing.expectEqualStrings(msg, ctx.err_msg);
}

test "parseReply: OpenAI string content with usage" {
    // Assumed: plain OpenAI chat.completion, the shape chatCompletion has
    // always expected.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    const r = try parseReply(&ctx,
        \\{"id":"chatcmpl-1","object":"chat.completion","created":1793000000,"model":"muse-spark-1.3",
        \\ "choices":[{"index":0,"message":{"role":"assistant","content":"{% endif %}\n"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":412,"completion_tokens":9,"total_tokens":421}}
    );
    try testing.expectEqualStrings("{% endif %}\n", r.content);
    try testing.expectEqual(@as(?[]const u8, null), r.reasoning);
    try testing.expectEqualStrings("stop", r.finish_reason.?);
    try testing.expect(!r.truncated());
    try testing.expect(r.usage.metered());
    try testing.expectEqual(@as(?u64, 412), r.usage.prompt_tokens);
    try testing.expectEqual(@as(?u64, 9), r.usage.completion_tokens);
    try testing.expectEqual(@as(?u64, 421), r.usage.total_tokens);
    try testing.expectEqual(@as(?u64, null), r.usage.reasoning_tokens);
}

test "parseReply: content as an array of parts, reasoning part split off" {
    // Assumed: a Responses-style parts array (`output_text`, `text` with
    // a `{value}` wrapper, a `reasoning` part, an image part to skip) —
    // the #89 question "is message.content ever an array?".
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    const r = try parseReply(&ctx,
        \\{"choices":[{"message":{"role":"assistant","content":[
        \\   {"type":"reasoning","text":"The if on line 3 never closes."},
        \\   {"type":"output_text","text":"{\"value\":"},
        \\   {"type":"text","text":{"value":"\"Ship it.\"}"}},
        \\   {"type":"image_url","image_url":{"url":"data:,"}},
        \\   "\n"
        \\ ]},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":"88","completion_tokens":30.0,"total_tokens":118,
        \\          "completion_tokens_details":{"reasoning_tokens":21}}}
    );
    try testing.expectEqualStrings("{\"value\":\"Ship it.\"}\n", r.content);
    try testing.expectEqualStrings("The if on line 3 never closes.", r.reasoning.?);
    try testing.expectEqual(@as(?u64, 88), r.usage.prompt_tokens);
    try testing.expectEqual(@as(?u64, 30), r.usage.completion_tokens);
    try testing.expectEqual(@as(?u64, 21), r.usage.reasoning_tokens);
}

test "parseReply: reasoning in a separate message field" {
    // Assumed: vLLM / DeepSeek-style `reasoning_content` next to the
    // answer — the likely shape if Baseten serves the open model on vLLM.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    const r = try parseReply(&ctx,
        \\{"choices":[{"message":{"role":"assistant","reasoning_content":"Close the block.","content":"{\"value\":null}"},"finish_reason":"stop"}]}
    );
    try testing.expectEqualStrings("{\"value\":null}", r.content);
    try testing.expectEqualStrings("Close the block.", r.reasoning.?);
    try testing.expect(!r.usage.metered());
    // OpenRouter-style `reasoning` spelling.
    const r2 = try parseReply(&ctx,
        \\{"choices":[{"message":{"content":"ok","reasoning":"hmm"}}]}
    );
    try testing.expectEqualStrings("ok", r2.content);
    try testing.expectEqualStrings("hmm", r2.reasoning.?);
}

test "parseReply: a leading <think> block is reasoning, not answer" {
    // Assumed: an open reasoning model that inlines its chain of thought.
    // JSON-only callers (ratchet enrich) must see only the JSON after it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    const r = try parseReply(&ctx,
        \\{"choices":[{"message":{"content":"<think>\nThe evidence says soon.\n</think>\n\n{\"value\":\"coming soon\"}"}}]}
    );
    try testing.expectEqualStrings("{\"value\":\"coming soon\"}", r.content);
    try testing.expectEqualStrings("The evidence says soon.", r.reasoning.?);
    // Cut off mid-thought: no answer at all, and flagged truncated.
    const cut = try parseReply(&ctx,
        \\{"choices":[{"message":{"content":"<think>The if on line"},"finish_reason":"length"}],
        \\ "usage":{"input_tokens":50,"output_tokens":256,"output_tokens_details":{"reasoning_tokens":256}}}
    );
    try testing.expectEqualStrings("", cut.content);
    try testing.expect(cut.truncated());
    try testing.expectEqual(@as(?u64, 50), cut.usage.prompt_tokens);
    try testing.expectEqual(@as(?u64, 256), cut.usage.completion_tokens);
    try testing.expectEqual(@as(?u64, 256), cut.usage.reasoning_tokens);
    // `<think>` anywhere but the front is content.
    const mid = try parseReply(&ctx,
        \\{"choices":[{"message":{"content":"a <think>b</think>"}}]}
    );
    try testing.expectEqualStrings("a <think>b</think>", mid.content);
}

test "parseReply: null content, legacy text and junk usage degrade quietly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    // Assumed: an OpenAI refusal — null content, reason in `refusal`.
    const refused = try parseReply(&ctx,
        \\{"choices":[{"message":{"role":"assistant","content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":-1,"completion_tokens":1.5,"total_tokens":"lots"}}
    );
    try testing.expectEqualStrings("", refused.content);
    try testing.expect(!refused.usage.metered());
    const legacy = try parseReply(&ctx,
        \\{"choices":[{"text":"{{ x }}","finish_reason":"stop"}]}
    );
    try testing.expectEqualStrings("{{ x }}", legacy.content);
}

test "parseReply: structural breakage is a ToolFailed with a bounded message" {
    try expectReplyFails("<html>502</html>", "backend returned non-JSON");
    // Assumed: an OpenAI-style error object delivered with HTTP 200.
    try expectReplyFails(
        \\{"error":{"message":"model 'muse-spark-1.3' not found","type":"invalid_request_error"}}
    , "backend error: model 'muse-spark-1.3' not found");
    try expectReplyFails(
        \\{"error":"overloaded"}
    , "backend error: overloaded");
    try expectReplyFails("{}", "backend reply has no choices");
    try expectReplyFails(
        \\{"choices":{}}
    , "backend choices is not an array");
    try expectReplyFails(
        \\{"choices":[]}
    , "backend reply has empty choices");
    try expectReplyFails(
        \\{"choices":[{"index":0}]}
    , "backend reply has no message.content");
    try expectReplyFails(
        \\{"choices":[{"message":{"content":42}}]}
    , "backend message.content is not a string or parts array");
}

test "parseModelIds: OpenAI list, alternate keys, string items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    // Assumed: OpenAI's `GET /v1/models` list object.
    const ids = try parseModelIds(&ctx,
        \\{"object":"list","data":[
        \\  {"id":"muse-spark-1.3","object":"model","owned_by":"meta"},
        \\  {"id":"muse-wonder-1.0","object":"model","owned_by":"meta"},
        \\  {"object":"model"}
        \\]}
    );
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("muse-spark-1.3", ids[0]);
    try testing.expectEqualStrings("muse-wonder-1.0", ids[1]);
    const alt = try parseModelIds(&ctx,
        \\{"models":[{"name":"meta-models/muse-spark-open-1026"},"other"]}
    );
    try testing.expectEqual(@as(usize, 2), alt.len);
    try testing.expectEqualStrings("meta-models/muse-spark-open-1026", alt[0]);
    try testing.expectEqualStrings("other", alt[1]);
    try testing.expectError(error.ToolFailed, parseModelIds(&ctx, "{\"data\":1}"));
    try testing.expectError(error.ToolFailed, parseModelIds(&ctx, "nope"));
}

test "endpoint: defaults, per-kind overrides and derived models URL" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);
    const spark = try endpoint(&ctx, .spark);
    try testing.expectEqualStrings("https://api.meta.ai/v1/chat/completions", spark.url);
    try testing.expectEqualStrings("muse-spark-1.3", spark.model);
    try testing.expectEqualStrings("https://api.meta.ai/v1/models", spark.models_url.?);
    try testing.expectEqual(@as(?f64, 0), spark.temperature);
    try testing.expectEqualStrings("muse-wonder-1.0", (try endpoint(&ctx, .wonder)).model);
    try testing.expectEqualStrings("meta-models/muse-spark-open-1026", (try endpoint(&ctx, .baseten)).model);

    try env.put("KNAP_WONDER_MODEL", " muse-wonder-1.1 ");
    try env.put("KNAP_BASETEN_URL", "https://model-x.api.baseten.co/environments/production/sync/v1/chat/completions/");
    try env.put("KNAP_SPARK_URL", "https://proxy.example/complete");
    try env.put("KNAP_SPARK_MODEL", "");
    try testing.expectEqualStrings("muse-wonder-1.1", (try endpoint(&ctx, .wonder)).model);
    try testing.expectEqualStrings("https://model-x.api.baseten.co/environments/production/sync/v1/models", (try endpoint(&ctx, .baseten)).models_url.?);
    // A URL of another shape has no derivable model list until one is set;
    // an empty override falls back to the default.
    const proxied = try endpoint(&ctx, .spark);
    try testing.expectEqual(@as(?[]const u8, null), proxied.models_url);
    try testing.expectEqualStrings("muse-spark-1.3", proxied.model);
    try env.put("KNAP_SPARK_MODELS_URL", "https://proxy.example/models");
    try testing.expectEqualStrings("https://proxy.example/models", (try endpoint(&ctx, .spark)).models_url.?);
    try testing.expectError(error.ToolFailed, endpoint(&ctx, .mock));
}

test "endpoint: temperature is configurable, omittable and guarded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);
    try env.put("KNAP_TEMPERATURE", "0.7");
    try testing.expectEqual(@as(?f64, 0.7), (try endpoint(&ctx, .spark)).temperature);
    try env.put("KNAP_WONDER_TEMPERATURE", "omit");
    try testing.expectEqual(@as(?f64, null), (try endpoint(&ctx, .wonder)).temperature);
    try testing.expectEqual(@as(?f64, 0.7), (try endpoint(&ctx, .baseten)).temperature);
    try env.put("KNAP_BASETEN_TEMPERATURE", "NONE");
    try testing.expectEqual(@as(?f64, null), (try endpoint(&ctx, .baseten)).temperature);
    for ([_][]const u8{ "hot", "-0.1", "2.5", "nan", "inf" }) |bad| {
        try env.put("KNAP_SPARK_TEMPERATURE", bad);
        try testing.expectError(error.ToolFailed, endpoint(&ctx, .spark));
    }
    try env.put("KNAP_SPARK_TEMPERATURE", "hot");
    _ = endpoint(&ctx, .spark) catch {};
    try testing.expectEqualStrings("temperature 'hot' is not a number or 'omit'", ctx.err_msg);
}

test "requestBody: temperature 0 keeps the historical body, null drops the field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"system","content":"s"},{"role":"user","content":"u\n\"q\""}],"temperature":0}
    , try requestBody(a, "m", "s", "u\n\"q\"", 0));
    try testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}],"temperature":0.2}
    , try requestBody(a, "m", "s", "u", 0.2));
    const omitted = try requestBody(a, "m", "s", "u", null);
    try testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}]}
    , omitted);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, omitted, .{});
}

test "rejectsTemperature and splitStatus" {
    try testing.expect(rejectsTemperature(.{ .exit = 22, .status = 400, .body =
        \\{"error":{"message":"Unsupported value: 'temperature' does not support 0 with this model.","param":"temperature"}}
    , .stderr = "" }));
    try testing.expect(!rejectsTemperature(.{ .exit = 22, .status = 401, .body = "temperature", .stderr = "" }));
    try testing.expect(!rejectsTemperature(.{ .exit = 22, .status = 400, .body = "bad model", .stderr = "" }));
    const body, const status = splitStatus("{\"a\":1}\n200");
    try testing.expectEqualStrings("{\"a\":1}", body);
    try testing.expectEqual(@as(u32, 200), status);
    const b2, const s2 = splitStatus("no status");
    try testing.expectEqualStrings("no status", b2);
    try testing.expectEqual(@as(u32, 0), s2);
}

test "live entry points stay compiled without a key" {
    // Nothing calls listModels yet; referencing it keeps it type-checked.
    _ = &listModels;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    try testing.expectError(error.ToolFailed, completeReply(&ctx, .spark, .repair, "s", "u"));
    try testing.expectEqualStrings("backend 'spark' needs MODEL_API_KEY", ctx.err_msg);
    try testing.expectError(error.ToolFailed, listModels(&ctx, .wonder));
    try testing.expectEqualStrings("backend 'wonder' needs MODEL_API_KEY", ctx.err_msg);
}

// --- compat -------------------------------------------------------------------

test "compat: required vars, optional key, and MODEL_API_KEY is never read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var ctx = testCtx(a, &env);

    try testing.expectEqual(Kind.compat, parseKind("compat").?);
    try testing.expect(!needsKey(.compat));

    // No defaults: URL first, then MODEL.
    try testing.expectError(error.ToolFailed, endpoint(&ctx, .compat));
    try testing.expectEqualStrings("backend 'compat' needs KNAP_COMPAT_URL", ctx.err_msg);
    // Port 1 is never listening, so the live-path checks below fail fast.
    try env.put("KNAP_COMPAT_URL", "http://127.0.0.1:1/v1/chat/completions");
    try testing.expectError(error.ToolFailed, endpoint(&ctx, .compat));
    try testing.expectEqualStrings("backend 'compat' needs KNAP_COMPAT_MODEL", ctx.err_msg);
    try testing.expect(std.mem.startsWith(u8, statusLine(&ctx, .compat), "needs KNAP_COMPAT_MODEL"));

    // MODEL_API_KEY must not satisfy or leak into compat: the bearer stays
    // empty and authConfig emits no header for it.
    try env.put("MODEL_API_KEY", "sponsor-key");
    try env.put("KNAP_COMPAT_MODEL", "muse-spark-1.3");
    const ep = try endpoint(&ctx, .compat);
    try testing.expectEqualStrings("http://127.0.0.1:1/v1/chat/completions", ep.url);
    try testing.expectEqualStrings("muse-spark-1.3", ep.model);
    try testing.expectEqualStrings("http://127.0.0.1:1/v1/models", ep.models_url.?);
    try testing.expectEqualStrings("", try apiKey(&ctx, .compat));
    try testing.expectEqualStrings("", try authConfig(a, ""));
    try testing.expectEqualStrings("no KNAP_COMPAT_KEY — unauthenticated calls", statusLine(&ctx, .compat));

    // KNAP_COMPAT_KEY is picked up as the bearer when set.
    try env.put("KNAP_COMPAT_KEY", " proxy-key ");
    try testing.expectEqualStrings("proxy-key", try apiKey(&ctx, .compat));
    try testing.expectEqualStrings("header = \"Authorization: Bearer proxy-key\"\n", try authConfig(a, "proxy-key"));
    try testing.expectEqualStrings("KNAP_COMPAT_KEY set — live calls enabled", statusLine(&ctx, .compat));

    // compat reaches the live paths without any key: the failure mode is
    // the HTTP call (port 1 refuses), not a missing-key gate.
    ctx.io = testing.io;
    ctx.store_dir = "/tmp";
    ctx.store_warned = true;
    try testing.expectError(error.ToolFailed, listModels(&ctx, .compat));
}

// --- acp ---------------------------------------------------------------------

test {
    _ = acp;
}

test "acp: parseKind, status and the missing-agent error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var ctx = testCtx(arena.allocator(), &env);
    ctx.calls = 0;
    try testing.expectEqual(Kind.acp, parseKind("acp").?);
    try testing.expect(std.mem.startsWith(u8, statusLine(&ctx, .acp), "needs KNAP_ACP_AGENT"));
    try testing.expectError(error.ToolFailed, complete(&ctx, .acp, .repair, "s", "u"));
    try testing.expect(std.mem.startsWith(u8, ctx.err_msg, "backend 'acp' needs KNAP_ACP_AGENT"));
    try testing.expectEqual(@as(usize, 0), ctx.calls);
    try testing.expectError(error.ToolFailed, endpoint(&ctx, .acp));
    try testing.expectError(error.ToolFailed, listModels(&ctx, .acp));
    try env.put("KNAP_ACP_AGENT", "devin acp --agent-type summarizer");
    try testing.expectEqualStrings("KNAP_ACP_AGENT set — live calls via 'devin'", statusLine(&ctx, .acp));
}

test "acp: a turn becomes a Reply with usage, counted like a live call" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    var ctx = try f.ctx("ok");
    const r = try completeReply(&ctx, .acp, .verify, "system", "user");
    try testing.expectEqualStrings("reply from s1", r.content);
    try testing.expectEqualStrings("end_turn", r.finish_reason.?);
    try testing.expect(!r.truncated());
    try testing.expectEqual(@as(?u64, 40), r.usage.prompt_tokens);
    try testing.expectEqual(@as(?u64, 3), r.usage.completion_tokens);
    try testing.expectEqual(@as(?u64, 43), r.usage.total_tokens);
    try testing.expectEqual(@as(?u64, 1), r.usage.reasoning_tokens);
    try testing.expectEqual(@as(usize, 1), ctx.calls);
    try testing.expectEqual(@as(usize, 6), ctx.prefix_bytes);
}

test "acp: repair runs agent output through sanitizePatch and degrades on a cut-off turn" {
    var f: acp.FakeAgent = undefined;
    try f.init();
    defer f.deinit();
    const diag: engine.Diag = .{ .kind = "syntax error", .line = 1, .col = 1, .detail = "unclosed if block" };
    var ctx = try f.ctx("fenced");
    const patch = try repairPatch(&ctx, .acp, "{% if a %}A\n", 1, diag);
    try testing.expectEqualStrings("{% if a %}A{% endif %}\n", patch.?);
    ctx = try f.ctx("maxtok");
    try testing.expectEqual(@as(?[]const u8, null), try repairPatch(&ctx, .acp, "{% if a %}A\n", 1, diag));
    ctx = try f.ctx("crash");
    try testing.expectError(error.ToolFailed, repairPatch(&ctx, .acp, "{% if a %}A\n", 1, diag));
}
