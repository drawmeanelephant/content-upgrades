---
title: "Verdict: AcmeDB"
year: 1999
genre:
  - "Action"
  - "Sci-fi"
verdict: "give-a-shit"
---

# Verdict: AcmeDB

**give a shit** — the boring database that actually ships

## The case

AcmeDB does one thing — durable key-value storage — and does it without a operator PhD. No consensus wizardry, no sharding astrology; just a WAL, a manifest, and docs that answer the question you actually asked.

## Blockers

- no managed backup story yet
- single-region only


## Receipts

<table>
<thead>
<tr><th>claim</th><th>evidence</th></tr>
</thead>
<tbody>
<tr><td>p99 reads under 2ms</td><td>vendor benchmark, unreplicated claim</td></tr>
<tr><td>backup gap confirmed</td><td>docs page lists snapshots as 'coming soon'</td></tr>
</tbody>
</table>


## Verdict

Ship it behind a cache. Do not put your crown jewels in it.

## Sources

- [[AcmeDB docs — backups]] — https://example.com/acmedb/docs#backups (documentation, reliability high, gaf high)
- [[AcmeDB launch post]] — https://example.com/acmedb/launch (self-published, reliability medium, gaf low)


## Footnotes

[^1]: Benchmark numbers are vendor-reported; treat them as the ceiling, not the floor.

[^2]: Backup gap confirmed against the docs page on demo-freeze day.

