//! knap_doc_voice + `knap-mcp doc-voice`: the guarded doc-level voice
//! pass over an existing record (FILED-VOICE, #257). The walk, guard and
//! proof live in voice.zig; this file gates on the collection policy,
//! runs publish-check under the raw profile, and reports.
//!
//! Nothing here writes into a source tree. The MCP tool stores the
//! patched doc as an artifact; the CLI is dry-run by default and
//! `--apply` writes only to a stated `--out` outside any `content/` dir.
//! A run that can't prove every invariant exits 1 and writes nothing.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const backend = @import("../backend.zig");
const boris = @import("../boris.zig");
const policy = @import("../policy.zig");
const store = @import("../store.zig");
const voice = @import("../voice.zig");
const voicetics = @import("../voicetics.zig");
const tools = @import("../tools.zig");
const common = @import("common.zig");

const Allocating = std.Io.Writer.Allocating;
const ObjectMap = std.json.ObjectMap;

pub const tool: tools.Tool = .{
    .name = "knap_doc_voice",
    .description = "Guarded voice pass over an existing markdown record (doc_id from knap_ingest) in one tone (mild|spicy|feral). Only prose paragraphs and single-line list items the collection policy grants are sent, one model call each; every other byte (frontmatter, headings, verse line groups, fences, quotes, tables, includes, Aside/Details blocks, links, URLs) is copied verbatim. Each reply must pass the voice guard (insert-only **, *, ~~, ==, code spans quoting the input, allowlisted emoji; protected atoms kept in order); a rejected reply keeps the original. The patched doc must keep structhash --ignore-formatting, frontmatter bytes, wiki-link targets and protected atoms identical, must not lose density, and must pass publish-check under the raw staging profile; only then is it stored (out_doc_id). Within a pass a content word may be added once and an existing word italicized once: a reply re-adding a term an earlier run (or the optional 'ledger' file's earlier records) already used is retried once, then rejected. 'as' is the record's content path (content/mascots/x.md): it picks the policy collection and the staged position. Never writes into the source tree.",
    .input_schema =
    \\{"type":"object","properties":{"doc_id":{"type":"string"},"tone":{"type":"string","enum":["mild","spicy","feral"]},"as":{"type":"string"},"policy":{"type":"string"},"backend":{"type":"string","enum":["mock","spark","wonder","baseten","acp","compat"]},"replies":{"type":"string"},"ledger":{"type":"string"}},"required":["doc_id","tone","as"]}
    ,
    .run = run,
};

pub const Input = struct {
    doc_id: []const u8,
    doc: []const u8,
    tone: voice.Tone,
    kind: backend.Kind,
    /// The record's source path; its part after `content/` is matched
    /// against the policy and is the staged position.
    as: []const u8,
    policy_path: ?[]const u8 = null,
    /// Canned replies (voice.Canned JSONL), consulted before any backend.
    replies_path: ?[]const u8 = null,
    /// Batch ledger: terms added by earlier records, one per line —
    /// added words bare, italicized existing words as `*x*` (#401). When
    /// set the file seeds the pass's seen-set and is rewritten with this
    /// pass's additions whenever a rewrite was accepted — terms the pass
    /// used are spent even if the doc later fails its checks (#390).
    ledger_path: ?[]const u8 = null,
    /// Tests only: `zig build test` has no boris binary.
    publish: bool = true,
};

pub const PublishCheck = union(enum) {
    /// Why it did not run (denied, unchanged, invariants failed).
    not_run: []const u8,
    failed: []const u8,
    ran: boris.Report,
};

pub const Outcome = struct {
    in: Input,
    source: []const u8,
    policy_path: []const u8,
    collection: ?[]const u8,
    gate: voice.Gate,
    result: voice.DocResult,
    publish: PublishCheck,
    /// Content words this pass registered in the seen-set, sorted.
    added_terms: []const []const u8 = &.{},
    /// Every invariant proven and publish-check clean (or nothing changed).
    ok: bool,
    out_doc_id: ?[]const u8 = null,

    fn changed(o: Outcome) bool {
        return o.result.rewritten > 0;
    }
};

