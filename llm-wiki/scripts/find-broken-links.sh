#!/bin/bash
# find-broken-links.sh — Find [[wikilinks]] pointing to missing pages
# Usage: find-broken-links.sh <wiki_root>
# Output: one line per broken link
# Exit: 0 = no broken links, 1 = broken links found, 2 = error

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: find-broken-links.sh [wiki_root]"
    echo "Find [[wikilinks]] pointing to missing pages."
    echo "  wiki_root   Wiki directory (default: ./wiki)"
    echo "Exit: 0 = no broken links, 1 = broken links found, 2 = error"
    exit 0
fi

WIKI_ROOT="${1:-./wiki}"

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VALID="$TMP/valid.txt"
: > "$VALID"

# Valid link targets: every page slug, plus every alias declared in
# frontmatter. `extract_frontmatter` reads only the block on line 1, so a `---`
# horizontal rule in the body can no longer masquerade as an alias list.
while IFS= read -r -d '' file; do
    page_slug "$file" >> "$VALID"
    fm_list "$(extract_frontmatter "$file")" aliases >> "$VALID"
done < <(wiki_pages "$WIKI_ROOT")

sort -u -o "$VALID" "$VALID"

BROKEN_FOUND=0

while IFS= read -r -d '' file; do
    rel="${file#"$WIKI_ROOT"/}"
    # `extract_links` returns every link on a line. The previous sed captured
    # only the last one per line, so multi-link rows — which the schema
    # mandates for evidence tables and "Related" lists — went unchecked.
    while IFS= read -r link; do
        [ -z "$link" ] && continue
        if ! grep -qFx "$link" "$VALID"; then
            echo "BROKEN: $rel → [[$link]]"
            BROKEN_FOUND=1
        fi
    done < <(extract_links "$file")
done < <(wiki_pages "$WIKI_ROOT")

if [ "$BROKEN_FOUND" -eq 0 ]; then
    echo "OK: No broken wikilinks found."
fi

exit "$BROKEN_FOUND"
