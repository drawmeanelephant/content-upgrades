---
product: "AcmeDB"
version: "2.0.0"
codename: "Seatbelt"
released: "2026-10-21"
verdict: "upgrade now"
gaf: "high"
slug: "acme-db-2.0:-finally,-backups"
tags:
  - "release-notes"
  - "databases"
  - "acmedb"
related:
  - "[[Verdict: AcmeDB]]"
  - "[[AcmeDB docs — backups]]"
  - "[[Apparatus: AcmeDB verdict]]"
---
# AcmeDB 2.0: Finally, Backups

**upgrade now** — the boring database finally learned how to save your ass

`2.0.0` · released 2026-10-21 · give-a-shit: **high**

![acmedb doctor output: three green checks and one passive-aggressive yellow one](https://example.com/acmedb/img/doctor-2.0.png)
> [!tip] TL;DR
> Snapshots exist now. Real ones: online, point-in-time, restorable without a support ticket. That was the dealbreaker in our last verdict and it is gone. The rest is one config rename, one protocol cut, and a health check with opinions.

## Breaking changes

> [!danger] Read this before you upgrade
> Something in here will break your build. Read it before you upgrade, not after.

### wal_dir is now storage.wal_path

Rename the key in acmedb.toml. 2.0 refuses to boot on the old name instead of quietly ignoring it, which is rude but correct.[^config]
### The v1 wire protocol is gone

Drivers older than 1.8 can no longer connect. Bump the driver first, then the server. Not the other way round, unless you enjoy pages at 3am.[^drivers]
## What actually changed

### Point-in-time snapshots

acmedb snapshot create takes a consistent snapshot without pausing writes, and restore replays the WAL to any second inside the retention window. This is the feature we yelled about. It is real.[^retention]

> [!quote] Their words, not ours
> Snapshots are online, incremental, and restorable to any point in the last seven days. [link](https://example.com/acmedb/releases/2.0.0#:~:text=Snapshots%20are%20online%2C%20incremental%2C%20and%20restorable%20to%20any%20point%20in%20the%20last%20seven%20days.)
### Manifest compaction

The manifest no longer grows forever, so cold starts on old databases drop from minutes to seconds. Nobody will tweet about it. Everybody will feel it.
> [!quote] Their words, not ours
> Cold start on a 500 GB database fell from 4 minutes to 9 seconds. [link](https://example.com/acmedb/releases/2.0.0#:~:text=Cold%20start%20on%20a%20500%20GB%20database%20fell%20from%204%20minutes%20to%209%20seconds.)
### acmedb doctor

A health check that tells you what is wrong in plain English instead of a hex dump. Petty? Yes. Useful? Also yes.

## Upgrade math

| you are on | effort | downtime | should you bother |
| --- | --- | --- | --- |
| 1.9.x | rename one config key | one restart | yes, today |
| 1.8.x | config key plus driver bump | one restart | yes, this week |
| 1.7 or older | dump and reload | plan a window | yes, but bring snacks |
## Still broken

- Snapshots of databases over 2 TB take hours, not minutes.
- Still single-region. Cross-region replication is on the roadmap. Again.
## Migration guide

![[AcmeDB 2.0 migration guide]]
## The verdict

This is the release that moves AcmeDB from cute toy to fine for prod, behind a cache. Upgrade, take a snapshot, go to bed.

## Receipts

[Full changelog](https://example.com/acmedb/releases/2.0.0)· [Upgrade docs](https://example.com/acmedb/docs/upgrading)

Filed under:
[[Verdict: AcmeDB]]
· [[AcmeDB docs — backups]]
· [[Apparatus: AcmeDB verdict]]

## Footnotes

[^config]: In 1.x the old key was silently ignored, which is how half of you ended up writing the WAL to /tmp.

[^drivers]: Driver 1.8 shipped in March. If you are older than that, the protocol cut is the least of your problems.

[^retention]: Seven days is the default. The changelog says it is configurable and does not say how far. We asked.
