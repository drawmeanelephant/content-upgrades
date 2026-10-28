# MD-SH lane notes — #223: structhash sees `==highlight==` and `$math$`

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/structhash.zig` | `hl`/`/hl` for `==…==`, `math` for `$…$`, `mathblock` for `$$` blocks, `mark` in `fmt_html_tags`, `hl`/`/hl`/`<mark>`/`</mark>` in `isFormatting`, header doc updated, new unit tests |

No other files touched. `voice.zig` W1 picks the new `isFormatting` kinds up
for free; W6's `==` hard-reject (`voice.zig:1117`) and the `$` lock
(`voice.zig:618`) stay as they are — lane MD-VH owns unlocking them.

## New token kinds

- `hl` / `/hl` — `==…==`, resolved with the same delimiter-run machinery as
  `~~` (flanking, nearest-opener matching, two chars per side). Only a run
  of exactly two `=` is a candidate; `a == b` flanks out to text, an
  unmatched `==` leaves two `delim:=` tokens, and `==a *b*==` nests as
  `hl em /em /hl`.
- `math` — one leaf token per `$…$` span, content opaque like a code span.
  The rule is pandoc's, verified against dogbed `d96b125`: opener `$`
  followed by a non-space, non-`$`; closer `$` preceded by non-space and
  not followed by a digit; no newline inside; `\$` never opens or closes.
  `$400 or $500`, `$ 5 $`, `\$5` all stay invisible; `a$b$c` and
  `Between $5 and $10, or 10$ to 20$ each.` produce `math` (the second
  closes at `10$`). A `$` inside a code span never opens.
- `mathblock` — a line that trims to exactly `$$` opens a block closed by
  the next such line; content opaque; unclosed runs to EOF, same as a
  fence. `$$` interrupts a paragraph everywhere a fence does (`interrupts`
  and `startsBlockInTable`).

`hl` is formatting (dropped by `ignore_formatting`, in `isFormatting`);
`math`/`mathblock` are structural and always kept — `$x$` must not hash
equal to `x`. On the html side `<mark>`/`</mark>` join `isFormatting` and
`fmt_html_tags`, while `<span class="math inline">` and
`<div class="math display">` keep their structural `class` values (pinned
by test).

## Probe

`knap-mcp structhash /tmp/md-probe.md --explain` now ends

```
quote p /quote mathblock p math hl /hl del /del hr p
```

Previously `quote p /quote p p em /em del /del hr p` — the `$$` block read
as `p`, the `*c*` inside math leaked as `em /em`, and `==` was invisible.

## Hash table, before → after (a03bd3a → this branch)

Default mode. Only docs containing `==` or `$` may move; that's the point
of the lane.

| doc | before | after | changed |
|---|---|---|---|
| eval/density/README.md | c5f301cc47ccd9e1 | c5f301cc47ccd9e1 | - |
| eval/density/apparatus.md | e31011da7ab77a85 | e31011da7ab77a85 | - |
| eval/density/confetti.md | 6e1aa9749be87368 | 36738b3279c6e427 | `==` highlights |
| eval/density/dense-ideal.md | d543a27d07304221 | 2775898381ff3199 | `==restraint==` |
| eval/density/flat-barf.md | dddba9de24978cb1 | dddba9de24978cb1 | - |
| eval/density/generic.md | 2694a09267f06532 | 2694a09267f06532 | - |
| eval/density/reading-note.md | 576b7ce1dde06cfa | 576b7ce1dde06cfa | - |
| eval/density/reading-note.min.md | 74498e60d5fddd75 | 74498e60d5fddd75 | - |
| eval/density/release-notes.md | 1a4baebfb2e6d0d1 | 1a4baebfb2e6d0d1 | - |
| eval/density/release-notes.min.md | 29ec1dd155648d47 | 29ec1dd155648d47 | - |
| eval/density/verdict-v1.html-table.md | 727193b1f9e34cca | 727193b1f9e34cca | - |
| eval/density/verdict-v1.pipe-table.md | 1292152b5b90a177 | 1292152b5b90a177 | - |
| eval/density/verdict.md | 6a738a8906ac2273 | 6a738a8906ac2273 | - |
| render verdict.sample (markdown) | 6a738a8906ac2273 | 6a738a8906ac2273 | - |
| render verdict.sample (html) | 17e30c88180f8893 | 17e30c88180f8893 | - |
| render reading-note.sample (markdown) | 576b7ce1dde06cfa | 576b7ce1dde06cfa | - |
| render reading-note.sample (html) | c71e5ede8aed5663 | c71e5ede8aed5663 | - |
| render apparatus.sample (markdown) | e31011da7ab77a85 | e31011da7ab77a85 | - |
| render apparatus.sample (html) | 89ea94236e26bc71 | 89ea94236e26bc71 | - |
| render release-notes.sample (markdown) | 1a4baebfb2e6d0d1 | 1a4baebfb2e6d0d1 | - |
| render release-notes.sample (html) | 2bc474ceed3d521f | 2bc474ceed3d521f | - |

Recorded hashes still match: `demo/frozen/06-structhash.txt` (demo beat 6)
and `6a738a8906ac2273` from `docs/tracks/VOICE.md`.

`--ignore-formatting`: `the ==key== bit` == `the key bit`
(`f1ecaf67698af55a`); `$x$` (`a292df407a860ba4`) != `x`.

## Gate

- `make test` — pass
- `KNAP_MCP_HOME=$(mktemp -d) make eval` — converged 120/167, controls 2/2
- `KNAP_MCP_HOME=$(mktemp -d) make voice-eval` — 12 template x tone runs
  matched the jq reference; guard controls pass
- `sh knap-mcp/prompts/voice/check.sh` — 36 examples, 44/44 selftest breaks
  caught, 0 warnings, 0 failures
- `make demo` — all 9 beats ok; beat 6 still `6a738a8906ac2273`
- `cd knap-mcp && zig fmt --check src` — clean

## What other lanes must know

- `hl`, `math`, `mathblock`, `delim:=` are new kind strings in the token
  stream; `isOpener` treats `hl` as a container for `--explain` depth only.
- MD-VH can now drop the `==` hard-reject and the `$` lock in `voice.zig`;
  `isFormatting("hl")` is already true for its insert-only check.
- `$$x$$` on one line hashes as `p math` (pandoc rule), not `mathblock` —
  `mathblock` is only for lines that trim to exactly `$$`, matching the
  issue. dogbed renders `$$x$$` inline as `math display`; if a later lane
  needs that distinction, file it as new work.
