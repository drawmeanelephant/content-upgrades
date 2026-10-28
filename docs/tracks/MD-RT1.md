# MD-RT1: the `code` apparatus

Issue #228. A code-block slot: the model hands back one command line, the
template owns the fence. `eval/ratchet/code.knap` renders it through
`code_block:"sh"`.

## What landed

- `Apparatus.code` plus `Field.code`. Valid only on `string` and
  `array<string>` kinds — anything else is `error.BadShape` at
  `parseShape`.
- `codeInert` / `codeViolation`: the literal-safe inert rule. Inside a
  fence, pipes, backticks, emphasis openers, `<tag` and leading
  `#`/`>`/`- ` are all literal, so only `\r`/`\n`, ` ``` `, `~~~`, `{{`
  and `{%` reject. Routed by `s.field.code` at the judge site; each item
  of an `array<string>` code slot is checked.
- Verbatim evidence gate: `Slot.gated()` is true for code fields
  regardless of `evidence`, and `codeVerbatim` requires the trimmed value
  to be an exact substring of some evidence string. It runs even with
  `--verifier none` and never calls `verifier.checkCitation` — a command
  is a quote, and a model judge could wave a paraphrase through as
  `entails`. Rejects as `verifier` with `code: not verbatim in evidence`.
- `buildSlice`: code slots get one extra line after SCHEMA telling the
  model the value renders verbatim in a code block and pipes are fine.
  `enrich_prefix` is byte-identical — it stays cacheable.

## Fixture notes

- `code.data.json`'s intro is deliberately ~200 prose words: the density
  scorer shrinks all positive credit linearly below `min_words` (200), so
  on a thin doc a code fence (weight 3) probes under epsilon and the loop
  stops at ceiling before ever asking. Future ratchet fixtures that want
  a single light slot should keep this in mind.
- Cases: `fixture-code` accepts the verbatim command; `adv-code-*` reject
  a paraphrase (`verifier`), a fence in the value (`inert`), and a
  newline (`inert`).

## What other lanes must know

- `Field.code` is parse-only right now; nothing else reads it. A shape
  with `apparatus: "code"` on `number`/`array<object>`/etc. now fails
  `parseShape` with `BadShape` — same as an unknown apparatus name.
