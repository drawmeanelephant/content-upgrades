# prompts/voice

The content half of `knap_voice`: a system prefix, three tone guides, few-shot examples, and canned mock replies. The model rewrites one JSON string value per call. It never sees the template, so the same template renders every tone with the same structure.

Nothing here is Zig. `src/voice.zig` (lane C1) loads these files at runtime.

## Files

| File | What it is | Sent to the model? |
|---|---|---|
| `system.md` | The contract: rewrite one value, keep facts exact, return only the string, add no markup, stay within length bounds. | Yes, verbatim |
| `mild.md`, `spicy.md`, `feral.md` | Tone guides. | Yes, verbatim, one per call |
| `examples/<tone>.jsonl` | Few-shot pairs, 11 per tone, with the same inputs in every tone. | Yes, rendered into the system message |
| `mock/<tone>.jsonl` | Canned replies for every `voice: true` value in the four `data/*.sample.json` files, for the mock backend. | No |
| `voice.awk` | The guard (fact and markup checks) and the reference prompt assembler. | No |
| `check.sh` | Runs the guard over every example and mock reply, plus `testdata/bad.jsonl`. | No |
| `assemble.sh` | Prints the exact system and user messages for one call. | No |
| `testdata/bad.jsonl` | Known-bad rewrites. Each must trip the guard with the expected reason. | No |
| `testdata/system.<tone>.txt`, `testdata/user.take.txt` | `assemble.sh` output, checked in. `src/voice.zig`'s tests compare its own assembly with them. Regenerate them when a prompt file or example changes. | No |

The `.md` files are prompt text, sent byte for byte apart from trailing whitespace. Don't add front matter, comments or notes to them; put notes in this README.

## JSONL format

One JSON object per line: UTF-8, LF line endings, no blank lines, no comments. Every value is a string. Write non-ASCII characters raw (`—`, not `\u2014`). The checker accepts only these escapes: `\"`, `\\`, `\/`, `\n`, `\t`, `\r`.

| Key | Meaning |
|---|---|
| `template` | Template id: `verdict`, `apparatus`, `release-notes` or `reading-note`. |
| `field` | JSON path inside the data, without the template id: `take`, `blockers[0]`, `receipts[1][0]`, `subtitle`, `sources[0].quotes[0].used_for`. A dot separates object keys; `[n]` is an array index. |
| `field_role` | The shape descriptor's `role` for the field, verbatim. An element of an `array<string>` adds ` (one item)`. |
| `input` | The value before the voice pass. |
| `output` | The value in this file's tone. |

Lines in `testdata/bad.jsonl` add `tone` and `expect`, a substring of the failure reason the guard must report.

## Voice-eligible fields

The shape descriptors in `templates/shapes/*.json` are the source of truth. A field is rewritten only if its descriptor has `"voice": true`. Today that means:

| Template | Voice fields | Notes |
|---|---|---|
| verdict | `title`, `verdict`, `take`, `summary`, `bottom_line`, `sources[i].quotes[j].used_for` | `verdict` is direction-locked (a yes stays a yes) and four words at most. `summary` may carry footnote markers like `[^1]`, which must survive. `frontmatter.title` is never rewritten, so it diverges from `title` after a voice pass. `quotes[j].text` stays verbatim; only the `used_for` annotation is rewritten. |
| apparatus | `subtitle`, `sources[i].quotes[j].used_for` | `quotes[j].text` stays verbatim; only the `used_for` annotation is rewritten. |
| release-notes | `verdict`, `take`, `screenshot_alt`, `tldr`, `breaking_warning`, `breaking[i].change`, `breaking[i].fix`, `highlights[i].what`, `known_issues[i]`, `bottom_line` | `title` is not flagged: its kebab-case form becomes the frontmatter `slug`, so rewriting it would move the page URL invisibly to the structure hash. |
| reading-note | `verdict`, `take`, `summary`, `quotes[i].why`, `thoughts[i]`, `spoilers`, `bottom_line` | `title` is not flagged: it is the work's title. |

The few-shot examples come from verdict and apparatus roles. The other templates' roles are close enough (verdict, take, summary, bottom line, bullets) that the same examples carry over.

Proposed, but not flagged in the shapes yet. The examples already cover them, so flagging them later needs no prompt change:

