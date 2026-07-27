# /wiki-ingest — Two-Phase Source Ingestion

**Purpose**: Transform a raw source document (file or URL) into interlinked wiki pages.

**Invoked by**: `/wiki-ingest <file|URL>` → SKILL.md routes here

---

## Design Rationale

`★ Insight ─────────────────────────────────────`

- Two-phase ingest separates "what should we extract?" (analysis) from "how do we write it?" (generation). This gives the user a checkpoint to correct the LLM's understanding before pages are created, preventing garbage-in-garbage-out compounding.
- SHA-256 sentinel files (`cache/ingests/$HASH.done`) make re-ingestion idempotent — the same source can be dropped into `.raw/` again without duplicating pages. This is crucial for automated workflows (cron, watch-directory).
- The contradiction detection step (Phase 1, step 7) is the single most valuable quality lever — it catches inconsistent claims across pages before they become entrenched.
`─────────────────────────────────────────────────`

---

## Pre-Flight

### Step 0: Resolve Wiki Root

Determine the wiki root (from `SKILL.md` resolution rules):

1. `$LLM_WIKI_ROOT` environment variable
2. `wiki/` in current project
3. Ask user

### Step 1: Identify and Hash the Source

**If source is a file path:**

```bash
scripts/hash-files.sh <source_path>
```

**If source is a URL:**

- Use `WebFetch` to retrieve the content
- Pipe content through `sha256sum` to compute hash
- Store the fetched content as a temporary reference (or write to `.raw/` if configured)

### Step 2: Check if Already Ingested

```bash
test -f "$WIKI_ROOT/.llm-wiki/cache/ingests/$HASH.done"
```

If the sentinel file exists → **skip entirely**:

- Report: "This source was already ingested on {date}. Skipping."
- If the user wants to re-ingest: they should delete the sentinel file first.

---

## Phase 1 — Analysis

### Step 3: Read Context

Read these files to understand the current state of the wiki:

1. **`WIKI_SCHEMA.md`** (skill-level) — page types, field definitions, conventions
   - Path: `~/.claude/skills/llm-wiki/WIKI_SCHEMA.md`

2. **`.llm-wiki/index.md`** (project-level) — all existing pages, tags, summaries
   - Path: `$WIKI_ROOT/.llm-wiki/index.md`

3. **`.llm-wiki/config.md`** (project-level) — user settings (language, review preferences)
   - Path: `$WIKI_ROOT/.llm-wiki/config.md`

### Step 4: Read the Source Content

**If source is a file:** Read it directly.

**If source is a URL:** Use the already-fetched content from Step 1.

If the content is too large (>15,000 words), read it in chunks. For very large sources (books, long PDFs), suggest the user split it first.

### Step 5: Detect Language

Analyze the source content:

- Count CJK characters (Unicode U+4E00–U+9FFF)
- Count Latin characters (a-z, A-Z)
- `>70% CJK` → `zh`
- `>70% Latin` → `en`
- `30-70% mix` → `bilingual`

Store this as `SOURCE_LANGUAGE` for later steps.

### Step 6: Extract Key Elements

From the source, identify:

**Concepts** — terms, ideas, methodologies, tools worth having their own page:

- Is this term defined or explained in the source?
- Would someone encountering this term want to look it up?
- Does it already have a page in the wiki? (check index)

**Persons** — authors, researchers, notable figures mentioned:

- Are they central to the content?
- Do they already have a page?

**Key claims** — factual assertions worth preserving:

- Claims that would be useful in future queries
- Claims that might contradict existing wiki pages

**Structure** — how to organize the extracted knowledge:

- What would be the article page?
- What concepts need their own pages?
- What are the natural relationships?

### Step 7: Detect Contradictions

Compare extracted claims against existing wiki pages:

- For each key claim, search the index for related pages
- Read relevant existing pages and compare claims
- Flag any direct contradictions (two pages saying different things about the same fact)
- Flag any indirect contradictions (different interpretations or frameworks)

