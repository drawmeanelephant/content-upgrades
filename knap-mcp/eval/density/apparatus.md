---
title: "Apparatus: AcmeDB verdict"
type: "apparatus"
verdict: "[[Claims]]"
date: "2026-10-24"
sources:
  - "[[AcmeDB docs — backups]]"
  - "[[AcmeDB launch post]]"
---
# Apparatus: AcmeDB verdict

*every claim, pinned to the thing it came from*

The receipts behind [[Claims]]. Sources cited: 2.

> [!info] How to read this page
> Reliability is how far we trust a source. Give-a-shit is how much it moved the verdict. Every quote links to the exact passage it came from.

## Source ledger

| Source | Kind | Reliability | Give-a-shit | Accessed |
| --- | --- | --- | --- | --- |
| [[AcmeDB docs — backups]] | `documentation` | **high** | high | 2026-10-24 |
| [[AcmeDB launch post]] | `self-published` | **medium** | low | 2026-10-24 |

## Sources

### [[AcmeDB docs — backups]]

[Read the source](https://example.com/acmedb/docs/backups) · `documentation` · reliability **high** · give-a-shit high

> [!quote] Pulled quote
> Point-in-time snapshots are coming soon. [link](https://example.com/acmedb/docs/backups#:~:text=Point-in-time%20snapshots%20are%20coming%20soon.)

Backs the backup blocker.

> [!quote] Pulled quote
> Cross-region replication is on the roadmap. [link](https://example.com/acmedb/docs/backups#:~:text=Cross-region%20replication%20is%20on%20the%20roadmap.)

Backs the single-region blocker.

### [[AcmeDB launch post]]

[Read the source](https://example.com/acmedb/launch) · `self-published` · reliability **medium** · give-a-shit low

> [!quote] Pulled quote
> p99 read latency under 2ms on a laptop. [link](https://example.com/acmedb/launch#:~:text=p99%20read%20latency%20under%202ms%20on%20a%20laptop.)

Backs the latency claim, read as a ceiling.

## Claim map

| Claim | Backed by | Confidence |
| --- | --- | --- |
| p99 reads under 2ms[^benchmark] | [[AcmeDB launch post]] | low |
| no managed backups yet[^backup-gap] | [[AcmeDB docs — backups]] | high |
| single-region only | [[AcmeDB docs — backups]] | high |

> [!warning]- Open questions
> - We did not run our own benchmark. The latency number is theirs, not ours.
> - Checked against the docs on the date above. Roadmaps move.

## Footnotes

[^benchmark]: Benchmark numbers are vendor-reported; treat them as the ceiling, not the floor.

[^backup-gap]: Backup gap confirmed against the docs page on demo-freeze day.
