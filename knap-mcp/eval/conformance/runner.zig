//! k4o conformance runner over the vendored knap portable corpus
//! (corpus/render.json: format_version 1, `standard` preset).
//!
//! Every case renders through `k4o render --format markdown` via temp files
//! (knap's reference output is Markdown). Results are reported as pass / fail
//! / unsupported, separately:
//!
//!   pass         stdout byte-exact (trailing whitespace included), error codes
//!                equal and in order, warnings equal, clean stderr on exit 0.
//!   unsupported  a no-error case that needs a filter k4o does not register
//!                (black-box probe of the binary), or that k4o rejects with a
//!                diagnostic naming a construct it does not parse at that
//!                revision (`unsupportedConstruct`).
//!   fail         everything else: wrong bytes, a valid template rejected for
//!                any other reason, a missing or wrong error, a crash.
//!
//! Standalone so it runs with `zig run` and needs no build.zig wiring:
//!
//!   zig run eval/conformance/runner.zig -- run --k4o <bin> --corpus <render.json>
//!       [--label <name>] [--revision <sha>] [--json <report.json>]
//!   zig run eval/conformance/runner.zig -- summarize [--json <summary.json>] <report.json>...
//!
//! Output carries no timestamps or temp paths, so identical inputs give
//! byte-identical reports.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const usage_text =
    \\usage:
    \\  zig run eval/conformance/runner.zig -- run --k4o <bin> --corpus <render.json>
    \\      [--label <name>] [--revision <sha>] [--json <report.json>]
    \\  zig run eval/conformance/runner.zig -- summarize [--json <summary.json>] <report.json>...
    \\
;

const case_timeout_s = 10;

const Status = enum { pass, fail, unsupported };

const Case = struct {
    id: []const u8,
    template: []const u8,
    variables: json.Value,
    expected_output: []const u8,
    expected_errors: []const []const u8,
    expected_warnings: []const []const u8,
    filters: []const []const u8,
};

const Corpus = struct {
    format_version: []const u8,
    preset: []const u8,
    cases: []Case,
};

const Term = union(enum) {
    exited: u8,
    signal: u32,
    timeout,
    abnormal,
};

