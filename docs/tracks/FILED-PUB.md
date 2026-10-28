# FILED-PUB: publish-check staging profiles (#252)

Status: done, PR open. `knap_publish_check` no longer assumes the frozen
`boris-site/` conventions. A staging profile per site selects how the doc is
adapted before `boris validate` runs; `raw` passes a canonical-id site's
records through untouched, which is what filed.fyi needs.

## knap-site.json (site staging profile spec)

Optional file discovered at `<site>/knap-site.json` — next to `content/`.
Absent file means all defaults. Unknown keys are ignored, so later lanes can
extend it (FILED-BORIS's closed frontmatter schema is the known next one).

```json
{
  "staging": "frozen | raw",
  "theme":   "<theme root, site-relative>"
}
```

| Key | Meaning | Default |
|---|---|---|
| `staging` | `frozen`: today's adapter (title-only frontmatter, `[[T]]` → `[[slug(T)\|T]]`, staged at `staged/<name>.md`). `raw`: passthrough (below). | `frozen` |
| `theme` | Passed to `boris validate --theme <root>` (validate renders pages, so a site whose layout is not `themes/boris` must name it). Must stay inside the site. | boris's own default (`themes/boris`) |

Env overrides, per key: `KNAP_BORIS_STAGING`, `KNAP_BORIS_THEME`. A
set-but-unknown staging name, a malformed file, or an escaping theme path
fails loudly — never a silent fallback to frozen.

`boris-site/knap-site.json` pins `{"staging": "frozen"}` — the file is real
and the demo exercises it, while behavior stays the default it already was.

## raw staging rules

- **Frontmatter:** the `---` block passes through verbatim — closed-schema
  keys (`id`, `parent`, `status`, `tags`) reach boris untouched. An unclosed
  block stages as-is; boris reports it, we don't.
- **Links:** `[[T]]` and `[[T|L]]` pass through unmodified — no slug, no
  label injection, `#frag` kept in place. Canonical ids are case-sensitive.
- **Embeds:** unchanged in both profiles — `![[T]]` loses its `!` and is
  checked as a link (boris 0.8.2 cannot embed a page).
- **Path:** the doc lands at its source-relative path under `content/` —
  `as` today, ingest metadata when FILED-ING (#251) lands. Without either,
  the fallback is `staged/<name>.md`. Landing on an existing record's path
  replaces it in the staged copy — that is the point.
- **Positions:** staged text is byte-identical except dropped embed bangs,
  so doc coordinates already are boris coordinates; no frontmatter remap.

## `--as <path>` / `as` argument

`publish-check <doc_id> --as content/mascots/003.blamey-mctypoface.md` and
the `as` input property give the staged doc its graph position when the
artifact store doesn't carry one. The value is resolved to a
content-relative path: the part after the first `content` component when
one is present (`content/mascots/x.md` or `/site/content/mascots/x.md` →
`mascots/x.md`), else the path itself (`mascots/x.md`). `..`, empty
results, and non-`.md` names are rejected; `--as` under `frozen` fails.

`publish-check` is now a tool row (was a custom fn): `--as` rides
`tool_flags` into the arguments object like the other shared flags, and
`ok:false` → exit 1 comes from `runTool` for free. No behavior change —
verified by `make demo` beat 5 below.

## Report

`"profile":"frozen|raw"` joined the report (after `staged_as`) so a passing
run is auditable. `staged_as` is the content-relative path under raw.

## Done-when evidence (boris/0.8.2, filed.fyi checkout)

- `003.blamey-mctypoface.md` staged `--as content/mascots/003.blamey-mctypoface.md`
  under `KNAP_BORIS_STAGING=raw KNAP_BORIS_THEME=themes/cantilever`:
  `{"ok":true,"profile":"raw","staged_as":"mascots/003.blamey-mctypoface","pages":2552,"links":2,"diagnostics":[]}`
  — `limericks/LIM-0155` resolves; under `frozen` the same run produced the
  issue's two false `EREFERENCEMISSING`s. (`pages` counts the doc as the
  record it replaced, not +1.)
- A `parent: mascots` record staged `--as content/mascots/999.testy-mctest.md`
  validates clean in its satellite position. A bogus `[[limericks/LIM-9999]]`
  still reports `EREFERENCEMISSING` at the right doc line — raw surfaces only
  real diagnostics, including `EDUPLICATEID` when an `id:` collides.
- `KNAP_BORIS_STAGING=bogus` exits 1 naming the value, before any work.
- `make demo` beat 5 is byte-identical to the pre-change transcript under
  `frozen` (the only transcript delta is the numbers-card LOC count).

## Handoff notes for other lanes

- `boris.check(ctx, doc, name, as)` gained the `as` parameter; `stage()`
  gained a `Profile` parameter, and `Staged` carries `profile` for report
  mapping. FILED-BORIS (#254): frontmatter model can hang off
  `SiteConfig`/`knap-site.json` — the file is parsed once in `siteConfig()`
  with `ignore_unknown_fields`.
- FILED-ING (#251): when ingest metadata carries a source path, feed it as
  `as` — `sourceRelPath()` already normalizes `content/`-prefixed and
  absolute forms.
