---
title: "Verdict: AcmeDB"
subject: "AcmeDB"
verdict: "worth caring about"
gaf: "high"
slug: "acme-db"
date: "2026-10-24"
tags:
  - "verdict"
  - "databases"
  - "acmedb"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB launch post]]"
apparatus: "[[Sources]]"
related:
  - "[[AcmeDB docs — architecture]]"
  - "[[Claims]]"
---

# Verdict: AcmeDB

**worth caring about** — the boring database that *actually ships*

Give-a-shit level: **high** · sources cited: 2 · as of 2026-10-24

## The case

AcmeDB does one thing — *durable key-value storage* — and does it without an operator PhD. No consensus wizardry, no sharding astrology; just a WAL, a manifest, and docs that answer the question you actually asked.

> [!quote] Straight from the source
> Point-in-time snapshots are coming soon. [link](https://example.com/acmedb/docs/backups#:~:text=Point-in-time%20snapshots%20are%20coming%20soon.)

## Blockers

> [!danger] Dealbreakers
> - no managed backup story yet
> - single-region only

## Receipts

| Claim | Evidence | Source |
| --- | --- | --- |
| p99 reads under 2ms | vendor benchmark on a laptop, not replicated[^benchmark] | [[AcmeDB launch post]] |
| no managed backups yet | the docs list snapshots as 'coming soon'[^backup-gap] | [[AcmeDB docs — backups]] |
| single-region only | cross-region replication is 'on the roadmap' | [[AcmeDB docs — backups]] |

## Verdict

Ship it behind a cache. Do not put your *crown jewels* in it.

> [!warning]- Fine print
> - We did not run our own benchmark. The latency number is theirs, not ours.
> - Checked against the docs on the date above. Roadmaps move.

## Sources

- [[AcmeDB docs — backups]] · `documentation` · reliability **high** · give-a-shit high · [source](https://example.com/acmedb/docs/backups)
- [[AcmeDB launch post]] · `self-published` · reliability **medium** · give-a-shit low · [source](https://example.com/acmedb/launch)

> [!info]- The full apparatus
> ![[Sources]]

See also: [[AcmeDB docs — architecture]] · [[Claims]]

## Footnotes

[^benchmark]: Benchmark numbers are vendor-reported; treat them as the ceiling, not the floor.

[^backup-gap]: Backup gap confirmed against the docs page on demo-freeze day.
