# AGENTS.md

Rules for agents working in this repo, often several at once. The lane
tables and file-ownership hot map live in `docs/PARALLEL-PLAN.md`.

## Setup

- One git worktree per agent. Work on the branch your worktree gives you
  (else `feat/<lane>-<slug>` off `main`, per `CONTRIBUTING.md`). Never work
  in another agent's checkout.
- Zig 0.17.0. Build from `knap-mcp/` or through the root `Makefile`.
- Engines are pinned in `scripts/engines.sh`. `make engines` builds any
  missing pin into `~/.cache/knap-engines/<name>-<sha7>/`; the Makefile
  exports `KNAP_K4O_PATH` / `KNAP_DOGBED_PATH` from the pins for every
  target. Outside make: `eval "$(scripts/engines.sh env)"`.
- Never point at `~/dev/k4o/zig-out` or `~/dev/dogbed/zig-out`, and never
  build in, check out, or modify those working trees. Never overwrite
  anything under `~/.cache/knap-engines/`.
- Use a private artifact store: `export KNAP_MCP_HOME=$(mktemp -d)`.
- A pin bump is its own PR: change one SHA line at the top of
  `scripts/engines.sh`.

## Picking up an issue

The roadmap is the GitHub milestones (`1 · Pre-freeze hardening` →
`4 · Ship`), not the plan docs. Each issue is one lane.

- Labels say who takes it: `agent:swe-2` (default), `agent:advanced`
  (Opus-class; the body says why), `human-only` (skip it). Don't take an
  issue above your tier.
- Skip anything labeled `blocked:model-key`, and anything whose
  **Depends on:** issues are still open.
- Work the lowest-numbered milestone first. Claim the issue with a comment
  before you start, and leave it alone if someone else already claimed it.
- The issue's **Files you own** is your lane's ownership list. Its
  **Done when** plus the Gates below is your gate.
- Put `Closes #N` in the PR body. If the spec turns out wrong, comment on
  the issue instead of improvising.
- New work you find goes in a new issue that follows
  `.github/ISSUE_TEMPLATE/task.md`, with a tier label and a milestone.

## File ownership

- Edit only the files your lane owns. If you need another file, don't
  edit it; say so in your handoff.
- The only shared edits are one-line entries: the tool registry, the CLI
  table, and the test-import list. The merge captain resolves conflicts
  there.
- Don't edit `README.md`, `docs/SPEC.md`, `docs/GAMEPLAN.md` or
  `docs/PARALLEL-PLAN.md`. Write notes to `docs/tracks/<LANE>.md`.

## Adding a tool

All paths are under `knap-mcp/src/`.

1. **One file:** `tools/<name>.zig` exporting `pub const tool: tools.Tool`
   (`name`, `description`, `input_schema`, `run`). Shared handler helpers
   are in `tools/common.zig`. Real logic goes in its own `<name>.zig`.
2. **One registry line:** append `@import("tools/<name>.zig").tool,` to
   `all` in `tools.zig`. Its order is the MCP `tools/list` order.
3. **One CLI row:** add to `commands` in `main.zig`. A tool row sets
   `.tool` and `.key` (the argument the first positional fills); `data`
   and the `tool_flags` options are passed through automatically. A new
   string flag for tools is one entry in `tool_flags` plus a help line in
   `usage_tail`. Anything else is a `.custom` fn
   `fn (ctx: *Ctx, args: [][]const u8) anyerror!u8`.
4. **One test-import line** per new file in the `test { ... }` block at
   the bottom of `main.zig`. Tests in unlisted files never run.

`zig build` fails if a CLI row names an unregistered tool, or if a tool or
command name is duplicated.

Model calls go through `backend.complete(ctx, kind, task, system, user)`
with a `backend.Task`; don't add another curl path. `mock` has no live
completion, so a feature that needs offline output keeps its own canned
path (as `repairPatch` does).

## Gates

Before opening a PR:

```sh
make test
KNAP_MCP_HOME=$(mktemp -d) make eval    # mock convergence table
```

plus your lane's own gate. For behavior-preserving changes, capture
outputs before and after and diff them.

## PR flow

- Short conventional commit messages that say why (`feat:`, `fix:`,
  `docs:`, `chore:`). Keep the configured git author identity.
- Rebase on `main`; linear history is enforced.
- One small PR per lane against `main`, titled `<type>(<LANE>): <summary>`.
  The body lists everything it adds plus the gate output.
- Never push to `main` and never merge your own PR. The merge captain
  merges in dependency order and reruns `make test` after each merge.

## Handback

End with a short handoff (what landed, what's left, what other lanes must
know). The last line is exactly:

```
PR <full URL>, head <SHA>, checks and reviews <state>
```
