# /wiki-lint — Wiki Health Check

**Purpose**: Verify the structural and semantic health of the wiki. Catch errors, warnings, and improvement opportunities.

**Invoked by**: `/wiki-lint [--quick|--full]` → SKILL.md routes here

Default mode (no flag): `--quick`

---

## Design Rationale

`★ Insight ─────────────────────────────────────`

- Separating "quick" (bash) from "full" (LLM) lint is a cost optimization: structural checks like frontmatter validation and broken links run in milliseconds via grep/sed, while semantic checks like contradiction detection require reading page content and reasoning — expensive LLM operations. Most issues are caught by quick lint, so full lint is only needed periodically.
- Exposing lint results as exit codes (0=clean, 1=issues, 2=error) enables CI/CD integration. A `check-stale.sh` failure in CI can block a deploy, while `find-orphans.sh` warnings can be non-blocking.
- The review queue (`review.json`) serves as a persistent task list — lint doesn't just report problems, it schedules them for human attention. This closes the loop between automated checking and human curation.
`─────────────────────────────────────────────────`

---

## Quick Lint (Default, --quick)

Quick lint uses bash scripts for deterministic checks. Zero LLM token cost beyond reading this file.

### Step Q1: Validate Frontmatter

```bash
scripts/validate-frontmatter.sh "$WIKI_ROOT"
```

**What it checks:**

- All pages have `---` frontmatter delimiters
- Required fields present: `title`, `type`, `language`, `created`, `modified`, `tags`, `summary`
- `type` is one of: `note`, `concept`, `entity`, `project`, `area`, `synthesis`
- `class` is present and valid on `entity` pages, absent elsewhere
- `status`, if present, is one of: `active`, `reference`, `someday`, `archived`, `stub`
- `article` and `person` are reported as superseded, not invalid
- `language` is one of: `en`, `zh`, `bilingual`
- Dates are in `YYYY-MM-DD` format

**Exit codes:** 0 = all valid, 1 = issues found

**Severity:** ❌ ERROR — invalid frontmatter breaks index generation and query

### Step Q2: Find Broken Wikilinks

```bash
scripts/find-broken-links.sh "$WIKI_ROOT"
```

**What it checks:**

- Every `[[target]]` wikilink points to an existing page slug
- Also resolves aliases (if a page has `aliases: [alt-name]`, `[[alt-name]]` is valid)
- Skips external URLs (containing `://`)
- Skips section-only references (`#section`)

**Exit codes:** 0 = no broken links, 1 = broken links found

**Severity:** ❌ ERROR — broken links confuse navigation

### Step Q3: Find Orphan Pages

```bash
scripts/find-orphans.sh "$WIKI_ROOT"
```

**What it checks:**

- Every page has at least one incoming `[[wikilink]]` from another page
- Pages with zero incoming links are flagged

**Exit codes:** 0 = success (even if orphans found)

**Severity:** ⚠️ WARNING — orphans are harder to discover but may be intentional (e.g., new pages not yet linked)

### Step Q4: Check Index Freshness

```bash
scripts/check-stale.sh "$WIKI_ROOT"
```

**What it checks:**

- Compares stored hash of all page frontmatter against live hash
- Detects if pages have been modified since the last index generation

**Exit codes:** 0 = fresh, 1 = stale, 2 = no stored hash

**Severity:** ⚠️ WARNING — stale index means `/wiki-query` may miss recent pages

**Fix:** `scripts/build-index.sh "$WIKI_ROOT"` — this regenerates the index and
records the new baseline in one step.

### Step Q4b: Check Backlinks

```bash
scripts/update-backlinks.sh "$WIKI_ROOT" --check
```

**What it checks:** whether each page's generated `## Backlinks` block matches
the current link graph.

**Exit codes:** 0 = up to date, 1 = pages out of date

**Severity:** ⚠️ WARNING — **Fix:** drop `--check` to rewrite them.

### Step Q5: Naming Convention Check

The LLM performs a quick scan (no page content reads needed):

1. List all pages, including those in subdirectories such as `topics/`:

   ```bash
   find "$WIKI_ROOT" -name '.llm-wiki' -type d -prune -o \
        -type f -name '*.md' ! -name 'index.md' -print
   ```

