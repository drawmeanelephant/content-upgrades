---
title: AcmeDB research desk
tags: [home]
summary: The frozen research pack behind the knap verdicts on AcmeDB.
---

# AcmeDB research desk

This is the research pack behind the knap verdicts on AcmeDB. Every source a
verdict cites has a page here, and every claim is pinned to the source it came
from.

The site is a frozen artifact. knap-mcp reads its search index and graph, and
stages rendered verdicts into a throwaway copy to check that every wiki-link
resolves before anything is published. Nothing is indexed live.

- [[sources]]: what we read, with reliability and give-a-shit ratings.
- [[claims]]: what we concluded, each with a verdict and its evidence.

## How references resolve

A knap template writes a source name as a wiki-link, for example
`[[AcmeDB launch post]]`. Boris entity ids cannot contain spaces, so the
staging step rewrites the target to its slug (`acmedb-launch-post`) and keeps
the name as the label. Each source page declares that slug as its `id`. A
name that has no page fails the check with `EREFERENCEMISSING`.
