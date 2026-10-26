# k4o conformance

Measured k4o results on the vendored knap portable corpus
([`corpus/render.json`](../../../corpus/render.json): 188 cases,
`format_version` 1, `standard` preset). These are conformance numbers. Per
SPEC they stay separate from repair-convergence and density numbers, and the
corpus is about 98% happy path (2 error cases, 3 warning cases), so it says
nothing about repair.

## Results

**k4o main 187/188 → #70 43/188 → #71 48/188**

`main` is the k4o pin in `scripts/engines.sh` (`aeba163`, k4o PR #72:
knap-faithful filter warnings). The line is not a progression. PRs #70 and
#71 stack on `019fac3` (Oct 8), when k4o was a 15-filter Textile/CommonMark
subset. Since then `main` has landed the commits (PRs #45–#72) that turn
k4o into a knap 0.6.0 fidelity engine. On the lineage #70 and #71 actually
extend:

**k4o base 15/188 → #70 43/188 → #71 48/188**

| label | revision | what it is | pass | fail | unsupported | corpus filters registered |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| main | `aeba163` | k4o pin (merge of PR #72) | **187** | 1 | 0 | 79 / 80 |
| base | `019fac3` | merge-base of `main` and #70/#71 | **15** | 12 | 161 | 13 / 80 |
| #70 | `2436fee` | PR #70 head: referential filters | **43** | 12 | 133 | 22 / 80 |
| #71 | `f97c5db` | PR #71 head: `{% set %}`, `??`, `callout` (on #70) | **48** | 12 | 128 | 23 / 80 |

The one corpus filter `main` lacks is `toString`, which appears only in the
case that expects `UNKNOWN_FILTER`.

Pass count by category:

| category | cases | main | base | #70 | #71 |
| --- | ---: | ---: | ---: | ---: | ---: |
| filters | 163 | 163 | 10 | 37 | 39 |
| logic | 3 | 3 | 1 | 2 | 3 |
| clipper-logic | 13 | 13 | 3 | 3 | 5 |
| diagnostics | 5 | 4 | 1 | 1 | 1 |
| typed-values | 4 | 4 | 0 | 0 | 0 |

SPEC's demo (referential) filters: corpus cases that use each filter, and how
many pass. A case that uses two of these filters counts under both.

| filter | cases | main | base | #70 | #71 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `footnote` | 2 | 2 | 0 | 2 | 2 |
| `fragment_link` | 2 | 2 | 0 | 2 | 2 |
| `wikilink` | 5 | 5 | 0 | 5 | 5 |
| `callout` | 2 | 2 | 0 | 0 | 2 |
| `embed` | 3 | 3 | 0 | 3 | 3 |
| `image` | 3 | 3 | 0 | 3 | 3 |
| `yaml` | 11 | 9 | 0 | 6 | 6 |
| `yaml_property` | 6 | 6 | 0 | 5 | 5 |
| `{% set %}` | 2 | 2 | 0 | 0 | 1 |
| `??` | 4 | 4 | 0 | 0 | 2 |

At #71 every non-passing case in this table chains a filter outside the
subset (`first`, `last`, `round`, `length`, `lower`, `upper`, `replace`). No
referential case fails on its own filter.

### Top failure categories

`main`: 1 fail, 0 unsupported.

- **Partial output on error (1).** `diagnostics/unknown-filter` expects
  knap's output `value` alongside `UNKNOWN_FILTER`. k4o reports the right
  error, but its buffered contract empties stdout on any error. This is an
  accepted difference, documented in k4o's `KNAP-FIDELITY.md`.

The three warning cases (`diagnostics/pass-through-warnings`,
`calc-invalid-input`, `round-invalid-input`) pass: k4o reports each
`INVALID_FILTER_INPUT` warning at the filter's position. The previous pin
(`bdfb838`, 181/188) had no warning channel and also failed
`clipper-logic/elseif` and the two `typed-values` singleton cases.

base, #70 and #71 fail the same 12 cases, so the 33 cases #70 and #71 gain
all come from unsupported → pass:

- **Standalone-tag whitespace (4).** `clipper-logic/if`, `elseif`,
  `combined-logic`, `empty-iterations-before-and-after-content`.
- **`link` argument order (3).** This k4o takes the label as input and the
  URL as argument; knap is the reverse (k4o's own differential harness lists
  this as a known incompatibility). `string-data` swaps them; `array-data`
  and `object-data` are rejected.
- **`table` input shapes (2).** `simple-array` and `array-of-objects` are
  rejected ("expects each row to be an array of cells").
- **Multi-line `blockquote` (1).** Rejected ("expects single-line text").
- **`<item>_index` loop variable (1).** `clipper-logic/loop-metadata`
  renders `tag_index` as empty.
- **Partial output on error (1).** Same as `main`.

Unsupported at #71 (128): 120 cases need at least one of the 57 unregistered
corpus filters (most cases: `replace` 6, `date` 5, `map` 5, `duration` 4,
`length` 4, `slice` 4). The other 8 pass an argument to a filter that takes
none in k4o: `bold:_`, `italic:_`, `code:"typescript"`, three `list:<style>`
cases and two `table:("Name", "Role")` cases.

Full per-case detail (expected vs actual bytes, k4o's diagnostic, reason)
is in the JSON reports.

## How cases are judged

Each case is written to temp files and rendered with
`k4o render case.knap --data data.json --format markdown` (knap's reference
output is Markdown). Case data keeps its source number text, so `42.567`
reaches k4o unchanged.

- **pass**: stdout is byte-exact (trailing whitespace included), the error
  codes match in order, the warnings match in order, and stderr on exit 0
  holds nothing but warning lines.
- **unsupported** applies only to cases that expect no error, when either:
  1. the template uses a filter this binary does not register. The runner
     renders `{{ x | <name> }}` for each of the 80 filter names in the corpus
     and records which ones k4o answers with `unknown filter`. Such a case
     cannot pass whatever k4o reports first.
  2. k4o rejects the template with a diagnostic that names a construct this
     revision does not parse (`unsupportedConstruct` in `runner.zig`):
     `takes no arguments`; `unknown logic tag '<x>'`; a syntax error where
     `??` sits between the tag opening and the reported token (k4o reads
     `title ??` as a spaced name); or a syntax error at a `(` right after
     `:`.
- **fail**: everything else. That covers wrong bytes, a valid template
  rejected for any other reason, a missing or wrong error code, missing,
  extra or misplaced warnings, a crash, or a timeout (10 s per case).

Warnings: on exit 0 k4o prints non-fatal filter warnings as
`k4o: warning <CODE> at line <L>, column <C>: <filter>: <detail>`. Each one
flattens to `CODE:filter`, the form the corpus uses, and the list must equal
the case's `expected.warnings` exactly, so a missing or extra warning fails
(`warning mismatch`). The corpus records no positions. knap reports a
warning at the filter name, and so does k4o, so the runner also checks that
`<L>, <C>` lands on `| <filter>` in the template (`misplaced warning` if it
doesn't). Any other stderr line on exit 0 fails as `stderr on success`. Each
report lists the warnings it saw as `CODE:filter@L:C`. A fatal error
(exit 1) is judged on its error code alone, as before; k4o prints no
warnings then.

Error codes: k4o stops at its first error, so it reports at most one.
`syntax error` maps to `PARSE_ERROR` and `unknown filter` maps to
`UNKNOWN_FILTER`. Other k4o kinds get `K4O_*` codes that can never match a
knap code by accident.

The pass count does not depend on these choices. Only the fail/unsupported
split does. Counting the 8 argument cases as fail instead would make #71
48 / 20 / 120.

## Run it

Needs Zig 0.17.0 and the engine binaries. No `build.zig` changes; the runner
is standalone.

```sh
cd knap-mcp
eval/conformance/run.sh                  # every revision -> eval/conformance/results/
eval/conformance/run.sh /tmp/k3-check    # same, elsewhere (diff -r for determinism)

# one binary
zig run eval/conformance/runner.zig -- run --k4o "$KNAP_K4O_PATH" \
  --corpus ../corpus/render.json --label mine --revision <sha> --json /tmp/k4o.json

# compare reports
zig run eval/conformance/runner.zig -- summarize [--json out.json] a.json b.json ...

zig test eval/conformance/runner.zig     # runner unit tests
```

`run.sh` expects `$KNAP_ENGINES_DIR/k4o-<sha7>/k4o` (default
`~/.cache/knap-engines`). Each engine was built read-only from the k4o
checkout, without touching its working tree:

```sh
src=$(mktemp -d); git -C ~/dev/k4o archive <sha> | tar -x -C "$src"
(cd "$src" && zig build -Doptimize=ReleaseSafe)
stage=$(mktemp -d ~/.cache/knap-engines/.k4o-<sha7>.XXXXXX)
cp "$src/zig-out/bin/k4o" "$stage/" && mv "$stage" ~/.cache/knap-engines/k4o-<sha7>
```

Reports carry no timestamps or temp paths, and the home directory is
written as `~`, so two runs on the same binaries produce byte-identical
files. Each report records the engine and corpus sha256, so a rebuilt
binary that differs shows up immediately.

## Files

- `runner.zig`: the runner (`run`, `summarize`) plus unit tests.
- `run.sh`: runs every pinned revision and both summaries. `main` follows
  `K4O_SHA` in `scripts/engines.sh`, so a pin bump needs only a rerun.
- `results/k4o-<label>-<sha7>.json`: full per-case report for each revision.
  The `.md` files beside them are the same run as markdown.
- `results/summary.{md,json}`: main → #70 → #71 (the numbers card line).
- `results/summary-lineage.{md,json}`: base → #70 → #71 (the same-lineage
  delta).
