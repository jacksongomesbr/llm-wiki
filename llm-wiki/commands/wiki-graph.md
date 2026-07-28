---
description: Generate an interactive D3.js knowledge graph visualization of the wiki
---

# Generate Knowledge Graph

The user ran `/wiki-graph $ARGUMENTS`.

## Wiki Root

Resolve it, do not assume `./wiki`:

1. `$LLM_WIKI_ROOT` if set
2. otherwise the nearest `wiki/` walking up from the current directory
3. otherwise ask

`scripts/_utils.sh` exposes `find_wiki_root` which implements exactly this; every
script already uses it. A project may hold more than one wiki (`wiki-research/`,
`wiki-personal/`), so a hardcoded `./wiki` silently targets the wrong one.

## Procedure

Use `Skill("wiki")` → `workflows/graph.md` for the full procedure:

1. Read all wiki pages and extract wikilinks
2. Build nodes (pages) and edges (links between pages)
3. Write `$WIKI_ROOT/.llm-wiki/graph.json`
4. Generate an interactive D3.js HTML visualization
5. Present to the user (offer to open in browser or save)
