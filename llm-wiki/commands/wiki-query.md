---
description: Answer a question from the wiki's accumulated knowledge using index-first retrieval
argument-hint: <question>
---

# Query the Wiki

The user asked: `/wiki-query $ARGUMENTS`

## Wiki Root

Resolve it, do not assume `./wiki`:

1. `$LLM_WIKI_ROOT` if set
2. otherwise the nearest `wiki/` walking up from the current directory
3. otherwise ask

`scripts/_utils.sh` exposes `find_wiki_root` which implements exactly this; every
script already uses it. A project may hold more than one wiki (`wiki-research/`,
`wiki-personal/`), so a hardcoded `./wiki` silently targets the wrong one.

## Procedure

### 1. Find wiki root

Check `$WIKI_ROOT/.llm-wiki/` — if missing, wiki needs to be initialized first.

### 2. Read the index

Read `$WIKI_ROOT/.llm-wiki/index.md` for the full page catalog (tags, titles, summaries, types).

### 3. Match query to pages

Find 3-5 most relevant pages by matching against tags, titles, and summaries.

### 4. Read pages and synthesize

- Read each relevant page
- Extract key claims and evidence
- Build an answer with:
  - Direct answer
  - Evidence table (page, key point, relevance, confidence)
  - Contradictions (if any)
  - Knowledge gaps
  - Confidence rating

### 5. Offer to save

After presenting the answer, offer to save as a synthesis page with `/wiki-save`.

### Full workflow

Use `Skill("wiki")` → `workflows/query.md` for the complete procedure.
