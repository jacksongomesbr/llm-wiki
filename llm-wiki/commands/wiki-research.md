---
description: Research a topic from the web, archive the sources, and ingest them into the wiki
argument-hint: <topic> [topic...]
---

# Research a Topic into the Wiki

The user ran `/wiki-research $ARGUMENTS`.

Unlike `/wiki-ingest`, which takes a source you already have, this discovers the
sources first. Nothing needs to be in `.raw/` beforehand.

## Key Paths

- Wiki root: `./wiki/` (or `$LLM_WIKI_ROOT`)
- Source archive: `./.raw/`
- Skill directory: `~/.claude/skills/llm-wiki/`

## Procedure

### 1. Check what the wiki already knows

Read `./wiki/.llm-wiki/index.md`. If a topic is already covered, say so and ask
whether to deepen it or skip it.

### 2. State the plan before spending searches

Name the topics, the angles you will search, and — if there are several related
topics — say that you will research the relationships between them too.

### 3. Load the full workflow

Use `Skill("wiki")` to load `workflows/research.md`, which covers:

- Three-round discovery: decompose into angles → rank and fetch → chase
  contradictions
- Source tiering: primary documents over reference works over reporting
- Archiving to `.raw/` with provenance via `scripts/archive-source.sh`
- Handoff to the existing two-phase `workflows/ingest.md`
- The cross-topic linking pass, where multi-topic research pays off
- Writing a synthesis page when the research settles a contested question

## Non-negotiables

- **Archive before writing pages.** Every fetched source goes to `.raw/` first.
  A page whose source is only a URL cannot be re-checked once the URL dies.
- **Never write a page from training data alone.** If search finds nothing
  usable, say so.
- **Record failed verification as a gap** and cap the page's confidence. Do not
  present a figure from secondary reporting as though it came from the filing.
