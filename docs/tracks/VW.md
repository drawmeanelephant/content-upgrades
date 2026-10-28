# Lane VW: voice audit fixes (#200, #201, #203)

Second audit batch on the voice guard. `src/voice.zig` stays the source
of truth; `prompts/voice/voice.awk` (the check.sh reference guard) is
brought to parity where the issue asked for it.

## What landed

**#200 — W3 + W6 ported to `voice.awk`.**

- W3 (`strikes input words`): the awk guard now walks `~~…~~` runs of
  exactly two tildes (code spans hidden first via `` gsub(/`[^`]*`/) `` —
  the Zig scan runs on the raw reply and is intentionally stricter there).
  `strikeinnerok` mirrors `strikeInnerOk`: no number token, none of the
  input's protected tokens (`FI` + `present`), no negation, and no inner
  content word sharing a stem with an input content word. The awk port
  re-implements `verifier.zig`'s tokenizing: `norm` (lowercase ASCII,
  curly quotes straightened, `…` -> `...`, whitespace collapsed),
  `contentwords` (stopwords/negations/number-words/`stem`, digit words
  kept raw), all in LC_ALL=C bytes.
- W6 (`code span text not in the input`): walks single-backtick runs the
  same way Zig does (a multi-backtick run is never an opener, but any
  backtick can close an open single span) and requires the inner text to
  be a substring of the input — plus the new whole-input rule below.
- `bad.jsonl` cases: `~~boring~~` and `~~shipped~~` strikes,
  `` `vacuumdb` `` not in the input, and a code span wrapping the whole
  input.

**#201 — emoji allowlist is now a named set, plus a drop rule.**

- `allowed_emoji` in `voice.zig` and `EMOJI` in `voice.awk` are explicit
  lists: the six dingbats (✨ ⚡ ⚠ ✅ ❌ ☕) plus a curated pictograph set
  (🔥 💀 🙄 🎁 🪣 🏛 🚀 🐛 🎉 📉) that covers everything the
  examples/mocks/tests actually ship. `isDisallowedEmoji`/`NOEMOJI` now
  mean "every other code point in U+1F000–1FAFF", so 💩 🤡 🫠 🥵 🪦 and
  anything else the model picks are `adds disallowed emoji`. The allowlist
  is checked first in both guards (Zig `classifyCp` order flipped;
  `emojiscan` tests `EMOJI` before `NOEMOJI`).
- The awk comment that claimed 1F600–1F64F while the regex covered
  1F600–1F67F is gone — the named list has no range to misstate.
- `mock/feral.jsonl` `breaking[0].change` ends with 💀 instead of 🪦.
- Keep rule: a reply may not drop a non-ASCII code point the input
  carried (`drops non-ASCII character U+XXXX`), in both guards — the
  non-ASCII twin of the insertable-markup drop check. This caught a real
  bug: `mock/mild.jsonl` `summary` silently dropped the input's two
  em-dashes; they are restored.
- README rule 4 now describes the named allowlist and the drop rule.

**#203 — four guard gaps.**

- W6 rejects a code span whose text equals the entire input
  (`code span wraps the whole input`), in both guards.
- `plainRole`/`plainrole` match on normalized words (lowercase, split on
  non-alphanumerics): `ALT TEXT` and `Frontmatter value` now match;
  `rendered boldly` and `image alt` no longer substring-match. Verified
  every `field_role` in examples/, mock/ and bad.jsonl classifies the
  same as before.
- W3 stem gap: `sameStem`/`samestem` treat two stems as equal when one
  is a ≥4-byte prefix of the other, so `~~shipped~~` retracts input
  `ships` (crude stemmer gives `shipp` vs `ship`).
- Mild tone: formatting-span overruns, `mild: only *italic*` and emoji
  overruns moved from advisory (`budget`) to hard failures — same reason
  strings, so `bad.jsonl` expects still match. Caps and `!` budgets stay
  advisory in every tone.
- README Files-table `system.md` row now says "keep the input's markup,
  add only inline formatting within limits" instead of "add no markup".

`bad.jsonl` is now 44 cases (37 + 7 new).

## Gate output

**UNVERIFIED — see handoff.** The sandbox this lane ran in denied every
mutating/execution command (`git worktree`, `git checkout`, `git commit`,
`gh`, `make`, `sh`, `awk`), so no gate could be run. Required before
merge:

- `make test` (bad.jsonl count assertion updated to 44)
- `sh knap-mcp/prompts/voice/check.sh` — break count should rise to
  44/44 selftest breaks caught
- `KNAP_MCP_HOME=$(mktemp -d) make voice-eval`

## Left / other lanes should know

- Behavior changes beyond the audit items: mild formatting-span and
  emoji overruns are now hard failures (#203 item 4 was optional; I took
  it — the diff is three lines and mild is the conservative tone).
- Zig W3 still scans the raw reply; awk hides code spans first per the
  issue text, so awk is slightly more permissive for `` `~~` `` inside
  backticks. Noted as an intentional divergence, like the skeleton check
  awk can't express.
- New reason strings other lanes/evals may match on:
  `code span wraps the whole input`, `drops non-ASCII character U+XXXX`.
- No worktree could be created and no commit could be made from this
  environment — see handoff for the exact commands to run.
