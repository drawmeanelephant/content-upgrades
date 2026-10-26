# Boris working context pack 1/1

Each document below is a complete Boris source file. To reuse one, copy
everything after its `<!-- boris-rag-doc: ... -->` marker through the next
marker (or the end of the file).


<!-- boris-rag-doc: id="content/acmedb-docs-architecture" source="sources/acmedb-docs-architecture.md" category="content" -->
---
id: acmedb-docs-architecture
title: AcmeDB docs — architecture
parent: sources
tags: [source, documentation, reliability-high, gaf-medium]
summary: AcmeDB's architecture page; one node, a write-ahead log, and a manifest.
---

# AcmeDB docs — architecture

- URL: https://example.com/acmedb/docs#architecture
- Kind: documentation
- Reliability: high
- Give-a-shit: medium
- Accessed: 2026-10-24, demo-freeze day

## What it says

> Every write is appended to the write-ahead log and fsynced before it is
> acknowledged.

> A single manifest file records the live set of sorted tables.

> AcmeDB does not shard. One node owns the whole keyspace.

## Why it matters

The durability story is simple enough to audit: WAL, fsync, manifest. The
same page rules out horizontal scale; there is no partitioning layer to tune.

## Used for

- [[claims/durable-writes]]
- [[claims/horizontal-sharding]]


<!-- boris-rag-doc: id="content/acmedb-docs-backups" source="sources/acmedb-docs-backups.md" category="content" -->
---
id: acmedb-docs-backups
title: AcmeDB docs — backups
parent: sources
tags: [source, documentation, reliability-high, gaf-high]
summary: AcmeDB's backups documentation; lists point-in-time snapshots as coming soon.
---

# AcmeDB docs — backups

- URL: https://example.com/acmedb/docs#backups
- Kind: documentation
- Reliability: high
- Give-a-shit: high
- Accessed: 2026-10-24, demo-freeze day

## What it says

> Point-in-time snapshots are coming soon.

> Cross-region replication is on the roadmap.

The page documents one operation: a manual dump to a local file. There is no
scheduled backup, no managed snapshot, and no restore-to-timestamp.

## Why it matters

This is the vendor's own reference documentation, so a gap here is a gap in
the product. Anyone running AcmeDB today owns their own backups.

## Used for

- [[claims/backup-gap]]
- [[claims/single-region-only]]


<!-- boris-rag-doc: id="content/acmedb-issue-412-cross-region-replication" source="sources/acmedb-issue-412-cross-region-replication.md" category="content" -->
---
id: acmedb-issue-412-cross-region-replication
title: AcmeDB issue #412 — cross-region replication
parent: sources
tags: [source, issue-tracker, reliability-medium, gaf-high]
summary: Maintainer reply on the AcmeDB tracker; multi-region is not planned this year.
---

# AcmeDB issue #412 — cross-region replication

- URL: https://example.com/acmedb/issues/412
- Kind: issue tracker
- Reliability: medium
- Give-a-shit: high
- Accessed: 2026-10-24, demo-freeze day

## What it says

> Multi-region is not planned for this year. Run one region and ship your
> dumps somewhere else.

The issue has 140 upvotes and one maintainer reply. It is still open.

## Why it matters

It turns the docs' "on the roadmap" into a date: not this year.

## Used for

- [[claims/single-region-only]]


<!-- boris-rag-doc: id="content/acmedb-launch-post" source="sources/acmedb-launch-post.md" category="content" -->
---
id: acmedb-launch-post
title: AcmeDB launch post
parent: sources
tags: [source, self-published, reliability-medium, gaf-low]
summary: AcmeDB's launch announcement; the only source for the 2ms p99 read number.
---

# AcmeDB launch post

- URL: https://example.com/acmedb/launch
- Kind: self-published
- Reliability: medium
- Give-a-shit: low
- Accessed: 2026-10-24, demo-freeze day

## What it says

> p99 read latency under 2ms on a laptop.

> AcmeDB is a durable key-value store. No consensus, no sharding, no surprises.

The post links no benchmark harness, names no dataset size, and reports no
write latency.

## Why it matters

It is marketing. The latency number is the vendor's best case on one machine,
and nobody has reproduced it.

## Used for

- [[claims/p99-reads-under-2ms]]


<!-- boris-rag-doc: id="content/claims" source="claims.md" category="content" -->
---
title: Claims
parent: index
tags: [claims]
summary: What the AcmeDB verdict concludes, each claim with a verdict and its evidence.
---

# Claims

Each claim page carries one verdict tag: `supported`, `refuted`, or
`unverified`. Its `cites` relations name the sources that decide it.

| Claim | Verdict |
|---|---|
| [[claims/backup-gap]] | supported |
| [[claims/single-region-only]] | supported |
| [[claims/durable-writes]] | supported |
| [[claims/p99-reads-under-2ms]] | unverified |
| [[claims/horizontal-sharding]] | refuted |

Back to the [[index|research desk]].


<!-- boris-rag-doc: id="content/claims/backup-gap" source="claims/backup-gap.md" category="content" -->
---
title: AcmeDB has no managed backups
parent: claims
tags: [claim, supported]
relations: [cites=acmedb-docs-backups]
summary: Supported. AcmeDB has no managed backup or point-in-time restore today.
---

# AcmeDB has no managed backups

## Claim