/// The part of a source path after its first `content` component (else
/// the whole path): the policy-glob and staging coordinate.
pub fn contentRel(ctx: *Ctx, as: []const u8) tools.Error![]const u8 {
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, as, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) return ctx.fail("source path '{s}' cannot contain '..'", .{as});
        try comps.append(ctx.arena, c);
    }
    const start = for (comps.items, 0..) |c, i| {
        if (std.mem.eql(u8, c, "content")) break i + 1;
    } else 0;
    const rel = try std.mem.join(ctx.arena, "/", comps.items[start..]);
    if (rel.len == 0 or !std.mem.endsWith(u8, rel, ".md"))
        return ctx.fail("source path '{s}' must name a .md record under content/", .{as});
    return rel;
}

/// The directory policy discovery starts from: the source path's
/// `content` dir when it names one, else the cwd.
fn policyRoot(ctx: *Ctx, as: []const u8) tools.Error![]const u8 {
    var off: usize = 0;
    while (std.mem.indexOfPos(u8, as, off, "content")) |p| {
        const end = p + "content".len;
        if ((p == 0 or as[p - 1] == '/') and (end == as.len or as[end] == '/'))
            return if (p == 0) "content" else try std.fmt.allocPrint(ctx.arena, "{s}content", .{as[0..p]});
        off = end;
    }
    return ".";
}

pub fn execute(ctx: *Ctx, in: Input) tools.Error!Outcome {
    const a = ctx.arena;
    const source = try contentRel(ctx, in.as);
    const policy_path = in.policy_path orelse (try policy.discover(ctx, try policyRoot(ctx, in.as))) orelse
        return ctx.fail("no collection policy found (pass --policy <file> or set KNAP_POLICY); voice is denied without one", .{});
    const pol = try policy.load(ctx, policy_path);
    const coll = pol.match(source);
    const gate: voice.Gate = .{
        .paragraphs = policy.voiceAllowed(coll, in.tone, .paragraphs),
        .list_items = policy.voiceAllowed(coll, in.tone, .list_items),
    };
    var canned: []const voice.Canned = &.{};
    if (in.replies_path) |p| {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, p, a, .limited(16 << 20)) catch
            return ctx.fail("cannot read replies file {s}", .{p});
        canned = voice.parseCanned(a, bytes) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.fail("replies file {s} has a bad line ({s})", .{ p, @errorName(e) }),
        };
    }
    var seen: voice.Seen = .empty;
    if (in.ledger_path) |p| try loadLedger(ctx, &seen, p);
    const result = try voice.voiceDoc(ctx, in.doc, .{ .tone = in.tone, .kind = in.kind, .gate = gate, .canned = canned, .seen = &seen });
    var added: std.ArrayList([]const u8) = .empty;
    var it = seen.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != 0) try added.append(a, e.key_ptr.*);
    }
    std.mem.sort([]const u8, added.items, {}, voicetics.strLess);
    var o: Outcome = .{
        .in = in,
        .source = source,
        .policy_path = policy_path,
        .collection = if (coll) |c| c.name else null,
        .gate = gate,
        .result = result,
        .publish = .{ .not_run = "no changes" },
        .added_terms = added.items,
        .ok = result.proof.holds(),
    };
    if (!gate.paragraphs and !gate.list_items) {
        o.publish = .{ .not_run = "policy denies voice for this collection and tone" };
    } else if (!o.ok) {
        o.publish = .{ .not_run = "invariants failed" };
    } else if (o.changed() and !in.publish) {
        o.publish = .{ .not_run = "disabled" };
    } else if (o.changed()) {
        o.publish = try publishCheck(ctx, result.doc, in);
        o.ok = o.publish == .ran and o.publish.ran.ok;
    }
    if (o.changed()) {
        if (in.ledger_path) |p| try writeLedger(ctx, p, &seen);
        if (o.ok) o.out_doc_id = try store.put(ctx, "md", result.doc);
    }
    return o;
}

/// Read one-term-per-line ledger `path` into `seen` (missing file is an
/// empty ledger). Blank lines and `#` comments are skipped.
fn loadLedger(ctx: *Ctx, seen: *voice.Seen, path: []const u8) tools.Error!void {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.arena, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return ctx.fail("cannot read ledger {s}", .{path}),
    };
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        try seen.put(ctx.arena, try std.ascii.allocLowerString(ctx.arena, t), 0);
    }
}

