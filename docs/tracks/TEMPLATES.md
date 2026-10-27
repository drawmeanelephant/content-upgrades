# TEMPLATES lane notes

## #81 block-gap fixes (this lane)

Rendered all four templates against every matching `data/*.json` and
flagged every non-blank line directly preceding a heading, callout
opener, or table. Fixes, all verified byte-level against k4o
`aeba163`:

- **`---` -> `# h1`**: literal blank line after the closing frontmatter
  fence in all four templates.
- **Chained `{% endif %}{% if x %}` blocks**: a standalone `{% endif %}`
  trims the whitespace run ending the branch body, so a block ends bare
  while the next `{% if %}`'s line-end eat swallows the newline that
  would have separated them. `{{ "" }}{% endif %}` shields it — the last
  body node is an output, not text, so the trim never fires and the block
  emits `content\n`; the chained opener's line-end eat keeps it at one
  blank line.
- **Loop separators**: `{% if not loop.last %}` holding only newlines
  emits nothing (a whitespace-only branch is rolled back), so those
  separators were dead code. Replaced with a trailing blank line in the
  loop body — each iteration discharges one trailing newline and the
  loop joins iterations with one `\n`, leaving exactly one blank line.
- **Footnote refs**: `{% if x.note %}[^{{ x.note | kebab }}]{% endif %}`
  is a silent inline if when the note is absent, which arms the
  strip_leading flag that eats the next newline (claim callouts after a
  note-less `what`). Replaced with
  `{{ x.note | kebab | replace:"/(.+)/":"[^$1]" }}` — an output node
  never arms the strip, so spacing is identical with or without a note.

Checker used: flag any non-blank line directly before `^#{1,6} `,
`^> \[!`, or a table start. Zero violations across all 14 renders
(10 template/data pairs + apparatus rendered from each verdict file).

## Pre-existing, not in scope

- `reading-note.min` renders `by Anonymous·` — a silent inline
  `{% if author %}` arms the strip and eats the space before `·`.
  Same engine rule as the note-if; cosmetic.
