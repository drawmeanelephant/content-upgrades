//! The `--- … ---` block model: parsed once per doc into a frozen byte
//! range plus a top-level key set. Boris frontmatter is a closed schema,
//! not a YAML playground — tools that touch it keep the range as opaque
//! bytes and use the key set for membership checks (site profiles assert
//! the closed schema; staging splices around the range).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Block = struct {
    /// [lo, hi) byte range in the doc: the opening fence through the
    /// closing fence's newline, so doc[hi..] is the body verbatim.
    lo: usize,
    hi: usize,
    /// 1-based line number of the closing fence.
    close_line: u32,
    /// Top-level `key:` names in document order — views into the doc.
    keys: []const []const u8,
    /// 1-based line of each key, parallel to `keys` (for diagnostics).
    key_lines: []const u32,

    /// Is `key` present (case-sensitive)?
    pub fn has(b: Block, key: []const u8) bool {
        for (b.keys) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    /// Index into `keys`/`key_lines` of the first key outside `schema`,
    /// else null — the closed-schema membership question a site profile
    /// asks.
    pub fn firstUnknown(b: Block, schema: []const []const u8) ?usize {
        for (b.keys, 0..) |k, i| {
            for (schema) |s| {
                if (std.mem.eql(u8, k, s)) break;
            } else return i;
        }
        return null;
    }
};

/// Parse the leading `--- … ---` block. Null when the doc doesn't open
/// with `---` or the block never terminates — an unterminated block is
/// prose, the convention density, formatcheck and structhash share.
/// Keys are the dedented `name:` tokens; indented lines, `- ` sequence
/// items and `#` comments belong to the previous key's value.
pub fn parse(alloc: Allocator, doc: []const u8) Allocator.Error!?Block {
    var keys: std.ArrayList([]const u8) = .empty;
    var key_lines: std.ArrayList(u32) = .empty;

    var it = std.mem.splitScalar(u8, doc, '\n');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \r\t"), "---")) return null;

    var pos: usize = first.len + 1; // byte offset of the current line
    var line_no: u32 = 1;
    while (it.next()) |line| {
        line_no += 1;
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) {
            // hi is the byte after the closer's newline (or EOF).
            const hi = @min(pos + line.len + 1, doc.len);
            return .{
                .lo = 0,
                .hi = hi,
                .close_line = line_no,
                .keys = keys.items,
                .key_lines = key_lines.items,
            };
        }
        pos += line.len + 1;
        if (t.len == 0 or t[0] == '#') continue;
        if (line[0] == ' ' or line[0] == '\t') continue; // nested / list values
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t\"'");
        if (key.len == 0 or std.mem.indexOfAny(u8, key, " \t") != null) continue;
        try keys.append(alloc, key);
        try key_lines.append(alloc, line_no);
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn blockAt(a: Allocator, doc: []const u8) !Block {
    return (try parse(a, doc)) orelse error.TestUnexpectedResult;
}

test "parse: range, closer line and key set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = "---\ntitle: \"T\"\nid: limericks/LIM-0155\ntags: [a, b]\n---\n\nbody\n";
    const b = try blockAt(arena.allocator(), doc);
    try testing.expectEqual(@as(usize, 0), b.lo);
    try testing.expectEqualStrings("---\ntitle: \"T\"\nid: limericks/LIM-0155\ntags: [a, b]\n---\n", doc[b.lo..b.hi]);
    try testing.expectEqualStrings("\nbody\n", doc[b.hi..]);
    try testing.expectEqual(@as(u32, 5), b.close_line);
    try testing.expectEqual(@as(usize, 3), b.keys.len);
    try testing.expect(b.has("id"));
    try testing.expect(!b.has("parent"));
}

test "parse: values, sequences, comments and nested lines are not keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc =
        \\---
        \\title: x
        \\tags:
        \\  - a
        \\  - b
        \\# a comment
        \\nested:
        \\  inner: nope
        \\parent: index
        \\---
    ;
    const b = try blockAt(arena.allocator(), doc);
    try testing.expectEqual(@as(usize, 4), b.keys.len);
    try testing.expectEqualStrings("title", b.keys[0]);
    try testing.expectEqualStrings("tags", b.keys[1]);
    // `nested` is a key (its indented map is illegal in boris, but the
    // name is what a schema check judges); `inner` is not.
    try testing.expectEqualStrings("nested", b.keys[2]);
    try testing.expectEqualStrings("parent", b.keys[3]);
    try testing.expectEqual(@as(u32, 9), b.key_lines[3]);
}

test "parse: no block without a leading fence or a closer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parse(a, "# Title\n\n---\nx: 1\n---\n")) == null);
    try testing.expect((try parse(a, "x ---\ny: 1\n---\n")) == null);
    try testing.expect((try parse(a, "---\nx: 1\n")) == null);
    try testing.expect((try parse(a, "---\n")) == null);
    // `...` also closes, matching formatcheck's frontmatterEnd.
    const b = try blockAt(a, "---\nx: 1\n...\nbody");
    try testing.expectEqual(@as(u32, 3), b.close_line);
    try testing.expect(b.has("x"));
}

test "firstUnknown asserts closed-schema membership" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schema = [_][]const u8{ "id", "title", "parent", "status", "tags" };
    const good = try blockAt(arena.allocator(), "---\nid: a\ntitle: T\nstatus: draft\n---\n");
    try testing.expect(good.firstUnknown(&schema) == null);
    const bad = try blockAt(arena.allocator(), "---\ntitle: T\nmood: feral\n---\n");
    const i = bad.firstUnknown(&schema).?;
    try testing.expectEqualStrings("mood", bad.keys[i]);
    try testing.expectEqual(@as(u32, 3), bad.key_lines[i]);
}
