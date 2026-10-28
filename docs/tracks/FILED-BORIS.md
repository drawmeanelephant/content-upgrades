# FILED-BORIS (issue #254) — boris surface awareness

## What landed

- `src/frontmatter.zig` (new): the `--- … ---` block model — frozen byte
  range (`lo`/`hi`, `close_line`) plus the top-level key set (`keys`,
  `key_lines`, `has`, `firstUnknown`). Parsed once per doc; the range is
  opaque bytes a consumer can splice around. Leniency matches
  `formatcheck.frontmatterEnd` / `structhash.mdDoc` (trimmed `---`/`...`
  fences), so no existing doc re-parses differently.
- `src/structhash.zig`: `{{include <path>}}` inline atom (`include`,
  `include(path)` under strict) — boris's directive form, opaque
  whatever the path is. `<Aside …>`/`<Details …>` line-start components
  as bounded blocks: `component:aside[:kind]` / `component:details[:open]`
  open, body as blocks, `/component` only on the same-name close
  (wrong-name closes stay body; unclosed runs to EOF and hashes
  differently). Mid-line tags stay `html:` tokens.
- `src/voice.zig`: three new protected-token kinds — `embed` (`![[…]]`),
  `include` (`{{…}}`), `component` (`<Aside …>`, `</Aside>`,
  `<Details …>`, `</Details>` whole tags, quote-aware `>` scan).
  `[[id|label]]` was already atomic; the canonical id stays opaque
  inside it.
- `src/formatcheck.zig`: `Site` rule-pack inputs + `checkSite`;
  `check` is a null-site wrapper — frozen warnings byte-identical.
  New rules: `unknown-frontmatter-key` (declared schema only),
  `unresolved-include` + `bad-include-path` (boris's path grammar
  verbatim + existence under `content_dir`), `unclosed-component` /
  `stray-component-close` / `mismatched-component-close` /
  `nested-component`, `noncanonical-link` (`isCanonicalId`: `/`-joined
  segments, no `.`/`..`/empty, no page extension, ≤255B, Unicode kept).
  Fences and inline code spans are masked, like boris's own scanners.
- `src/boris.zig` (consumer side, additive section marked for #252
  reconciliation): `siteProfile(ctx)` resolves `<site>/knap-site.json`
  + `KNAP_BORIS_STAGING`; `siteRules(ctx)` maps to `?formatcheck.Site`
  (null under frozen).
- `tools/format_check.zig`: 3-line wiring — `run` calls `checkSite`
  with `boris.siteRules(ctx)`. Flagged: outside the lane's file list,
  but it's the only `Ctx` → `formatcheck` bridge; the registry/CLI
  edits stay untouched.

## knap-site.json consumer contract (hand to #252)

```json
{
  "profile": "raw",                       // or "staging"; default frozen
  "frontmatter": ["id", "title", "parent", "status", "tags",
                  "relations", "published_at", "summary"],
  "canonical_ids": true                   // default: true under raw
}
```

- `KNAP_BORIS_STAGING=<name>` overrides the file's profile name.
- Unknown profile names (file or env) fail loudly — never silent frozen.
- `frozen` means today's behavior, full stop: `siteRules` returns null
  even if the file declares a schema.
- `raw` without `"canonical_ids"` defaults it true; `"frontmatter"` is
  the declared closed key set (empty/absent = no key check).

## Merge-captain notes

- `boris.zig` additions are one contiguous section after `stage()`'s
  adapter (`// --- site profile ---`) plus one import — #252's staging
  work should merge around it; the profile file/env names follow #252's
  stated contract exactly.
- `tools/format_check.zig` overlaps #251's rewrite of that file (it adds
  a file-path `cli`); my change is only the import + the `checkSite`
  call line.
- `main.zig`: one test-import line for `frontmatter.zig`.
- density.zig untouched: it still calls `formatcheck.check`, so density
  penalties never see boris warnings — profile awareness is a
  format-check surface only, per the issue.

## Gates

- `make test` — 226 tests pass (was 209).
- `KNAP_MCP_HOME=$(mktemp -d) make eval` — convergence table unchanged.
- Frozen-site byte-identical: structhash golden token test pins the
  skeleton; every new emit path is gated on syntax absent from the
  frozen corpus (`{{include`, line-start `<Aside`/`<Details>`) or on a
  resolved non-frozen profile.
