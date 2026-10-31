---
title: "Verdict: AcmeDB"
subject: "Verdict: AcmeDB"
verdict: "give a shit"
gaf: "unrated"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB issue 412 — cross-region replication]]"
  - "[[AcmeDB launch post]]"
---

# Verdict: AcmeDB

**give a shit** — the boring database that actually ships

Give-a-shit level: **unrated** · sources cited: 3 · as of press time

## The case

AcmeDB does one thing — durable key-value storage — and does it without an operator PhD. No consensus wizardry, no sharding astrology; just a WAL, a manifest, and docs that answer the question you actually asked.

## Blockers

> [!danger] Dealbreakers
> - Cross-region replication is on the roadmap.

## Receipts

| Claim | Evidence | Source |
| --- | --- | --- |
| p99 latency under 2ms | p99 read latency under 2ms on a laptop. | unsourced |

## Verdict

Ship it behind a cache. Do not put your crown jewels in it.

## Sources

- [[AcmeDB docs — backups]] · `documentation` · reliability **high** · give-a-shit high · [source](https://example.com/acmedb/docs/backups)
- [[AcmeDB issue 412 — cross-region replication]] · `issue-tracker` · reliability **medium** · give-a-shit high · [source](https://example.com/acmedb/issues/412)
- [[AcmeDB launch post]] · `self-published` · reliability **medium** · give-a-shit low · [source](https://example.com/acmedb/launch)
