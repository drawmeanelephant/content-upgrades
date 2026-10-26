# Design note — ACP as a model backend (later goal)

Status: captured, not scheduled. Lives behind `backend.repairPatch()` in
`knap-mcp/src/backend.zig` — add it as `Kind.acp` and nothing upstream changes.

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
ACP-speaking agent" instead of "any OpenAI-compatible endpoint". Spawn the
agent subprocess once per `knap_repair`/`knap_voice` call sequence, reuse
the session across iterations (each iteration's slice is a fresh prompt in
the same session — iteration noise stays in the cheap tier per SPEC).

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

- **Judge-pluggable demo**: the repair loop runs on whatever ACP agent the
  judge has configured — no key wrangling, no hardcoded provider.
- **Muse Code dogfood beat**: if the sponsor's agent speaks ACP, it becomes
  our repair backend over a standard protocol — the "their agent drives our
  server" beat from GAMEPLAN gets a second leg.
- **keeps the story clean**: models write patches; agents are just another
  way to get model output. The broker contract doesn't care.

## What it is not

- Not a replacement for direct API calls — metering/pricing visibility for
  the numbers card still wants the raw HTTP path.
- Not something knap-mcp *serves*. knap-mcp is a tool server; MCP stays its
  upstream surface. ACP here is strictly downstream (us as client).
- Not on the Oct 26–30 critical path. Mock covers plumbing; spark covers
  real numbers. This lands after freeze or not at all.

## Open questions when it lands

1. Which ACP agents to smoke first (Muse Code? Zed-ecosystem agents?)
2. Session lifecycle: one session per repair call vs. per server lifetime.
3. Permission/terminal capabilities — we want agents in read-none/write-none
   mode (prompt in, text out); confirm the protocol supports refusing
   capability requests cleanly.
4. Streaming vs. collect: `session/prompt` streams chunks; the repair loop
   wants the final text only — collect-and-take-last is fine.
