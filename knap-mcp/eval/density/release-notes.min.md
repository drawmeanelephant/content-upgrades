---
product: "AcmeDB"
version: "2.0.0"
codename: "none (too busy shipping)"
released: "2026-10-21"
verdict: "upgrade now"
gaf: "high"
slug: "acme-db"
---
# AcmeDB

**upgrade now** — the boring database finally learned how to save your ass

`2.0.0` · released 2026-10-21 · give-a-shit: **high**

> [!tip] TL;DR
> Snapshots exist now. Real ones: online, point-in-time, restorable without a support ticket. That was the dealbreaker in our last verdict and it is gone. The rest is one config rename, one protocol cut, and a health check with opinions.

## What actually changed

### Point-in-time snapshots

acmedb snapshot create takes a consistent snapshot without pausing writes, and restore replays the WAL to any second inside the retention window. This is the feature we yelled about. It is real.
### Manifest compaction

The manifest no longer grows forever, so cold starts on old databases drop from minutes to seconds. Nobody will tweet about it. Everybody will feel it.
### acmedb doctor

A health check that tells you what is wrong in plain English instead of a hex dump. Petty? Yes. Useful? Also yes.

## The verdict

This is the release that moves AcmeDB from cute toy to fine for prod, behind a cache. Upgrade, take a snapshot, go to bed.

## Receipts

[https://example.com/acmedb/releases/2.0.0](Full%20changelog)
