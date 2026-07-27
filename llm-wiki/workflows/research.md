# /wiki-research — Discover Sources on a Topic, Then Ingest Them

**Purpose**: Turn a bare topic — with nothing in `.raw/` — into archived sources
and interlinked wiki pages.

**Invoked by**: `/wiki-research <topic> [topic...]` → SKILL.md routes here

---

## Design Rationale

`★ Insight ─────────────────────────────────────`

- `/wiki-ingest` takes a source you have already identified. This workflow finds
  them. It is the missing front half: search → archive → then hand off to the
  existing two-phase ingest, which is left completely unchanged.
- Everything fetched is written to `.raw/` before any page is written. Without
  that, the wiki's "immutable sources" layer is a URL that may 404 next year,
  there is nothing to hash, and re-running duplicates pages instead of skipping
  them.
- The highest-value output is not a summary — it is a **contradiction between
  the popular account and the primary document**. Chase those deliberately;
  they are what a wiki gives you that a search engine does not.
- When verification *fails* — a paywall, a 403, a dead archive — record it as an
  explicit gap and cap the page's confidence. A gap you wrote down is knowledge;
  a gap you papered over is a defect that compounds.
`─────────────────────────────────────────────────`

---

## Pre-Flight

### Step 0: Resolve Wiki Root

As in `ingest.md`: `$LLM_WIKI_ROOT`, then `wiki/`, then ask.

### Step 1: Confirm Scope

If several topics were given, state the plan before spending searches:

```
Researching 4 topics: Apple, Microsoft, Steve Jobs, Bill Gates.
These are densely related, so I will also research the relationships between
them and cross-link the results. Estimated 6-10 sources.
```

Read `.llm-wiki/index.md` first. If the wiki already covers a topic, say so and
ask whether to deepen it or skip it.

---

## Phase 1 — Discovery (three rounds)

### Round 1: Decompose and Sweep

For each topic, break it into **3–5 angles** rather than searching the bare
name. For an organisation: founding, key products, leadership, controversies.
For a person: biography, principal work, later career, criticism.

For a *set* of related topics, add the relationships as their own angles — the
Apple/Microsoft/Jobs/Gates set yields "the 1997 agreement" and "the GUI
lawsuit", and those turn out to carry most of the interesting content.

Run `WebSearch` per angle. Collect candidate URLs; do not fetch yet.

### Round 2: Rank, Then Fetch

Prefer, in this order:

1. **Primary documents** — press releases from the party itself, court opinions,
   SEC filings, published papers with a DOI or arXiv ID.
2. **Reference works** — Wikipedia, Britannica, Library of Congress. Good for
   overview and, more importantly, for finding the primary sources.
3. **Reporting** — usable, but attribute it and prefer it corroborated.
4. **Blogs and aggregators** — last resort; treat as a lead, not a citation.

`WebFetch` the best 1–3 per topic. In the fetch prompt, ask for **exact dates,
figures and verbatim quotations**, not a summary — you are building a source
archive, and a paraphrase of a paraphrase cannot be checked later.

### Round 3: Find and Chase Contradictions

Compare what you fetched against:

- **The popular narrative.** Where a widely repeated claim conflicts with a
  primary document, that is the finding. Search specifically to settle it.
- **Existing wiki pages.** Follow `ingest.md` Step 7.
- **Itself.** Dates especially. Companies have a partnership date, a name
  registration date and an incorporation date, and different sources call each
  one "founded".

Run targeted searches to resolve each. Record what you could not resolve.

---

## Phase 2 — Archive

### Step 2: Write Every Source to `.raw/`

For each fetched source:

```bash
scripts/archive-source.sh \
  --topic "The 1997 Apple–Microsoft agreement" \
  --slug "apple-microsoft-1997-agreement" \
  --url "https://news.microsoft.com/source/1997/08/06/..." \
  --primary \
  --note "Primary press release" <<'CONTENT'
{the extracted content, with exact quotations preserved}
CONTENT
```

It writes `.raw/YYYY-MM-DD-{slug}.md` with provenance frontmatter and prints the
path and SHA-256.

Rules:

- **One file per source or per coherent topic**, not one giant dump.
- Preserve **verbatim quotations** for anything a page will assert as fact.
- Record what a source **does not** say when that matters — the 1997 press
  release never calls Apple distressed, and that absence is evidence.
- Note failed verification inline: *"SEC EDGAR returned HTTP 403 on
  2026-07-27; figure is from secondary reporting."*

### Step 3: Report the Archive

List what was archived and the hash of each, so the user can see the sources
before any page is written.

---

## Phase 3 — Ingest

### Step 4: Hand Off

Run `workflows/ingest.md` for each archived file, starting at its Step 2
(sentinel check). Nothing in that workflow changes: the source is now an
ordinary file in `.raw/`, and everything downstream — hashing, two-phase review,
contradiction callouts, sentinels — applies unmodified.

If `require_review: true`, present the combined Phase 1 analysis for **all**
sources at once rather than prompting per file.

### Step 5: Cross-Link Across Topics

This step is specific to multi-topic research and is where the value is.

After all sources are ingested, make a pass over the new pages for
relationships **between** topics that no single source stated. Researching Apple
and Microsoft separately produces two summaries; researching them together
should produce the 1985 GUI licence, the QuickTime suit and the 1997 settlement
as first-class pages linking both.

Add a page for a relationship when it has its own facts and dates. Otherwise add
reciprocal links.

### Step 6: Write a Synthesis Page

If the research settled a contested question, save it via
`workflows/save-synthesis.md`, with:

- `based_on` listing every page used
- `gaps_noted` listing every unverified claim
- `confidence` set by the **weakest** link in the argument, not the strongest

### Step 7: Regenerate and Log

```bash
scripts/build-index.sh "$WIKI_ROOT"
scripts/update-backlinks.sh "$WIKI_ROOT"
scripts/log-event.sh "$WIKI_ROOT" --op research \
  --title "{topics}" --detail "{N} sources archived, {M} pages created"
```

---

## Report

```
# Research Complete

**Topics:** {list}
**Sources archived:** {N} → .raw/
**Pages created:** {M} | **Updated:** {K}

## Sources
| File | Tier | URL |
|------|------|-----|
| ... | primary | ... |

## Contradictions Resolved
| Question | Finding |
|----------|---------|

## Gaps
- {what could not be verified, and why}

## Next
- /wiki-query to test the new knowledge
- /wiki-lint --full to check consistency
```

---

## Edge Cases

### Topic Already Well Covered

Report what exists and ask whether to deepen (new angles only) or skip. Do not
silently re-ingest — the sentinels will skip identical sources anyway, but a
re-fetch produces a *different* hash for the same page and would duplicate.

### Search Returns Nothing Usable

Say so plainly. Do not write pages from training data alone: a page with no
source is indistinguishable from a page with a bad source once it is in the
wiki. Offer to broaden the terms or ask the user for a starting URL.

### Paywalled or Blocked Sources

Record the attempt and the block in the archived file. Look for a primary
alternative — a court opinion instead of an article about it, a filing instead
of coverage of it. If none exists, cap confidence at medium and note the gap.

### Rapidly Changing Topics

Put the retrieval date in the page body, not just the frontmatter, for anything
time-sensitive (market cap, headcount, "current CEO"). Announced-but-not-yet-
effective facts should say so explicitly.

### Very Broad Topic ("artificial intelligence")

Narrow before searching. Propose 3–5 concrete sub-topics and confirm.

### Conflicting Primary Sources

Both go in the wiki, with a contradiction callout on both pages and an entry in
`review.json`. Do not pick a winner silently.
