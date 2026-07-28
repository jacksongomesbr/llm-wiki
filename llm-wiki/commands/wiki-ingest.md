---
description: Ingest a source (file or URL) into the wiki — two-phase analysis and generation
argument-hint: <file|URL>
---

# Ingest a Source into the Wiki

The user ran `/wiki-ingest $ARGUMENTS`.

## Wiki Root

Resolve it, do not assume `./wiki`:

1. `$LLM_WIKI_ROOT` if set
2. otherwise the nearest `wiki/` walking up from the current directory
3. otherwise ask

`scripts/_utils.sh` exposes `find_wiki_root` which implements exactly this; every
script already uses it. A project may hold more than one wiki (`wiki-research/`,
`wiki-personal/`), so a hardcoded `./wiki` silently targets the wrong one.

## Key Paths

- Source files: `./.raw/`
- Skill directory: `~/.claude/skills/llm-wiki/`

## Procedure

### 1. Verify wiki exists

Check `$WIKI_ROOT/.llm-wiki/index.md`. If not found, offer to run init-wiki.sh.

### 2. Identify and hash the source

- If file path: run `~/.claude/skills/llm-wiki/scripts/hash-files.sh <path>`
- If URL: use WebFetch to retrieve, then compute SHA-256

### 3. Check if already ingested

Look for sentinel: `$WIKI_ROOT/.llm-wiki/cache/ingests/$HASH.done`

### 4. Load the full workflow

Use `Skill("wiki")` to load the complete ingestion procedure from `workflows/ingest.md`, which covers:

- Language detection
- Concept/person/article extraction
- Contradiction detection
- Two-phase generation with user review checkpoints
- Index regeneration
