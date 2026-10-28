# FILED-VOICE — guarded doc-level voice pass (#257)

## What landed

`knap-mcp doc-voice <doc_id|file> --tone <t> [--dry-run | --apply --out <file>]
[--report <file>] [--as <content path>] [--policy <file>] [--backend <b>]
[--replies <jsonl>]` and the `knap_doc_voice` MCP tool.

| Path | What |
|---|---|
| `knap-mcp/src/voice.zig` | Doc section (after `guard`): `docWalk` (paragraph and list-item runs), `docGuard` (field guard plus protected atoms kept in order), `atomList`/`linkTargets`, `prove` (whole-doc invariants), `mockEmphasis`, `Canned` replies, `voiceDoc`. `systemPrompt` was factored out of `voiceData` with no behavior change (`make voice-eval` passes). `components` now shares `componentEnd`. |
| `knap-mcp/src/tools/doc_voice.zig` | New. Policy gate, publish-check under raw, report, MCP tool, CLI. |
| `knap-mcp/src/tools.zig`, `src/main.zig` | One registry line, one CLI row, three help lines, one test import. |
| `knap-mcp/eval/doc-voice/` | `record.md` (fixture), `replies.jsonl` (3 must-reject + 1 must-pass), `record.feral.md` (golden), `run.sh` (21 CLI checks incl. publish-check on a throwaway raw site). |

## How the pass works

1. **Walk** (`voice.docWalk`). Only two shapes are rewritable: a
   blank-line-separated group that is **one plain line** (paragraph), or a
   group made **entirely of single-line list items** (each item's text after
   the marker). Everything else is copied verbatim: frontmatter, headings,
   fences, `$$`, html, `<!-- -->`, `<Aside>`/`<Details>` (depth-tracked
   across blank lines), quotes and callouts, tables, footnote and link
   definitions, `{{include}}` and `![` lines, thematic breaks, setext
   underlines, indented code, and **every multi-line group**. That last
   rule covers verse: haiku lines, limerick lines with hard breaks, and
   soft-wrapped label blocks like `**Role:** …`. Those count as
   `line_groups_skipped`. They map to policy region `verse`, and they stay
   frozen even when a policy grants `verse`.
2. **Gate.** `policy.voiceAllowed(match(rel), tone, .paragraphs|.list_items)`.
   If no policy is found, the run errors out (pass `--policy`, or put
   `knap-policy.json` in or above the `content/` dir). If the policy is
   found but the doc is unpoliced, or denied for this tone, every run is
   `skipped`: no backend call, no write, exit 0.
3. **One call per run.** A canned reply (`--replies`) wins. Otherwise
   `mock` uses `mockEmphasis`: the longest free lowercase word of 5+
   letters, wrapped as `*x*` for mild or `**x**` otherwise. Otherwise the
   pass calls `backend.complete(.voice)` with the existing voice prompt
   contract (`Field: paragraph N`). There are no retries. A backend error
   becomes a rejection.
4. **Guard per reply** (`docGuard`) = the field `guard` (insert-only
   skeleton, delimiter accounting, locked chars, block markers, facts,
   meta-prose, budgets) **plus** a check that the reply's protected atoms
   match the input's in exact order. If the guard fails, the run keeps its
   original text and the failure goes into `guard_rejections`.
5. **Proof** (`voice.prove`) on the patched doc: `structhash
   --ignore-formatting` equal, frontmatter bytes equal, wiki-link targets
   equal, atom list equal (in order), and `density_after >= density_before`.
6. **publish-check** (`boris.check`) runs only if the proof holds and
   something changed. It requires the **raw** profile. Any other profile
   is reported as a failure, not a fallback.
7. **Writes.** The pass writes only when the proof holds and publish-check
   is ok. The MCP tool stores the patched doc (`out_doc_id`). The CLI
   writes `--out` only with `--apply`. It refuses `--apply` without
   `--out`, `--out` without `--apply`, any `--out`/`--report` path with a
   `content` component, and an `--out` that resolves to the source. Exit
   code 1 means not proven or not clean.