/// Rewrite `path` as every term `seen` holds, sorted, one per line.
fn writeLedger(ctx: *Ctx, path: []const u8, seen: *const voice.Seen) tools.Error!void {
    var list: std.ArrayList([]const u8) = .empty;
    var it = seen.iterator();
    while (it.next()) |e| try list.append(ctx.arena, e.key_ptr.*);
    std.mem.sort([]const u8, list.items, {}, voicetics.strLess);
    const body = try std.mem.join(ctx.arena, "\n", list.items);
    const data = if (body.len == 0) body else try std.fmt.allocPrint(ctx.arena, "{s}\n", .{body});
    std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path, .data = data }) catch
        return ctx.fail("cannot write ledger {s}", .{path});
}

/// boris validate on the patched doc at its source position. Only the
/// raw profile passes a canonical-id record through untouched, so any
/// other profile is a failure, not a fallback.
fn publishCheck(ctx: *Ctx, doc: []const u8, in: Input) error{OutOfMemory}!PublishCheck {
    const config = boris.siteConfig(ctx, boris.siteDir(ctx) catch |e| return failed(ctx, e)) catch |e| return failed(ctx, e);
    if (config.profile != .raw)
        return .{ .failed = "publish-check needs the raw staging profile (KNAP_BORIS_STAGING=raw or knap-site.json)" };
    const r = boris.check(ctx, doc, in.doc_id, in.as) catch |e| return failed(ctx, e);
    return .{ .ran = r };
}

fn failed(ctx: *Ctx, e: boris.Error) error{OutOfMemory}!PublishCheck {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    const msg = ctx.err_msg;
    ctx.err_msg = "";
    return .{ .failed = msg };
}

/// The report is a diff summary, not a content echo (#330): original
/// run text redacts to length + sha256 so `before`/`after` equality
/// stays checkable without the store's bytes leaving the tool result.
fn writeRedacted(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try w.print("{{\"bytes\":{d},\"sha256\":\"{s}\"}}", .{ s.len, hex });
}

