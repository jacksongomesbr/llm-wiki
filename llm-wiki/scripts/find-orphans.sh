#!/bin/bash
# find-orphans.sh — Find wiki pages with zero incoming [[wikilinks]]
# Usage: find-orphans.sh <wiki_root>
# Output: one line per orphan page
# Exit: 0 on success (even if orphans found), 1 on error

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: find-orphans.sh [wiki_root]"
    echo "Find wiki pages with zero incoming [[wikilinks]]."
    echo "  wiki_root   Wiki directory (default: ./wiki)"
    exit 0
fi

WIKI_ROOT="${1:-./wiki}"

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SLUGS="$TMP/slugs.txt"
ALIASES="$TMP/aliases.tsv"
INBOUND="$TMP/inbound.txt"
: > "$SLUGS"; : > "$ALIASES"; : > "$INBOUND"

# Collect slugs and aliases.
#
# `wiki_pages` excludes `.llm-wiki/` and any index file. That matters: the
# generated index lists every page under "By Tag" as `- [[slug]] — summary`,
# so counting the index as a link source made every page look reachable and
# this check could never report anything.
while IFS= read -r -d '' file; do
    slug="$(page_slug "$file")"
    echo "$slug" >> "$SLUGS"
    fm_list "$(extract_frontmatter "$file")" aliases | while IFS= read -r alias; do
        [ -n "$alias" ] && printf '%s\t%s\n' "$alias" "$slug" >> "$ALIASES"
    done
done < <(wiki_pages "$WIKI_ROOT")

# Collect inbound links, resolving aliases and ignoring self-links.
while IFS= read -r -d '' file; do
    src="$(page_slug "$file")"
    extract_links "$file" | while IFS= read -r target; do
        [ -z "$target" ] && continue
        resolved=""
        if grep -qFx "$target" "$SLUGS"; then
            resolved="$target"
        elif [ -s "$ALIASES" ]; then
            resolved="$(awk -F'\t' -v a="$target" '$1 == a { print $2; exit }' "$ALIASES")"
        fi
        if [ -n "$resolved" ] && [ "$resolved" != "$src" ]; then
            echo "$resolved" >> "$INBOUND"
        fi
    done
done < <(wiki_pages "$WIKI_ROOT")

sort -u -o "$INBOUND" "$INBOUND"

ORPHANS_FOUND=0
while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if ! grep -qFx "$slug" "$INBOUND"; then
        echo "ORPHAN: $slug"
        ORPHANS_FOUND=1
    fi
done < "$SLUGS"

if [ "$ORPHANS_FOUND" -eq 0 ]; then
    echo "OK: No orphan pages found."
fi
