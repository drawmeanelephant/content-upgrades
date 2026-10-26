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