const Run = struct {
    term: Term,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

const Diag = struct {
    kind: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,
    detail: []const u8 = "",
    text: []const u8 = "",
};

const Verdict = struct {
    status: Status,
    class: []const u8,
    reason: []const u8 = "",
};

const CaseReport = struct {
    id: []const u8,
    category: []const u8,
    status: Status,
    class: []const u8,
    reason: []const u8,
    exit: []const u8,
    diagnostic: ?[]const u8 = null,
    missing_filters: ?[]const []const u8 = null,
    expected_output: ?[]const u8 = null,
    actual_output: ?[]const u8 = null,
};

const Totals = struct {
    cases: usize = 0,
    pass: usize = 0,
    fail: usize = 0,
    unsupported: usize = 0,

    fn add(t: *Totals, s: Status) void {
        t.cases += 1;
        switch (s) {
            .pass => t.pass += 1,
            .fail => t.fail += 1,
            .unsupported => t.unsupported += 1,
        }
    }
};

const CategoryRow = struct {
    name: []const u8,
    totals: Totals,
};

const Count = struct {
    name: []const u8,
    cases: usize,
};

const Report = struct {
    report: []const u8 = "knap-conformance",
    report_version: u32 = 1,
    label: []const u8,
    revision: []const u8,
    engine: struct {
        path: []const u8,
        version: []const u8,
        sha256: []const u8,
        command: []const u8 = "k4o render <case.knap> --data <data.json> --format markdown",
    },
    corpus: struct {
        path: []const u8,
        sha256: []const u8,
        format_version: []const u8,
        preset: []const u8,
        cases: usize,
    },
    totals: Totals,
    categories: []const CategoryRow,
    filters: struct {
        implemented: []const []const u8,
        missing: []const []const u8,
    },
    unsupported_by_filter: []const Count,
    unsupported_by_construct: []const Count,
    fail_by_class: []const Count,
    cases: []const CaseReport,
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.next();
    while (it.next()) |arg| try args.append(a, arg);

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    if (args.items.len == 0) return usage("missing command");
    const cmd = args.items[0];
    const code = if (eql(cmd, "run"))
        try cmdRun(init, a, io, w, args.items[1..])
    else if (eql(cmd, "summarize"))
        try cmdSummarize(a, io, w, args.items[1..])
    else if (eql(cmd, "--help") or eql(cmd, "-h")) blk: {
        try w.writeAll(usage_text);
        break :blk 0;
    } else return usage("unknown command");
    try w.flush();
    return code;
}

fn usage(msg: []const u8) u8 {
    std.debug.print("conformance: {s}\n{s}", .{ msg, usage_text });
    return 2;
}

// ---------------------------------------------------------------- run

fn cmdRun(init: std.process.Init, a: Allocator, io: Io, w: *Io.Writer, argv: []const []const u8) !u8 {
    var k4o_opt: ?[]const u8 = null;
    var corpus_opt: ?[]const u8 = null;
    var label: []const u8 = "k4o";
    var revision: []const u8 = "unknown";
    var json_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return usage("option needs a value");
        const flag = argv[i];
        const val = argv[i + 1];
        if (eql(flag, "--k4o")) k4o_opt = val else if (eql(flag, "--corpus")) corpus_opt = val else if (eql(flag, "--label")) label = val else if (eql(flag, "--revision")) revision = val else if (eql(flag, "--json")) json_path = val else return usage("unknown option");
    }
    const k4o = k4o_opt orelse return usage("missing --k4o");
    const corpus_path = corpus_opt orelse return usage("missing --corpus");
    const home = init.environ_map.get("HOME");

    const corpus_bytes = Io.Dir.readFileAlloc(.cwd(), io, corpus_path, a, .limited(64 << 20)) catch |e| {
        std.debug.print("conformance: cannot read corpus '{s}': {s}\n", .{ corpus_path, @errorName(e) });
        return 1;
    };
    const corpus = loadCorpus(a, corpus_bytes) catch |e| {
        std.debug.print("conformance: bad corpus '{s}': {s}\n", .{ corpus_path, @errorName(e) });
        return 1;
    };
    const engine_bytes = Io.Dir.readFileAlloc(.cwd(), io, k4o, a, .limited(512 << 20)) catch |e| {
        std.debug.print("conformance: cannot read k4o binary '{s}': {s}\n", .{ k4o, @errorName(e) });
        return 1;
    };
    const version_run = runArgv(a, io, &.{ k4o, "--version" });
    const version = switch (version_run.term) {
        .exited => |c| if (c == 0) std.mem.trim(u8, version_run.stdout, " \r\n\t") else "unknown",
        else => "unknown",
    };

    const tmp_base = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
    const stamp: u64 = @intCast(@max(0, Io.Timestamp.now(io, .real).nanoseconds));
    const tmp = try std.fmt.allocPrint(a, "{s}/knap-conformance-{d}", .{ tmp_base, stamp });
    Io.Dir.createDirPath(.cwd(), io, tmp) catch |e| {
        std.debug.print("conformance: cannot create temp dir '{s}': {s}\n", .{ tmp, @errorName(e) });
        return 1;
    };
    defer Io.Dir.deleteTree(.cwd(), io, tmp) catch {};
    const tpl_path = try std.fmt.allocPrint(a, "{s}/case.knap", .{tmp});
    const data_path = try std.fmt.allocPrint(a, "{s}/data.json", .{tmp});

    // Registry probe: which corpus filters does this binary register at all?
    var missing_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var implemented: std.ArrayList([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (corpus.cases) |c| for (c.filters) |f| try seen.put(a, f, {});
    const sorted_filters = try a.dupe([]const u8, seen.keys());
    std.mem.sort([]const u8, sorted_filters, {}, lessStr);
    for (sorted_filters) |f| {
        const probe = try std.fmt.allocPrint(a, "{{{{ x | {s} }}}}", .{f});
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tpl_path, .data = probe });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = data_path, .data = "{\"x\":\"probe\"}" });
        const r = runArgv(a, io, &.{ k4o, "render", tpl_path, "--data", data_path, "--format", "markdown" });
        const unknown = switch (r.term) {
            .exited => |c| c == 1 and eql(parseDiag(r.stderr).kind, "unknown filter"),
            else => false,
        };
        if (unknown) try missing_set.put(a, f, {}) else try implemented.append(a, f);
    }

    var totals: Totals = .{};
    var categories: std.ArrayList(CategoryRow) = .empty;
    var by_filter: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var by_construct: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var by_class: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var reports: std.ArrayList(CaseReport) = .empty;

    for (corpus.cases) |c| {
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tpl_path, .data = c.template });
        const data = try json.Stringify.valueAlloc(a, c.variables, .{});
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = data_path, .data = data });
        const r = runArgv(a, io, &.{ k4o, "render", tpl_path, "--data", data_path, "--format", "markdown" });

        var case_missing: std.ArrayList([]const u8) = .empty;
        for (c.filters) |f| if (missing_set.contains(f)) try case_missing.append(a, f);
        const v = try classify(a, c, r, case_missing.items);
        const diag = parseDiag(r.stderr);

        totals.add(v.status);
        const category = categoryOf(c.id);
        const row = for (categories.items) |*row| {
            if (eql(row.name, category)) break row;
        } else blk: {
            try categories.append(a, .{ .name = category, .totals = .{} });
            break :blk &categories.items[categories.items.len - 1];
        };
        row.totals.add(v.status);
        switch (v.status) {
            .pass => {},
            .fail => try bump(a, &by_class, v.class),
            .unsupported => if (eql(v.class, "missing filter")) {
                var names = std.mem.splitSequence(u8, v.reason, ", ");
                while (names.next()) |n| try bump(a, &by_filter, n);
            } else try bump(a, &by_construct, v.reason),
        }
        const non_pass = v.status != .pass;
        try reports.append(a, .{
            .id = c.id,
            .category = category,
            .status = v.status,
            .class = v.class,
            .reason = v.reason,
            .exit = try termText(a, r.term),
            .diagnostic = if (diag.text.len > 0) diag.text else null,
            .missing_filters = if (case_missing.items.len > 0) case_missing.items else null,
            .expected_output = if (non_pass) c.expected_output else null,
            .actual_output = if (non_pass) r.stdout else null,
        });
    }

    const report: Report = .{
        .label = label,
        .revision = revision,
        .engine = .{
            .path = try tildePath(a, k4o, home),
            .version = version,
            .sha256 = try sha256Hex(a, engine_bytes),
        },
        .corpus = .{
            .path = try tildePath(a, corpus_path, home),
            .sha256 = try sha256Hex(a, corpus_bytes),
            .format_version = corpus.format_version,
            .preset = corpus.preset,
            .cases = corpus.cases.len,
        },
        .totals = totals,
        .categories = categories.items,
        .filters = .{ .implemented = implemented.items, .missing = missing_set.keys() },
        .unsupported_by_filter = try ranked(a, by_filter),
        .unsupported_by_construct = try ranked(a, by_construct),
        .fail_by_class = try ranked(a, by_class),
        .cases = reports.items,
    };

    try writeMarkdown(w, &report);
    if (json_path) |p| {
        const body = try json.Stringify.valueAlloc(a, report, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
        const with_nl = try std.mem.concat(a, u8, &.{ body, "\n" });
        Io.Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = with_nl }) catch |e| {
            std.debug.print("conformance: cannot write report '{s}': {s}\n", .{ p, @errorName(e) });
            return 1;
        };
    }
    return 0;
}

