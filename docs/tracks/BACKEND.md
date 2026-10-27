# BACKEND — ACP subprocess backend (#129)

Stacked on #130 (feat/backend-live-robustness). Design: `docs/acp-backend.md`;
feasibility: `docs/tracks/M1.md` ("ACP backend feasibility").

## What landed

- `backend.Kind.acp`. Every `--backend` / `KNAP_BACKEND` parse picks it up.
  `complete`/`completeReply(.acp)` run one ACP turn; `repairPatch(.acp)` goes
  through `remotePatch`, so agent output gets the same `sanitizePatch`,
  truncation and trailing-newline handling as HTTP replies.
- `knap-mcp/src/acp.zig`: the ACP client. It sends `initialize`,
  `session/new`, `session/prompt` and `session/cancel`, and collects
  `agent_message_chunk` text from `session/update`.
  - One agent subprocess per knap-mcp process. It starts on the first call
    and starts again only if it dies or `KNAP_ACP_AGENT` changes. Each call
    gets its own `session/new`.
  - Prompt in, text out. The client advertises no fs or terminal
    capabilities and cancels `session/request_permission`. It refuses every
    other agent→client request with -32601. It keeps chunks from its own
    session only and drops thoughts, tool calls and other sessions.
  - When a turn runs past `KNAP_ACP_TIMEOUT` the client sends
    `session/cancel` and gives the agent 5 s to acknowledge. Without an
    acknowledgement it kills the agent. A crash, broken framing, an
    unsupported protocolVersion or a timeout in init/session/new also
    kills it. Each of these returns `ToolFailed` with `ctx.err_msg`, and
    callers degrade as they do for HTTP failures.
  - Error messages name only argv[0], never the rest of `KNAP_ACP_AGENT`.
    Agent stderr is discarded unless `KNAP_DEBUG` is set. Agent error
    text passes through `brief` (300 bytes).
- `stopReason` maps onto `Reply.finish_reason`: `max_tokens` is read as
  truncated, `refusal` gives empty content and `cancelled` fails. ACP
  `usage` (`inputTokens`/`outputTokens`/`totalTokens`/`thoughtTokens`) is
  parsed into `Usage`.
- `backend.statusLine(ctx, kind)` returns the `knap-mcp backends` text for
  each kind, acp included.
- Tests: `src/acp_fake_agent.sh` is a fake ACP agent in POSIX sh with modes
  ok, fenced, maxtok, hang, mute, crash, auth and v2. The tests cover chunk
  filtering, refused capabilities, reuse of one process with a new session
  per call, a respawn when the agent line changes, cancel and kill on
  timeout, a crash, an auth error, a protocolVersion mismatch, a spawn
  failure that keeps argv out of the message, and repair through the
  sanitizer.

## Settings

| env | meaning |
|---|---|
| `KNAP_ACP_AGENT` | agent argv, split on whitespace; `'…'`/`"…"` group. Keep secrets out (argv is `ps`-visible) |
| `KNAP_ACP_TIMEOUT` | seconds per session/new + prompt (default 180, 0 none) |
| `KNAP_ACP_INIT_TIMEOUT` | seconds for spawn + initialize (default 60) |
| `KNAP_ACP_CWD` | absolute session cwd (default: process cwd); point it at `$KNAP_MCP_HOME` to keep tool-capable agents out of the tree |

## Live smoke (2026-10-26, this machine)

Template `# {{ title | upper }` followed by an `{% if %}` that never
closes. The data is `{"title":"hi","items":["a","b"]}`.

```
KNAP_ACP_AGENT="devin acp --agent-type summarizer" KNAP_ACP_CWD=$KNAP_MCP_HOME \
  knap-mcp repair smoke -d data.json --backend acp
→ converged:true, iterations:2, ~10 s wall
  patch 1: "# {{ title | upper }}\n\n{% if items %}…"   (mock would emit "}} }")
  patch 2: "…{% endfor %}{% endif %}\nDone.\n"         (mock appends at the end)
```

Both patches came from the model. Neither matches the mock table's output.

`gemini --acp` started and initialized. Its `session/prompt` returned a 403
("Agent Platform API has not been used in project undefined"), so this
machine's gemini account is not set up. The failure degraded into a
non-convergence step carrying the bounded message. gemini also takes about
5 s to exit after its stdin closes.

## Left for other lanes

- **#131 / main.zig:** `cmdBackends` hardcodes `{.spark,.wonder,.baseten}`
  under a MODEL_API_KEY line, so `knap-mcp backends` doesn't list acp yet.
  The fix is a loop over every non-mock kind that prints
  `backend.statusLine(ctx, k)`. `usage_tail` / `--backend` help should
  mention `acp` and `KNAP_ACP_*`.
- **voice.zig / ratchet.zig / verifier.zig:** these gate non-mock backends
  on `MODEL_API_KEY` (voice.zig:96, ratchet.zig:960, verifier.zig:131), so
  voice, ratchet and the decision verifier still refuse `acp`. Repair and
  eval work today. Each gate becomes `kind != .acp and …`.
- **tools/*.zig input schemas:** the `backend` enums (repair, ratchet,
  voice) leave out `"acp"`. The CLI passes it through, but schema-checking
  MCP clients will reject it.
- No temperature control and no per-token metering, beyond what the agent
  reports in `usage`. Record this in eval provenance. The devin summarizer
  agent also writes a summary file per session under
  `~/.local/share/devin/summaries/`.