Report (stdout, or `--report <file>`, in which case stdout carries the
patched doc): `doc_id, source, tone, backend, policy{path,collection,
paragraphs,list_items}, paragraphs_seen, paragraphs_rewritten,
line_groups_skipped, frozen_blocks, guard_rejections[{para,line,reason}],
density_before, density_after, structhash_equal, frontmatter_equal,
links_equal, atoms_equal, publish_check, ok, out_doc_id, written,
fields[{para,line,region,status,before,after,reasons}]`.

## Done-when evidence

Real record, filed@ce44821f, mock backend:

```sh
KNAP_BORIS_SITE=~/dev/filed.fyi KNAP_BORIS_STAGING=raw KNAP_BORIS_THEME=themes/cantilever \
  knap-mcp doc-voice ~/dev/filed.fyi/content/mascots/003.blamey-mctypoface.md \
  --tone feral --dry-run --policy knap-mcp/policy/filed.json --report /tmp/blamey.json
```

- exit 0. Paragraphs seen 41, rewritten 32, unchanged 8, skipped 1 (the
  alt text). 62 line groups (haiku and limerick stanzas, label blocks)
  untouched. 0 rejections.
- Density went from 37.55 to 40.25. `structhash_equal`, `frontmatter_equal`,
  `links_equal` and `atoms_equal` are all true. publish-check returned
  `{"ok":true,"profile":"raw","pages":2552,"links":2,"diagnostics":[]}`.
- The diff is 32 lines, each one a single inserted `**word**`. No line
  ending in a hard break changed, the line count is unchanged (622), and
  the source sha256 is unchanged.
- Crafted rejections (`eval/doc-voice/replies.jsonl`): an added `# ` gives
  `starts with a block marker`. `[[limericks/LIM-0001|Patchy]]` →
  `LIM-0002` gives `drops wikilink …` and `moves or edits a protected atom`.
  A dropped input `**` gives `drops markup character *`. In each case the
  original paragraph survives byte for byte.
- `--apply` without `--out` refuses. `--out …/content/…` refuses. The
  source is never written.
- Fixtures cover skipped verse lines, untouched include, Aside, fence and
  quote atoms, and rejection accounting. The Zig test
  `tools/doc_voice.zig` runs the fixture against the golden file inside
  `make test`. `eval/doc-voice/run.sh` covers the CLI and publish-check.

## Gates

- `make test`: 261/261 (was 253).
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 120/167 (unchanged).
- `make voice-eval`: pass (checks the `systemPrompt` refactor).
- `knap-mcp/eval/doc-voice/run.sh`: 21/21. Needs boris and jq.
- `zig fmt --check src`: clean.

## For other lanes / follow-ups

- **Mock is a canned path, as AGENTS.md asks.** The real-record evidence
  above uses mock emphasis, not a model. A live run (`--backend acp|…`)
  goes through the same guard and proof. The live voice prompt was written
  for template fields, so a doc-specific prompt section (in
  `prompts/voice/`, which this lane doesn't own) would probably cut live
  rejections.
- **Conservative walk.** Soft-wrapped multi-line prose paragraphs are
  never voiced, because the field guard is single-line by contract. If
  filed starts wrapping prose, the next step is a per-line pass inside
  such groups.
- **Site inference.** publish-check needs `KNAP_BORIS_SITE`,
  `KNAP_BORIS_STAGING=raw` and `KNAP_BORIS_THEME=themes/cantilever` for
  filed, because filed has no `knap-site.json`. Adding
  `{"staging":"raw","theme":"themes/cantilever"}` there would drop two of
  the three env vars. That change belongs in the filed repo.
- **Captain.** README and `docs/SPEC.md` could list `doc-voice` and
  `knap_doc_voice`. Those files are outside this lane.