fn classify(a: Allocator, c: Case, r: Run, case_missing: []const []const u8) !Verdict {
    const diag = parseDiag(r.stderr);
    var actual_errors: []const []const u8 = &.{};
    switch (r.term) {
        .exited => |code| switch (code) {
            0 => {},
            1 => actual_errors = try a.dupe([]const u8, &.{codeFor(diag.kind)}),
            else => return .{ .status = .fail, .class = "crash", .reason = try std.fmt.allocPrint(a, "exit {d}", .{code}) },
        },
        .signal => |sig| return .{ .status = .fail, .class = "crash", .reason = try std.fmt.allocPrint(a, "signal {d}", .{sig}) },
        .timeout => return .{ .status = .fail, .class = "timeout", .reason = std.fmt.comptimePrint("no exit within {d}s", .{case_timeout_s}) },
        .abnormal => return .{ .status = .fail, .class = "crash", .reason = "abnormal termination" },
    }
    const clean_exit = actual_errors.len == 0;
    const output_ok = eql(r.stdout, c.expected_output);
    const errors_ok = eqlList(actual_errors, c.expected_errors);
    // k4o has no warning channel: a clean exit carries no warnings.
    const warnings_ok = c.expected_warnings.len == 0;
    const stderr_ok = !clean_exit or r.stderr.len == 0;
    if (output_ok and errors_ok and warnings_ok and stderr_ok) return .{ .status = .pass, .class = "pass" };

    if (c.expected_errors.len == 0) {
        if (case_missing.len > 0)
            return .{ .status = .unsupported, .class = "missing filter", .reason = try std.mem.join(a, ", ", case_missing) };
        if (!clean_exit) {
            if (eql(diag.kind, "unknown filter")) {
                if (quotedName(diag.detail)) |name|
                    return .{ .status = .unsupported, .class = "missing filter", .reason = name };
            }
            if (try unsupportedConstruct(a, c.template, diag)) |feature|
                return .{ .status = .unsupported, .class = "unsupported construct", .reason = feature };
            return .{ .status = .fail, .class = "rejected valid template", .reason = diag.text };
        }
        if (!output_ok) return .{ .status = .fail, .class = "output mismatch", .reason = try mismatchText(a, c.expected_output, r.stdout) };
        if (!stderr_ok) return .{ .status = .fail, .class = "stderr on success", .reason = firstLine(r.stderr) };
        return .{ .status = .fail, .class = "missing warnings", .reason = try std.fmt.allocPrint(a, "output byte-exact; k4o reported no warnings, expected {s}", .{try std.mem.join(a, ", ", c.expected_warnings)}) };
    }
    const want = try std.mem.join(a, ", ", c.expected_errors);
    if (clean_exit) return .{ .status = .fail, .class = "missing error", .reason = try std.fmt.allocPrint(a, "expected {s}, k4o exited 0", .{want}) };
    if (!errors_ok) return .{ .status = .fail, .class = "wrong error code", .reason = try std.fmt.allocPrint(a, "expected {s}, got {s} ({s})", .{ want, actual_errors[0], diag.text }) };
    if (!output_ok) return .{ .status = .fail, .class = "error-case output mismatch", .reason = try std.fmt.allocPrint(a, "error code matches; expected {d} bytes of output alongside the error, k4o's buffered contract emits {d}", .{ c.expected_output.len, r.stdout.len }) };
    return .{ .status = .fail, .class = "missing warnings", .reason = try std.mem.join(a, ", ", c.expected_warnings) };
}

