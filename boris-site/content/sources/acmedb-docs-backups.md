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
