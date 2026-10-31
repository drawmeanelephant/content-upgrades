---
title: "AcmeDB: Should you give a shit?"
subject: "AcmeDB"
verdict: "skip it for now"
gaf: "low"
slug: "acme-db"
date: "2026-10-24"
tags:
  - "database"
  - "storage"
  - "infrastructure"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB launch post]]"
apparatus: "[[AcmeDB apparatus]]"
---

# AcmeDB: Should you give a shit?

**skip it for now** — Fast on a laptop, nowhere near prod ready

Give-a-shit level: **low** · sources cited: 2 · as of 2026-10-24

## The case

AcmeDB promises p99 reads under 2ms on a laptop, which is cute. But backups are still coming soon and cross-region replication is just a roadmap bullet. Until those ship, it is a toy, not a database you bet on.

> [!quote] Straight from the source
> Point-in-time snapshots are coming soon. [link](https://example.com/acmedb/docs/backups#:~:text=Point-in-time%20snapshots%20are%20coming%20soon.)

## Blockers

> [!danger] Dealbreakers
> - No point-in-time snapshots yet
> - No cross-region replication yet

## Receipts

| Claim | Evidence | Source |
| --- | --- | --- |
| Backups not ready | Point-in-time snapshots are coming soon.[^coming-soon] | [[AcmeDB docs — backups]] |
| Single region only | Cross-region replication is on the roadmap.[^roadmap-risk] | [[AcmeDB docs — backups]] |
| Fast laptop reads | p99 read latency under 2ms on a laptop.[^laptop-only] | [[AcmeDB launch post]] |

## Verdict

Skip AcmeDB until snapshots and replication actually ship. Revisit when coming soon becomes shipped.

> [!warning]- Fine print
> - Based on docs accessed 2026-10-24
> - Laptop benchmark not production evidence
> - Roadmap features may slip

## Sources

- [[AcmeDB docs — backups]] · `documentation` · reliability **high** · give-a-shit high · [source](https://example.com/acmedb/docs/backups)
- [[AcmeDB launch post]] · `self-published` · reliability **medium** · give-a-shit low · [source](https://example.com/acmedb/launch)

> [!info]- The full apparatus
> ![[AcmeDB apparatus]]

## Footnotes

[^coming-soon]: Coming soon means not available to rely on now

[^roadmap-risk]: Roadmap items have no ship date guarantee

[^laptop-only]: Laptop result does not predict production latency