/// Rejections of a valid template that name a construct k4o does not parse
/// at this revision, judged from the detail text or from the template token
/// the diagnostic points at. Anything unmatched stays a fail, so a generic
/// syntax error is never excused without evidence.
fn unsupportedConstruct(a: Allocator, template: []const u8, d: Diag) !?[]const u8 {
    if (std.mem.indexOf(u8, d.detail, "takes no arguments") != null)
        return "argument on a k4o filter that takes none";
    if (std.mem.startsWith(u8, d.detail, "unknown logic tag '")) {
        const name = d.detail["unknown logic tag '".len..];
        return try std.fmt.allocPrint(a, "`{{% {s} %}}` tag", .{name[0 .. std.mem.indexOfScalar(u8, name, '\'') orelse name.len]});
    }
    if (!eql(d.kind, "syntax error")) return null;
    const at = offsetOf(template, d.line, d.column) orelse return null;
    // k4o reads `title ??` as a spaced variable name and reports the token
    // after it, so look for `??` from the tag opening through that token.
    const open = std.mem.lastIndexOf(u8, template[0..at], "{{") orelse 0;
    if (std.mem.indexOf(u8, template[open..@min(template.len, at + 2)], "??") != null) return "`??` fallback";
    if (template[at] == '(' and at > 0 and template[at - 1] == ':') return "parenthesized filter arguments `:(a, b)`";
    return null;
}

/// Byte offset of a k4o line/column (columns count code points).
fn offsetOf(template: []const u8, line: u32, column: u32) ?usize {
    var l: u32 = 1;
    var c: u32 = 1;
    for (template, 0..) |b, i| {
        if (l == line and c == column) return i;
        if (b == '\n') {
            l += 1;
            c = 1;
        } else if ((b & 0xC0) != 0x80) c += 1;
    }
    return null;
}

/// k4o diagnostic kinds mapped to knap error codes. Only the two kinds with
/// an unambiguous knap counterpart get a knap code; the rest stay k4o-named
/// so they can never match by accident.
fn codeFor(kind: []const u8) []const u8 {
    if (eql(kind, "syntax error")) return "PARSE_ERROR";
    if (eql(kind, "unknown filter")) return "UNKNOWN_FILTER";
    if (eql(kind, "bad argument")) return "K4O_BAD_ARGUMENT";
    if (eql(kind, "render error")) return "K4O_RENDER_ERROR";
    return "K4O_ERROR";
}

fn mismatchText(a: Allocator, want: []const u8, got: []const u8) ![]const u8 {
    const n = @min(want.len, got.len);
    var at: usize = 0;
    while (at < n and want[at] == got[at]) at += 1;
    return std.fmt.allocPrint(a, "first difference at byte {d}: expected \"{s}\", got \"{s}\"", .{ at, try preview(a, want), try preview(a, got) });
}

/// Short escaped excerpt so whitespace differences stay visible in a table.
fn preview(a: Allocator, s: []const u8) ![]const u8 {
    const max = 48;
    var out: std.ArrayList(u8) = .empty;
    for (s[0..@min(s.len, max)]) |ch| switch (ch) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\\' => try out.appendSlice(a, "\\\\"),
        '"' => try out.appendSlice(a, "\\\""),
        else => try out.append(a, ch),
    };
    if (s.len > max) try out.appendSlice(a, "…");
    return out.items;
}