pub fn writeReport(o: Outcome, written: ?[]const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const r = o.result;
    const p = r.proof;
    const S = std.json.Stringify;
    try w.writeAll("{\"doc_id\":");
    try S.value(o.in.doc_id, .{}, w);
    try w.writeAll(",\"source\":");
    try S.value(o.source, .{}, w);
    try w.print(",\"tone\":\"{s}\",\"backend\":\"{s}\",\"policy\":{{\"path\":", .{ @tagName(o.in.tone), @tagName(o.in.kind) });
    try S.value(o.policy_path, .{}, w);
    try w.writeAll(",\"collection\":");
    try S.value(o.collection, .{}, w);
    try w.print(",\"paragraphs\":{},\"list_items\":{}}}", .{ o.gate.paragraphs, o.gate.list_items });
    try w.print(",\"paragraphs_seen\":{d},\"paragraphs_rewritten\":{d},\"line_groups_skipped\":{d},\"frozen_blocks\":{d},\"guard_rejections\":[", .{
        r.fields.len, r.rewritten, r.line_groups, r.frozen_blocks,
    });
    var first = true;
    for (r.fields) |f| {
        if (f.status != .rejected) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"para\":{d},\"line\":{d},\"reason\":\"", .{ f.para, f.line });
        var n: usize = 0;
        for (f.reasons) |why| {
            if (std.mem.startsWith(u8, why, "warning: ")) continue;
            if (n > 0) try w.writeAll("; ");
            n += 1;
            try S.encodeJsonStringChars(why, .{}, w);
        }
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"added_terms\":");
    try S.value(o.added_terms, .{}, w);
    try w.print(",\"density_before\":{d:.2},\"density_after\":{d:.2},\"structhash_equal\":{},\"frontmatter_equal\":{},\"links_equal\":{},\"atoms_equal\":{},\"publish_check\":", .{
        p.density_before, p.density_after, p.structhash_equal, p.frontmatter_equal, p.links_equal, p.atoms_equal,
    });
    switch (o.publish) {
        .not_run => |why| {
            try w.writeAll("{\"ok\":null,\"skipped\":");
            try S.value(why, .{}, w);
            try w.writeAll("}");
        },
        .failed => |why| {
            try w.writeAll("{\"ok\":false,\"error\":");
            try S.value(why, .{}, w);
            try w.writeAll("}");
        },
        .ran => |pr| {
            try w.print("{{\"ok\":{},\"profile\":\"{s}\",\"staged_as\":", .{ pr.ok, @tagName(pr.profile) });
            try S.value(pr.staged_as, .{}, w);
            try w.print(",\"pages\":{d},\"links\":{d},\"diagnostics\":", .{ pr.pages, pr.links });
            try S.value(pr.diagnostics, .{}, w);
            try w.writeAll("}");
        },
    }
    try w.print(",\"ok\":{},\"out_doc_id\":", .{o.ok});
    try S.value(o.out_doc_id, .{}, w);
    try w.writeAll(",\"written\":");
    try S.value(written, .{}, w);
    try w.writeAll(",\"fields\":[");
    for (r.fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"para\":{d},\"line\":{d},\"region\":\"{s}\",\"status\":\"{s}\",\"before\":", .{ f.para, f.line, f.kind.region(), @tagName(f.status) });
        try writeRedacted(f.before, w);
        try w.writeAll(",\"after\":");
        // `after` is the model's rewrite and stays readable; when it
        // repeats the input verbatim (unchanged/rejected/skipped) it
        // redacts the same way, so equality is still observable.
        if (std.mem.eql(u8, f.after, f.before)) {
            try writeRedacted(f.after, w);
        } else {
            try S.value(f.after, .{}, w);
        }
        try w.writeAll(",\"reasons\":");
        try S.value(f.reasons, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn run(ctx: *Ctx, args: ?ObjectMap, out: *Allocating) tools.Error!void {
    const doc_id = try common.requireStr(ctx, args, "doc_id");
    const tone_name = try common.requireStr(ctx, args, "tone");
    const tone = voice.parseTone(tone_name) orelse
        return ctx.fail("unknown tone '{s}': tone must be mild|spicy|feral", .{tone_name});
    const kind = if (common.getStr(args, "backend")) |b|
        backend.parseKind(b) orelse return ctx.fail("backend must be mock|spark|wonder|baseten|acp|compat", .{})
    else
        ctx.backend_kind;
    const entries = store.list(ctx) catch return ctx.fail("cannot list the artifact store", .{});
    const ext = for (entries) |e| {
        if (std.mem.eql(u8, e.doc_id, doc_id)) break e.extension;
    } else return ctx.fail("no such doc '{s}'", .{doc_id});
    if (!std.mem.eql(u8, ext, "md"))
        return ctx.fail("knap_doc_voice needs a markdown doc; '{s}' is .{s}", .{ doc_id, ext });
    const doc = (store.read(ctx, doc_id) catch null) orelse return ctx.fail("no such doc '{s}'", .{doc_id});
    const o = try execute(ctx, .{
        .doc_id = doc_id,
        .doc = doc,
        .tone = tone,
        .kind = kind,
        .as = try common.requireStr(ctx, args, "as"),
        .policy_path = common.getStr(args, "policy"),
        .replies_path = common.getStr(args, "replies"),
        .ledger_path = common.getStr(args, "ledger"),
    });
    try writeReport(o, null, &out.writer);
}

// --- CLI -----------------------------------------------------------------------

const usage_line = "usage: knap-mcp doc-voice <doc_id|file> --tone <t> [--dry-run | --apply --out <file>] [--report <file>] [--as <content path>] [--policy <file>] [--backend <b>] [--replies <jsonl>] [--ledger <file>]";

fn usage(msg: []const u8) u8 {
    std.debug.print("knap-mcp: {s}\n{s}\n", .{ msg, usage_line });
    return 1;
}

/// True when any component of `path` is `content`: the CLI never writes
/// into a source tree, whatever the tree is called beyond that.
fn inContentDir(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "content")) return true;
    return false;
}

