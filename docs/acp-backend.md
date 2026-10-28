# Design note — ACP as a model backend

Status: shipped as `Kind.acp` (`knap-mcp/src/acp.zig`). The transport
lives behind `backend.complete()` in `knap-mcp/src/backend.zig`. This
note keeps the design rationale and records the lifecycle as shipped.

## What ACP is

[Agent Client Protocol](https://agentclientprotocol.com/get-started/introduction)
— agent↔editor, not model↔server. An editor (or any client) spawns an agent
as a subprocess and talks JSON-RPC 2.0 over stdio: `initialize`,
`session/new`, `session/prompt`, streamed `session/update` notifications,
`session/cancel`. It reuses MCP's JSON representations where possible.

So ACP is **not** an inference-provider protocol. `spark`/`wonder`/`baseten`
stay curl + OpenAI-compatible HTTP against `https://api.meta.ai/v1` —
that path is direct inference and needs no second component.

## Where it fits

`Kind.acp` = *agent-as-provider*: the cheap iteration tier becomes "any
ACP-speaking agent" instead of "any OpenAI-compatible endpoint". The
shipped lifecycle (acp.zig's header contract):

- One agent subprocess per knap-mcp process, spawned lazily on the first
  call and respawned only if it dies or `KNAP_ACP_AGENT` changes.
- One `session/new` **per prompt** — repair iterations and voice slots
  never see each other's turns, so iteration noise can't leak across
  slices.
- The contract is prompt in, text out: `initialize` advertises no
  fs/terminal capabilities, every `session/request_permission` is
  cancelled, every other agent→client request is refused
  (`-32601`), and only `agent_message_chunk` text for the prompt's own
  session is collected.

Three edge behaviors worth knowing:

- The agent's stderr is discarded unless `KNAP_DEBUG` is set — it is the
  agent's log and may carry account details.
- Normal exit relies on the agent exiting at stdin EOF: knap-mcp closes
  its end of the pipe and the agent reaps itself; `kill` is only for the
  error/respawn paths.
- A prompt that outlives `KNAP_ACP_TIMEOUT` (default 180s, 0 = none)
  gets a `session/cancel` and a 5s grace period; an agent that ignores
  the cancel is killed so the next call starts a fresh subprocess.

Minimal client surface we actually need:

- `initialize` → protocolVersion, capabilities handshake
- `session/new` → `sessionId` (+ `cwd`)
- `session/prompt` → prompt parts carry the repair slice (stable prefix +
  diag + region + patch grammar); response lands via `session/update`
  notifications (`agent_message_chunk` content) + the `session/prompt`
  result's `stopReason`
- `session/cancel` for bailing a runaway iteration

That's ~4 methods + 1 notification — a few hundred LOC of client, or a
thin component in another language wrapping an official SDK. The transport
is the same newline-delimited JSON-RPC we already run inbound for MCP, so
a Zig client reuses `mcp.zig`'s framing almost verbatim.

## Why it's worth it

- **Pluggable iteration tier**: the repair and voice loops run on whatever
  ACP-speaking agent the user has installed — no API-key wrangling, no
  hardcoded provider.
- **Agents as just another backend**: any agent that speaks ACP becomes a
  model source over a standard protocol, behind the same
  `backend.complete()` contract as the HTTP providers.
- **keeps the story clean**: models write patches; agents are just another
  way to get model output. The broker contract doesn't care.

## What it is not

- Not a replacement for direct API calls — metering/pricing visibility for
  the numbers card still wants the raw HTTP path.
- Not something knap-mcp *serves*. knap-mcp is a tool server; MCP stays its
  upstream surface. ACP here is strictly downstream (us as client).
- Not a required backend. `mock` covers plumbing in tests; the HTTP
  providers cover metered calls.

## Design questions — answered at implementation

1. Which ACP agents to smoke first — the bundled profiles cover
   `devin acp`, `gemini --acp`, `codex-acp` and `opencode`
   (`scripts/live.sh --list`; `knap-mcp smoke --backend acp` handshakes
   one before eval calls are spent).
2. Session lifecycle — neither "one session per repair call" nor "per
   server lifetime": one agent subprocess per knap-mcp process, but a
   fresh `session/new` for every prompt, so repair iterations and voice
   slots never see each other's turns.
3. Permission/terminal capabilities — confirmed cleanly refused: the
   client advertises `readTextFile`/`writeTextFile`/`terminal` all false
   at `initialize`, answers `session/request_permission` with
   `cancelled`, and `-32601`s every other agent→client request.
4. Streaming vs. collect — `session/update` notifications stream in while
   `session/prompt` is in flight; the client concatenates
   `agent_message_chunk` text for its own session (thoughts, tool calls,
   plans and other sessions' updates are dropped) and returns it with the
   result's `stopReason` and `usage`.