fn runArgv(a: Allocator, io: Io, argv: []const []const u8) Run {
    const result = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(case_timeout_s), .clock = .awake } },
    }) catch |e| return switch (e) {
        error.Timeout => .{ .term = .timeout },
        else => .{ .term = .abnormal, .stderr = @errorName(e) },
    };
    return .{
        .term = switch (result.term) {
            .exited => |c| .{ .exited = c },
            .signal => |s| .{ .signal = @backingInt(s) },
            else => .abnormal,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn termText(a: Allocator, t: Term) ![]const u8 {
    return switch (t) {
        .exited => |c| std.fmt.allocPrint(a, "{d}", .{c}),
        .signal => |s| std.fmt.allocPrint(a, "signal {d}", .{s}),
        .timeout => "timeout",
        .abnormal => "abnormal",
    };
}

/// `k4o: <kind> at line <L>, column <C>: <detail>`; k4o stops at the first
/// error, so only the first line matters.
fn parseDiag(stderr: []const u8) Diag {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    const first = while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        if (t.len > 0) break t;
    } else return .{};
    const s = if (std.mem.startsWith(u8, first, "k4o: ")) first["k4o: ".len..] else first;
    const at = std.mem.indexOf(u8, s, " at line ") orelse return .{ .text = s };
    const sep = std.mem.indexOfPos(u8, s, at, ": ") orelse return .{ .kind = s[0..at], .text = s };
    var d: Diag = .{ .kind = s[0..at], .detail = s[sep + 2 ..], .text = s };
    const pos = s[at + " at line ".len .. sep];
    if (std.mem.indexOf(u8, pos, ", column ")) |comma| {
        d.line = std.fmt.parseInt(u32, pos[0..comma], 10) catch 0;
        d.column = std.fmt.parseInt(u32, pos[comma + ", column ".len ..], 10) catch 0;
    }
    return d;
}

fn quotedName(detail: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, detail, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, detail, open + 1, '"') orelse return null;
    return detail[open + 1 .. close];
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

fn categoryOf(id: []const u8) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, '/') orelse id.len];
}

// ---------------------------------------------------------------- corpus

fn loadCorpus(a: Allocator, bytes: []const u8) !Corpus {
    // Numbers stay as source text so case data round-trips byte-for-byte
    // (42.567 must reach k4o as 42.567, not a reformatted float).
    const root = try json.parseFromSliceLeaky(json.Value, a, bytes, .{ .parse_numbers = false });
    const obj = objectOf(root) orelse return error.BadCorpus;
    const format_version = switch (obj.get("format_version") orelse return error.BadCorpus) {
        .number_string, .string => |s| s,
        else => return error.BadCorpus,
    };
    const preset = stringOf(obj.get("preset")) orelse return error.BadCorpus;
    const items = arrayOf(obj.get("cases") orelse return error.BadCorpus) orelse return error.BadCorpus;
    const cases = try a.alloc(Case, items.len);
    for (items, cases) |item, *c| {
        const co = objectOf(item) orelse return error.BadCase;
        const expected = objectOf(co.get("expected") orelse return error.BadCase) orelse return error.BadCase;
        const template = stringOf(co.get("template")) orelse return error.BadCase;
        c.* = .{
            .id = stringOf(co.get("id")) orelse return error.BadCase,
            .template = template,
            .variables = co.get("variables") orelse .{ .object = .empty },
            .expected_output = stringOf(expected.get("output")) orelse return error.BadCase,
            .expected_errors = try codeList(a, expected.get("errors")),
            .expected_warnings = try codeList(a, expected.get("warnings")),
            .filters = try usedFilters(a, template),
        };
    }
    return .{ .format_version = format_version, .preset = preset, .cases = cases };
}

/// Error/warning entries are bare codes or `{code, filter}` objects; the
/// latter flatten to `CODE:filter` so order and filter both compare.
fn codeList(a: Allocator, v: ?json.Value) ![]const []const u8 {
    const items = arrayOf(v orelse return &.{}) orelse return error.BadCase;
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |item, *o| {
        o.* = switch (item) {
            .string => |s| s,
            .object => |m| blk: {
                const code = stringOf(m.get("code")) orelse return error.BadCase;
                const filter = stringOf(m.get("filter")) orelse break :blk code;
                break :blk try std.fmt.allocPrint(a, "{s}:{s}", .{ code, filter });
            },
            else => return error.BadCase,
        };
    }
    return out;
}