/// Canonicalize `path` through the filesystem so a symlink cannot hide the
/// real destination of a write. `realPathFileAbsoluteAlloc` resolves a path
/// that exists whole; a missing or dangling tail peels back to the deepest
/// resolvable ancestor and is re-appended, and a symlinked endpoint is
/// followed by hand so even a dangling link names its target. The result
/// is an absolute path with no `..`.
fn canonicalPath(ctx: *Ctx, path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.arena);
    var suffix: []const u8 = "";
    var rest: []const u8 = try std.fs.path.resolveAlloc(ctx.arena, &.{ cwd, path });
    var hops: usize = 0;
    while (std.fs.path.dirname(rest)) |parent| {
        hops += 1;
        if (hops > 40) return error.SymLinkLoop;
        if (std.Io.Dir.realPathFileAbsoluteAlloc(ctx.io, rest, ctx.arena)) |real| {
            if (suffix.len == 0) return real;
            return std.fs.path.resolveAlloc(ctx.arena, &.{ real, suffix });
        } else |e| switch (e) {
            error.FileNotFound, error.NotDir => {},
            else => return e,
        }
        const stat = std.Io.Dir.statFile(.cwd(), ctx.io, rest, .{ .follow_symlinks = false }) catch null;
        if (stat != null and stat.?.kind == .sym_link) {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const n = std.Io.Dir.readLinkAbsolute(ctx.io, rest, &buf) catch |e| switch (e) {
                error.FileNotFound, error.NotDir => 0,
                else => return e,
            };
            if (n > 0) {
                rest = if (std.fs.path.isAbsolute(buf[0..n]))
                    try ctx.arena.dupe(u8, buf[0..n])
                else
                    try std.fs.path.resolveAlloc(ctx.arena, &.{ parent, buf[0..n] });
                continue;
            }
        }
        suffix = if (suffix.len == 0)
            rest[parent.len + 1 ..]
        else
            try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ rest[parent.len + 1 ..], suffix });
        rest = parent;
    }
    return rest;
}

/// The CLI never writes into a source tree: refuse when `path` names a
/// `content` component lexically or through any symlink it resolves
/// through, and fail closed when the path cannot be canonicalized.
fn writeIntoContent(ctx: *Ctx, path: []const u8) bool {
    if (inContentDir(path)) return true;
    return inContentDir(canonicalPath(ctx, path) catch return true);
}

/// True when `x` and `y` resolve to the same file — symlinks followed, so
/// a linked `--out` or `--report` onto the source is caught. Unresolvable
/// paths compare equal (fail closed).
fn sameFile(ctx: *Ctx, x: []const u8, y: []const u8) bool {
    const cx = canonicalPath(ctx, x) catch return true;
    const cy = canonicalPath(ctx, y) catch return true;
    return std.mem.eql(u8, cx, cy);
}

