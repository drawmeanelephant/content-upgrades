# Track VOICE-AWK-MIRROR: awk guard catches up to the zig runtime (issue #332)

Lane: issue #332. Owner files: `knap-mcp/prompts/voice/voice.awk`,
`check.sh`, `README.md`, `testdata/bad.jsonl`.

`voice.awk` under-enforced the documented contract vs `voice.guard`
(`knap-mcp/src/voice.zig`), so `check.sh` — the CI gate for examples and
mock replies — admitted replies the runtime rejects.

## What the awk side gained

- **Boris atoms as protected tokens** (zig `facts()`): `![[embeds]]`,
  `{{include …}}` includes and `<Aside …>`/`<Details …>` component tags
  (open and close tags are one atom each; unterminated tags protect the
  rest of the string). Kind names and reasons match zig: `embed`,
  `include`, `component`, substring-matched. A `{{include a}}` →
  `{{include b}}` or `<Aside>` → `<Details>` swap now reports
  `drops/adds <kind> <token>` instead of passing.
- **Content-word retention** (zig `guard` W-overlap): keep at least half
  the input's content words (the `ci.len >= 3` floor too) —
  `keeps only K of N input content words`.
- **Meta-prose wrap**: a reply containing the input verbatim may not lead
  with two or more content words the input lacks —
  `wraps the input with extra prose`.
- **`footnote_abutting`** (zig `guard`'s `footnote_abutting` param): the
  JSONL format gained the one non-string value — a bare `true`/`false`
  literal (jparse decodes it to its spelling; anything else is a schema
  error). `guard(tone, role, fab, in_, out)` reports
  `ends with ! where a footnote marker follows (renders as image syntax)`.
  The key is allowed on every line kind, validated to be true/false, and
  joined into the cross-tone `SEQ` key so an example/mock lane can't mark
  the flag in one tone only.

## Still runtime-only

The W1 insert-only skeleton (`structhash.isFormatting` — a code span
around `[^1]` or the input's own `**bold**`) needs a structhash rebuild,
which is beyond POSIX awk. README rule 3 marks it in place.

## `src/voice.zig` twin edit (landed on this branch)

`zig build test` reads `testdata/bad.jsonl` through `parseLines` →
`Line`: unknown keys are hard errors (`error.UnknownField`) and the count
is pinned. On the merge captain's instruction this lane carried the twin
edit: `Line` gains `footnote_abutting: bool = false`, both `Line`-driven
selftests pass `l.footnote_abutting` to `guard`, and the count is the
branch's actual 60 lines. 287/287 zig tests pass; the six new cases are
caught by the zig oracle. Sibling lanes #331/#333/#334 also edit
`src/voice.zig` and `bad.jsonl`, so whichever lands last re-bumps the
count.