AcmeDB has no managed backup and no point-in-time restore today.

## Verdict

**Supported.** The vendor's backups page lists snapshots as coming soon and
documents only a manual dump.

## Evidence

- [[acmedb-docs-backups]]: "Point-in-time snapshots are coming soon."


<!-- boris-rag-doc: id="content/claims/durable-writes" source="claims/durable-writes.md" category="content" -->
---
title: AcmeDB acknowledges only durable writes
parent: claims
tags: [claim, supported]
relations: [cites=acmedb-docs-architecture]
summary: Supported. Every write is fsynced to the write-ahead log before it is acknowledged.
---

# AcmeDB acknowledges only durable writes

## Claim

An acknowledged write survives a crash: AcmeDB fsyncs each write to its
write-ahead log before acknowledging it.

## Verdict

**Supported.** The architecture page states it directly.

## Evidence

- [[acmedb-docs-architecture]]: "Every write is appended to the write-ahead
  log and fsynced before it is acknowledged."


<!-- boris-rag-doc: id="content/claims/horizontal-sharding" source="claims/horizontal-sharding.md" category="content" -->
---
title: AcmeDB shards the keyspace across nodes
parent: claims
tags: [claim, refuted]
relations: [cites=acmedb-docs-architecture]
summary: Refuted. AcmeDB does not shard; one node owns the whole keyspace.
---

# AcmeDB shards the keyspace across nodes

## Claim

AcmeDB partitions its keyspace across several nodes for horizontal scale.

## Verdict

**Refuted.** The architecture page says one node owns the whole keyspace.

## Evidence

- [[acmedb-docs-architecture]]: "AcmeDB does not shard. One node owns the
  whole keyspace."


<!-- boris-rag-doc: id="content/claims/p99-reads-under-2ms" source="claims/p99-reads-under-2ms.md" category="content" -->
---
title: AcmeDB serves p99 reads under 2ms
parent: claims
tags: [claim, unverified]
relations: [cites=acmedb-launch-post]
summary: Unverified. The 2ms p99 read number is vendor-reported, on a laptop, and unreplicated.
---

# AcmeDB serves p99 reads under 2ms

## Claim

AcmeDB serves p99 point reads in under 2 milliseconds.

## Verdict

**Unverified.** The only evidence is the vendor's own benchmark, run on a
laptop, with no published harness. Treat 2ms as the ceiling, not the floor.

## Evidence

- [[acmedb-launch-post]]: "p99 read latency under 2ms on a laptop."


<!-- boris-rag-doc: id="content/claims/single-region-only" source="claims/single-region-only.md" category="content" -->
---
title: AcmeDB is single-region only
parent: claims
tags: [claim, supported]
relations: [cites=acmedb-docs-backups, cites=acmedb-issue-412-cross-region-replication]
summary: Supported. AcmeDB runs in one region; cross-region replication is not planned this year.
---

# AcmeDB is single-region only

## Claim

AcmeDB runs in a single region. There is no cross-region replication.

## Verdict

**Supported.** The docs put replication on the roadmap, and the maintainers
say it is not planned this year.

## Evidence

- [[acmedb-docs-backups]]: "Cross-region replication is on the roadmap."
- [[acmedb-issue-412-cross-region-replication]]: "Multi-region is not planned
  for this year."


<!-- boris-rag-doc: id="content/index" source="index.md" category="content" -->
---
title: AcmeDB research desk
tags: [home]
summary: The frozen research pack behind the knap verdicts on AcmeDB.
---

# AcmeDB research desk

This is the research pack behind the knap verdicts on AcmeDB. Every source a
verdict cites has a page here, and every claim is pinned to the source it came
from.

The site is a frozen artifact. knap-mcp reads its search index and graph, and
stages rendered verdicts into a throwaway copy to check that every wiki-link
resolves before anything is published. Nothing is indexed live.

- [[sources]]: what we read, with reliability and give-a-shit ratings.
- [[claims]]: what we concluded, each with a verdict and its evidence.

## How references resolve

A knap template writes a source name as a wiki-link, for example
`[[AcmeDB launch post]]`. Boris entity ids cannot contain spaces, so the
staging step rewrites the target to its slug (`acmedb-launch-post`) and keeps
the name as the label. Each source page declares that slug as its `id`. A
name that has no page fails the check with `EREFERENCEMISSING`.


<!-- boris-rag-doc: id="content/sources" source="sources.md" category="content" -->
---
title: Sources
parent: index
tags: [sources]
summary: Every source cited by an AcmeDB verdict, with reliability and give-a-shit ratings.
---

# Sources

Every source an AcmeDB verdict cites. A source page's id is the slug of its
name, so a knap `wikilink` on the name resolves here.

| Source | Kind | Reliability | Give-a-shit |
|---|---|---|---|
| [[acmedb-docs-backups]] | documentation | high | high |
| [[acmedb-docs-architecture]] | documentation | high | medium |
| [[acmedb-launch-post]] | self-published | medium | low |
| [[acmedb-issue-412-cross-region-replication]] | issue tracker | medium | high |

## Reliability scale

- **high**: the vendor's own reference documentation, versioned with the
  product.
- **medium**: vendor marketing or a maintainer comment; true at the time,
  never re-checked.
- **low**: hearsay, screenshots, or unsourced benchmarks.

Back to the [[index|research desk]].

