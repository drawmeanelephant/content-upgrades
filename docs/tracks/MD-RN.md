# MD-RN lane notes (issue #225)

Lane: `feat/md-rn-upgrade-path`. Files owned:
`knap-mcp/templates/release-notes.knap`,
`knap-mcp/templates/shapes/release-notes.json`,
`knap-mcp/data/release-notes.sample.json`, this file.

## #225 — release-notes upgrade path

The template covered callouts, a pipe table, a bullet list, links,
wikilinks, embeds, images, footnotes, bold and code spans, but none of
the four remaining k4o `aeba163` apparatus: `list:numbered`,
`list:task`, `code_block`, or the folded callout tuple form
`callout:(kind, title, folded)`. An "Upgrade path" section between
"Upgrade math" and "Still broken" exercises all four, gated on
`upgrade_steps` being non-empty.

### Shape (`templates/shapes/release-notes.json`)

Four optional fields, inserted in render order after `upgrade_matrix`.
No `apparatus`, no `voice` — MD-RT2 and MD-VC add those later:

- `preflight` (`array<string>`) — `- [ ]` task list under
  'Before you start'.
- `upgrade_steps` (`array<string>`) — numbered procedure; gates the
  whole section.
- `upgrade_command` (`string`) — one shell command, rendered as a
  ```sh fence.
- `rollback` (`array<string>`) — numbered steps inside a collapsed
  'Rollback plan' warning callout.

`description` now mentions the section. No existing field name or role
touched (`voice.zig` pins mock `field_role` verbatim;
`eval/voice/run.sh` uses `breaking[0].fix`; `eval/seeds.json` find
strings `| yaml_property:"codename"` / `:"version"` untouched).

### Template (`templates/release-notes.knap`)

Inserted between the upgrade_matrix `{{ "" }}{% endif %}` and
`{% if known_issues %}` (see `release-notes.knap:73-91` for the exact
block): the outer `{% if upgrade_steps %}`
opens inline after the upgrade_matrix shield; `preflight`,
`upgrade_command` and `rollback` are nested optional blocks, each
closing with `{{ "" }}{% endif %}`; the outer `{% endif %}` sits
mid-line after the rollback closer so it never goes standalone and the
last body line keeps its newline. Verified against pinned k4o in all
four on/off combinations — every render ends each block with exactly
one blank line.

One subtlety checked empirically: when `rollback` is absent, the outer
`{% endif %}` lands at output line start (everything before it on the
source line was inside the removed branch). k4o's standalone-endif
trim is decided on the source line — which contains `{{ "" }}` — so no
trim fires and the code fence keeps its trailing newline.

### Data (`data/release-notes.sample.json`)

All four fields filled, consistent with the AcmeDB 2.0 story (the
`wal_dir` -> `storage.wal_path` rename, the driver bump, `acmedb
doctor`, snapshots-as-backup since 1.x has none). Sizes kept modest —
9 new list lines vs ~25 prose lines, so `format_check`'s `list-heavy`
(needs >= 3 list lines and more list than prose) stays quiet.
`release-notes.min.json` and `release-notes.hallucinated.json` were not
touched; their renders are byte-identical to main (`cmp`, markdown and
html).

### Before/after `structhash --explain` (sample render)

Before (`1a4baebfb2e6d0d1`), between `table:4:----` and the "Still
broken" `h2`:

```
h2            <- Upgrade math
table:4:----
  ...
/table
h2            <- Still broken
ul
  ...
/ul
```

After (`530b47ec7a942e19`), the same region gains:

```
h2            <- Upgrade path
h3            <- Before you start
ul
  li
    task      <- task-list item marker
    p
  /li
  ... (3 items)
/ul
h3            <- Steps
ol
  li
    p
  /li
  ... (4 items)
/ol
code:sh       <- upgrade_command fence
callout:warning-
  title       <- Rollback plan
  ol
    li
      p
    /li
    ... (3 items)
  /ol
/callout
h2            <- Still broken
ul
  ...
/ul
```

`callout:warning-` is the folded form (kind `warning`, `-` = closed);
the `ol` inside it is the rollback list. dogbed renders the section as
`<ul>` with `<input type="checkbox" disabled="" />`, `<ol>`,
`<code class="language-sh">`, and
`class="callout callout-warning callout-fold-closed"` wrapping an
`<ol>`.

### Scores

- `format-check` on the new sample render: no warnings (main: none).
- `density/2` on the new sample render: 85.6 (main: 82.8, 451 -> 528
  words).
- `knap-mcp lint templates/release-notes.knap`: clean.

## What's left / what other lanes must know

- `preflight`, `upgrade_steps`, `upgrade_command`, `rollback` have no
  `apparatus` or `voice` keys yet — MD-RT2 (apparatus annotations) and
  MD-VC (voice) own those. The roles are written so `apparatus`
  values drop in cleanly (`list`, `code_block`, `callout` candidates).