/// `knap-mcp doc-voice <doc_id|file> --tone <t> [...]`. Dry-run is the
/// default. The report goes to `--report <file>` (stdout then carries
/// the patched doc) or to stdout. `--apply` writes the patched doc to
/// `--out` only when every invariant holds and something changed.
pub fn cli(ctx: *Ctx, args: [][]const u8) anyerror!u8 {
    const Opt = struct { name: []const u8, val: ?[]const u8 = null };
    var opts = [_]Opt{ .{ .name = "--tone" }, .{ .name = "--as" }, .{ .name = "--policy" }, .{ .name = "--backend" }, .{ .name = "--replies" }, .{ .name = "--report" }, .{ .name = "--out" }, .{ .name = "--ledger" } };
    var apply = false;
    var dry_run = false;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    next: while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--apply")) {
            apply = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        for (&opts) |*o| {
            if (std.mem.eql(u8, arg, o.name)) {
                i += 1;
                if (i >= args.len) return usage(try std.fmt.allocPrint(ctx.arena, "missing value for {s}", .{o.name}));
                o.val = args[i];
                continue :next;
            }
            if (std.mem.startsWith(u8, arg, o.name) and arg.len > o.name.len and arg[o.name.len] == '=') {
                o.val = arg[o.name.len + 1 ..];
                continue :next;
            }
        }
        if (arg.len > 1 and arg[0] == '-') return usage(try std.fmt.allocPrint(ctx.arena, "doc-voice: unknown option '{s}'", .{arg}));
        if (target != null) return usage(try std.fmt.allocPrint(ctx.arena, "doc-voice: unexpected argument '{s}'", .{arg}));
        target = arg;
    }
    const tone_opt, const as_opt, const policy_opt, const backend_opt, const replies_opt, const report_opt, const out_opt, const ledger_opt =
        .{ opts[0].val, opts[1].val, opts[2].val, opts[3].val, opts[4].val, opts[5].val, opts[6].val, opts[7].val };
    const arg = target orelse return usage("doc-voice needs exactly one doc_id or file");
    if (apply and dry_run) return usage("--apply and --dry-run are exclusive");
    if (apply and out_opt == null) return usage("--apply needs --out <file>: the patched doc is never written in place");
    if (!apply and out_opt != null) return usage("--out needs --apply (dry-run is the default)");
    for ([_]?[]const u8{ out_opt, report_opt, ledger_opt }) |maybe| if (maybe) |p| if (writeIntoContent(ctx, p))
        return usage(try std.fmt.allocPrint(ctx.arena, "refusing to write '{s}': doc-voice never writes into a content/ dir", .{p}));
    if (out_opt != null and report_opt != null and sameFile(ctx, out_opt.?, report_opt.?))
        return usage("refusing to write: --out and --report resolve to the same file");
    const tone = voice.parseTone(tone_opt orelse return usage("doc-voice needs --tone mild|spicy|feral")) orelse
        return usage("--tone must be mild|spicy|feral");
    const kind = if (backend_opt) |b| backend.parseKind(b) orelse return usage("--backend must be mock|spark|wonder|baseten|acp|compat") else ctx.backend_kind;

    const r = common.resolveDoc(ctx, arg) orelse return usage(try std.fmt.allocPrint(ctx.arena, "no such file or doc '{s}'", .{arg}));
    var doc_id = arg;
    if (r.file_path) |path| {
        if (!std.mem.eql(u8, common.docExtForPath(path), "md")) return usage("doc-voice reads markdown records (.md)");
        for ([_]?[]const u8{ out_opt, report_opt }) |maybe| if (maybe) |o| if (sameFile(ctx, o, path)) return usage("refusing to write over the source doc");
        doc_id = try store.put(ctx, "md", r.bytes);
    }
    const as = as_opt orelse (if (r.file_path) |p| (if (inContentDir(p)) p else null) else null) orelse
        return usage("doc-voice needs --as <content/...> to find the record's collection and staged position");

    const o = execute(ctx, .{ .doc_id = doc_id, .doc = r.bytes, .tone = tone, .kind = kind, .as = as, .policy_path = policy_opt, .replies_path = replies_opt, .ledger_path = ledger_opt }) catch {
        std.debug.print("knap-mcp: {s}\n", .{if (ctx.err_msg.len > 0) ctx.err_msg else "doc-voice failed"});
        return 1;
    };
    var written: ?[]const u8 = null;
    if (apply and o.ok and o.changed()) {
        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = out_opt.?, .data = o.result.doc }) catch {
            std.debug.print("knap-mcp: cannot write --out file '{s}'\n", .{out_opt.?});
            return 1;
        };
        written = out_opt.?;
    }
    var report: Allocating = .init(ctx.arena);
    try writeReport(o, written, &report.writer);
    try report.writer.writeAll("\n");
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    if (report_opt) |p| {
        std.Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = p, .data = report.written() }) catch {
            std.debug.print("knap-mcp: cannot write --report file '{s}'\n", .{p});
            return 1;
        };
        if (o.ok) try w.interface.writeAll(o.result.doc);
    } else try w.interface.writeAll(report.written());
    try w.flush();
    return @intFromBool(!o.ok);
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn testRoot() []const u8 {
    std.Io.Dir.access(.cwd(), testing.io, "eval/doc-voice/record.md", .{}) catch return "knap-mcp/";
    return "";
}

fn testCtx(a: std.mem.Allocator, env: *std.process.Environ.Map, tmp: *std.testing.TmpDir) !Ctx {
    return .{
        .arena = a,
        .gpa = a,
        .io = testing.io,
        .environ = env,
        .engines = .{ .k4o = "k4o", .dogbed = "dogbed" },
        .backend_kind = .mock,
        .templates_dir = try std.fmt.allocPrint(a, "{s}templates", .{testRoot()}),
        .store_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]}),
        .project_root = ".",
    };
}

fn readFixture(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}{s}", .{ testRoot(), rel });
    return std.Io.Dir.readFileAlloc(.cwd(), testing.io, path, a, .limited(1 << 20));
}

test "contentRel takes the part after content/ and rejects escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(arena.allocator(), &env, &tmp);
    try testing.expectEqualStrings("mascots/003.x.md", try contentRel(&ctx, "content/mascots/003.x.md"));
    try testing.expectEqualStrings("mascots/003.x.md", try contentRel(&ctx, "/site/content/mascots/./003.x.md"));
    try testing.expectEqualStrings("mascots/003.x.md", try contentRel(&ctx, "mascots/003.x.md"));
    try testing.expectError(error.ToolFailed, contentRel(&ctx, "content/../x.md"));
    try testing.expectError(error.ToolFailed, contentRel(&ctx, "content/mascots/x.txt"));
    try testing.expectEqualStrings("/site/content", try policyRoot(&ctx, "/site/content/mascots/x.md"));
    try testing.expectEqualStrings("content", try policyRoot(&ctx, "content/x.md"));
    try testing.expectEqualStrings(".", try policyRoot(&ctx, "mascots/contents/x.md"));
}

