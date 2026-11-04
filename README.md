# Content Upgrades

[![CI](https://github.com/drawmeanelephant/content-upgrades/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/drawmeanelephant/content-upgrades/actions/workflows/ci.yml)

**Meta does the thinking. Give the content an upgrade.**

Content Upgrades turns model output and existing Markdown into richer documents:
callouts, receipts tables, footnotes, source links, and prose with some personality.
Meta Muse models supply content. Human-authored templates and deterministic checks
control the structure.

**Knap is the engine, not a second product name.** `knap-mcp` is one Zig binary
with the same tools available through a stdio MCP server and a direct CLI.

## An improvement loop, not another formatting prompt

The server scores the rendered document, probes its empty template slots, and
chooses the slot with the most promising formatting gain. It asks the model for
one value, checks that value, and keeps it only if the rendered score improves.
Existing nonempty values and the template do not change.

The model does not choose layout during content generation. A separate repair
path can ask for a template-region patch, which the engine must render again.

The same toolchain also supports existing Markdown: read-only corpus audits,
confined ingestion, extraction into template data, and policy-gated voice passes.
Those paths keep source-tree writes separate from generated artifacts.

## Run the demo without an API account

Use Zig 0.17.0 and `jq`. Install `boris` to include the publication-reference
check. Without it, `make demo` reports that beat as skipped.

From the repository root:

```sh
make engines
make
export KNAP_MCP_HOME="$(mktemp -d)"
make demo
```

The demo uses the offline `mock` backend and recorded model takes. It makes no
live model requests. Its transcript and generated documents are in
`demo/out/demo/`. Initial engine setup may fetch pinned source revisions.

Try the core loop yourself:

```sh
eval "$(scripts/engines.sh env)"
export KNAP_MCP_HOME="$(mktemp -d)"
knap-mcp/zig-out/bin/knap-mcp ratchet release-notes \
	-d knap-mcp/data/release-notes.min.json --backend mock
```

Inspect `steps`, `score`, `stop`, `data_id`, and `doc_id` in the response.
`density/3` measures formatting density, not factual accuracy or writing quality.
The loop can stop before filling every slot.

`make install` installs the binary under `~/.local/bin` by default. Set
`KNAP_TEMPLATES_DIR` and `KNAP_MCP_HOME` when running an installed binary outside
this checkout. See the [command and MCP reference](knap-mcp/README.md).

## Where Meta and Baseten fit

| Work | Model and route | Evidence |
|---|---|---|
| Draft structured content | Meta Muse Spark open through Baseten's direct API | [Submission capture](demo/frozen-submission/README.md) |
| Fill upgrade slots | Meta Muse Spark open through Baseten | Recorded upgrade input, output, and receipt in the submission capture |
| Repair a template and vary voice | Meta Muse Wonder 1.0 through ACP | [Recorded takes and provenance](demo/frozen/provenance.json) |
| Exercise the pipeline without credentials | `mock`, not a Meta model | `make demo` and `make eval` |

Recorded cases are examples, not a claim that every model call succeeds.
The video labels recorded takes, seeded failures, and shortened API waits.
The typed API key is an invented joke, never a real key or key prefix.

## Use an existing model connection

No paid provider is required for the offline demo. Live requests can consume
provider credits.

| Backend | Configuration |
|---|---|
| `baseten` | `MODEL_API_KEY`; requests `meta-models/muse-spark-open-1026` from Baseten |
| `spark`, `wonder` | `MODEL_API_KEY` for the Meta API |
| `acp` | `KNAP_ACP_AGENT` for an ACP agent you already have |
| `compat` | `KNAP_COMPAT_URL`, `KNAP_COMPAT_MODEL`, and optional `KNAP_COMPAT_KEY` |
| Local Ollama | Configure `compat`, or use the `ollama` profile in `scripts/live.sh` |

Provide credentials privately through your environment or credential manager.
Never put them in a tape, source file, or recording.
`scripts/live.sh --list` describes provider profiles. `backends --probe` and live
smoke tests contact providers; they are not part of the credential-free quickstart.

## What the checks establish

- Templates own document structure. Content generation fills values, not layout.
- Accepted ratchet steps improve the deterministic formatting score.
- Evidence-marked fields pass the configured verifier. The default is a heuristic,
  not a general semantic fact-checker.
- Voice guards protect named tokens and constrain markup, length, and tone.
  They do not prove that arbitrary rewritten prose means the same thing.
- Publication checks resolve references against a site graph. A resolved link
  does not establish that its claims are true.

## Verify the checkout

```sh
make test
KNAP_MCP_HOME=$(mktemp -d) make eval
make demo
```

The mock eval measures seeded repair behavior and controls, not Meta model
performance. [Submission notes](docs/tracks/SUBMISSION.md) map the public claims
to the commands and recorded artifacts that support them.

## Components and credits

- [`knap-mcp/`](knap-mcp/README.md): MCP server, CLI, scorer, upgrade loop, guards,
  and eight shipped templates.
- [`scripts/engines.sh`](scripts/engines.sh): pinned k4o and dogbed rendering
  engines. The Makefile uses those pins, never a mutable neighboring build.
- [`boris-site/`](boris-site/): the frozen site graph used by reference checks.
- [`demo/`](demo/storyboard.md): executable recordings and the end-to-end demo.
- `corpus/render.json`: a vendored 188-case fixture set from upstream Obsidian
  knap, under MIT. Rendering engines and vendored fixtures are credited
  dependencies, not model-generated project code.

## License

MIT. See [LICENSE](LICENSE).