| Template | Field | Why it's safe | Role to send |
|---|---|---|---|
| verdict | `blockers[i]` | Prose bullets. | `dealbreakers, bulleted (one item)` |
| verdict | `footnotes[i]` | Prose notes about sources; the guard protects their facts. | `rendered as [^n] footnote definitions (one item)` |
| verdict | `receipts[r][0]`, r ≥ 1 | The claim cell only. This needs a column-aware flag, so it waits for a shape change. | `claim/evidence rows -> pipe table (one claim cell)` |
| SPEC sketch | `claims[i].text` | Claim prose. `source_ids` stays in its own field. | the shape's role |
| SPEC sketch | `sources[i].quotes[j].used_for` | An annotation, not the quote. | the shape's role |

## Never rewritten

C1 must never send these to the model, whatever a future shape says:

- Ids and citation ids: `id`, `source_ids`, and anything used as a key.
- URLs: `sources[*].url` and any other `url` field.
- Wikilink targets: `sources[*].name` (rendered as `[[name]]`) and `sources[*].title`. Changing them breaks `knap_publish_check`.
- Dates and numbers stored as fields: `accessed`, `year`, and any number or boolean.
- Enums: `rel`, `reliability`, `gaf`, `confidence`.
- Verbatim quotes: `sources[*].quotes[*]` (apparatus) and `quotes[*].text` (SPEC sketch). A quote is evidence.
- `frontmatter`, the whole object. It is YAML metadata that the site graph reads.
- Table structure: `receipts[0]` (the header row) and `receipts[r][1]` (the evidence column).
- `apparatus.title`, `reading-note.title` and `release-notes.title`. They are page identities in the site, and the release-notes title's kebab-case form is the frontmatter `slug`. The same slug hazard makes `verdict.title` never-rewritten whenever `subject` is absent: `subject`'s kebab-case is the slug, and it falls back to `title` via `??`.
- release-notes and reading-note: `product`, `version`, `date`, `codename`, `highlights[*].name`, the verbatim `highlights[*].claim` and `quotes[*].text` (both deep-linked with `#:~:text=`, so a reworded quote breaks the link), page-name fields (`related`, `connections`, `migration_guide`, `up_next`), URL fields (`screenshot`, `cover`, `source_url`, `changelog_url`, `docs_url`), `note` keys, `notes`, `tags`, `gaf`, `status`, and the `upgrade_matrix` and `aged` tables.

## Call assembly

Make one call per eligible value, through `backend.complete(ctx, kind, .voice, system, user)`.

1. Walk the template's shape. For each field with `"voice": true`, a `string` is one value and an `array<string>` gives one value per element. For an `array<object>`, walk its `fields` for every element the same way (`breaking[0].change`). Skip values that are not strings, are empty, or contain a line break or control character.
2. `field` is the JSON path (`take`, `blockers[0]`, `breaking[0].change`). `role` is the shape's `role` string for that field; for an element of an `array<string>`, append ` (one item)`.
3. Build the system message. It is identical for every call in a tone:

   ```
   system = rtrim(system.md) + "\n\n" + rtrim(<tone>.md) + "\n\n## Examples"
            + for each line of examples/<tone>.jsonl, in file order:
                "\n\nField: " + field + "\nRole: " + field_role
                + "\nInput: " + input + "\nOutput: " + output
   ```

   `rtrim` drops trailing spaces, tabs, CR and LF. The message has no trailing newline.
4. Build the user message, also without a trailing newline:

   ```
   user = "Field: " + field + "\nRole: " + role + "\nInput: " + value
   ```

5. Clean the reply: trim surrounding whitespace, drop a leading `Output:` and trim again, and if the reply is wrapped in one pair of `"` that the input doesn't have, drop the pair.
6. Run the guard (below). If it passes, the value becomes the reply. If it fails, keep the original value and record the reasons. Don't retry at temperature 0: the same request gets the same reply.
7. The per-field diff count is the number of values whose final text differs from the original.

`assemble.sh` is the reference implementation. A Zig test can compare its own assembly with it:

```sh
sh prompts/voice/assemble.sh system spicy > want-system.txt
sh prompts/voice/assemble.sh user take "one-line hot take" "the boring database that actually ships" > want-user.txt
```

Caching: there are exactly three system messages, one per tone, each 5.6 to 6.3 KB. Each one is the same for every field, template and document. Only the short user message changes, so every call after the first in a tone can hit the prompt cache. The model never gets the template, sibling fields or the boris graph (SPEC, context economy rule 1).

## The guard

These are the rules `voice.awk` applies to the examples. C1 ports the hard rules to Zig and runs them on every reply. Lengths are in UTF-8 bytes.

Hard rules. A failure keeps the original value.