2. Check naming rules:
   - `concept`, `entity`, `project`, `area` pages: `{slug}.md` (no date prefix)
   - `note` pages: `{YYYY-MM-DD}-{slug}.md`
   - `synthesis` pages: `synth-{YYYY-MM-DD}-{slug}.md`
   - All slugs: lowercase kebab-case, no spaces, no non-ASCII
   - No duplicate slugs (case-insensitive)

3. For each violation, report filename and expected pattern.

**Severity:** ⚠️ WARNING — inconsistent naming makes the wiki harder to navigate programmatically

### Step Q5b: Check Graph Freshness

```bash
scripts/check-graph-stale.sh "$WIKI_ROOT"
```

**What it checks:** whether `graph.json` reflects the current pages. Only
`/wiki-graph` rebuilds the graph, while ingest and save rebuild the index and
backlinks — so without this the graph rots and nothing says so.

**Exit codes:** 0 = fresh, 1 = stale, 2 = never built

**Severity:** ⚠️ WARNING — **Fix:** `scripts/build-graph.sh "$WIKI_ROOT"`

### Step Q6: Validate Citations

```bash
scripts/validate-bib.sh "$WIKI_ROOT"
```

**What it checks:**

- Duplicate citation keys in `references.bib`
- Entries with no title, or with neither `url` nor `doi`
- **Dangling citations** — a `references:` key or `[@key]` with no entry
- **Orphan entries** — a bibliography entry no page cites
- Drift between a page's `references:` list and its inline `[@key]` markers

**Exit codes:** 0 = valid, 1 = issues found

**Severity:** dangling citations are ERROR (a claim points at nothing); orphan
entries and drift are WARNING.

---

## Quick Lint Report

After running Q1-Q6, present:

```
# Wiki Health Report

## Errors ({N})
| Check | Details |
|-------|---------|
| Frontmatter | ... |
| Broken Links | ... |

## Warnings ({N})
| Check | Details |
|-------|---------|
| Orphan Pages | ... |
| Stale Index | ... |
| Naming | ... |
| Citations | ... |
| Graph | ... |

## Summary
- {N} errors, {N} warnings
- {✓ All good | ⚠ Needs attention | ❌ Has errors}

## Next Steps
- Fix errors with: [specific actions]
- Run /wiki-lint --full for semantic analysis
```

---

## Full Lint (--full)

Full lint requires the LLM to read page content and reason about it. This has token cost but catches issues that bash cannot.

**Only run `--full` when:**

- User explicitly requests it
- `full_lint_frequency` threshold is reached (config, default: every 10 ingests)
- After major changes (many pages created/updated)

### Step F1: Run Quick Lint First

Always run Q1-Q6 before full lint. If there are errors, ask the user if they want to proceed anyway (semantic checks may be unreliable on structurally broken pages).

### Step F2: Contradiction Sweep

1. Read all pages in the wiki (this is the expensive part)
2. For each page, identify factual claims
3. Cross-reference claims across pages:
   - Same topic, different values → contradiction
   - Same topic, different interpretations → potential contradiction
   - Same topic, different dates/versions → check if one supersedes the other
4. For each contradiction found:
   - Verify it's a real contradiction (not different contexts)
   - Add callout blocks to both pages
   - Add to `review.json`

**Focus on high-impact contradictions:**

- Dates, numbers, measurements
- Causality claims ("X causes Y" vs "X does not cause Y")
- Definitions (same term, different definitions)

### Step F3: Quality Analysis

For each page, assess:

**Completeness:**

- Are required sections present?
- Are sections substantially filled (not just placeholders)?
- Are there "TODO" or "TBD" markers?

**Staleness:**

- Pages not modified in 30+ days → flag
- Pages not modified in 90+ days → stronger flag
- Articles about rapidly-changing topics → suggest refresh

**Depth:**

- Pages under 200 words → flag as potentially too shallow
- Pages with no wikilinks → flag as isolated
- Pages with no references → flag as unsourced

**Boilerplate:**

- Template language still present ("[Clear, concise definition]")
- Empty lists or sections
- Generic content that doesn't add information

