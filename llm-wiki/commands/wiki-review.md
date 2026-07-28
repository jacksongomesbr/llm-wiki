---
description: Walk through the review queue — contradictions, stale pages, knowledge gaps
---

# Process Review Queue

The user ran `/wiki-review $ARGUMENTS`.

## Wiki Root

Resolve it, do not assume `./wiki`:

1. `$LLM_WIKI_ROOT` if set
2. otherwise the nearest `wiki/` walking up from the current directory
3. otherwise ask

`scripts/_utils.sh` exposes `find_wiki_root` which implements exactly this; every
script already uses it. A project may hold more than one wiki (`wiki-research/`,
`wiki-personal/`), so a hardcoded `./wiki` silently targets the wrong one.

## Procedure

Use `Skill("wiki")` → `workflows/review.md` for the full procedure:

1. Read `$WIKI_ROOT/.llm-wiki/review.json` for pending items
2. For each item, present the issue and relevant pages
3. Let the user decide: resolve, defer, or escalate
4. Update `review.json` accordingly
5. If changes were made, regenerate the index
