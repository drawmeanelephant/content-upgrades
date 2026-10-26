# k4o conformance: base

- engine: `~/.cache/knap-engines/k4o-019fac3/k4o` (k4o 0.1.0), revision `019fac3c27d552f65b3e09c7e6135c1e8ae1e452`
- engine sha256: `82bfec67b9c66956f861773577a1398e35a10e62d857c9725d4bd356d9c29160`
- corpus: `../corpus/render.json` (format_version 1, preset `standard`, 188 cases), sha256 `a7c011908343cf34c3c1a07d282349b8bc97f03d130f21f4f87ced35466ad152`
- mode: `k4o render <case.knap> --data <data.json> --format markdown`; stdout byte-exact, error codes in order

**base: 15/188 pass** (12 fail, 161 unsupported)

## By category

| category | cases | pass | fail | unsupported |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 10 | 6 | 147 |
| logic | 3 | 1 | 0 | 2 |
| clipper-logic | 13 | 3 | 5 | 5 |
| diagnostics | 5 | 1 | 1 | 3 |
| typed-values | 4 | 0 | 0 | 4 |
| **total** | **188** | **15** | **12** | **161** |

## Unsupported: filters k4o does not register (67 of 80 corpus filters)

A case that chains several missing filters counts once under each.

| filter | cases |
| --- | ---: |
| `yaml` | 11 |
| `replace` | 6 |
| `yaml_property` | 6 |
| `date` | 5 |
| `map` | 5 |
| `wikilink` | 5 |
| `duration` | 4 |
| `indent` | 4 |
| `length` | 4 |
| `slice` | 4 |
| `calc` | 3 |
| `date_modify` | 3 |
| `embed` | 3 |
| `first` | 3 |
| `image` | 3 |
| `join` | 3 |
| `kebab` | 3 |
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
| `callout` | 2 |
| `compact` | 2 |
| `decode_uri` | 2 |
| `footnote` | 2 |
| `fragment_link` | 2 |
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
| argument on a k4o filter that takes none | 6 |
| `??` fallback | 2 |
| parenthesized filter arguments `:(a, b)` | 2 |

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

