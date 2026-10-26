# boris-site

A small, real, frozen [boris](https://github.com/drawmeanelephant/boris) site:
the research pack behind the AcmeDB verdict that `knap-mcp/data/*.sample.json`
renders. knap-mcp reads its artifacts and stages rendered docs into a copy of
it. It never indexes live and never writes here.

Measurements, command shapes, and design notes: [`docs/tracks/B1.md`](../docs/tracks/B1.md).

## Layout

| Path | What |
|---|---|
| `content/` | 12 pages: `index`, `sources`, `claims`, 4 source pages, 5 claim pages |
| `themes/boris/` | Minimal no-JavaScript layout; boris needs a layout to render the search index |
| `boris.json` | Publication profile from `boris init` |
| `artifact/` | Frozen artifacts, committed. Regenerate with `./build.sh` |
| `stage-check.sh` | Stage one rendered doc into a temp copy and check its wiki-links |
| `selftest.sh` | Gate: clean verdict and apparatus pass, a hallucinated link fails |
| `ask.sh` | Reference ranked-snippet query over `artifact/` (needs `jq`) |
| `bench.sh` | Latency of the checks (median / p90 over N runs) |

## Invariants

- **Source ids are slugs of source names.** A knap template renders
  `{{ s.name | wikilink }}` as `[[AcmeDB docs — backups]]`. Boris ids cannot
  contain spaces, so `stage-check.sh` rewrites it to
  `[[acmedb-docs-backups|AcmeDB docs — backups]]`, and that source page sets
  `id: acmedb-docs-backups`. Slug: lowercase ASCII, keep `[a-z0-9/]`, every
  other run of bytes becomes `-`, trim the ends.
- **Every page id is already in slug form**, so a slug-form link such as
  `[[claims/backup-gap]]` passes through unchanged.
- **Claim pages carry one verdict tag** (`supported`, `refuted`, or
  `unverified`) and `relations: [cites=<source-id>, ...]`.
- **The frozen site checks clean**: `boris check` reports no findings, so any
  finding after staging comes from the staged doc.

## Commands

Run from this directory. Needs `boris` 0.8.2 on `PATH` (or `BORIS=...`).

```sh
./stage-check.sh path/to/doc.md            # boris check: exit 0 ok, 1 unresolved
./stage-check.sh --validate path/to/doc.md # boris validate: also checks #fragments
./build.sh                                 # regenerate artifact/ from content/
./build.sh --check                         # fail if artifact/ is stale
./selftest.sh                              # the B1 gate (needs knap-mcp built + k4o)
./ask.sh "point-in-time snapshots"         # ranked snippets, JSON lines
./ask.sh --claims "AcmeDB backups"         # claim pages with verdict + citations
```

Adding a page: write it under `content/`, run `boris check --input content`
until it is clean, then `./build.sh` and commit `content/` and `artifact/`
together.
