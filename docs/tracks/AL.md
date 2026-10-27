# AL: audit findings — repair degradation, eval gate, ratchet/eval batch

Lane: `fix/audit-loops`. Files owned: `src/repair.zig`, `src/ratchet.zig`,
`src/eval.zig`, `eval/ratchet.json`, `eval/ratchet-mock.json`, new
`eval/ratchet/ladder.*` fixtures, this file.

## #45 — repair degrades on transient backend failure

`repair.run` caught nothing: one `error.ToolFailed` from
`backend.repairPatch` aborted the loop and discarded the working template
and step history, against the module's "non-convergence is a feature"
contract. Now `ToolFailed` records a step (`detail: "backend error: <err>"`,
`patch_applied: false`), breaks, and returns the non-converged `Outcome`
with diagnostics — same degradation path `knap_voice` uses for a rejected
field. `OutOfMemory`/`WriteFailed`/`RunError` still propagate.

## #47 — eval gate can fail

`knap-mcp eval` now probes the engine once before the seed loop
(`probeEngine`: one render of a trivial template + `{}` data, scratch files
cleaned by defer). A missing/unrunnable binary fails fast with the engine
error — no more 22-row "converged 0/22" table with exit 0.

Per-seed harness errors (missing `template_path`, unfound `find` target,
bad data ref) now emit an `.errored` row instead of aborting the run —
`runSeed` errors are caught at the loop, matching the existing repair-error
catch. A control that errors counts as `control_broken`.

Exit code is now `@intFromBool(errored > 0 or controls_clean < controls)`,
with a `FAIL:` line printed. Non-converged (`.failed`) seeds still do not
fail the gate — non-convergence is a measurement, not an error. Verified:
`KNAP_K4O_PATH=/nonexistent/k4o` exits 1 fast; `make eval` green path
unchanged (12/22, controls 3/3; 2nap 120/167, controls 2/2).

## #52 — latent batch

1. **ref integrity on scalars**: `checkSchema` now checks `f.ref` for
   `.string`/`.strings` slots after `checkString`, same message shape as
   the object-sub-field check.
2. **evidence on non-claim kinds**: `parseShape` rejects `evidence: true`
   on any slot kind that can't produce a string claim (rows, objects,
   number). `notes` (`object<string,string>` → `.other`, never a slot) is
   untouched — the check runs only where a slot is created. Non-string
   `evidence` sub-fields are also rejected in `parseField`.
3. **`Reason.parse`**: `.bad` replies (non-JSON) now map to `parse`, not
   `schema`; the ratchet-eval table has a `parse` column and the
   `rejections` JSON/`reject` expect key pick it up via `label()`.
4. **Step numbering**: `Step.iteration` is now 1-based, same counter as
   `Result.iterations` (documented on the field).
5. **Malformed expect blocks fail the case**: `expect` stays a raw `Value`
   into `checkExpect`, which returns `FAIL:` on a non-object expect,
   non-numeric `min_gain`, non-string `stop`, non-integer `min_accepted`,
   and non-positive/non-integer `reject` counts.
6. **max_iterations clamped**: per-case value must be an integer 0-20
   (same bound the tool/CLI enforce); anything else is a corpus error.
7. **Header honesty**: the header no longer prints the default
   `max_iters`; a `cap` column shows each case's actual bound.
8. **occurrence**: non-integer or negative `break.occurrence` is a corpus
   error (was silently coerced to 0).
9. **per-seed errors**: covered under #47 above.
10. **coverage**: two new cases on the new `eval/ratchet/ladder.*`
    fixture (one slot per apparatus so candidate order is predictable):
    - `budget-burn` — `box` mock is ten schema violations; it stays the
      top probe candidate forever, so every iteration burns a call on the
      reject plus one on the accept → `stop: budget` at 10 calls, 5
      schema rejects.
    - `plateau-dilution` — a ~170-word `box` value (and wordy table
      cells) makes the real doc much heavier than the stub path, so real
      gains undershoot the ceiling; every ask still lands ≥ eps, slots
      exhaust, and `stop: plateau` fires at 54.4 vs ceiling 56.5.

Design note for future corpus authors: `plateau` needs the real path to
undershoot `stubCeiling` by ≥ eps; prose words inside callouts/quotes/
lists/tables count toward `words`, so long values dilute the probe gains
while short stub text keeps the ceiling high.

## Scratch cleanup (#46 item 1)

`defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {}` added at every
scratch writer in the owned files: `repair.zig` (working template),
`ratchet.zig` (`Run.render` data file, start-failed re-render),
`eval.zig` (`baseRender`, probe files, and `runSeed` for staged inline
data — an `@path` ref is a corpus file and is not deleted). Verified:
`$KNAP_MCP_HOME/tmp` is empty after eval and ratchet-eval runs.

## Gates

- `make test` — green.
- `KNAP_MCP_HOME=$(mktemp -d) make eval` — seeds 12/22 (controls 3/3),
  2nap 120/167 (controls 2/2), exit 0.
- `ratchet-eval --corpus eval/ratchet.json --backend mock` — 13/13
  expectations met, exit 0.
- `KNAP_K4O_PATH=/nonexistent/k4o knap-mcp eval` — exit 1.
- Malformed `expect`/`max_iterations` verified: per-case `FAIL:` and
  corpus errors as designed.
