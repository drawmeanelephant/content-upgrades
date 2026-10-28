# AC: ACP process lifecycle + CLI arg strictness (issues #199, #208)

Lane AC. Owner files: `src/acp.zig`, `src/mcp.zig`, `src/main.zig`,
`src/acp_fake_agent.sh`, this note.

## What landed

### #199 — ACP process-lifecycle holes

- **`acp.shutdown` now runs on every exit path**, not just respawn/error
  teardown: `mcp.serve` gained `defer acp.shutdown(ctx.io)` (covers stdin
  EOF, `ReadFailed`, and error returns) and `main` gained the same defer
  after `Ctx.init` (covers every CLI command — `ask`, `smoke`,
  `backends --probe`, tool rows — plus `serve`).
- **`shutdown` is grace-then-kill.** It closes the agent's stdin first
  (a cooperative agent's cue to exit), then pumps the stdout
  `MultiReader` for a 1s `shutdown_grace_secs` so a dying agent's EOF
  lands promptly, then `child.kill` SIGKILLs (a no-op if it already
  exited) and reaps. An agent that ignores EOF — or double-forks — is
  gone by the time `shutdown` returns; `agent.child.id` is null.
- **`send` is bounded.** It was `writeStreamingAll` with no deadline:
  an agent that stops reading + a prompt bigger than the pipe buffer
  (~64 KiB; `ask` reads files up to 4 MiB) hung forever since
  `KNAP_ACP_TIMEOUT` only covered reads. Now each write goes through
  `io.operateTimeout(.file_write_streaming, deadline)` in `send_chunk`
  (512 B) pieces. 512 is the smallest PIPE_BUF across supported
  platforms (Darwin 512, Linux 4096): POSIX guarantees a
  poll-reported-writable pipe accepts a ≤PIPE_BUF write without
  blocking, so the deadline is never defeated inside `writev`. A
  timed-out write surfaces as `acp agent '<name>' stopped reading its
  input` and stops the subprocess (the next call respawns).
- `send` takes the call's `std.Io.Timeout`; `call`, `answerRequest`, and
  `notifyCancel` thread their live deadline through (the cancel path
  uses the 5s grace deadline).
- `KNAP_ACP_TIMEOUT` doc line now says it bounds the prompt write too.

### #208 — surplus args silently dropped

- **`serve` is now a real `commands` row** (`.custom = cmdServe`, first
  row so `--help` output keeps its order). `cmdServe` rejects any arg:
  `knap-mcp serve --bogus` exits 1 with usage instead of serving on EOF.
  `knap-mcp serve --help` prints its usage row like every other command
  — the generic `-h|--help` scan now covers `serve` for free. Bare
  `knap-mcp` still goes straight to `mcp.serve`.
- **Tool rows reject surplus positionals.** `key` commands (`render`,
  `validate`, `repair`, `voice`, `ratchet`, …) require exactly one
  positional — `knap-mcp render verdict extra1 extra2` now fails
  `render: unexpected argument 'extra1'` + usage, exit 1. `key == null`
  commands (`templates`) reject any positional. `exactly_one` rows keep
  their `needs exactly one` message covering both 0 and >1.
- **`eval` rejects positionals** the same way (`--corpus`/`--backend`
  flags unchanged).

### Fake agent + tests

- `acp_fake_agent.sh` gained two modes: `deaf` (replies like `ok` but
  `exec sleep 3600` after stdin EOF instead of exiting) and `stuffed`
  (answers `session/new`, then `exec sleep 3600` — stdin is never read
  again, so a large prompt backs up in the pipe).
- New tests in `acp.zig`: `shutdown kills and reaps an agent that
  ignores stdin EOF` (mode `deaf`: prompt, `shutdown`, assert `!live`
  and `agent.child.id == null`) and `a prompt larger than the pipe to a
  non-reading agent fails at the deadline` (mode `stuffed`,
  `KNAP_ACP_TIMEOUT=1`, 128 KiB prompt → `ToolFailed` "stopped reading
  its input", `!live`, elapsed < 30s).

## Interface notes for other lanes

- `mcp.serve` signature changed: `serve(init: std.process.Init, ctx:
  *Ctx)` → `serve(ctx: *Ctx)` — everything it needed is already on
  `ctx` (`ctx.io`, `ctx.gpa`). `main.zig` is the only caller.
- `acp.send`, `acp.answerRequest`, `acp.notifyCancel` gained a leading
  `deadline: std.Io.Timeout` parameter (all file-private).
- `serve` moving into `commands` means `usage_text` emits it from the
  table — the hand-written `usageLine("serve", ...)` is gone; help
  output order is unchanged.
- `commands`/`tool_flags` are shared one-line surfaces: the `serve` row
  is a first-row insert; merge captain may see adjacent-row conflicts.
- Not mine, same bug class: `ratchet-eval` (`ratchet.zig` cmdEval),
  `structhash` (variadic by design), `publish-check`, `density`
  (tools/*.zig) still accept whatever positionals their own parsers
  drop. If #208 wants total coverage those lanes need a positional
  check too.
- `--help`/`--version`/`ask`/`smoke`/`backends` already reject or
  intentionally ignore args; left as-is.

## Gates

- `make test`, `KNAP_MCP_HOME=$(mktemp -d) make eval`,
  `make live P=fake` — to be run by the merge captain / parent agent
  (this subagent's sandbox denied `zig`/`make`/`git worktree`; code was
  written and reviewed against the Zig 0.17 std sources at
  /opt/homebrew/lib/zig/std).
- Expected new-test runtime ≈ 2s each: `deaf` spends the 1s shutdown
  grace before the kill; `stuffed` hits the 1s write deadline + grace.
- Manual verification for the checklist: `knap-mcp render verdict e1
  e2` → exit 1 + usage; `knap-mcp serve --bogus` → exit 1 + usage;
  `knap-mcp serve --help` → usage, exit 0; `KNAP_ACP_AGENT="/bin/sh
  '…/acp_fake_agent.sh' deaf" knap-mcp ask …` → no fake-agent left in
  `ps` after exit.
