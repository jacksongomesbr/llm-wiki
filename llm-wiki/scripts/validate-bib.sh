#!/bin/bash
# validate-bib.sh — Check the bibliography and the citations that point into it
# Usage: validate-bib.sh [wiki_root] [--bib <path>] [--quiet]
# Output: one line per issue found
# Exit: 0 = all valid, 1 = issues found, 2 = error
#
# Checks both directions:
#   - every citation resolves to an entry  (dangling citations)
#   - every entry is cited by some page    (orphan entries)
#
# Citations are checked in both places a page can carry them: the `references:`
# frontmatter list and inline [@key] markers in the body. They are supposed to
# agree, and a body citation missing from the frontmatter list is reported —
# that drift is what makes the index and any export incomplete.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

QUIET=false
WIKI_ROOT=""
BIB=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            echo "Usage: validate-bib.sh [wiki_root] [--bib <path>] [--quiet]"
            echo "Check references.bib and the citations pointing into it."
            echo "  wiki_root   Wiki directory (default: auto-detected, else ./wiki)"
            echo "  --bib       Bibliography file (default: <wiki_root>/references.bib)"
            echo "  --quiet     Suppress the OK line"
            echo "Exit: 0 = all valid, 1 = issues found, 2 = error"
            exit 0 ;;
        --bib)   BIB="${2:-}"; shift 2 ;;
        --quiet) QUIET=true; shift ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then
                WIKI_ROOT="$1"; shift
            else
                echo "Unknown option: $1 (use --help for usage)" >&2; exit 2
            fi ;;
    esac
done

if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi
[ -z "$BIB" ] && BIB="$WIKI_ROOT/references.bib"

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 2
fi

ISSUES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KEYS="$TMP/keys.txt"
CITED="$TMP/cited.txt"
: > "$KEYS"; : > "$CITED"

if [ ! -f "$BIB" ]; then
    # A wiki that has never cited anything is valid; one with citations and no
    # bibliography is not.
    if wiki_pages "$WIKI_ROOT" | xargs -0 -I{} sh -c 'true' 2>/dev/null; then :; fi
    HAS_CITES=0
    while IFS= read -r -d '' file; do
        if [ -n "$(extract_citations "$file")" ] || \
           [ -n "$(fm_list "$(extract_frontmatter "$file")" references)" ]; then
            HAS_CITES=1
            break
        fi
    done < <(wiki_pages "$WIKI_ROOT")
    if [ "$HAS_CITES" -eq 1 ]; then
        echo "ERROR: pages contain citations but '$BIB' does not exist"
        exit 1
    fi
    [ "$QUIET" = false ] && echo "OK: No bibliography and no citations."
    exit 0
fi

# ── Bibliography integrity ──────────────────────────────────────────────────

# Entry keys, in file order, so duplicates can be reported.
awk '
    /^[[:space:]]*@/ {
        k = $0
        sub(/^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*/, "", k)
        sub(/[[:space:]]*,.*$/, "", k)
        if (k != "") print k
    }
' "$BIB" > "$KEYS"

DUPES="$(sort "$KEYS" | uniq -d)"
if [ -n "$DUPES" ]; then
    while IFS= read -r k; do
        [ -n "$k" ] && { echo "ERROR: duplicate citation key in $(basename "$BIB"): $k"; ISSUES=1; }
    done <<< "$DUPES"
fi

# Entries must be identifiable and locatable.
awk -v bib="$(basename "$BIB")" '
    function flush() {
        if (key == "") return
        if (!has_title) { print "ERROR: " bib " entry {" key "} has no title"; bad = 1 }
        if (!has_url && !has_doi) { print "ERROR: " bib " entry {" key "} has neither url nor doi"; bad = 1 }
    }
    /^[[:space:]]*@/ {
        flush()
        key = $0
        sub(/^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*/, "", key)
        sub(/[[:space:]]*,.*$/, "", key)
        has_title = 0; has_url = 0; has_doi = 0
        next
    }
    /^[[:space:]]*title[[:space:]]*=/ { has_title = 1 }
    /^[[:space:]]*url[[:space:]]*=/   { has_url = 1 }
    /^[[:space:]]*doi[[:space:]]*=/   { has_doi = 1 }
    END { flush(); exit bad }
' "$BIB" || ISSUES=1

sort -u -o "$KEYS" "$KEYS"

# ── Citations from pages ────────────────────────────────────────────────────

while IFS= read -r -d '' file; do
    slug="$(page_slug "$file")"
    fm="$(extract_frontmatter "$file")"

    fm_refs="$(fm_list "$fm" references || true)"
    body_refs="$(extract_citations "$file" || true)"

    # Dangling: cited but not in the bibliography.
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "$key" >> "$CITED"
        if ! grep -qFx "$key" "$KEYS"; then
            echo "ERROR: $slug — references: [$key] has no entry in $(basename "$BIB")"
            ISSUES=1
        fi
    done <<< "$fm_refs"

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "$key" >> "$CITED"
        if ! grep -qFx "$key" "$KEYS"; then
            echo "ERROR: $slug — [@$key] has no entry in $(basename "$BIB")"
            ISSUES=1
        fi
        # Drift: an inline citation the frontmatter list does not declare.
        if [ -n "$fm_refs" ] || [ -n "$key" ]; then
            if ! printf '%s\n' "$fm_refs" | grep -qFx "$key"; then
                echo "WARNING: $slug — [@$key] is cited in the body but missing from references:"
                ISSUES=1
            fi
        fi
    done <<< "$body_refs"
done < <(wiki_pages "$WIKI_ROOT")

sort -u -o "$CITED" "$CITED"

# ── Orphan entries ──────────────────────────────────────────────────────────

while IFS= read -r key; do
    [ -z "$key" ] && continue
    if ! grep -qFx "$key" "$CITED"; then
        echo "WARNING: $(basename "$BIB") entry {$key} is not cited by any page"
        ISSUES=1
    fi
done < "$KEYS"

if [ "$ISSUES" -eq 0 ] && [ "$QUIET" = false ]; then
    echo "OK: $(wc -l < "$KEYS" | tr -d ' ') bibliography entries, all citations resolve."
fi

exit "$ISSUES"