/// Filter names applied anywhere in a template: identifiers after a single
/// `|` inside `{{ }}` / `{% %}` tags, skipping quoted strings and `||`.
fn usedFilters(a: Allocator, template: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i + 1 < template.len) {
        const open = template[i] == '{' and (template[i + 1] == '{' or template[i + 1] == '%');
        if (!open) {
            i += 1;
            continue;
        }
        const close: u8 = if (template[i + 1] == '{') '}' else '%';
        i += 2;
        var quote: u8 = 0;
        while (i < template.len) : (i += 1) {
            const ch = template[i];
            if (quote != 0) {
                if (ch == '\\') i += 1 else if (ch == quote) quote = 0;
                continue;
            }
            if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (ch == close and i + 1 < template.len and template[i + 1] == '}') {
                i += 2;
                break;
            } else if (ch == '|') {
                if (i + 1 < template.len and template[i + 1] == '|') {
                    i += 1;
                    continue;
                }
                var j = i + 1;
                while (j < template.len and (template[j] == ' ' or template[j] == '\t')) j += 1;
                const start = j;
                while (j < template.len and (std.ascii.isAlphanumeric(template[j]) or template[j] == '_')) j += 1;
                if (j > start) {
                    const name = template[start..j];
                    for (out.items) |seen| {
                        if (eql(seen, name)) break;
                    } else try out.append(a, name);
                }
                i = j - 1;
            }
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- output

fn writeMarkdown(w: *Io.Writer, r: *const Report) !void {
    const t = r.totals;
    try w.print("# k4o conformance: {s}\n\n", .{r.label});
    try w.print("- engine: `{s}` ({s}), revision `{s}`\n", .{ r.engine.path, r.engine.version, r.revision });
    try w.print("- engine sha256: `{s}`\n", .{r.engine.sha256});
    try w.print("- corpus: `{s}` (format_version {s}, preset `{s}`, {d} cases), sha256 `{s}`\n", .{ r.corpus.path, r.corpus.format_version, r.corpus.preset, r.corpus.cases, r.corpus.sha256 });
    try w.print("- mode: `{s}`; stdout byte-exact, error codes in order\n\n", .{r.engine.command});
    try w.print("**{s}: {d}/{d} pass** ({d} fail, {d} unsupported)\n\n", .{ r.label, t.pass, t.cases, t.fail, t.unsupported });

    try w.writeAll("## By category\n\n| category | cases | pass | fail | unsupported |\n| --- | ---: | ---: | ---: | ---: |\n");
    for (r.categories) |row| {
        try w.print("| {s} | {d} | {d} | {d} | {d} |\n", .{ row.name, row.totals.cases, row.totals.pass, row.totals.fail, row.totals.unsupported });
    }
    try w.print("| **total** | **{d}** | **{d}** | **{d}** | **{d}** |\n\n", .{ t.cases, t.pass, t.fail, t.unsupported });

    try w.print("## Unsupported: filters k4o does not register ({d} of {d} corpus filters)\n\n", .{ r.filters.missing.len, r.filters.missing.len + r.filters.implemented.len });
    if (r.unsupported_by_filter.len == 0) try w.writeAll("None.\n\n") else {
        try w.writeAll("A case that chains several missing filters counts once under each.\n\n| filter | cases |\n| --- | ---: |\n");
        for (r.unsupported_by_filter) |c| try w.print("| `{s}` | {d} |\n", .{ c.name, c.cases });
        try w.writeAll("\n");
    }
    if (r.unsupported_by_construct.len > 0) {
        try w.writeAll("## Unsupported: constructs this revision does not parse\n\n| construct | cases |\n| --- | ---: |\n");
        for (r.unsupported_by_construct) |c| try w.print("| {s} | {d} |\n", .{ c.name, c.cases });
        try w.writeAll("\n");
    }

    try w.writeAll("## Failures by class\n\n");
    if (r.fail_by_class.len == 0) try w.writeAll("None.\n\n") else {
        try w.writeAll("| class | cases |\n| --- | ---: |\n");
        for (r.fail_by_class) |c| try w.print("| {s} | {d} |\n", .{ c.name, c.cases });
        try w.writeAll("\n| case | class | reason |\n| --- | --- | --- |\n");
        for (r.cases) |c| {
            if (c.status != .fail) continue;
            try w.print("| `{s}` | {s} | ", .{ c.id, c.class });
            try cell(w, c.reason);
            try w.writeAll(" |\n");
        }
        try w.writeAll("\n");
    }
}

fn cell(w: *Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '|' => try w.writeAll("\\|"),
        '\n', '\r' => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
}

// ---------------------------------------------------------------- summarize

const Summary = struct {
    report: []const u8 = "knap-conformance-summary",
    report_version: u32 = 1,
    headline: []const u8,
    revisions: []const struct { label: []const u8, revision: []const u8, totals: Totals },
    changes: []const struct { id: []const u8, statuses: []const []const u8 },
};

fn cmdSummarize(a: Allocator, io: Io, w: *Io.Writer, argv: []const []const u8) !u8 {
    var json_path: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (eql(argv[i], "--json")) {
            i += 1;
            if (i >= argv.len) return usage("--json needs a value");
            json_path = argv[i];
        } else try files.append(a, argv[i]);
    }
    if (files.items.len == 0) return usage("summarize needs at least one report");

    const Loaded = struct { label: []const u8, revision: []const u8, totals: Totals, cases: []json.Value, categories: []json.Value };
    var loaded: std.ArrayList(Loaded) = .empty;
    for (files.items) |f| {
        const bytes = Io.Dir.readFileAlloc(.cwd(), io, f, a, .limited(64 << 20)) catch |e| {
            std.debug.print("conformance: cannot read report '{s}': {s}\n", .{ f, @errorName(e) });
            return 1;
        };
        const root = json.parseFromSliceLeaky(json.Value, a, bytes, .{}) catch {
            std.debug.print("conformance: report '{s}' is not JSON\n", .{f});
            return 1;
        };
        const obj = objectOf(root) orelse return badReport(f);
        const totals = objectOf(obj.get("totals") orelse return badReport(f)) orelse return badReport(f);
        try loaded.append(a, .{
            .label = stringOf(obj.get("label")) orelse return badReport(f),
            .revision = stringOf(obj.get("revision")) orelse return badReport(f),
            .totals = .{
                .cases = intOf(totals.get("cases")),
                .pass = intOf(totals.get("pass")),
                .fail = intOf(totals.get("fail")),
                .unsupported = intOf(totals.get("unsupported")),
            },
            .cases = arrayOf(obj.get("cases") orelse return badReport(f)) orelse return badReport(f),
            .categories = arrayOf(obj.get("categories") orelse return badReport(f)) orelse return badReport(f),
        });
    }

    var headline: std.ArrayList(u8) = .empty;
    try headline.appendSlice(a, "k4o ");
    for (loaded.items, 0..) |l, n| {
        if (n > 0) try headline.appendSlice(a, " → ");
        try headline.print(a, "{s} {d}/{d}", .{ l.label, l.totals.pass, l.totals.cases });
    }

    try w.print("# k4o conformance summary\n\n**{s}**\n\n", .{headline.items});
    try w.writeAll("| revision | label | pass | fail | unsupported | cases |\n| --- | --- | ---: | ---: | ---: | ---: |\n");
    for (loaded.items) |l| {
        try w.print("| `{s}` | {s} | {d} | {d} | {d} | {d} |\n", .{ shortSha(l.revision), l.label, l.totals.pass, l.totals.fail, l.totals.unsupported, l.totals.cases });
    }

    try w.writeAll("\n## Pass count by category\n\n| category | cases |");
    for (loaded.items) |l| try w.print(" {s} |", .{l.label});
    try w.writeAll("\n| --- | ---: |");
    for (loaded.items) |_| try w.writeAll(" ---: |");
    try w.writeAll("\n");
    for (loaded.items[0].categories) |cat| {
        const name = stringOf(field(cat, "name")) orelse continue;
        try w.print("| {s} | {d} |", .{ name, intOf(field(field(cat, "totals"), "cases")) });
        for (loaded.items) |l| {
            const pass = for (l.categories) |other| {
                if (eql(stringOf(field(other, "name")) orelse "", name)) break intOf(field(field(other, "totals"), "pass"));
            } else 0;
            try w.print(" {d} |", .{pass});
        }
        try w.writeAll("\n");
    }

    const Change = @typeInfo(@FieldType(Summary, "changes")).pointer.child;
    var changes: std.ArrayList(Change) = .empty;
    for (loaded.items[0].cases) |first_case| {
        const id = stringOf(field(first_case, "id")) orelse continue;
        const statuses = try a.alloc([]const u8, loaded.items.len);
        var differs = false;
        for (loaded.items, statuses) |l, *s| {
            s.* = for (l.cases) |other| {
                if (eql(stringOf(field(other, "id")) orelse "", id)) break stringOf(field(other, "status")) orelse "?";
            } else "absent";
            if (!eql(s.*, statuses[0])) differs = true;
        }
        if (differs) try changes.append(a, .{ .id = id, .statuses = statuses });
    }
    try w.print("\n## Cases whose status changes across revisions ({d})\n\n| case |", .{changes.items.len});
    for (loaded.items) |l| try w.print(" {s} |", .{l.label});
    try w.writeAll("\n| --- |");
    for (loaded.items) |_| try w.writeAll(" --- |");
    try w.writeAll("\n");
    for (changes.items) |ch| {
        try w.print("| `{s}` |", .{ch.id});
        for (ch.statuses) |s| try w.print(" {s} |", .{s});
        try w.writeAll("\n");
    }

    if (json_path) |p| {
        const Rev = @typeInfo(@FieldType(Summary, "revisions")).pointer.child;
        const revs = try a.alloc(Rev, loaded.items.len);
        for (loaded.items, revs) |l, *r| r.* = .{ .label = l.label, .revision = l.revision, .totals = l.totals };
        const summary: Summary = .{ .headline = headline.items, .revisions = revs, .changes = changes.items };
        const body = try json.Stringify.valueAlloc(a, summary, .{ .whitespace = .indent_2 });
        const with_nl = try std.mem.concat(a, u8, &.{ body, "\n" });
        Io.Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = with_nl }) catch |e| {
            std.debug.print("conformance: cannot write summary '{s}': {s}\n", .{ p, @errorName(e) });
            return 1;
        };
    }
    return 0;
}

