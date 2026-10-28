# Track MD-VC: voice coverage for the new slots and the runbook template (issue #231, wave 3)

Lane MD-VC. Owner files: `knap-mcp/templates/shapes/{release-notes,reading-note,runbook}.json`,
`knap-mcp/prompts/voice/mock/*.jsonl`, `knap-mcp/src/voice.zig` (the two test
template lists), `knap-mcp/eval/voice/run.sh` (the template list), this note.
Depends on #229 (MD-VH: `==highlight==` legal in voice replies, `rendered
highlight` as the W4 plain-slot marker) and #230 (MD-RT2: ratchet wiring for
the new slots), both merged.

## What changed

### `voice: true` on the new slots (shape files)

- `release-notes`: `preflight`, `upgrade_steps`, `rollback` — the
  array-of-strings fields the template lanes shipped without voice.
- `reading-note`: `argument`, `follow_ups`, `thesis`.
- `runbook`: `summary`, `preflight`, `rollback`, and the nested
  `phases[].steps[].do` / `phases[].steps[].expect`. The two-level walk in
  `collect`/`collectFields` (`voice.zig:262-312`) already recurses
  `array<object>` inside `array<object>`, so `phases[*].steps[*]` slots come
  out as `phases[0].steps[0].do` with the leaf role — no walker change
  needed. `do` keeps `footnote_abutting`: steps carrying a `note` reject a
  reply that ends with `!`.

Never voiced, per the issue and the `never_keys` list: `command`, `lang`,
`epigraph`, `lesson`, `error_budget`, `slo_target`, `escalation` rows, URLs,
names, `notes` keys, `service`/`owner`/`severity`/`last_reviewed`.

### Role tweaks for the W4 plain-slot marker

`plainRole` matches normalized words — `rendered` immediately followed by
`highlight`. Two roles said "highlighted" or described the `==` mechanics
without the marker phrase, so a `voice: true` reply could legally inject
formatting into slots the template already styles. Changed minimally:

- `reading-note.thesis`: "rendered highlighted after a bold 'Thesis:'
  label" → "a rendered highlight after a bold 'Thesis:' label".
- `runbook.danger`: "highlighted with == == inside the 'Do not skip' danger
  callout" → "a rendered highlight inside the 'Do not skip' danger callout".

Both are now plain slots: their mock replies add no `*`/`` ` ``/`~~`/`==`
and no emoji in any tone. (`thesis`'s "highlighted" did not match the
marker — the issue anticipated this; the note records the change as
required.)

### Mock replies (`prompts/voice/mock/*.jsonl`)

42 new replies per tone, appended in the same order in all three files —
`check.sh`/`voice.awk` aligns `(template, field, field_role, input)`
positionally across tones, so the appended blocks are identical but for
`output`. `field_role` is the shape role verbatim, ` (one item)` suffixed
for `array<string>` items, matching `collect`'s `item_role`. Counts:
release-notes 10, reading-note 9, runbook 23 (every voice slot in
`runbook.sample.json`). Tone budgets hold; runbook feral carries `**`,
`==` and one `🎉` across its replies, so the eval's feral-format check and
the zig test's `feral_fmt` pass.

### Template lists

`runbook` added to the two test lists in `voice.zig` (the mock voice-pass
test and the verbatim field-roles test) and to `templates=` in
`eval/voice/run.sh`.

### Description line

`runbook.json`'s `description` gained the same "except that `voice: true`
fields may carry constrained inline formatting" clause the other voiced
shapes already had — it previously claimed strings hold no markup at all,
which the new flags contradict.

## Verification

- `knap-mcp voice runbook -d data/runbook.sample.json --tone feral
  --backend mock`: exit 0, `changed` 23, `rejected` 0, `unchanged` 0; the
  same for mild and spicy, and for release-notes (24) and reading-note
  (21) on all tones.
- `make voice-eval`: runbook rows render with identical normalized
  structhashes across mild/spicy/feral, markdown and html; all three
  tones differ from the original; feral adds formatting.
- `sh knap-mcp/prompts/voice/check.sh`: 240 mock replies, 0 warnings,
  0 failures.
- `make test`: 209/209. `make eval`, `make ratchet-eval`, `make demo`:
  pass.