test "eval fixture: canned replies, guard rejections, verse and atoms untouched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    const doc = try readFixture(a, "eval/doc-voice/record.md");
    const o = try execute(&ctx, .{
        .doc_id = "fixture",
        .doc = doc,
        .tone = .feral,
        .kind = .mock,
        .as = "content/mascots/990.doc-voice-fixture.md",
        .policy_path = try std.fmt.allocPrint(a, "{s}policy/filed.json", .{testRoot()}),
        .replies_path = try std.fmt.allocPrint(a, "{s}eval/doc-voice/replies.jsonl", .{testRoot()}),
        .publish = false,
    });
    try testing.expect(o.ok);
    try testing.expect(o.result.proof.holds());
    try testing.expectEqualStrings("mascots", o.collection.?);
    try testing.expectEqualStrings(try readFixture(a, "eval/doc-voice/record.feral.md"), o.result.doc);
    try testing.expect(o.out_doc_id != null);

    var rejected: std.ArrayList([]const u8) = .empty;
    for (o.result.fields) |f| if (f.status == .rejected) try rejected.append(a, try std.mem.join(a, "; ", f.reasons));
    try testing.expectEqual(@as(usize, 3), rejected.items.len);
    const want = [_][]const u8{ "starts with a block marker", "drops wikilink [[limericks/LIM-0001|Patchy]]", "drops markup character *" };
    for (want, rejected.items) |needle, got| {
        if (std.mem.indexOf(u8, got, needle) == null) {
            std.debug.print("rejection '{s}' lacks '{s}'\n", .{ got, needle });
            return error.TestUnexpectedResult;
        }
    }
    // The **Role:** label block, the limerick and the haiku.
    try testing.expectEqual(@as(usize, 3), o.result.line_groups);

    var out: Allocating = .init(a);
    try writeReport(o, null, &out.writer);
    const rep = try std.json.parseFromSliceLeaky(struct {
        paragraphs_rewritten: usize,
        guard_rejections: []const struct { para: usize, reason: []const u8 },
        structhash_equal: bool,
    }, a, out.written(), .{ .ignore_unknown_fields = true });
    try testing.expectEqual(o.result.rewritten, rep.paragraphs_rewritten);
    try testing.expectEqual(@as(usize, 3), rep.guard_rejections.len);
    try testing.expect(rep.structhash_equal);

    // #330: `before` is a redaction, never source text; `after` stays
    // readable only for rewrites, so before==after is still checkable.
    const rep2 = try std.json.parseFromSliceLeaky(struct {
        fields: []const struct {
            status: []const u8,
            before: std.json.Value,
            after: std.json.Value,
        },
    }, a, out.written(), .{ .ignore_unknown_fields = true });
    try testing.expectEqual(o.result.fields.len, rep2.fields.len);
    for (rep2.fields, o.result.fields) |rf, f| {
        try testing.expect(rf.before == .object);
        try testing.expectEqual(@as(i64, @intCast(f.before.len)), rf.before.object.get("bytes").?.integer);
        try testing.expect(rf.before.object.get("sha256") != null);
        if (std.mem.eql(u8, rf.status, "rewritten")) {
            try testing.expect(rf.after == .string);
            try testing.expectEqualStrings(f.after, rf.after.string);
        } else {
            const b = try std.json.Stringify.valueAlloc(a, rf.before, .{});
            const af = try std.json.Stringify.valueAlloc(a, rf.after, .{});
            try testing.expectEqualStrings(b, af);
        }
    }
    for (o.result.fields) |f| {
        if (f.before.len > 0)
            try testing.expect(std.mem.indexOf(u8, out.written(), f.before) == null);
    }
}

