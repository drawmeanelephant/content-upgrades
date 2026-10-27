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
    // Mock counts the slice a live call would carry so eval numbers
    // measure the real context economy.
    if (kind == .mock) ctx.countCall(repair_prefix, try repairUser(ctx, region, first_line, diag));
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
    "h1",        "h2",           "h3",         "h4",
    "h5",        "h6",           "bold",       "italic",
    "code",      "code_block",   "blockquote", "list",
    "link",      "image",        "hr",         "hard_break",
    "escape_md", "fragment_link", "embed",
    "camel",     "capitalize",   "kebab",      "lower",
    "pascal",    "snake",        "title",      "uncamel",
    "upper",     "trim",         "truncate",   "truncatewords",
    "indent",    "unescape",     "safe_name",  "encode_uri",
    "decode_uri",
    "calc",      "number_format", "round",
    "date",      "date_modify",  "duration",
    "compact",   "first",        "join",       "last",
    "length",    "merge",        "nth",        "object",
    "parse_json", "reverse",     "slice",      "sort",
    "split",     "sum",          "unique",     "where",
    "callout",   "wikilink",     "footnote",   "strike",
    "table",     "table_pretty", "highlight",  "math",
    "math_block", "comment",
    "map",       "template",     "replace",    "yaml",
    "yaml_property",
    "remove_attr", "strip_attr", "remove_tags", "replace_tags",
    "strip_tags",  "strip_md",   "stripmd",
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
    const body = try complete(ctx, kind, .repair, repair_prefix, try repairUser(ctx, region, first_line, diag));
    const patch = sanitizePatch(body) orelse return null;
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

/// One chat completion on a live backend: resolves the endpoint and model
/// for `kind`, needs MODEL_API_KEY, returns the first choice's content.
/// `mock` has no endpoint; callers keep their own canned path for it.
pub fn complete(ctx: *Ctx, kind: Kind, task: Task, system: []const u8, user: []const u8) Error![]const u8 {
    if (kind == .mock)
        return ctx.fail("backend 'mock' has no live completion (task '{s}')", .{@tagName(task)});
    const key = ctx.environ.get("MODEL_API_KEY") orelse "";
    if (key.len == 0)
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
    ctx.countCall(system, user);
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
    warnProjectTreeStore(ctx);
    var payload: std.Io.Writer.Allocating = .init(ctx.arena);
    try payload.writer.print("{{\"model\":", .{});
    try std.json.Stringify.value(model, .{}, &payload.writer);
    try payload.writer.print(",\"messages\":[{{\"role\":\"system\",\"content\":", .{});
    try std.json.Stringify.value(system, .{}, &payload.writer);
    try payload.writer.print("}},{{\"role\":\"user\",\"content\":", .{});
    try std.json.Stringify.value(user_msg, .{}, &payload.writer);
    try payload.writer.print("}}],\"temperature\":0}}", .{});

    // The request body goes through an owner-only scratch file, not argv,
    // so the prompt doesn't show up in `ps`. The API key never touches
    // disk: curl reads it as a `-K -` config stream on stdin.
    const body_path = try store.scratchFile(ctx, "json");
    defer std.Io.Dir.deleteFile(.cwd(), ctx.io, body_path) catch {};
    const Permissions = std.Io.File.Permissions;
    const private: std.Io.Dir.CreateFileOptions = .{
        .permissions = if (@hasDecl(Permissions, "fromMode")) Permissions.fromMode(0o600) else .default_file,
    };
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = body_path, .data = payload.written(), .flags = private }) catch
        return ctx.fail("cannot stage backend request body", .{});
    const body_arg = try std.fmt.allocPrint(ctx.arena, "@{s}", .{body_path});

    // `-m`/`--connect-timeout` bound the call curl-side (`KNAP_CURL_TIMEOUT`
    // default 60s, `KNAP_CURL_CONNECT_TIMEOUT` default 10s); the process
    // deadline adds 15s of slack as a backstop in case curl itself wedges.
    // `-w` appends the HTTP status after the body so `--fail-with-body`
    // can keep the provider's error payload.
    const total_secs = ctx.envSecs("KNAP_CURL_TIMEOUT", 60);
    const config = try std.fmt.allocPrint(ctx.arena, "header = \"Authorization: Bearer {s}\"\n", .{key});
    const result = try runCurl(ctx, &.{
        "curl",               "-sS", "--fail-with-body", "-X", "POST", url,
        "-m",                 try std.fmt.allocPrint(ctx.arena, "{d}", .{total_secs}),
        "--connect-timeout",  try std.fmt.allocPrint(ctx.arena, "{d}", .{ctx.envSecs("KNAP_CURL_CONNECT_TIMEOUT", 10)}),
        "-K",                 "-",
        "-H",                 "Content-Type: application/json",
        "--data-binary",      body_arg,
        "-w",                 "\n%{http_code}",
    }, config, if (total_secs == 0) .none else ctx.deadline(total_secs + 15));

    // `-w` appends "\n<status>" after the body; split them back apart.
    var body: []const u8 = result.stdout;
    var status: u32 = 0;
    if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| {
        const s = std.fmt.parseInt(u32, std.mem.trim(u8, body[i + 1 ..], " \r"), 10) catch 0;
        if (s > 0) {
            status = s;
            body = body[0..i];
        }
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (status >= 400)
                return ctx.fail("backend http {d}: {s}", .{ status, brief(if (body.len > 0) body else result.stderr) });
            return ctx.fail("backend request failed (curl exit {d}): {s}", .{ code, brief(result.stderr) });
        },
        else => return ctx.fail("curl terminated abnormally", .{}),
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, body, .{}) catch
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
fn brief(s: []const u8) []const u8 {
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
