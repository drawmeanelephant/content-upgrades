# AS: structhash audit fixes (#58, #59)

Status: done. Fixes for the Oct 26 audit findings against
`knap-mcp/src/structhash.zig`, each verified with a live CLI probe
(`KNAP_MCP_HOME=$(mktemp -d) knap-mcp structhash <file> --target markdown`)
before and after.

## What landed

- **#58 — `scanInline` recursion is depth-bounded.** Link text used to
  recurse with no cap; `max_depth = 64` covered only block containers.
  A one-line doc of ~10^5 nested links (`[a [a … x …](u)](u)`, ~700 KB,
  under the 64 MB read cap) segfaulted the CLI — and would abort the MCP
  server via a stored rendered doc → `knap_structure_hash`. Now
  `scanInline` carries a link-nesting depth; at the cap it emits a single
  `deep` token inside the link instead of recursing, mirroring the block
  rule. Probe: the same file now hashes (`8e63dc471908e840`), exit 0.
  The stale `max_depth` comment and the C2.md cap claim now say "block
  containers and inline links".

- **#59.1 — two-space hard breaks emit `br`.** `joinTrimmed` trimmed
  trailing spaces/tabs from every paragraph line, so `a  \nb` (renders
  `<br>`) hashed equal to `a\nb`. It now appends the scanner's
  `\<newline>` sentinel when a non-final line ends with ≥2 spaces, so
  both hard-break forms produce the same `br` token. One trailing space
  stays a soft break.

- **#59.2 — markdown inline HTML keeps tag names and attributes.**
  `angle()` used to return only a coarse kind (`html:sup`, or the lumped
  `html:tag` for anything unknown). It now emits `html:<tag attrs>`
  reusing the HTML side's `tagToken` (sorted attribute names, structural
  values kept — `class`, `type`, `colspan`, …; `id`/`title`/`href`
  dropped unless strict). `<video controls>` vs `<audio>` and
  `<span class="a">` vs `<span class="b">` now hash differently.
  The `>` scan skips quoted attribute values (`<a title="x>">` parses to
  the real end). `tagKinds` is gone.

- **#59.3 — ordered-list start is kept.** `Marker` gained `start`; a
  list not starting at 1 emits `ol:{start}` (`3. a` → `ol:3`). Close
  token is still `/ol`.

- **#59.4 — strict keeps raw-URL and autolink targets.** The `h`
  raw-URL branch and `angle()`'s autolink now go through `p.target`, so
  `--strict` emits `rawurl(<url>)` / `autolink(<url>)`. Default mode
  still emits bare `rawurl` / `autolink` — two docs differing only in a
  bare URL collide in default mode by design.

- **Shared edits:** none. Tests for all of the above live inside
  `structhash.zig` (already imported by the `test` block in main.zig).

## Residual collision sources (#59.5, documented — no fix required)

- **64-bit Wyhash** (`hashTokens`, seed 0): birthday collisions are
  possible in principle at ~2^32 docs; far above the artifact-store
  scale. If it ever matters, mix a second independent hash or widen to
  128 bits.
- **Frontmatter empty collection vs null:** `key: []` and `key:` both
  emit `fm:key[0]` — the parser can't distinguish an empty flow list
  from a missing value.
- **Literal dotted keys vs nested maps:** a frontmatter key literally
  written `a.b: 1` collides with `a:` + indented `b: 1` — both produce
  the `fm:a.b` path. Escaped/quoted dotted keys are not un-escaped.
- **Markdown/HTML token namespaces overlap deliberately** (`html:<…>`
  mirrors the HTML side's `<…>`), but formats are separate inputs, so
  this cannot collide within one comparison.
- **Below-cap truncation:** inline link nesting past 64 collapses to one
  `deep` token per truncated link — two docs differing only under the
  cap hash equal, same as over-cap block containers.

## For other lanes

- Nothing required. The strict-mode tool description
  ("strict also keeps link targets") is now true for raw URLs and
  autolinks; no description changes needed.
