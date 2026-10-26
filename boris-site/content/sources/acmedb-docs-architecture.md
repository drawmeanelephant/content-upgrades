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
