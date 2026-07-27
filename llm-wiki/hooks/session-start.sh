#!/bin/bash
# session-start.sh — SessionStart hook for LLM Wiki
# Outputs wiki context and PROACTIVE WIKI RULE for Claude.
#
# Configured as a SessionStart hook in settings.json (via setup-project.sh --with-hooks).
# The output of this script becomes part of Claude's session context.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/_utils.sh"

WIKI_ROOT=$(find_wiki_root)
[ -z "$WIKI_ROOT" ] && exit 0

SKILL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

HOT_CACHE="$WIKI_ROOT/.llm-wiki/cache/hot-cache.md"
INDEX="$WIKI_ROOT/.llm-wiki/index.md"
STATE_HASH_FILE="$WIKI_ROOT/.llm-wiki/cache/state-hash.txt"
REVIEW_JSON="$WIKI_ROOT/.llm-wiki/review.json"

# Hash the full content of every page to detect edits made outside a session
# (in Obsidian, an editor, a git pull). Portable: no bare `sha256sum`, which a
# stock macOS install does not have.
CURRENT_HASH=$(
    while IFS= read -r -d '' f; do
        cat "$f"
    done < <(wiki_pages "$WIKI_ROOT" | sort -z) | sha256_stdin
)

cat << HEADER
---
## LLM Wiki — Session Context
**Wiki root:** $WIKI_ROOT
**Skill:** Use \`Skill("wiki")\` to load full wiki capabilities
---

HEADER

# === PROACTIVE WIKI RULE (most important) ===
cat << RULES
### PROACTIVE WIKI RULE — ALWAYS FOLLOW THIS

1. **Check the wiki before answering** — When the user asks any factual, conceptual, or knowledge-based question, FIRST read \`$WIKI_ROOT/.llm-wiki/index.md\` to check if the wiki has relevant information. Do NOT answer from your training data without checking the wiki.

2. **How to use the wiki**:
   - Read the index to find relevant pages (by tags, titles, summaries)
   - Read 3-5 most relevant pages
   - Synthesize answer with citations: \`[[page-slug]]\`
   - Report confidence, contradictions, and knowledge gaps

3. **When the wiki lacks knowledge**: Tell the user what's missing and suggest sources to ingest. Use \`/wiki-ingest\` to add knowledge.

4. **After creating or editing any page**: regenerate the derived files.
   Never hand-write \`index.md\`.
   \`\`\`bash
   $SKILL_SCRIPTS/build-index.sh "$WIKI_ROOT"
   $SKILL_SCRIPTS/update-backlinks.sh "$WIKI_ROOT"
   \`\`\`

RULES

# Compare with stored hash
if [ -f "$STATE_HASH_FILE" ]; then
    STORED_HASH=$(cat "$STATE_HASH_FILE")
    if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
        echo "⚠️  **Wiki state has changed** since last session. Run /wiki-lint to check health."
        echo ""
    fi
fi
mkdir -p "$(dirname "$STATE_HASH_FILE")"
echo "$CURRENT_HASH" > "$STATE_HASH_FILE"

# Quick stats from index
if [ -f "$INDEX" ]; then
    # Read the count the index itself reports. Counting table rows with
    # `grep -c '^| \['` also matched the By Tag and Orphan sections.
    PAGE_COUNT=$(sed -n 's/^\*\*Total pages:\*\* *//p' "$INDEX" | head -1)
    PAGE_COUNT="${PAGE_COUNT:-unknown}"
    LAST_GEN=$(sed -n 's/^\*\*Last generated:\*\* *//p' "$INDEX" | head -1)
    LAST_GEN="${LAST_GEN:-unknown}"
    echo "**Wiki pages:** $PAGE_COUNT | **Index generated:** $LAST_GEN"
    echo ""

    # Tag cloud
    TAGS=$(grep '^### ' "$INDEX" 2>/dev/null | sed 's/^### //' | sed 's/ ([0-9]* pages)//' || true)
    if [ -n "$TAGS" ]; then
        echo "### Available Topics"
        echo "$TAGS" | while read -r tag; do
            echo "- \`$tag\`"
        done
        echo ""
    fi
else
    echo "**Wiki:** Empty — ingest some sources first!"
    echo ""
fi

# Pending reviews
if [ -f "$REVIEW_JSON" ] && command -v jq >/dev/null 2>&1; then
    PENDING=$(jq '(.pending // []) | length' "$REVIEW_JSON" 2>/dev/null || echo "0")

    if [ "$PENDING" -gt 0 ]; then
        echo "🔔 **$PENDING pending review(s)** — run /wiki-review to process"
        echo ""
    fi
fi

# Hot cache from previous session
if [ -f "$HOT_CACHE" ]; then
    echo "### Context from Previous Session"
    cat "$HOT_CACHE"
    echo ""
fi

# Reminder
cat << REMINDER
---
**Commands:** /wiki, /wiki-ingest, /wiki-query, /wiki-lint, /wiki-save, /wiki-graph, /wiki-review
**Skill:** Use \`Skill("wiki")\` for advanced wiki operations
REMINDER
