---
name: Roadmap task
about: A scoped lane an agent can pick up (see AGENTS.md → Picking up an issue)
title: "<high|medium|low>(<area>): <summary>"
labels: ["agent:swe-2"]
---

**Agent:** SWE-2. <!-- or: **Agent: advanced (Opus-class).** Why: <design judgment / cross-module / open-ended debugging> -->
**Depends on:** <#N, or none>

## Context
<!-- What is wrong or missing, with file:line refs and a repro or the current output. -->

## Task
<!-- Numbered steps. Name the pattern to copy if one exists. -->

## Files you own
<!-- The only files this lane may edit. -->

## Done when
<!-- Checkable outcomes: commands and expected output. -->

## Gate
```sh
make test
KNAP_MCP_HOME=$(mktemp -d) make eval
```
