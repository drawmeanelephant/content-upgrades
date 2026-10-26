# Captain notes

Loose ends the merge captain handled or is tracking across lanes.

## 2026-10-26: trailing `!` before a template footnote marker

`release-notes.knap` appends a footnote marker straight after a voice-eligible
value: `{{ h.what }}[^{{ h.note | kebab }}]`. A value ending in `!` makes the
bytes `![^...]`, which oliver reads as image syntax and leaves literal — the
footnote ref and its definition vanish from the html (markdown output is
unchanged; k4o's structhash markdown mode still counts the marker). Caught by
eval/voice: release-notes html hashed differently under feral.

Handled for now: the feral mock reply for `highlights[0].what` ends with
"somebody pinch me." instead of "pinch me!". The hazard is real for live
feral output, which loves a trailing `!`. Open follow-up: the voice guard
(src/voice.zig) could reject a value ending in `!` for fields a shape marks
as abutting a footnote marker, or the shape could forbid it per field.

## 2026-10-26: conformance is 187/188

K5 (#33) taught the runner k4o's warning lines. Sole failure:
`diagnostics/unknown-filter` (accepted: knap prints partial output on
fatal error, k4o buffers; k4o KNAP-FIDELITY.md). SPEC updated; the stale
"181/188" in demo/storyboard.md (line ~220) is deferred until I1 lands,
since I1 owns demo/ this wave.

## dogbed findings to route to a dogbed lane

- Verdict html drops the footnote definitions (found by C2).
- Frontmatter renders as `<hr/><p>` text in html (found by C2; dogbed
  renders what it is given, so the fix may be template-side).
