# MD-RB lane notes

Runbook template — the full-markdown showcase (#227). Everything below
verified on the pinned engines (k4o `aeba163`, dogbed `d96b125`).

## Files

- `knap-mcp/templates/runbook.knap` — frontmatter built key by key with
  `yaml_property`; meta line (`[[owner]]` wikilink, severity and
  last_reviewed as code spans); `abstract` "When to use this" callout;
  `danger | highlight | callout:("danger", "Do not skip")`; preflight
  `list:"task"`; `phases[]` of h2 + steps (h3 `do` with `replace`-trick
  footnote ref, `code_block:lang`, h4 "Expect"); literal `---` between
  phases; rollback `list:"numbered"` folded into
  `callout:("warning", "Rollback", true)`; escalation pipe table;
  `error_budget | math_block`; `lesson | blockquote` + postmortem link;
  "See also" wikilink cloud; `notes | footnote`.
- `knap-mcp/templates/shapes/runbook.json` — only existing apparatus
  values, no `voice: true` (MD-VC adds voice later).
- `knap-mcp/data/runbook.sample.json` — AcmeDB restore-from-snapshot,
  consistent with the AcmeDB 2.0 release-notes sample.
- `knap-mcp/data/runbook.min.json` — required fields only.

## Template gotchas hit

- `code_block:s.lang` cannot carry a `??` default — filter params don't
  parse `??` inside parens (`expected ',' or ')'`), and a bare
  `code_block:s.lang` with an absent field resolves to the literal
  string "s.lang". Solved with `{% set lang = s.lang ?? "sh" %}` per
  step.
- A `{% if %}` chained on the same line as `{% endfor %}` (an inline
  opener) ate the blank line opening its own body — the rollback
  callout glued to the last code fence. A standalone `{% if rollback %}`
  on its own line fixes it.
- The `---` phase separator needs blank lines on both sides. The
  trailing one is eaten by a column-0 `{% endif %}` (standalone-endif
  trim), so the separator block closes with `{{ "" }}{% endif %}` like
  every other optional block.
- Step footnote ref abuts the h3:
  `{{ s.do | h3 }}{{ s.note | kebab | replace:"/(.+)/":"[^$1]" }}`
  renders `### Do the thing[^wal-path]` — the ref rides inside the
  heading, so min steps (do-only, no notes) still render clean.

## structhash --explain (data/runbook.sample.json)

```
frontmatter
  fm:title
  fm:service
  fm:severity
  fm:last_reviewed
  fm:tags[4]
  fm:related[3]
/frontmatter
h1
p
  wikilink
  code
  code
callout:abstract
  title
  p
/callout
callout:danger
  title
  p
/callout
h2
ul
  li
    task
    p
  /li
  li
    task
    p
  /li
  li
    task
    p
  /li
  li
    task
    p
  /li
  li
    task
    p
  /li
/ul
h2
h3
  fnref
code:sh
h4
p
h3
h4
p
hr
h2
h3
code:sh
h4
p
h3
  fnref
code:sh
hr
h2
h3
h4
p
h3
code:sql
h4
p
h3
code:sh
h4
p
callout:warning-
  title
  ol
    li
      p
    /li
    li
      p
    /li
    li
      p
    /li
  /ol
/callout
h2
table:3:---
  tr
    th
    th
    th
  tr
    td
    td
    td
  tr
    td
    td
    td
  tr
    td
    td
    td
/table
h2
p
  strong
  /strong
p
h2
quote
  p
/quote
p
  link
  /link
p
  wikilink
  wikilink
  wikilink
h2
fndef
  p
/fndef
fndef
  p
/fndef
```

All required tokens present: `frontmatter`, `h1`-`h4`, `ol`, `task`,
`code:sh` + `code:sql`, `callout:danger`, `callout:warning-`,
`callout:abstract`, `hr`, non-callout `quote`, `table`, `fndef`,
`fnref`, `wikilink`.

## density (density/2 @ a03bd3a)

Sample render: **total 83.2, words 516** (>= 75 required; MD-DN scorer
v3 not yet merged, so no second number to report).

```
callouts                 raw=  3 value=    5.81 contrib=11.00
footnotes                raw=  2 value=    3.88 contrib=11.63
tables                   raw=  1 value=    1.94 contrib=10.00
wikilinks                raw=  4 value=    7.75 contrib= 7.00
embeds                   raw=  0                          0.00
fragment_links           raw=  0                          0.00
links                    raw=  1 value=    1.94 contrib= 2.33
frontmatter              raw=  6 value=    6.00 contrib= 6.00
code_fences              raw=  5 value=    9.69 contrib= 3.00
styled_runs              raw=  4 value=    7.75 contrib= 2.58
styled_coverage          raw=169 value=    0.07 contrib= 5.11
emphasis_variety         raw=  3 value=    3.00 contrib= 4.00
blockquotes              raw=  1 value=    1.94 contrib= 3.00
heading_levels           raw=  4 value=    4.00 contrib= 3.00
heading_density          raw= 22 value=   42.64 contrib= 4.00
lists                    raw=  1 value=    1.94 contrib= 2.58
block_variety            raw= 10 value=   10.00 contrib= 8.00
raw_urls                 raw=  0                          0.00
overload                 raw=  0                          0.00
```

Density tuning note: at ~460 words the scorer trips twice —
`heading_density` crosses `over` at 50/kw and `code_fences` at 10/kw,
and each pays into `overload` (-20, sat 4). Keeping the sample at 5
commands and >= 500 prose words holds both under `over`: no decay, no
overload tax.

## format-check

Sample and min renders: `{"ok":true,"warnings":[]}` — zero warnings
both. The same list is embedded in the density output
(`"warnings":[]`).

## Done-when spot checks

- `validate runbook` ok for sample and min; `render` ok for
  markdown/oliver/html on both.
- `knap-mcp lint templates/runbook.knap` clean.
- Markdown text: `==…==` (danger highlight) and a `$$…$$` block.
- HTML: `<mark>`, `math display`, `callout-fold-closed`, `<hr />`,
  `type="checkbox"`, `<ol>` all present.
- `ratchet runbook -d data/runbook.min.json --backend mock` exits 0
  with `stop: stalled` (no mock values, as expected).