### Step F4: Language Consistency

1. For each page, compare the `language` field against actual body content:
   - `language: en` but body is mostly Chinese → flag
   - `language: zh` but body is mostly English → flag
2. Check bilingual pages have actual content in both languages (not just headings)
3. Verify aliases exist for cross-language linking

### Step F5: Drift Detection

1. Read the oldest pages first
2. Check if newer pages reference older concepts differently
3. Identify if fundamental definitions have shifted over time
4. Flag pages that reference deprecated or renamed concepts

### Step F6: Knowledge Gap Analysis

1. From all pages, extract:
   - Concepts mentioned in passing but without their own page
   - Questions raised but not answered
   - "Further research needed" markers
   - Broken source links
2. Compile a gap report:
   - High-priority gaps (core concepts without pages)
   - Medium-priority gaps (nice-to-have expansions)
   - Source suggestions for filling each gap

### Step F6b: Offer to Fill Gaps (`--fix`)

When invoked as `/wiki-lint --full --fix`, act on the gap analysis rather than
only reporting it:

1. For each **high-priority** gap — a concept referenced by several pages but
   having none of its own — create a stub from what the citing pages already
   say:
   - `status: stub`, `confidence: low`
   - body limited to what the existing pages assert, with `[[wikilinks]]` back
     to them
   - **no invented content**: a stub that reads as authoritative is worse than
     no page, because the next reader cannot tell them apart
2. Never auto-create medium or low priority gaps; list them instead.
3. Report every stub created, so the user can delete any that were a bad call.

Without `--fix`, only report.

### Step F7: Add to Review Queue

For issues that require human judgment:

```json
{
  "type": "quality|contradiction|staleness|gap",
  "pages": ["..."],
  "description": "...",
  "severity": "error|warning|info",
  "detected": "YYYY-MM-DD"
}
```

Add to `$WIKI_ROOT/.llm-wiki/review.json`.

---

## Full Lint Report

```
# Full Wiki Health Report

## Structural (from quick lint)
{Same table as quick lint report}

## Contradictions ({N})
| Pages | Conflict | Severity |
|-------|----------|----------|
| [[a]] vs [[b]] | ... | error |

## Quality Issues ({N})
| Page | Issue | Severity |
|------|-------|----------|
| [[x]] | Shallow (< 200 words) | warning |
| [[y]] | Not updated in 90 days | info |

## Language Issues ({N})
| Page | Issue |
|------|-------|
| [[z]] | Tagged 'en' but body is Chinese |

## Knowledge Gaps ({N})
| Gap | Priority | Suggested Source |
|-----|----------|-----------------|
| Missing page for X | high | [source suggestion] |

## Drift ({N})
| Old Page | New Page | Issue |
|----------|----------|-------|
| [[old]] | [[new]] | Definition changed |

## Summary
- {N} errors, {N} warnings, {N} info
- Review queue: {N} items added
- Next full lint suggested after {N} more ingests

## Actions
1. [Highest priority fix]
2. [Next fix]
3. Run /wiki-review to process the queue
```

---

## Edge Cases

### Very Large Wiki (>100 pages)

- Quick lint: still fast (bash-only)
- Full lint: warn user about token cost; suggest running on a subset
- Consider linting by tag (e.g., `/wiki-lint --full --tag machine-learning`)

### Wiki Has Errors (Quick Lint Fails)

- Full lint may produce unreliable results if the foundation is broken
- Ask user: "Fix errors first, or proceed anyway?"

### Newly Initialized Wiki (0 Pages)

- Quick lint: all checks pass (nothing to check)
- Report: "Wiki is empty — nothing to lint. Start by ingesting sources with /wiki-ingest."

### Contradiction That Can't Be Resolved

- Mark both pages with the contradiction callout
- Add to review queue with `severity: error`
- In full lint report, note: "Requires human judgment or additional sources"

### External Links Broken (URLs)

- `find-broken-links.sh` skips URLs by design
- In full lint, optionally check URLs:
  - Use `curl -sI` to check HTTP status
  - Flag 404, 500, redirect loops
  - This is slow for many URLs; run selectively