fn badReport(path: []const u8) u8 {
    std.debug.print("conformance: '{s}' is not a conformance report\n", .{path});
    return 1;
}

fn shortSha(s: []const u8) []const u8 {
    return s[0..@min(s.len, 7)];
}

// ---------------------------------------------------------------- helpers

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn eqlList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!eql(p, q)) return false;
    return true;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn objectOf(v: ?json.Value) ?json.ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn field(v: ?json.Value, name: []const u8) ?json.Value {
    const o = objectOf(v) orelse return null;
    return o.get(name);
}

fn arrayOf(v: json.Value) ?[]json.Value {
    return switch (v) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn stringOf(v: ?json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?json.Value) usize {
    return switch (v orelse return 0) {
        .integer => |n| @intCast(@max(0, n)),
        else => 0,
    };
}

fn bump(a: Allocator, m: *std.StringArrayHashMapUnmanaged(usize), key: []const u8) !void {
    const gop = try m.getOrPut(a, key);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

/// Counts descending, ties by name, so reports are order-stable.
fn ranked(a: Allocator, m: std.StringArrayHashMapUnmanaged(usize)) ![]const Count {
    const out = try a.alloc(Count, m.count());
    for (m.keys(), m.values(), out) |k, v, *o| o.* = .{ .name = k, .cases = v };
    std.mem.sort(Count, out, {}, struct {
        fn lt(_: void, x: Count, y: Count) bool {
            if (x.cases != y.cases) return x.cases > y.cases;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out;
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}

/// Reports are committed, so keep the user's home directory out of them.
fn tildePath(a: Allocator, path: []const u8, home: ?[]const u8) ![]const u8 {
    const h = std.mem.trimEnd(u8, home orelse return path, "/");
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    if (path.len > h.len and path[h.len] != '/') return path;
    return std.mem.concat(a, u8, &.{ "~", path[h.len..] });
}

test usedFilters {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const got = try usedFilters(arena.allocator(), "{% if a || b %}{{ x | where:(\"p|q\", true) | map:\"t\" | join:\", \" }}{% endif %}{{ y|upper }}");
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("where", got[0]);
    try std.testing.expectEqualStrings("map", got[1]);
    try std.testing.expectEqualStrings("join", got[2]);
    try std.testing.expectEqualStrings("upper", got[3]);
}

test parseDiag {
    const d = parseDiag("k4o: unknown filter at line 1, column 16: no filter named \"date\"\n");
    try std.testing.expectEqualStrings("unknown filter", d.kind);
    try std.testing.expectEqual(@as(u32, 1), d.line);
    try std.testing.expectEqual(@as(u32, 16), d.column);
    try std.testing.expectEqualStrings("no filter named \"date\"", d.detail);
    try std.testing.expectEqualStrings("date", quotedName(d.detail).?);
    try std.testing.expectEqualStrings("PARSE_ERROR", codeFor(parseDiag("k4o: syntax error at line 1, column 1: unclosed '{{' tag").kind));
}

test unsupportedConstruct {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fallback = parseDiag("k4o: syntax error at line 1, column 12: unexpected text in output tag (expected '|' or end of tag)");
    try std.testing.expectEqualStrings("`??` fallback", (try unsupportedConstruct(a, "{{title ?? \"Untitled\"}}", fallback)).?);
    try std.testing.expectEqual(null, try unsupportedConstruct(a, "{{ a }}{{title \"x\"}}", parseDiag("k4o: syntax error at line 1, column 16: unexpected text in output tag (expected '|' or end of tag)")));
    // The same generic detail pointing anywhere else is not excused.
    try std.testing.expectEqual(null, try unsupportedConstruct(a, "{{ value | replace:\",\":\"\" }}", parseDiag("k4o: syntax error at line 1, column 25: unexpected text in output tag (expected '|' or end of tag)")));
    const tuple = parseDiag("k4o: syntax error at line 1, column 17: expected a filter argument after ':'");
    try std.testing.expectEqualStrings("parenthesized filter arguments `:(a, b)`", (try unsupportedConstruct(a, "{{ rows | table:(\"Name\", \"Role\") }}", tuple)).?);
    const set = parseDiag("k4o: syntax error at line 1, column 7: unknown logic tag 'set'");
    try std.testing.expectEqualStrings("`{% set %}` tag", (try unsupportedConstruct(a, "{% set x = 1 %}", set)).?);
    try std.testing.expectEqual(null, try unsupportedConstruct(a, "{{ q | blockquote }}", parseDiag("k4o: render error at line 1, column 12: filter 'blockquote' expects single-line text")));
    try std.testing.expectEqual(@as(?usize, 4), offsetOf("é\nab", 2, 2));
}

test tildePath {
    const a = std.testing.allocator;
    const p = try tildePath(a, "/Users/me/.cache/k4o", "/Users/me");
    defer a.free(p);
    try std.testing.expectEqualStrings("~/.cache/k4o", p);
    try std.testing.expectEqualStrings("/Users/meow/x", try tildePath(a, "/Users/meow/x", "/Users/me"));
}
