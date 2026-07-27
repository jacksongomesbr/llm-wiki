#!/bin/bash
# check-stale.sh — Check if the wiki index is stale
# Usage: check-stale.sh [wiki_root] [--store]
# Compares stored index hash against live hash of all page frontmatter
# Exit: 0 = fresh, 1 = stale, 2 = no stored hash
# Writes details to stdout

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

STORE=false
WIKI_ROOT=""

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: check-stale.sh [wiki_root] [--store]"
            echo "Check if the wiki index is stale by comparing stored vs live frontmatter hash."
            echo "  wiki_root   Wiki directory (default: ./wiki)"
            echo "  --store     Record the current hash as the baseline and exit 0"
            echo "Exit: 0 = fresh, 1 = stale, 2 = no stored hash"
            exit 0 ;;
        --store) STORE=true ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then
                WIKI_ROOT="$arg"
            else
                echo "Unknown option: $arg (use --help for usage)" >&2; exit 1
            fi ;;
    esac
done

WIKI_ROOT="${WIKI_ROOT:-./wiki}"
INDEX_HASH_FILE="$WIKI_ROOT/.llm-wiki/cache/index-hash.txt"

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 1
fi

LIVE_HASH="$(wiki_frontmatter_hash "$WIKI_ROOT")"

# `build-index.sh` records the baseline whenever it regenerates the index.
# `--store` exists for the case where pages were reconciled by hand and the
# index is known to be correct. Without a writer, this check could only ever
# report "no stored hash".
if [ "$STORE" = true ]; then
    mkdir -p "$(dirname "$INDEX_HASH_FILE")"
    echo "$LIVE_HASH" > "$INDEX_HASH_FILE"
    echo "STORED: Baseline hash recorded."
    echo "Hash: $LIVE_HASH"
    exit 0
fi

if [ ! -f "$INDEX_HASH_FILE" ]; then
    echo "STALE: No stored index hash found."
    echo "Current live hash: $LIVE_HASH"
    echo "Regenerate the index with: build-index.sh '$WIKI_ROOT'"
    exit 2
fi

STORED_HASH="$(cat "$INDEX_HASH_FILE")"

if [ "$LIVE_HASH" = "$STORED_HASH" ]; then
    echo "FRESH: Index is up to date."
    echo "Hash: $LIVE_HASH"
    exit 0
else
    echo "STALE: Index is out of date."
    echo "Stored hash: $STORED_HASH"
    echo "Live hash:   $LIVE_HASH"
    echo "Regenerate the index with: build-index.sh '$WIKI_ROOT'"
    exit 1
fi