### Step 8: Write Phase 1 Analysis

Write the analysis to `$WIKI_ROOT/.llm-wiki/inbox/$HASH-analysis.md`:

```markdown
# Ingest Analysis — {source name}
**Source hash:** `$HASH`
**Language detected:** {en|zh|bilingual}
**Analyzed:** {ISO timestamp}

## Source Summary
[2-3 sentence summary of the source content.]

## Concepts to Extract
| Concept | Action | Reason |
|---------|--------|--------|
| concept-name | create | New concept defined in source |
| existing-concept | update | New information to add |

## Persons to Create/Update
| Person | Action | Details |
|--------|--------|---------|
| name | create | Key contributor |

## Pages to Create
| Filename | Type | Title | Key Content |
|----------|------|-------|-------------|
| ... | article | ... | ... |

## Contradictions Detected
| Existing Page | New Claim | Conflict |
|---------------|-----------|----------|
| [[page-a]] | "Claim from source" | "Existing claim from page-a" |

## Proposed Cross-Links
- [[page-a]] ↔ [[new-page]] — relationship description

## Items for User Review
- [ ] Decision point or question for the user
```

### Step 9: Present Analysis for Review

Show the user a summary of the analysis:

- Number of new concepts/pages to create
- Number of existing pages to update
- Any contradictions found
- Any decisions needed

**If `require_review: true` in config:** Wait for user approval before proceeding to Phase 2.

**If `require_review: false`:** Proceed automatically but still show the summary.

---

## Phase 2 — Generation

### Step 10: Create/Update Article Page

**If the source warrants an article page** (research notes, blog post, imported article):

1. Read `templates/article.md` from the skill directory
2. Create `$WIKI_ROOT/{YYYY-MM-DD}-{slug}.md`
3. Fill frontmatter:
   - `title`: Descriptive title (use bilingual format if source is bilingual)
   - `type: article`
   - `language`: from Step 5 detection
   - `created`, `modified`: today's date
   - `tags`: derived from content
   - `summary`: one-sentence overview
   - `source_url`: if URL source
   - `source_hash`: from Step 1
4. Fill body following the template structure
5. Include [[wikilinks]] to all related concept/person pages

### Step 11: Create/Update Concept Pages

For each concept identified in Phase 1:

**If creating a new concept page:**

1. Read `templates/concept.md`
2. Create `$WIKI_ROOT/{slug}.md`
3. Fill all required frontmatter
4. Write the body following the template
5. Include [[wikilinks]] to:
   - The source article page
   - Related concepts (existing or newly created)
   - Source references

**If updating an existing concept page:**

1. Read the current page
2. Add new information — do NOT overwrite existing content
3. Add a `> 📝 **Updated from [[source]]**: [what was added]` note at the end of the relevant section
4. Update `modified` date
5. Add new [[wikilinks]] as appropriate

### Step 12: Create/Update Person Pages

For each person identified in Phase 1:

**If creating a new person page:**

1. Read `templates/person.md`
2. Create `$WIKI_ROOT/{slug}.md`
3. Fill required frontmatter + any optional fields known
4. Write body following the template
5. Link to their work/concepts

