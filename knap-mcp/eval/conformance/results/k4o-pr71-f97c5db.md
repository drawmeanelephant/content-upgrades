# k4o conformance: #71

- engine: `~/.cache/knap-engines/k4o-f97c5db/k4o` (k4o 0.1.0), revision `f97c5dbbaec81ded2d90de66b0f4e62bb4c475b1`
- engine sha256: `1217032db130fcd149e3c657013ad0191eaef94003d2c8240d791c0b13b6743c`
- corpus: `../corpus/render.json` (format_version 1, preset `standard`, 188 cases), sha256 `a7c011908343cf34c3c1a07d282349b8bc97f03d130f21f4f87ced35466ad152`
- mode: `k4o render <case.knap> --data <data.json> --format markdown`; stdout byte-exact, error codes in order

**#71: 48/188 pass** (12 fail, 128 unsupported)

## By category

| category | cases | pass | fail | unsupported |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 39 | 6 | 118 |
| logic | 3 | 3 | 0 | 0 |
| clipper-logic | 13 | 5 | 5 | 3 |
| diagnostics | 5 | 1 | 1 | 3 |
| typed-values | 4 | 0 | 0 | 4 |
| **total** | **188** | **48** | **12** | **128** |

## Unsupported: filters k4o does not register (57 of 80 corpus filters)

A case that chains several missing filters counts once under each.

| filter | cases |
| --- | ---: |
| `replace` | 6 |
| `date` | 5 |
| `map` | 5 |
| `duration` | 4 |
| `length` | 4 |
| `slice` | 4 |
| `calc` | 3 |
| `date_modify` | 3 |
| `first` | 3 |
| `join` | 3 |
| `last` | 3 |
| `lower` | 3 |
| `number_format` | 3 |
| `object` | 3 |
| `reverse` | 3 |
| `round` | 3 |
| `sort` | 3 |
| `split` | 3 |
| `template` | 3 |
| `truncate` | 3 |
| `uncamel` | 3 |
| `unique` | 3 |
| `compact` | 2 |
| `decode_uri` | 2 |
| `highlight` | 2 |
| `hr` | 2 |
| `merge` | 2 |
| `nth` | 2 |
| `remove_attr` | 2 |
| `remove_tags` | 2 |
| `strip_md` | 2 |
| `strip_tags` | 2 |
| `sum` | 2 |
| `table_pretty` | 2 |
| `truncatewords` | 2 |
| `unescape` | 2 |
| `upper` | 2 |
| `where` | 2 |
| `camel` | 1 |
| `capitalize` | 1 |
| `code_block` | 1 |
| `comment` | 1 |
| `encode_uri` | 1 |
| `escape_md` | 1 |
| `hard_break` | 1 |
| `math` | 1 |
| `math_block` | 1 |
| `parse_json` | 1 |
| `pascal` | 1 |
| `replace_tags` | 1 |
| `safe_name` | 1 |
| `snake` | 1 |
| `strike` | 1 |
| `strip_attr` | 1 |
| `title` | 1 |
| `trim` | 1 |

## Unsupported: constructs this revision does not parse

| construct | cases |
| --- | ---: |
| argument on a k4o filter that takes none | 8 |

## Failures by class

| class | cases |
| --- | ---: |
| output mismatch | 6 |
| rejected valid template | 5 |
| error-case output mismatch | 1 |

| case | class | reason |
| --- | --- | --- |
| `filters/blockquote/basic-usage` | rejected valid template | render error at line 1, column 12: filter 'blockquote' expects single-line text |
| `filters/link/string-data` | output mismatch | first difference at byte 1: expected "[Example](https://example.com)", got "[https://example.com](Example)" |
| `filters/link/array-data` | rejected valid template | render error at line 1, column 11: filter 'link' expects a text value, but got an array |
| `filters/link/object-data` | rejected valid template | bad argument at line 1, column 12: filter 'link' requires a URL argument, e.g. link:"https://example.com/" |
| `filters/table/array-of-objects` | rejected valid template | render error at line 1, column 13: filter 'table' expects each row to be an array of cells |
| `filters/table/simple-array` | rejected valid template | render error at line 1, column 12: filter 'table' expects each row to be an array of cells |
| `clipper-logic/if` | output mismatch | first difference at byte 11: expected "Author: Ada", got "Author: Ada\n" |
| `clipper-logic/elseif` | output mismatch | first difference at byte 13: expected "Draft article", got "Draft article\n" |
| `clipper-logic/combined-logic` | output mismatch | first difference at byte 5: expected "- Ada", got "- Ada\n\n" |
| `clipper-logic/empty-iterations-before-and-after-content` | output mismatch | first difference at byte 0: expected "- Ada\n- Grace", got "\n- Ada\n\n\n- Grace\n\n" |
| `clipper-logic/loop-metadata` | output mismatch | first difference at byte 4: expected "1/0/0/2/true/false: a\n2/1/1/2/false/true: b", got "1/0//2/true/false: a\n2/1//2/false/true: b" |
| `diagnostics/unknown-filter` | error-case output mismatch | error code matches; expected 5 bytes of output alongside the error, k4o's buffered contract emits 0 |

