# MD-NOTE: reading-note block apparatus

Issue #226. Adds four optional fields to `reading-note`:

- `epigraph` — verbatim line from `source_url`, plain blockquote after the
  cover image / before the verdict line.
- `thesis` — one sentence, rendered `**Thesis**: ==...==` as its own
  paragraph after "The pitch" callout.
- `argument` — numbered steps under `## The argument`, after the thesis
  paragraph / before `## Receipts`.
- `follow_ups` — task list under `## Follow-ups`, after Marginalia / before
  the spoilers callout.

Shape fields carry **no `apparatus` and no `voice` keys** — MD-RT2 and
MD-VC add those later. `voice.zig` tests pin mock `field_role` to the role
text verbatim; existing field names and roles are unchanged.

## Template spacing

Followed the header convention (`reading-note.knap:7-13`): each optional
block opens with a blank line and closes with `{{ "" }}{% endif %}`. The
epigraph `{% if %}` chains onto the cover block's close line and the
follow-ups `{% if %}` chains onto the thoughts block's close line (same
idiom as `{% endfor %}{% if aged %}`); the thesis `{% if %}` stands alone
because the pitch callout line must keep its trailing newline. Thesis and
argument are independent `{% if %}`s — `argument` still renders when
`thesis` is unset.

## Done-when evidence

- `structhash --explain` of the sample render contains a non-callout
  `quote / p / /quote` (the epigraph), plus `ol` and `task` (see below).
- Sample markdown contains `==` (the highlighted thesis).
- `--target html` contains `<blockquote>`, `<mark>`, `<ol>` and
  `type="checkbox"`.
- `reading-note.min.json` renders byte-identical to `main`, markdown and
  html (`cmp` clean both targets).
- `lint templates/reading-note.knap`: clean.
- `format-check` on the sample render: `{"ok":true,"warnings":[]}` — no
  warning `main` lacks.
- `density` of the sample render: 82.0 vs `main`'s 71.0
  (scorer `density/2`).

## structhash --explain, before (main)

```
frontmatter
  fm:title
  fm:author
  fm:year
  fm:status
  fm:verdict
  fm:gaf
  fm:slug
  fm:source
  fm:tags[4]
  fm:related[3]
/frontmatter
h1
p
  wikilink
  link
  /link
p
  img
p
  strong
  /strong
p
  strong
  /strong
callout:abstract
  title
  p
/callout
h2
callout:quote
  title
  p
    link
    /link
/callout
p
  fnref
callout:quote
  title
  p
    link
    /link
/callout
p
callout:quote
  title
  p
    link
    /link
/callout
p
callout:quote
  title
  p
    link
    /link
/callout
p
  fnref
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
ul
  li
    p
  /li
  li
    p
  /li
  li
    p
  /li
/ul
callout:warning-
  title
  p
/callout
h2
p
h2
p
  wikilink
  wikilink
  wikilink
h2
p
  embed
h2
fndef
  p
/fndef
fndef
  p
/fndef
```

## structhash --explain, after (this branch)

```
frontmatter
  fm:title
  fm:author
  fm:year
  fm:status
  fm:verdict
  fm:gaf
  fm:slug
  fm:source
  fm:tags[4]
  fm:related[3]
/frontmatter
h1
p
  wikilink
  link
  /link
p
  img
quote
  p
/quote
p
  strong
  /strong
p
  strong
  /strong
callout:abstract
  title
  p
/callout
p
  strong
  /strong
h2
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
  li
    p
  /li
/ol
h2
callout:quote
  title
  p
    link
    /link
/callout
p
  fnref
callout:quote
  title
  p
    link
    /link
/callout
p
callout:quote
  title
  p
    link
    /link
/callout
p
callout:quote
  title
  p
    link
    /link
/callout
p
  fnref
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
ul
  li
    p
  /li
  li
    p
  /li
  li
    p
  /li
/ul
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
/ul
callout:warning-
  title
  p
/callout
h2
p
h2
p
  wikilink
  wikilink
  wikilink
h2
p
  embed
h2
fndef
  p
/fndef
fndef
  p
/fndef
```

Diff vs main: `quote/p//quote` (epigraph) after the cover `img`; the
`strong` thesis paragraph and `h2`+`ol` (argument) after the abstract
callout; `h2`+task `ul` (follow-ups) after the marginalia `ul`. The `==`
highlight is not yet a structhash token (lands with MD-SH); the markdown
itself contains `==`.

## Handoff notes

- `epigraph` is `evidence`-flavored (verbatim from `source_url`) but the
  issue scoped it without `evidence: true`; verify-citation lanes may
  want to revisit when they add apparatus keys.
- `reading-note.min.json` deliberately left without the new fields so the
  minimal render stays byte-identical.
