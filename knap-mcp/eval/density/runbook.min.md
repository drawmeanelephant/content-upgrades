---
title: "AcmeDB"
service: "AcmeDB"
severity: "sev2"
last_reviewed: "2026-10-24"
---

# AcmeDB

Owner [[AcmeDB SRE]] · severity `sev2` · last reviewed `2026-10-24`

> [!abstract] When to use this
> Use this when a production AcmeDB node needs a routine restart after a config change. It takes one node out of rotation at a time, so the cluster keeps serving reads and writes throughout. Do not use it for a node that is already down or failing its health check; that is an incident, not a restart.

## Drain

### Take the node out of the load balancer pool

### Wait for open connections to drop to zero

---

## Restart

### Restart the AcmeDB service on the node

### Watch the health check go green

### Put the node back in the load balancer pool

