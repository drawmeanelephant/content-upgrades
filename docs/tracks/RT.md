# RT: ratchet audit fixes (issue #210)

Lane: `fix/audit-ratchet`. Files owned: `src/ratchet.zig`,
`eval/ratchet.json`, this file.

## #210 — no default max_words; single-delimiter emphasis stuffing

### Default `max_words` from `words`

`checkString` enforced `max_words` only when the shape annotated it, and
the shipped shapes annotate `words` (probe-stub size) and `max_items`,
never `max_words` — so a model reply was bounded only by the backend's
8 MiB stdout cap.

`checkString` now applies `f.max_words orelse f.words *|
default_max_words_factor` (`16`). Why 16 and not the ~2x the curated
callouts shape uses: `words` is a stub size, not a target length, and the
corpus relies on that slack — the ladder `items[+]` mock ships a 21-word
bullet on a `words: 4` slot (~5x) and `adv-no-gain-wall` ships a ~159-word
bullet on `words: 12` (~13x) that must keep reaching the render so the
`no-gain` rejection path stays covered. 16 sits above every ratio the
corpus exercises, so the default only fires on replies longer than
anything the evals consider plausible; fields that need real length
discipline still set `max_words` explicitly (the callouts shape does, at
~2x). The factor is one constant if a tighter bound is wanted later.

The fallback lives in `checkString` rather than `parseField` so ad-hoc
`Field`s (the row-cell check) get the same bound.

### Single-delimiter emphasis is not inert

`inert_tokens` blocked `**`, `__`, `~~`, backtick and friends but not lone
`*`/`_`, so `_a_ _b_ …` added styled runs without content. `inertString`
now also scans for a `*` or `_` that opens an emphasis run — a word
character on the right and a non-word boundary (or string start) on the
left. The left-edge rule is the CommonMark intraword restriction: `_`
cannot open emphasis inside a word, so `snake_case` values (`wal_dir`)
stay legal, and a `*` with no word to its right (`2 * 3`) stays math.
Conservative on purpose: `a*b` passes.

### Corpus

Two new cases in `eval/ratchet.json`, both on the proven-asked
`upgrade_matrix[+]` slot (same shape as `adv-inert-markup`):

- `adv-inert-single-emphasis` — `effort` is `_rename_ _one_ _config_
  _key_` → `inert` rejection.
- `adv-max-words` — `effort` is a 45-word sentence; sub-fields inherit
  `words: 2` from the array, so the default cap is 32 → `schema`
  rejection (`max_words: 45 > 32`).

`adv-no-gain-wall` is untouched: its ~159-word wall still fits the new
default cap (192) and still exercises `no-gain`. Unit tests cover the
default cap, an explicit `max_words` override, emphasis rejection, and
the `snake_case`/`2 * 3`/`a*b` non-cases.

### Gates

- `make test` — pending (this environment had no shell; run before
  merge).
- `KNAP_MCP_HOME=$(mktemp -d) make ratchet-eval` — pending; expected
  delta vs main is exactly the two new rows (`adv-inert-single-emphasis`
  inert 1, `adv-max-words` schema 1); every other case's rejections are
  unchanged by construction.
