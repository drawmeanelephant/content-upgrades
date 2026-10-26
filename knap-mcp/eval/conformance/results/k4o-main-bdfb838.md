# k4o conformance: main

- engine: `~/.cache/knap-engines/k4o-bdfb838/k4o` (k4o 0.1.0), revision `bdfb838a115e86483d9ef1f14d6768a9b9ea0754`
- engine sha256: `ea9b18150686489e5f7a8ee321c0e69030e1ba40351b3047b8e80e064c35726b`
- corpus: `../corpus/render.json` (format_version 1, preset `standard`, 188 cases), sha256 `a7c011908343cf34c3c1a07d282349b8bc97f03d130f21f4f87ced35466ad152`
- mode: `k4o render <case.knap> --data <data.json> --format markdown`; stdout byte-exact, error codes in order

**main: 181/188 pass** (7 fail, 0 unsupported)

## By category

| category | cases | pass | fail | unsupported |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 163 | 0 | 0 |
| logic | 3 | 3 | 0 | 0 |
| clipper-logic | 13 | 12 | 1 | 0 |
| diagnostics | 5 | 1 | 4 | 0 |
| typed-values | 4 | 2 | 2 | 0 |
| **total** | **188** | **181** | **7** | **0** |

## Unsupported: filters k4o does not register (1 of 80 corpus filters)

None.

## Failures by class

| class | cases |
| --- | ---: |
| missing warnings | 3 |
| output mismatch | 3 |
| error-case output mismatch | 1 |

| case | class | reason |
| --- | --- | --- |
| `clipper-logic/elseif` | output mismatch | first difference at byte 13: expected "Draft article", got "Draft article\n" |
| `diagnostics/unknown-filter` | error-case output mismatch | error code matches; expected 5 bytes of output alongside the error, k4o's buffered contract emits 0 |
| `diagnostics/pass-through-warnings` | missing warnings | output byte-exact; k4o reported no warnings, expected INVALID_FILTER_INPUT:replace, INVALID_FILTER_INPUT:date |
| `diagnostics/calc-invalid-input` | missing warnings | output byte-exact; k4o reported no warnings, expected INVALID_FILTER_INPUT:calc |
| `diagnostics/round-invalid-input` | missing warnings | output byte-exact; k4o reported no warnings, expected INVALID_FILTER_INPUT:round |
| `typed-values/last-nested-collection` | output mismatch | first difference at byte 0: expected "[3]", got "3" |
| `typed-values/length-singleton-array` | output mismatch | first difference at byte 0: expected "1", got "5" |

