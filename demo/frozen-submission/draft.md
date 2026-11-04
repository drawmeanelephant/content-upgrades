---
title: "AcmeDB should you give a shit"
subject: "AcmeDB"
verdict: "skip it for now"
gaf: "low"
slug: "acme-db"
date: "2026-10-24"
tags:
  - "acmedb"
  - "database"
  - "backups"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB launch post]]"
apparatus: "[[AcmeDB apparatus 2026-10-24]]"
related:
  - "[[databases]]"
  - "[[backups]]"
  - "[[benchmarks]]"
---

# AcmeDB should you give a shit

**skip it for now** — Promising laptop numbers do not make up for missing fundamentals

Give-a-shit level: **low** · sources cited: 2 · as of 2026-10-24

## The case

AcmeDB talks fast on latency but is still missing the boring stuff that keeps data safe. The docs admit core backups and replication are not shipped yet. Until those land you are betting production on promises.

> [!quote] Straight from the source
> Point-in-time snapshots are coming soon. [link](https://example.com/acmedb/docs/backups#:~:text=Point-in-time%20snapshots%20are%20coming%20soon.)

## Blockers

> [!danger] Dealbreakers
> - No point-in-time snapshots yet
> - No cross-region replication yet
> - Self-published latency only

## Receipts

| Claim | Evidence | Source |
| --- | --- | --- |
| No point-in-time snapshots | Point-in-time snapshots are coming soon.[^soon-not-now] | [[AcmeDB docs — backups]] |
| No cross-region replication | Cross-region replication is on the roadmap.[^roadmap-risk] | [[AcmeDB docs — backups]] |
| Laptop latency only | p99 read latency under 2ms on a laptop.[^laptop-claim] | [[AcmeDB launch post]] |

## Verdict

AcmeDB is not ready for production where you need restores and redundancy. Revisit after snapshots and replication actually ship.

> [!warning]- Fine print
> - Docs reviewed October 2026 only
> - Launch post is self-published
> - No independent benchmarks found

## Sources

- [[AcmeDB docs — backups]] · `documentation` · reliability **high** · give-a-shit high · [source](https://example.com/acmedb/docs/backups)
- [[AcmeDB launch post]] · `self-published` · reliability **medium** · give-a-shit low · [source](https://example.com/acmedb/launch)

> [!info]- The full apparatus
> ![[AcmeDB apparatus 2026-10-24]]

See also: [[databases]] · [[backups]] · [[benchmarks]]

## Footnotes

[^soon-not-now]: Coming soon means not available to rely on today.

[^roadmap-risk]: Roadmap is a promise not a shipped feature.

[^laptop-claim]: Laptop benchmark does not reflect production conditions.