test "policy denial: a verse collection keeps every byte and calls nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    const doc = try readFixture(a, "eval/doc-voice/record.md");
    const o = try execute(&ctx, .{
        .doc_id = "fixture",
        .doc = doc,
        .tone = .feral,
        .kind = .spark,
        .as = "content/haikus/hai-990.md",
        .policy_path = try std.fmt.allocPrint(a, "{s}policy/filed.json", .{testRoot()}),
    });
    try testing.expect(o.ok);
    try testing.expectEqual(@as(usize, 0), o.result.rewritten);
    try testing.expectEqualStrings(doc, o.result.doc);
    try testing.expectEqual(@as(usize, 0), ctx.calls);
    try testing.expect(o.publish == .not_run);
    try testing.expect(o.out_doc_id == null);
    for (o.result.fields) |f| try testing.expectEqual(voice.DocStatus.skipped, f.status);
    // mascots grants mild..feral, so a spicy run needs a key for spark.
    try testing.expectError(error.ToolFailed, execute(&ctx, .{
        .doc_id = "fixture",
        .doc = doc,
        .tone = .spicy,
        .kind = .spark,
        .as = "content/mascots/990.doc-voice-fixture.md",
        .policy_path = try std.fmt.allocPrint(a, "{s}policy/filed.json", .{testRoot()}),
    }));
}

test "ledger: a term one record adds is closed to the next" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "replies.jsonl", .data =
        \\{"input":"First fixture paragraph keeps calm.","output":"First fixture paragraph keeps preternaturally calm."}
        \\{"input":"Second fixture paragraph keeps calm.","output":"Second fixture paragraph keeps preternaturally calm."}
        \\
    });
    const replies = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/replies.jsonl", .{tmp.sub_path});
    const ledger = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ledger.txt", .{tmp.sub_path});
    const policy_path = try std.fmt.allocPrint(a, "{s}policy/filed.json", .{testRoot()});
    const o1 = try execute(&ctx, .{
        .doc_id = "d1",
        .doc = "First fixture paragraph keeps calm.\n",
        .tone = .mild,
        .kind = .mock,
        .as = "content/mascots/991.dedup.md",
        .policy_path = policy_path,
        .replies_path = replies,
        .ledger_path = ledger,
        .publish = false,
    });
    try testing.expect(o1.ok);
    try testing.expectEqual(@as(usize, 1), o1.result.rewritten);
    try testing.expectEqual(@as(usize, 1), o1.added_terms.len);
    try testing.expectEqualStrings("preternaturally", o1.added_terms[0]);
    const body = try std.Io.Dir.readFileAlloc(.cwd(), testing.io, ledger, a, .limited(1 << 20));
    try testing.expectEqualStrings("preternaturally\n", body);
    const o2 = try execute(&ctx, .{
        .doc_id = "d2",
        .doc = "Second fixture paragraph keeps calm.\n",
        .tone = .mild,
        .kind = .mock,
        .as = "content/mascots/992.dedup.md",
        .policy_path = policy_path,
        .replies_path = replies,
        .ledger_path = ledger,
        .publish = false,
    });
    try testing.expect(o2.ok);
    try testing.expectEqual(@as(usize, 0), o2.result.rewritten);
    try testing.expectEqual(voice.DocStatus.rejected, o2.result.fields[0].status);
    const why = try std.mem.join(a, "; ", o2.result.fields[0].reasons);
    try testing.expect(std.mem.indexOf(u8, why, "repeats 'preternaturally' from an earlier record") != null);
    // Nothing shipped, so the ledger keeps only the first record's term.
    try testing.expectEqualStrings(body, try std.Io.Dir.readFileAlloc(.cwd(), testing.io, ledger, a, .limited(1 << 20)));
}

test "cli refuses --apply without --out and any write into content/" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = try testCtx(a, &env, &tmp);
    const cases = [_][]const []const u8{
        &.{ "x.md", "--tone", "feral", "--apply" },
        &.{ "x.md", "--tone", "feral", "--out", "y.md" },
        &.{ "x.md", "--tone", "feral", "--apply", "--dry-run", "--out", "y.md" },
        &.{ "x.md", "--tone", "feral", "--apply", "--out", "site/content/mascots/x.md" },
        &.{ "x.md", "--tone", "feral", "--report", "content/r.json" },
        &.{ "x.md", "--tone", "loud" },
        &.{"x.md"},
    };
    for (cases) |c| {
        const argv = try a.dupe([]const u8, c);
        try testing.expectEqual(@as(u8, 1), try cli(&ctx, argv));
    }
    try testing.expect(inContentDir("a/content/b.md"));
    try testing.expect(!inContentDir("a/contents/b.md"));
}
