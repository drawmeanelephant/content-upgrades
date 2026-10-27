# Track DEMO: real flat cold-open doc (#92, built on the acp backend from #130)

Owner files: `demo/fixtures/generic-ai-doc.md`,
`demo/fixtures/generic-ai-doc.provenance.json`, and this note.

## What landed

- `demo/fixtures/generic-ai-doc.md` is no longer hand-written: it is the
  verbatim reply of a live model asked to "write a verdict on AcmeDB" from
  the sources in `knap-mcp/data/verdict.sample.json`, with no template.
- `demo/fixtures/generic-ai-doc.provenance.json` records the backend, agent
  command, model id, exact system+user prompt, date, ACP usage, and the
  `knap-mcp density` score (`density/2` -> 25.7, 479 words).

## Provenance (honest on tape)

- `MODEL_API_KEY` is not available, so per the lane brief the output was
  produced through knap-mcp's `acp` backend (`acp.zig` driving an ACP
  agent subprocess, landed via #130), not Spark/Wonder. A sponsor-model re-render can
  replace the fixture later; that is why the PR says "Part of #92".
- `KNAP_ACP_AGENT='devin acp --model gpt-5-5-none'`, default agent. The
  brief's `--agent-type summarizer` was tried first: the summarizer
  answers with a session-summary envelope (`<summary>` + meta sections
  describing the request), not a document, so it cannot produce the
  fixture.
- ACP has no temperature knob (`acp.prompt` sends one text block).
  `gpt-5-5-none` (no-thinking) was picked as the lowest-variance stand-in
  for "temperature as low as the API allows".
- Selection: same prompt run against `gpt-5-5-none` and
  `claude-sonnet-4-6`. Claude's reply used footnotes, a sources table,
  and rules (density 56.4) — closer to knap's own apparatus than to the
  flat pattern — so the GPT reply (density 25.7, wall paragraph / header /
  wall paragraph) was picked. Neither was edited.
- 2026-10-27 re-run on Muse Wonder 1.0 via `devin acp --model
  muse-wonder-1-0-low` (probe reported `muse-wonder-1-0-high`, effort
  low). Two sessions, same prompt: both replies came back apparatus-rich
  — receipts tables/subsections, footnotes, blockquote citations, sources
  sections — scoring 52.5 and 35.2 on density/2. Neither is a fair flat
  example, so the fixture stays `gpt-5-5-none` (25.7, 479 words) and the
  Wonder replies are recorded in the provenance `selection` block with
  `why_not`. Beat 1's on-screen density number is unchanged.

## How it was produced

No CLI path exposes a raw `backend.complete`, so a throwaway
`src/ask_once.zig` harness (Ctx.init + `backend.completeReply(.acp,
.judge, system, user)`, compiled with a stub `build_options` module) made
the call through the real `--backend acp` code path. The harness is not
committed; the compiled binary lived outside the tree.

## Left for later

- Muse Spark re-run once the opencode account has funds (`scripts/live.sh
  --suite <suite> opencode-spark-1.3`, or `KNAP_ACP_AGENT` on a funded
  opencode). Same prompt, same selection rule. That is the last piece of
  #92.
- Beat 1 tape overlay: the density number on screen is still 25.7
  (`density/2`) — the Wonder re-run did not change the fixture, so no
  overlay change is needed — see `demo/run.sh` and the Kdenlive overlay
  note in `demo/storyboard.md`.
