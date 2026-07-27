#!/bin/bash
# session-stop.sh — SessionStop hook for LLM Wiki
# Stamps the hot-cache so the next session knows when it was last touched.
#
# Configured as a SessionStop hook in settings.json (via setup-project.sh --with-hooks).

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/_utils.sh"

WIKI_ROOT=$(find_wiki_root)
[ -z "$WIKI_ROOT" ] && exit 0

HOT_CACHE="$WIKI_ROOT/.llm-wiki/cache/hot-cache.md"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$HOT_CACHE")"

# The hot cache is written *during* the session by wiki operations. This hook
# must not overwrite it.
#
# It previously did exactly that — `cat > "$HOT_CACHE"` with a blank template
# on every session end — so the "multi-session context bridge" handed the next
# session an empty file, every time. Only stamp the timestamp here; scaffold
# only when the file does not exist yet.
if [ -f "$HOT_CACHE" ]; then
    TMP="$(mktemp)"
    if grep -q '^\*\*Last session:\*\*' "$HOT_CACHE"; then
        sed "s|^\*\*Last session:\*\*.*|**Last session:** $NOW|" "$HOT_CACHE" > "$TMP"
    else
        {
            echo "**Last session:** $NOW"
            echo ""
            cat "$HOT_CACHE"
        } > "$TMP"
    fi
    mv "$TMP" "$HOT_CACHE"
    echo "Hot cache stamped: $HOT_CACHE"
    exit 0
fi

cat > "$HOT_CACHE" << HOTEOF
# Hot Cache
**Last session:** $NOW

<!--
Written during the session by wiki operations, read back by session-start.sh.
Keep it short — it is injected into every new session's context.
-->

## Recent Activity

## Pages Read

## Pages Written

## Queries Asked

## Pending

## Notes
HOTEOF

echo "Hot cache created: $HOT_CACHE"
