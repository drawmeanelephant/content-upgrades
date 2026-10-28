# Track DC: audit docs — SPEC tool surface, voice-markup claims, ACP lifecycle

Status: done. Lane files: `docs/SPEC.md`, `README.md`,
`docs/acp-backend.md`, `knap-mcp/templates/shapes/*.json`
(description/role wording only), this note. Nothing else touched.

Closes audit issues #197, #206, #207. Everything below verified on the
tree at d4a6fa9 (= PR #198, `feat(VOICE): inline emphasis + emoji`) —
no issue fetched, `gh` unavailable in this lane's environment; claims
checked against code instead.

## What changed

- `docs/SPEC.md`
  - Tool surface now lists all 14 tools in `tools.zig` `all` order.
    Added `knap_structure_hash` (strict / ignore_formatting flags),
    `knap_verify_citation` (heuristic default, decision falls back),
    `knap_density` (density/2, markdown only, no model call) and
    `knap_ratchet` (values-only slot fill). Also fixed two drifts the
    same lane flagged earlier (docs/tracks/ADOC.md §"SPEC drift"):
    `knap_publish_check(doc_id, site)` → `knap_publish_check(doc_id)`
    (input_schema requires `doc_id` only), and `knap_templates` "slim
    catalog / shape on request" → shape inlined (matches
    `tools/templates.zig`'s own comment). `knap_lint` signature updated
    to `template_id | template_text` per its schema.
  - "Spark" as the only-backend phrasing generalized to the configured
    backend / backend call (dissemination rule, repair loop prose and
    state machine, `knap_voice`, scope-out line, risk #2). The tiering
    bullet is renamed "Fast/cheap (Spark-class)" and names the
    pluggable `Kind` set (`mock`, `acp`, `compat`,
    `spark`/`wonder`/`baseten`, backend.zig:18).
  - Eval plan: dropped the phantom "2nap's 41 output triples + 16 error
    cases" conformance corpus. Conformance is the vendored 188-case
    `corpus/render.json`, measured 187/188
    (`knap-mcp/eval/conformance/README.md`). The 41 triples + 16 errors
    are the *provenance* of `eval/seeds.2nap.json` (167 breaks + 2
    controls), stated as such alongside `eval/seeds.json` (22 breaks +
    3 controls).
  - Voice eval bullet: exact-hash equality → `structhash
    --ignore-formatting` normalized-hash equality, with exact-hash
    drift reserved for the negative controls (matches
    `eval/voice/run.sh` and its README). Demo beat 6 updated to match
    ("identical normalized structure hash ... feral inserts emphasis").
- `README.md`
  - Line 3 "the model never writes markup, so it can't break it" →
    insert-only inline emphasis (`**`, `*`, `~~`, code spans quoting
    the input, allowlisted emoji within the tone's budget) with the
    guard keeping everything else out.
  - Install note: dropped "(install-aware defaults are tracked in
    #176)" — #176 is closed, shipped in #190 as the exe-relative
    resolution now in `ctx.zig` (`KNAP_TEMPLATES_DIR` →
    `<exe>/../../templates` → `./templates`). The sentence now
    documents that order; the env-var advice stands.
- `docs/acp-backend.md`
  - "Reuse the session across iterations" replaced with the shipped
    contract (acp.zig:7-13): one subprocess per knap-mcp process
    (lazy spawn, respawn on death or `KNAP_ACP_AGENT` change), one
    `session/new` per prompt.
  - Documented: agent stderr discarded unless `KNAP_DEBUG`
    (acp.zig:26-27, 185); normal exit relies on the agent exiting at
    stdin EOF (`shutdown`/`kill` only runs on respawn/error paths —
    acp.zig:63, 164-172, 344); `session/cancel` on prompt timeout with
    a 5s grace then kill (`cancel_grace_secs`, acp.zig:43, 250-257).
  - Open questions section → "answered at implementation": #2 session
    lifecycle (per prompt), #3 capabilities (advertised false;
    permission requests cancelled, others `-32601`, acp.zig:214,
    285-294), #4 collect `agent_message_chunk` text + `stopReason` +
    `usage` (acp.zig:298-307, 130-133), #1 first-smoke agents
    (`scripts/providers.sh` profiles: devin, gemini, codex-acp,
    opencode; `knap-mcp smoke --backend acp`).
- `knap-mcp/templates/shapes/{verdict,apparatus,reading-note,release-notes}.json`
  - Template-level `description` tail "Plain strings, no markdown: the
    template does all formatting." → "The template does all layout;
    strings hold text, not markup — except that `voice: true` fields
    may carry constrained inline formatting (**, *, ~~ on words the
    reply added, code spans quoting the input, allowlisted emoji within
    the tone's budget)." Mirrors the guard contract in
    `prompts/voice/system.md` rule 6.
  - Per-field `role` sweep: nothing stale found. "rendered bold" /
    "rendered italic" / "alt text" / frontmatter roles are still
    correct — those slots are styled by the template and the voice
    rules tell the model to add no formatting there. "No | or newlines
    in values" (table rows) also stands: `|` is locked both directions
    and line breaks are still rejected.

## Not touched

- `knap-mcp/prompts/voice/README.md` Files-table staleness — another
  lane owns it, per issue #197's note.
- `docs/tracks/LIVE.md`, `knap-mcp/eval/results/` — other lanes.
- ADOC's remaining recommended edits: demo beat 7 keeps
  `verdict.oliver` (listed as an accept-or-fix deviation; left as-is).

## Gate

Docs-only lane; no required gate. `make test` could not be run in this
environment (shell restricted to read-only commands) — the change set
touches markdown and one JSON string field per shape file, no code
paths. JSON edits stay inside a single string value; no structure
changed.
