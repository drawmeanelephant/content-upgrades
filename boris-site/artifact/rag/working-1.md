# Boris working context pack 1/1

Each document below is a complete Boris source file. To reuse one, copy
everything after its `<!-- boris-rag-doc: ... -->` marker through the next
marker (or the end of the file).


<!-- boris-rag-doc: id="content/acmedb-2-0-migration-guide" source="published/acmedb-2-0-migration-guide.md" category="content" -->
---
id: acmedb-2-0-migration-guide
title: AcmeDB 2.0 migration guide
parent: published
tags: [published, guide]
summary: Upgrade steps from AcmeDB 1.x to 2.0, in order.
---

# AcmeDB 2.0 migration guide

1. Upgrade every driver to 1.8 or newer. 2.0 drops the v1 wire protocol.
2. Rename `wal_dir` to `storage.wal_path` in `acmedb.toml`. 2.0 refuses to
   start on the old key.
3. Restart the server on 2.0.
4. Run `acmedb doctor` and fix anything it flags.
5. Take a first snapshot with `acmedb snapshot create`.

From 1.7 or older, dump and reload instead of upgrading in place.


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


<!-- boris-rag-doc: id="content/apparatus-acmedb-verdict" source="published/apparatus-acmedb-verdict.md" category="content" -->
---
id: apparatus-acmedb-verdict
title: "Apparatus: AcmeDB verdict"
parent: published
tags: [published, apparatus]
summary: The published apparatus; every quote in the verdict, pinned to its source.
---

# Apparatus: AcmeDB verdict

- Companion to: [[verdict-acmedb]]
- Published: 2026-10-24, demo-freeze day

The apparatus lists each source the verdict cites, with its reliability and
the exact quotes used. The source pages are under [[sources]].


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


<!-- boris-rag-doc: id="content/e-m-forster" source="library/e-m-forster.md" category="content" -->
---
id: e-m-forster
title: E. M. Forster
parent: library
tags: [library, author]
summary: English novelist, 1879 to 1970; wrote "The Machine Stops" in 1909.
---

# E. M. Forster

- Born: 1879
- Died: 1970
- Known for: *A Room with a View*, *Howards End*, *A Passage to India*

His one piece of science fiction, "The Machine Stops", is collected in
[[the-eternal-moment-and-other-stories]].


<!-- boris-rag-doc: id="content/h-g-wells" source="library/h-g-wells.md" category="content" -->
---
id: h-g-wells
title: H. G. Wells
parent: library
tags: [library, author]
summary: English writer, 1866 to 1946; the scientific romances Forster was answering.
---

# H. G. Wells

- Born: 1866
- Died: 1946
- Known for: *The Time Machine*, *The War of the Worlds*, *A Modern Utopia*

[[e-m-forster]] wrote "The Machine Stops" as a reaction to one of Wells's
early utopias.


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


<!-- boris-rag-doc: id="content/library" source="library.md" category="content" -->
---
title: Library
parent: index
tags: [library]
summary: Authors and books that reading notes link to by name.
---

# Library

Authors and books a reading note can link to. A name such as
`[[E. M. Forster]]` stages as its slug, `e-m-forster`.

| Page | What |
|---|---|
| [[e-m-forster]] | Author |
| [[h-g-wells]] | Author |
| [[the-eternal-moment-and-other-stories]] | Collection |

What went out from this desk is under [[published]].

Back to the [[index|research desk]].


<!-- boris-rag-doc: id="content/published" source="published.md" category="content" -->
---
title: Published
parent: index
tags: [published]
summary: Docs knap has published from this desk; rendered docs link and embed them by name.
---

# Published

Docs that went out from this desk. A knap template names them with a
wiki-link or an embed, for example `[[Verdict: AcmeDB]]`; staging rewrites
the name to its slug, and each page here declares that slug as its `id`.

| Page | What |
|---|---|
| [[verdict-acmedb]] | The verdict |
| [[apparatus-acmedb-verdict]] | The verdict's sources and quotes |
| [[acmedb-2-0-migration-guide]] | Upgrade steps, embedded by the 2.0 release notes |
| [[reading-queue]] | What to read next, embedded by reading notes |

Back to the [[index|research desk]].


<!-- boris-rag-doc: id="content/reading-queue" source="published/reading-queue.md" category="content" -->
---
id: reading-queue
title: Reading queue
parent: published
tags: [published, reading]
summary: Short fiction queued for a reading note.
---

# Reading queue

1. "The Point of It", from [[the-eternal-moment-and-other-stories]].
2. "The Star", by [[h-g-wells]].
3. "The Story of the Days to Come", by [[h-g-wells]].

Authors and collections are in the [[library]].


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


<!-- boris-rag-doc: id="content/the-eternal-moment-and-other-stories" source="library/the-eternal-moment-and-other-stories.md" category="content" -->
---
id: the-eternal-moment-and-other-stories
title: The Eternal Moment and Other Stories
parent: library
tags: [library, book]
summary: Forster's 1928 story collection; it opens with "The Machine Stops".
---

# The Eternal Moment and Other Stories

- Author: [[e-m-forster]]
- Published: 1928
- Free text: https://www.gutenberg.org/ebooks/72890

"The Machine Stops" first appeared in *The Oxford and Cambridge Review* in
November 1909 and is the first story here.


<!-- boris-rag-doc: id="content/verdict-acmedb" source="published/verdict-acmedb.md" category="content" -->
---
id: verdict-acmedb
title: "Verdict: AcmeDB"
parent: published
tags: [published, verdict]
summary: The published verdict; ship it behind a cache.
---

# Verdict: AcmeDB

- Verdict: give a shit
- Bottom line: ship it behind a cache.
- Published: 2026-10-24, demo-freeze day

The rendered verdict is a knap doc, not a page on this desk. Its evidence is
under [[sources]] and its conclusions are under [[claims]].

