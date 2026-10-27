---
title: "AcmeDB: Fast, Unfinished, Single-Region"
subject: "AcmeDB"
verdict: "skip it"
gaf: "low"
slug: "acme-db"
date: "2026-10-24"
tags:
  - "database"
  - "review"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB launch post]]"
---

# AcmeDB: Fast, Unfinished, Single-Region

**skip it** — Fast on a laptop, not ready for production data.

Give-a-shit level: **low** · sources cited: 2 · as of 2026-10-24

## The case

AcmeDB promises very fast reads, but its own docs say point-in-time snapshots and cross-region replication are not here yet. That leaves backup and resilience as roadmap items rather than shipped features. For anything you cannot afford to lose, that is the whole story.

> [!quote] Straight from the source
> Point-in-time snapshots are coming soon. [link](https://example.com/acmedb/docs/backups#:~:text=Point-in-time%20snapshots%20are%20coming%20soon.)

## Blockers

> [!danger] Dealbreakers
> - No point-in-time snapshots yet
> - Cross-region replication still roadmap

## Receipts

| Claim | Evidence | Source |
| --- | --- | --- |
| No point-in-time snapshots | Point-in-time snapshots are coming soon.[^snapshots] | [[AcmeDB docs — backups]] |
| No cross-region replication | Cross-region replication is on the roadmap. | [[AcmeDB docs — backups]] |
| Latency claim is laptop-bound | p99 read latency under 2ms on a laptop. | [[AcmeDB launch post]] |

## Verdict

Skip AcmeDB for production until snapshots and replication ship. Revisit it only for disposable, local workloads.

> [!warning]- Fine print
> - Latency claim is laptop-only
> - Roadmap items have no dates

## Sources

- [[AcmeDB docs — backups]] · `documentation` · reliability **high** · give-a-shit high · [source](https://example.com/acmedb/docs/backups)
- [[AcmeDB launch post]] · `self-published` · reliability **medium** · give-a-shit low · [source](https://example.com/acmedb/launch)

## Footnotes

[^snapshots]: Coming soon means not available at review date.
