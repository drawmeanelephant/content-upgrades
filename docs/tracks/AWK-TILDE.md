# AWK-TILDE — voice.awk `~` pairing parity with the zig guard

Lane: fix/awk-tilde-pairing, issue #247. Surfaced by MD-VH (#244), which
left `~` on the weaker `addruns`/`added_runs_bad` run-length pairing while
`=` got `eqscan`'s flanking rule.

## What landed

- `voice.awk` gains `tildescan(s)`: the `eqscan` pattern for `~`. Hides
  `code` spans, pairs runs of exactly two `~` under the emphasis flanking
  rule (open iff next isn't space — punctuation next byte needs space or
  punctuation on the left; close iff prev isn't space — punctuation prev
  byte needs space or punctuation on the right; doing both, it closes iff
  the stack is non-empty). Returns the resolved `del` count.
- W2 `~` accounting now mirrors zig exactly: `countchar(out,"~") -
  countchar(in_,"~")` must equal `4 * (del_ou - del_in)`. The old run
  pairing saw `plan~~[^1]~~` (two closers, no opener — `~~` can't
  flank-hug `[`) as balanced; tildescan resolves zero spans there, so the
  chars fail the count as `unbalanced ~`, matching zig's W2 (zig also
  reports W1 `delim:~`, which awk has no equivalent for).
- `nspans` and the mild italic-only check use `del_ou - del_in` (was
  `AR[2]/2 - int(countchar(in_,"~")/4)`), matching zig's `opened()`
  delta — an input with stray `~~` no longer inflates its span credit.
- `testdata/bad.jsonl` line 50: `the plan~~[^1]~~ works` expects
  `unbalanced ~`.
- `src/voice.zig`: mechanical `lines.len` bump 49 → 50 in the bad.jsonl
  test (forced by the added line; outside the lane's ownership list but
  the test literal tracks the owned file).

## Gates

    sh knap-mcp/prompts/voice/check.sh   50/50 selftest breaks, 0 failures
    make test                            209/209

Done-when: check.sh reports the new selftest break caught —
`plan~~[^1]~~` rejected as `unbalanced ~` by awk (zig already did).

## Decisions

- tildescan keeps eqscan's approximation set: only code spans are hidden
  (not `[^…]` labels or link targets), and delimiters inside a resolved
  span stay matchable — zig's resolveEmphasis kills those. Both are
  contrived shapes that trip other checks first; same trade eqscan made.
- `~~` runs of length other than 2 resolve to nothing and their chars
  still count toward W2 — same as zig emitting no token for them.
