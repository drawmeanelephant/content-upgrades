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
