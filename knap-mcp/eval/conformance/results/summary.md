# k4o conformance summary

**k4o main 181/188 → #70 43/188 → #71 48/188**

| revision | label | pass | fail | unsupported | cases |
| --- | --- | ---: | ---: | ---: | ---: |
| `bdfb838` | main | 181 | 7 | 0 | 188 |
| `2436fee` | #70 | 43 | 12 | 133 | 188 |
| `f97c5db` | #71 | 48 | 12 | 128 | 188 |

## Pass count by category

| category | cases | main | #70 | #71 |
| --- | ---: | ---: | ---: | ---: |
| filters | 163 | 163 | 37 | 39 |
| logic | 3 | 3 | 2 | 3 |
| clipper-logic | 13 | 12 | 3 | 5 |
| diagnostics | 5 | 1 | 1 | 1 |
| typed-values | 4 | 2 | 0 | 0 |

## Cases whose status changes across revisions (143)

| case | main | #70 | #71 |
| --- | --- | --- | --- |
| `filters/date/format-a-date` | pass | unsupported | unsupported |
| `filters/date/specify-the-data-format` | pass | unsupported | unsupported |
| `filters/date/iso-week-and-literal-text` | pass | unsupported | unsupported |
| `filters/date-modify/add-time` | pass | unsupported | unsupported |
| `filters/date-modify/subtract-time` | pass | unsupported | unsupported |
| `filters/date-modify/cross-midnight-and-format` | pass | unsupported | unsupported |
| `filters/duration/iso-8601-duration` | pass | unsupported | unsupported |
| `filters/duration/seconds` | pass | unsupported | unsupported |
| `filters/duration/default-format` | pass | unsupported | unsupported |
| `filters/duration/more-than-24-hours` | pass | unsupported | unsupported |
| `filters/camel/basic-usage` | pass | unsupported | unsupported |
| `filters/capitalize/basic-usage` | pass | unsupported | unsupported |
| `filters/decode-uri/unicode-text` | pass | unsupported | unsupported |
| `filters/decode-uri/spaces` | pass | unsupported | unsupported |
| `filters/encode-uri/basic-usage` | pass | unsupported | unsupported |
| `filters/lower/basic-usage` | pass | unsupported | unsupported |
| `filters/pascal/basic-usage` | pass | unsupported | unsupported |
| `filters/replace/remove-text` | pass | unsupported | unsupported |
| `filters/replace/multiple-replacements` | pass | unsupported | unsupported |
| `filters/replace/regular-expression` | pass | unsupported | unsupported |
| `filters/replace/case-insensitive-match` | pass | unsupported | unsupported |
| `filters/safe-name/basic-usage` | pass | unsupported | unsupported |
| `filters/snake/basic-usage` | pass | unsupported | unsupported |
| `filters/title/basic-usage` | pass | unsupported | unsupported |
| `filters/trim/basic-usage` | pass | unsupported | unsupported |
| `filters/truncate/default-suffix` | pass | unsupported | unsupported |
| `filters/truncate/custom-suffix` | pass | unsupported | unsupported |
| `filters/truncate/no-suffix` | pass | unsupported | unsupported |
| `filters/truncatewords/default-suffix` | pass | unsupported | unsupported |
| `filters/truncatewords/no-suffix` | pass | unsupported | unsupported |
| `filters/uncamel/camelcase` | pass | unsupported | unsupported |
| `filters/uncamel/pascalcase` | pass | unsupported | unsupported |
| `filters/uncamel/initialism` | pass | unsupported | unsupported |
| `filters/unescape/newline` | pass | unsupported | unsupported |
| `filters/unescape/quotes` | pass | unsupported | unsupported |
| `filters/upper/basic-usage` | pass | unsupported | unsupported |
| `filters/blockquote/basic-usage` | pass | fail | fail |
| `filters/bold/underscores` | pass | unsupported | unsupported |
| `filters/callout/type-and-title` | pass | unsupported | pass |
| `filters/callout/collapsed-callout` | pass | unsupported | pass |
| `filters/code/language-block` | pass | unsupported | unsupported |
| `filters/code-block/basic-usage` | pass | unsupported | unsupported |
| `filters/comment/basic-usage` | pass | unsupported | unsupported |
| `filters/escape-md/basic-usage` | pass | unsupported | unsupported |
| `filters/hard-break/basic-usage` | pass | unsupported | unsupported |
| `filters/highlight/default` | pass | unsupported | unsupported |
| `filters/highlight/color` | pass | unsupported | unsupported |
| `filters/hr/after` | pass | unsupported | unsupported |
| `filters/hr/before` | pass | unsupported | unsupported |
| `filters/italic/underscore` | pass | unsupported | unsupported |
| `filters/link/string-data` | pass | fail | fail |
| `filters/link/array-data` | pass | fail | fail |
| `filters/link/object-data` | pass | fail | fail |
| `filters/list/numbered-list` | pass | unsupported | unsupported |
| `filters/list/task-list` | pass | unsupported | unsupported |
| `filters/list/numbered-task-list` | pass | unsupported | unsupported |
| `filters/math/basic-usage` | pass | unsupported | unsupported |
| `filters/math-block/basic-usage` | pass | unsupported | unsupported |
| `filters/strike/basic-usage` | pass | unsupported | unsupported |
| `filters/table/array-of-objects` | pass | fail | fail |
| `filters/table/simple-array` | pass | fail | fail |
| `filters/table/array-of-arrays` | pass | unsupported | unsupported |
| `filters/table/custom-columns` | pass | unsupported | unsupported |
| `filters/table-pretty/object-array` | pass | unsupported | unsupported |
| `filters/table-pretty/custom-columns` | pass | unsupported | unsupported |
| `filters/calc/addition` | pass | unsupported | unsupported |
| `filters/calc/exponentiation` | pass | unsupported | unsupported |
| `filters/number-format/decimal-places` | pass | unsupported | unsupported |
| `filters/number-format/custom-separators` | pass | unsupported | unsupported |
| `filters/number-format/array-data` | pass | unsupported | unsupported |
| `filters/round/basic-usage` | pass | unsupported | unsupported |
| `filters/first/basic-usage` | pass | unsupported | unsupported |
| `filters/first/empty-array` | pass | unsupported | unsupported |
| `filters/compact/array` | pass | unsupported | unsupported |
| `filters/compact/object` | pass | unsupported | unsupported |
| `filters/join/basic-usage` | pass | unsupported | unsupported |
| `filters/last/basic-usage` | pass | unsupported | unsupported |
| `filters/last/empty-array` | pass | unsupported | unsupported |
| `filters/length/array-length` | pass | unsupported | unsupported |
| `filters/length/string-length` | pass | unsupported | unsupported |
| `filters/length/object-length` | pass | unsupported | unsupported |
| `filters/map/property-shorthand` | pass | unsupported | unsupported |
| `filters/map/nested-property` | pass | unsupported | unsupported |
| `filters/map/construct-objects` | pass | unsupported | unsupported |
| `filters/map/build-strings` | pass | unsupported | unsupported |
| `filters/merge/append-one-value` | pass | unsupported | unsupported |
| `filters/merge/append-multiple-values` | pass | unsupported | unsupported |
| `filters/nth/every-nth-item` | pass | unsupported | unsupported |
| `filters/nth/repeating-groups` | pass | unsupported | unsupported |
| `filters/object/keys` | pass | unsupported | unsupported |
| `filters/object/values` | pass | unsupported | unsupported |
| `filters/object/key-value-pairs` | pass | unsupported | unsupported |
| `filters/parse-json/basic-usage` | pass | unsupported | unsupported |
| `filters/reverse/string` | pass | unsupported | unsupported |
| `filters/reverse/array` | pass | unsupported | unsupported |
| `filters/reverse/object` | pass | unsupported | unsupported |
| `filters/slice/string-range` | pass | unsupported | unsupported |
| `filters/slice/array-range` | pass | unsupported | unsupported |
| `filters/slice/negative-start` | pass | unsupported | unsupported |
| `filters/slice/negative-end` | pass | unsupported | unsupported |
| `filters/sort/numbers` | pass | unsupported | unsupported |
| `filters/sort/descending` | pass | unsupported | unsupported |
| `filters/sort/object-property` | pass | unsupported | unsupported |
| `filters/split/separator` | pass | unsupported | unsupported |
| `filters/split/characters` | pass | unsupported | unsupported |
| `filters/split/regular-expression` | pass | unsupported | unsupported |
| `filters/sum/numeric-values` | pass | unsupported | unsupported |
| `filters/sum/object-property` | pass | unsupported | unsupported |
| `filters/template/object` | pass | unsupported | unsupported |
| `filters/template/array-of-objects` | pass | unsupported | unsupported |
| `filters/template/strings` | pass | unsupported | unsupported |
| `filters/unique/primitive-values` | pass | unsupported | unsupported |
| `filters/unique/objects-in-an-array` | pass | unsupported | unsupported |
| `filters/unique/duplicate-object-values` | pass | unsupported | unsupported |
| `filters/where/boolean-property` | pass | unsupported | unsupported |
| `filters/where/typed-equality` | pass | unsupported | unsupported |
| `filters/remove-attr/one-attribute` | pass | unsupported | unsupported |
| `filters/remove-attr/multiple-attributes` | pass | unsupported | unsupported |
| `filters/remove-tags/one-tag` | pass | unsupported | unsupported |
| `filters/remove-tags/multiple-tags` | pass | unsupported | unsupported |
| `filters/replace-tags/basic-usage` | pass | unsupported | unsupported |
| `filters/strip-attr/basic-usage` | pass | unsupported | unsupported |
| `filters/strip-md/inline-formatting` | pass | unsupported | unsupported |
| `filters/strip-md/block-formatting` | pass | unsupported | unsupported |
| `filters/strip-tags/remove-every-tag` | pass | unsupported | unsupported |
| `filters/strip-tags/keep-selected-tags` | pass | unsupported | unsupported |
| `logic/set/create-a-slug` | pass | unsupported | pass |
| `clipper-logic/if` | pass | fail | fail |
| `clipper-logic/assignment-with-filters` | pass | unsupported | unsupported |
| `clipper-logic/fallback` | pass | unsupported | pass |
| `clipper-logic/chained-fallback` | pass | unsupported | pass |
| `clipper-logic/filter-before-fallback` | pass | unsupported | unsupported |
| `clipper-logic/filter-fallback-value` | pass | unsupported | unsupported |
| `clipper-logic/combined-logic` | pass | fail | fail |
| `clipper-logic/empty-iterations-before-and-after-content` | pass | fail | fail |
| `clipper-logic/loop-metadata` | pass | fail | fail |
| `diagnostics/pass-through-warnings` | fail | unsupported | unsupported |
| `diagnostics/calc-invalid-input` | fail | unsupported | unsupported |
| `diagnostics/round-invalid-input` | fail | unsupported | unsupported |
| `typed-values/round-into-yaml-property` | pass | unsupported | unsupported |
| `typed-values/first-nested-collection` | pass | unsupported | unsupported |
| `typed-values/last-nested-collection` | fail | unsupported | unsupported |
| `typed-values/length-singleton-array` | fail | unsupported | unsupported |
