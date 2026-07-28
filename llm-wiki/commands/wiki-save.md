---
description: Save the current answer as a permanent synthesis page in the wiki
---

# Save Answer as Synthesis Page

The user ran `/wiki-save $ARGUMENTS`.

This saves the current conversation answer as a permanent `synthesis` page in the wiki. This is the **compounding mechanism** — good answers become part of the knowledge base.

## Wiki Root

Resolve it, do not assume `./wiki`:

1. `$LLM_WIKI_ROOT` if set
2. otherwise the nearest `wiki/` walking up from the current directory
3. otherwise ask

`scripts/_utils.sh` exposes `find_wiki_root` which implements exactly this; every
script already uses it. A project may hold more than one wiki (`wiki-research/`,
`wiki-personal/`), so a hardcoded `./wiki` silently targets the wrong one.

## Procedure

Use `Skill("wiki")` → `workflows/save-synthesis.md` for the full procedure:

1. Identify the query and answer from conversation context
2. Create `synth-YYYY-MM-DD-{slug}.md` using the synthesis template
3. Cross-link to all source pages via `based_on`
4. Regenerate the index
