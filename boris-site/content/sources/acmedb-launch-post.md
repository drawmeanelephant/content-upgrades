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
