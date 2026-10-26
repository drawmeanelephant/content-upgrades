# k4o conformance summary

**k4o base 15/188 → #70 43/188 → #71 48/188**

| revision | label | pass | fail | unsupported | cases |
| --- | --- | ---: | ---: | ---: | ---: |
| `019fac3` | base | 15 | 12 | 161 | 188 |
| `2436fee` | #70 | 43 | 12 | 133 | 188 |
| `f97c5db` | #71 | 48 | 12 | 128 | 188 |

## Pass count by category

| category | cases | base | #70 | #71 |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 10 | 37 | 39 |
| logic | 3 | 1 | 2 | 3 |
| clipper-logic | 13 | 3 | 3 | 5 |
| diagnostics | 5 | 1 | 1 | 1 |
| typed-values | 4 | 0 | 0 | 0 |

## Cases whose status changes across revisions (33)

| case | base | #70 | #71 |
| --- | --- | --- | --- |
| `filters/kebab/basic-usage` | unsupported | pass | pass |
| `filters/indent/basic-usage` | unsupported | pass | pass |
| `filters/indent/choose-a-width` | unsupported | pass | pass |
| `filters/callout/type-and-title` | unsupported | unsupported | pass |
| `filters/callout/collapsed-callout` | unsupported | unsupported | pass |
| `filters/embed/file` | unsupported | pass | pass |
| `filters/embed/alias` | unsupported | pass | pass |
| `filters/embed/array-data` | unsupported | pass | pass |
| `filters/footnote/array-footnotes` | unsupported | pass | pass |
| `filters/footnote/object-footnotes` | unsupported | pass | pass |
| `filters/fragment-link/basic-usage` | unsupported | pass | pass |
| `filters/fragment-link/custom-link-text` | unsupported | pass | pass |
| `filters/image/string-data` | unsupported | pass | pass |
| `filters/image/array-data` | unsupported | pass | pass |
| `filters/image/object-data` | unsupported | pass | pass |
| `filters/wikilink/string-with-alias` | unsupported | pass | pass |
| `filters/wikilink/array-data` | unsupported | pass | pass |
| `filters/wikilink/object-data` | unsupported | pass | pass |
| `filters/yaml/scalar` | unsupported | pass | pass |
| `filters/yaml/ambiguous-strings` | unsupported | pass | pass |
| `filters/yaml/block-list` | unsupported | pass | pass |
| `filters/yaml/flow-list` | unsupported | pass | pass |
| `filters/yaml/frontmatter-from-an-object` | unsupported | pass | pass |
| `filters/yaml/wikilink-list` | unsupported | pass | pass |
| `filters/yaml-property/scalar` | unsupported | pass | pass |
| `filters/yaml-property/ambiguous-string` | unsupported | pass | pass |
| `filters/yaml-property/wikilink-list` | unsupported | pass | pass |
| `filters/yaml-property/nested-object` | unsupported | pass | pass |
| `filters/yaml-property/empty-list` | unsupported | pass | pass |
| `logic/for/list-tags` | unsupported | pass | pass |
| `logic/set/create-a-slug` | unsupported | unsupported | pass |
| `clipper-logic/fallback` | unsupported | unsupported | pass |
| `clipper-logic/chained-fallback` | unsupported | unsupported | pass |