1. Every protected token in the input appears unchanged in the reply:
   - URLs: `http://` or `https://` up to whitespace, a quote, `<`, `>` or `)`, minus trailing `.,;:!?`.
   - `[[wikilinks]]` and footnote markers like `[^1]`.
   - Quoted spans: `"..."`, and `'...'` where the opening quote doesn't follow a letter or digit and the closing quote isn't followed by one. Apostrophes don't count.
   - Number tokens: maximal runs of `[$#~<>A-Za-z0-9.,%/:_+-]` that contain a digit, minus trailing `.,:/_+-`. Examples: `p99`, `2ms`, `$400`, `2026-10-20`, `256MB`.
   - Names: letter runs with two or more capitals (`AcmeDB`, `PhD`, `WAL`), and capitalized words of two or more letters that don't start a sentence (`Redis`, `Enterprise`). A word starts a sentence if it comes first, or if the nearest character before it, skipping spaces, quotes, `(` and `[`, is `.`, `!` or `?`.

   Number tokens and names must match as whole words, with no letter or digit on either side. The other tokens match as substrings.
2. The reply adds no new URL, wikilink, footnote marker, quoted span, number token, or mixed-case name like `QuuxQueue`. New all-caps words and new capitalized words are allowed, because that is how shouting and title case look.
3. The reply keeps the input's markup exactly. Each of ``* _ ` | # < > [ ] { } ~ ^ @ \ "`` occurs at most as often as in the input and at least as often — dropped markup changes the rendered structure hash as surely as added markup. `!!` or `??` only where the input has them. It may not start with `- `, `+ `, `* `, `= `, `> `, `# `, `1. `, `1) `, `---`, or a textile block tag (`h1. `, `p. `, `bq. `, `bc. `, `pre. `, `fn1. `). The Zig guard also compares the inline structure skeletons of input and reply directly (`structhash.zig`), which catches re-paired or moved markup the character counts miss. Where a field's descriptor marks `footnote_abutting` and the element carries a `note`, the template emits `[^note]` right after the value, so a reply may not end in `!` (`![^n]` reads as image syntax).
4. No control characters, no line breaks, valid UTF-8, no emoji (no 4-byte UTF-8 sequences and nothing from U+2600 to U+27BF).
5. The length is between ceil(L/2) and max(2L, L + 40) bytes, where L is the input length. A role containing "one-word" or "four word" (as in "two-to-four word upgrade verdict") allows four words at most. The reply must keep at least half of the input's content words (stopword-free, stemmed — verifier.zig's tokenizing), and a reply that contains the input verbatim may not lead with two or more content words the input lacks: `Sure! Here is the take: <value>` is meta prose, not a rewrite.
6. The reply is not empty.

Tone budgets. `check.sh` enforces them on the examples. At runtime they are advisory and only logged, except that a mild reply containing profanity (the brand phrase included) should be rejected.

| Tone | Profanity words | New all-caps words | `!` |
|---|---|---|---|
| mild | 0 | 0 | 0 |
| spicy | 1, no f-word | 1 | 1 |
| feral | 2 | 3 | 2 |

The profanity list lives in `voice.awk`.

The guard can't see everything. When examples change, a person checks the verdict's direction, the hedges and certainty ("vendor-reported" stays hedged), new claims written in plain words, new acronyms (a new `SQL` passes as shouting), and the safety line in `feral.md`.

## Mock replies

`mock/<tone>.jsonl` holds hand-written replies for the 38 `voice: true` values in `data/*.sample.json` (verdict 8, apparatus 4, release-notes 14, reading-note 12). A mock backend looks up `(template, field, input)` and returns `output`. On a miss it returns the input unchanged, and the field counts as unchanged. These lines are never sent to a model. `check.sh` warns when a mock input no longer matches the sample data.

## Why the examples use other subjects

Every few-shot input is about a made-up subject (QuuxQueue, NimbusCache, OrbitDesk Pro), never AcmeDB. If the examples reused the demo data, the model could copy the example outputs, and the voice demo would show memorized text instead of a rewrite. `check.sh` fails if an example input equals any string in `data/*.sample.json`. The examples still cover the same field roles as the sample data, and the guard rejects replies that leak an example's mixed-case names.

## Checking

```sh
sh knap-mcp/prompts/voice/check.sh
```

It needs only POSIX sh and awk, and it was tested with macOS `/usr/bin/awk` and gawk. It prints one line per problem, then a summary, and exits non-zero on any failure:

```
voice check: 33 examples, 114 mock replies, 21/21 selftest breaks caught, 0 warnings, 0 failures
```

It checks that every line parses with the right keys, that every example and mock reply passes the guard, that each tone has at least 6 examples, that all three tones share the same `template`, `field`, `field_role` and `input` sequence, that no example input is copied from the sample data, and that every line in `testdata/bad.jsonl` is caught with the expected reason.