**If updating:** Same pattern as concept updates (add, don't overwrite).

### Step 13: Cross-Link All Pages

After creating all new pages:

1. Re-read each newly created/updated page
2. For every [[wikilink]] from page A to page B, check if page B should link back
3. Add reverse links where appropriate
4. Ensure no orphan pages were created (every new page should have at least one incoming link)

### Step 14: Add Contradiction Callouts

For each contradiction found in Phase 1:

1. Add a contradiction callout block on both conflicting pages
2. Format per `WIKI_SCHEMA.md` conventions:

   ```markdown
   > ⚠️ **Contradiction**: [description]
   > | Page | Claim |
   > |------|-------------|
   > | [[page-a]] | "Claim A" |
   > | [[page-b]] | "Claim B — contradicts A" |
   > *Detected: YYYY-MM-DD | Status: unresolved*
   ```

3. Add to `review.json` pending queue:

   ```json
   {"type": "contradiction", "pages": ["page-a", "page-b"], "description": "...", "detected": "YYYY-MM-DD"}
   ```

### Step 15: Regenerate Index and Backlinks

**This is a programmatic operation — never write `index.md` yourself.**

```bash
scripts/build-index.sh "$WIKI_ROOT"
scripts/update-backlinks.sh "$WIKI_ROOT"
```

`build-index.sh` walks every page (including subdirectories such as
`topics/`), extracts frontmatter, resolves the link graph through aliases, and
writes the All Pages table, By Tag sections, Orphan Pages list and Review Queue
in the format `WIKI_SCHEMA.md` specifies. It also records the staleness
baseline that `check-stale.sh` compares against.

`update-backlinks.sh` refreshes the generated `## Backlinks` block on each
page. It only rewrites the region between its own markers.

Rebuilding the index by reading every page yourself costs tokens proportional
to the whole wiki on every single ingest, and drifts from the schema. Run the
scripts.

### Step 16: Write Sentinel + Update Manifest

1. Create sentinel file:

   ```bash
   mkdir -p "$WIKI_ROOT/.llm-wiki/cache/ingests"
   echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$WIKI_ROOT/.llm-wiki/cache/ingests/$HASH.done"
   ```

2. Update `source-manifest.json`:
   - Read existing manifest
   - Add entry: `{"$HASH": {"name": "source name", "date": "ISO timestamp", "language": "en|zh|bilingual", "pages_created": [...], "pages_updated": [...]}}`
   - Write back

3. Record the ingest in the chronological log:

   ```bash
   scripts/log-event.sh "$WIKI_ROOT" --op ingest \
     --title "{source name}" --detail "Created N pages, updated M"
   ```

   (The staleness baseline was already stored by `build-index.sh` in Step 15 —
   `check-stale.sh` only reads it.)

### Step 17: Report Summary

Present a clean summary to the user:

```
# Ingest Complete

**Source:** {source name}
**Language:** {en|zh|bilingual}

## Created
| File | Type | Title |
|------|------|-------|
| ... | concept | ... |
| ... | article | ... |

## Updated
| File | What changed |
|------|-------------|

## Contradictions
{count} new contradictions flagged — run /wiki-lint to review

## Next Steps
- Run /wiki-lint to check health
- Use /wiki-query to test the new knowledge
```

---

## Edge Cases

### Very Large Sources (>15,000 words)

- Process in chunks
- Write one analysis covering the entire source
- Consider suggesting the user split the source if it covers too many distinct topics

### Source in an Unsupported Format

- `.pdf`: Use `Read` tool with pages parameter (may need OCR for scanned PDFs)
- `.docx`, `.epub`: Suggest user convert to markdown or plain text first
- Images: Describe that text extraction requires OCR — suggest user provide text

### Source Already Partially Ingested

- If some concepts already have pages but the source has new information: update mode
- If the source is a newer version of a previously ingested source: treat as update
- Check `source-manifest.json` for related hashes

### Nested Directory Sources

- If the user ingests a directory: hash the entire directory, process files individually
- Create a parent article page that links to all generated sub-pages

### Conflicting with Existing Pages

- **Never silently overwrite.** Always preserve existing content and add new information alongside it.
- If a new claim directly contradicts an existing claim, add contradiction callouts to BOTH pages.
- If you're unsure, add to review queue and flag for user attention.

### Rate Limiting / Token Budget

- For very large ingests, break work across multiple sessions
- Use the hot-cache to track progress
- If interrupted, the sentinel file won't exist yet, so the source will be re-processed — Phase 1 analysis will be cached in `inbox/`
