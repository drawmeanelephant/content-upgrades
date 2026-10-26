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
