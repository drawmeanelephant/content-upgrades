# k4o conformance: main

- engine: `~/.cache/knap-engines/k4o-aeba163/k4o` (k4o 0.1.0), revision `aeba16352a7b6c7fd8d54db53cb506bdf5ead994`
- engine sha256: `c526387b435027eefbf8fb7e5d36f89bdc1c710e689aced37fa27da36a26e450`
- corpus: `../corpus/render.json` (format_version 1, preset `standard`, 188 cases), sha256 `a7c011908343cf34c3c1a07d282349b8bc97f03d130f21f4f87ced35466ad152`
- mode: `k4o render <case.knap> --data <data.json> --format markdown`; stdout byte-exact, error codes in order

**main: 187/188 pass** (1 fail, 0 unsupported)

## By category

| category | cases | pass | fail | unsupported |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 163 | 0 | 0 |
| logic | 3 | 3 | 0 | 0 |
| clipper-logic | 13 | 13 | 0 | 0 |
| diagnostics | 5 | 4 | 1 | 0 |
| typed-values | 4 | 4 | 0 | 0 |
| **total** | **188** | **187** | **1** | **0** |

## Unsupported: filters k4o does not register (1 of 80 corpus filters)

None.

## Failures by class

| class | cases |
| --- | ---: |
| error-case output mismatch | 1 |

| case | class | reason |
| --- | --- | --- |
| `diagnostics/unknown-filter` | error-case output mismatch | error code matches; expected 5 bytes of output alongside the error, k4o's buffered contract emits 0 |

