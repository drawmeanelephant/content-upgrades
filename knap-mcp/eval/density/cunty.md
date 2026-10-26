---
title: "Verdict: AcmeDB"
subject: "[[AcmeDB]]"
verdict: give-a-shit
gaf: high
tags: [database, verdict]
accessed: 2026-10-26
---

# Verdict: AcmeDB

> [!verdict] Give a shit
> The **boring database that actually ships**, with one hole you can drive a truck through: *backups*.

AcmeDB does one thing (durable key-value storage) and does it without an operator PhD. No consensus wizardry, no sharding astrology: a `WAL`, a manifest, and docs that answer the question you actually asked.[^docs]

## The case

> "Point-in-time snapshots are coming soon."
> — [[AcmeDB docs — backups]]

The pitch is ==restraint==. The launch post brags about ~~features~~ *the absence of features*, and for once the receipts back it up.[^launch] See [[#Receipts]] for the numbers and [the apparatus page](apparatus.md#sources) for every source.

> [!warning] Blockers
> - No managed backup story yet.[^docs]
> - Single-region only, so plan your own failover.

## Receipts

| Claim | Evidence | Reliability |
| --- | --- | --- |
| p99 reads under **2ms** | vendor benchmark, unreplicated[^bench] | medium |
| Backup gap | docs list snapshots as *coming soon*[^docs] | high |
| Single region | [launch post](https://example.com/acmedb/launch) | medium |

![[acmedb-architecture.png]]

## Verdict

**Ship it behind a cache.** Do not put your crown jewels in it until `snapshot` lands.

### Sources

- [[AcmeDB docs — backups]] ([docs](https://example.com/acmedb/docs#backups)): documentation, reliability **high**
- [[AcmeDB launch post]] ([post](https://example.com/acmedb/launch)): self-published, reliability *medium*

[^docs]: [AcmeDB docs — backups](https://example.com/acmedb/docs#backups), accessed 2026-10-26.
[^launch]: [AcmeDB launch post](https://example.com/acmedb/launch). Self-published; weigh accordingly.
[^bench]: Vendor-reported on a laptop. Treat it as the ceiling, not the floor.
