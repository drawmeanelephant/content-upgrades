---
title: "AcmeDB: restore from a snapshot"
service: "AcmeDB"
severity: "sev1"
last_reviewed: "2026-10-24"
tags:
  - "runbook"
  - "restore"
  - "acmedb"
  - "sev1"
related:
  - "[[AcmeDB 2.0 migration guide]]"
  - "[[AcmeDB docs — backups]]"
  - "[[Verdict: AcmeDB]]"
---

# AcmeDB: restore from a snapshot

Owner [[AcmeDB SRE]] · severity `sev1` · last reviewed `2026-10-24`

> [!abstract] When to use this
> Use this when a production AcmeDB 2.x database is corrupt, dropped, or rolled to a bad state and you need a point-in-time restore from snapshots. Covers restores inside the seven-day retention window; anything older is an archive job, not this runbook. For databases over 2 TB, budget hours for the snapshot copy, not minutes.

> [!danger] Do not skip
> ==Never restore over the live data directory. Restore to a scratch path, verify with acmedb doctor, then cut over — the WAL may still be writing, and a restore on top of it corrupts both copies.==

## Before you start

- [ ] Confirm it is a data problem, not a config problem: run acmedb doctor on the live node first
- [ ] Get sign-off from the on-call lead — a restore drops every write after the restore point
- [ ] Check free disk: the restored copy needs roughly 1.1x the live data dir
- [ ] Pick a restore point inside the seven-day snapshot retention window
- [ ] Tell #acmedb-incidents the restore is starting so nobody else touches the node

## Phase 1: pick and check the snapshot

### List snapshots and choose the restore point[^retention]

```sh
acmedb snapshot list --db prod --before "2026-10-27T03:00:00Z"
```

#### Expect

A snapshot ID whose timestamp predates the incident.

### Verify the snapshot is complete before you touch it

#### Expect

acmedb snapshot verify exits 0 and prints ok: true for every segment.

---

## Phase 2: restore to a scratch path

### Restore into the scratch directory, not the live one

```sh
acmedb snapshot restore snap_0142 --to /var/lib/acmedb-restore
```

#### Expect

restore exits 0 and the scratch dir holds a full data directory.

### Replay the WAL up to the exact restore point[^wal-path]

```sh
acmedb wal replay --dir /var/lib/acmedb-restore --until "2026-10-27T02:58:00Z"
```

---

## Phase 3: verify and cut over

### Health-check the restored copy with acmedb doctor

#### Expect

Three green checks. A yellow on replication is expected — it rejoins after cutover.

### Spot-check the data you actually lost

```sql
SELECT count(*) FROM orders WHERE created_at > '2026-10-26';
```

#### Expect

Row counts match the pre-incident numbers in the incident doc. Check a few rows by hand, not just counts.

### Swap the data directories and restart

```sh
systemctl stop acmedb && mv /var/lib/acmedb /var/lib/acmedb.bad && mv /var/lib/acmedb-restore /var/lib/acmedb && systemctl start acmedb
```

#### Expect

acmedb doctor goes green on the live node within a minute.

> [!warning]- Rollback
> 1. systemctl stop acmedb on the live node
> 2. Move the restored directory aside and put acmedb.bad back in place as the live data dir
> 3. systemctl start acmedb — the bad state returns, but the service is up and you can regroup

## Escalation

| who | when | how |
| --- | --- | --- |
| AcmeDB SRE on-call | verify fails or replay stalls over 10 min | #acmedb-incidents |
| Infra lead | snapshot missing inside the retention window | pager |
| AcmeDB upstream | doctor reports manifest corruption on the restore | issue tracker, severity critical |

## Service level

Availability target: **99.9%** — monthly error budget:

$$
B = (1 - 0.999) \times 30 \times 24 \times 60 \approx 43.2 \; \text{min / month}
$$

## Why this exists

> We lost four hours of writes because the restore went over the live directory while the WAL was still being written, and nobody noticed until the morning.

[Postmortem](https://example.com/acmedb/postmortems/2026-03-restore-overwrite)

See also: [[AcmeDB 2.0 migration guide]] · [[AcmeDB docs — backups]] · [[Verdict: AcmeDB]]

## Footnotes

[^retention]: Seven days is the default retention. The changelog says it is configurable and does not say how far.

[^wal-path]: In 2.0 the config key is storage.wal_path; a 1.x config silently writes the WAL somewhere you are not replaying.
