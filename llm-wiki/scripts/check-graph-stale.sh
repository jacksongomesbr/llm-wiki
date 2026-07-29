#!/bin/bash
# check-graph-stale.sh — Is the knowledge graph stale with respect to the pages?
# Usage: check-graph-stale.sh [wiki_root]
# Exit: 0 = fresh, 1 = stale, 2 = never built
#
# Only /wiki-graph rebuilds the graph, while ingest and save rebuild the index
# and backlinks. Without this check the graph rots silently and nothing says so.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: check-graph-stale.sh [wiki_root]"
    echo "Check whether graph.json reflects the current pages."
    echo "Exit: 0 = fresh, 1 = stale, 2 = never built"
    exit 0
fi

WIKI_ROOT="${1:-}"
if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi
[ -d "$WIKI_ROOT" ] || { echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2; exit 2; }

STAMP="$WIKI_ROOT/.llm-wiki/cache/graph-hash.txt"
LIVE="$(wiki_frontmatter_hash "$WIKI_ROOT")"

if [ ! -f "$WIKI_ROOT/.llm-wiki/graph.json" ] || [ ! -f "$STAMP" ]; then
    echo "NEVER BUILT: run build-graph.sh '$WIKI_ROOT'"
    exit 2
fi

if [ "$LIVE" = "$(cat "$STAMP")" ]; then
    echo "FRESH: graph matches the current pages."
    exit 0
fi

echo "STALE: pages have changed since the graph was built."
echo "Rebuild with: build-graph.sh '$WIKI_ROOT'"
exit 1
