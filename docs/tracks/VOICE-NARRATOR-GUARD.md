# VOICE-NARRATOR-GUARD — mild doc-voice rejects added narrator phrases (#385)

Source finding: drawmeanelephant/filed.fyi#1061, measured by VOICE-TICS
(#382): the mild doc pass added stock narrator phrases at 39 per 100
rewrites and every reply passed the guard. A prompt fix reduces it; this
guard enforces it whatever the model or prompt.

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/voice.zig` | `docGuard`, mild only: a hard `adds narrator phrase '<p>'` for each `voicetics.default_lexicon` phrase whose count in the reply's words exceeds its count in the input's. Spicy and feral unchanged. One test next to the docGuard test. |
| `knap-mcp/src/voicetics.zig` | `phraseCount` is now `pub` so the guard shares the scorer's phrasing. |

## Notes

- Doc pass only: the template `guard` is untouched, so field-level
  rewrites keep their existing rules.
- Kept phrases are not additions: a reply that carries an input's
  "regrettably" forward counts equal and passes. Only a net gain fails.
- The doc-voice eval runs `--tone feral` and the voice-tics mock gate
  asserts `rejected == 0`; both still hold (mock adds emphasis, no
  lexicon words).
