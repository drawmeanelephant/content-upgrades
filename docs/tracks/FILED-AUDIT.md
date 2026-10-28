# FILED-AUDIT — corpus audit command (#253)

## What landed

`knap-mcp audit <dir> [--glob <p>] [--per-dir | --per-glob <name=glob,...>]
[--below <score>] [--jsonl <file>]` — batch density/format-check over a
content tree. Implementation lives in `knap-mcp/src/tools/audit.zig`;
registered as a `.custom` row in `main.zig` (after `density`), with its
options in `usage_tail` and a test-import line.

- Read-only by construction: no model calls, no artifact-store writes,
  no subprocesses. `density.score` already folds `formatcheck` warnings
  into each `Score`, so one in-process pass per file covers both — that
  is the "reused scorer context" the issue asks for. 2,574 filed records
  in ~0.9s (debug build) vs ~29s for sequential `knap-mcp density` per
  file; still far ahead of `xargs -P8`.
- JSONL row per doc: `{"file","total","words","signals":{"top":[3
  highest-contribution signal names],"penalties":[negative contributors,
  worst first]},"warnings":[{rule,line,detail}]}`. `total` prints at 2
  decimals (JSONL is machine-consumed); the table prints 1 like #250.
- Rollup to stdout: `collection n mean min max p25 p75`, groups sorted
  by mean desc then name, `overall` last. Percentiles are linear
  interpolation between order statistics (numpy default).
- `--below <s>` lists docs whose *raw* `total < s` (strict), worst first.
  Display rounding can show e.g. `10.00` for a raw 9.996 — the
  comparison is always on the raw f64.
- Determinism: matched paths are byte-sorted before scoring; every
  emitted order (rows, groups, hits) derives from that or a total-order
  comparator. Verified byte-identical across two runs on the filed
  corpus (2,574 rows + table).

## Decisions a reviewer should know

- **No `knap_audit` MCP tool.** The issue made the registry row
  conditional ("if exposed as `knap_audit`"), and batch commands that
  walk the filesystem (`eval`, `ratchet-eval`, `smoke`, `backends`) are
  all `.custom` CLI rows, not tools — audit follows that precedent.
  `tools.zig` is untouched.
- **Grouping.** Default collection = first path segment; a root-level
  file groups under its stem (`index.md` → `index`, matching #250's
  `index` row). `--per-dir` groups by containing directory (`.` at
  root). `--per-glob "name=pat,..."` (repeatable) names glob-defined
  groups, first match wins, unmatched files fall back to first-segment.
  `--per-dir` and `--per-glob` are mutually exclusive.
- **Glob.** Hand-rolled: `*`/`?` within a segment, `**` as a whole
  segment matching zero or more (so `**/*.md` covers root files too).
- **Walk.** Hidden entries (dotfiles, `.git`, `.knap-mcp`) and
  non-regular files (symlinks) are skipped. Unreadable files warn on
  stderr and are skipped — JSONL row count == *scored* file count.
- **Without `--jsonl`,** rows stream to stdout ahead of the table (per
  spec "(or stdout)"); consumers can split on `^{`.

## Verification (filed checkout, 2,574 docs)

- Reproduces the #250 table exactly (every n/mean/min/max; adds `guides`
  n=4 mean 4.2, absent from #250's pasted table).
- `--below 20` → 1,454 hits, all verified `total < 20`.
- Gates: `make test` 214/214; `make eval` converged 120/167 mock.

## For FILED-POL (#255) and friends

- The JSONL stream is the measurement harness: one row per doc with the
  score, top/penalizing signal names, and full warnings — group by
  `file`'s first segment or `--per-glob` for policy buckets.
- Root-level docs group under their filename stem, not a synthetic
  "root" bucket — policy files should name them accordingly.
