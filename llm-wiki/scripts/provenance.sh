#!/bin/bash
# provenance.sh — Trace what a page rests on, or what a source produced
# Usage: provenance.sh [wiki_root] [--page <slug> | --source <citekey> | --unsourced]
# Exit: 0 on success, 1 on error
#
# The wiki records provenance in three places and, until now, read none of it
# back: `references:` on each page, `references.bib`, and the ingest manifest at
# .llm-wiki/cache/source-manifest.json. This answers the two questions that
# provenance exists to answer:
#
#   --page   <slug>     what does this page rest on?
#   --source <citekey>  what did this source produce?
#   --unsourced         which pages assert things with nothing behind them?
#
# With no flag it prints a summary of all three.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

WIKI_ROOT=""
MODE="summary"
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            echo "Usage: provenance.sh [wiki_root] [--page <slug> | --source <citekey> | --unsourced]"
            echo "Trace what a page rests on, or what a source produced."
            echo "  --page <slug>       Sources behind this page"
            echo "  --source <citekey>  Pages resting on this source"
            echo "  --unsourced         Pages with no references at all"
            echo "  (no flag)           Summary of coverage"
            exit 0 ;;
        --page)      MODE="page";   TARGET="${2:-}"; shift 2 ;;
        --source)    MODE="source"; TARGET="${2:-}"; shift 2 ;;
        --unsourced) MODE="unsourced"; shift ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then WIKI_ROOT="$1"; shift
            else echo "Unknown option: $1 (use --help for usage)" >&2; exit 1; fi ;;
    esac
done

if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi
[ -d "$WIKI_ROOT" ] || { echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2; exit 1; }

BIB="$WIKI_ROOT/references.bib"

# bib_field <citekey> <field> — one field from one entry.
bib_field() {
    [ -f "$BIB" ] || return 0
    awk -v want="$1" -v field="$2" '
        /^[[:space:]]*@/ {
            k = $0
            sub(/^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*/, "", k)
            sub(/[[:space:]]*,.*$/, "", k)
            inentry = (k == want)
            next
        }
        inentry && $0 ~ "^[[:space:]]*" field "[[:space:]]*=" {
            v = $0
            sub(/^[^{]*\{/, "", v); sub(/\}.*$/, "", v)
            print v; exit
        }
    ' "$BIB"
}

case "$MODE" in
    page)
        [ -n "$TARGET" ] || { echo "ERROR: --page needs a slug" >&2; exit 1; }
        FILE=""
        while IFS= read -r -d '' f; do
            [ "$(page_slug "$f")" = "$TARGET" ] && FILE="$f" && break
        done < <(wiki_pages "$WIKI_ROOT")
        [ -n "$FILE" ] || { echo "ERROR: no page '$TARGET'" >&2; exit 1; }

        echo "# Provenance: $TARGET"
        echo ""
        KEYS="$(fm_list "$(extract_frontmatter "$FILE")" references)"
        if [ -z "$KEYS" ]; then
            echo "*No sources recorded. Claims on this page cannot be traced.*"
            exit 0
        fi
        echo "| Source | Title | URL |"
        echo "|--------|-------|-----|"
        printf '%s\n' "$KEYS" | while IFS= read -r k; do
            [ -z "$k" ] && continue
            printf '| %s | %s | %s |\n' "$k" \
                "$(bib_field "$k" title)" \
                "$(bib_field "$k" url)"
        done
        ;;

    source)
        [ -n "$TARGET" ] || { echo "ERROR: --source needs a citekey" >&2; exit 1; }
        echo "# Pages resting on: $TARGET"
        echo ""
        TITLE="$(bib_field "$TARGET" title)"
        [ -n "$TITLE" ] && echo "**$TITLE**" && echo ""
        FOUND=0
        while IFS= read -r -d '' f; do
            if fm_list "$(extract_frontmatter "$f")" references | grep -qFx "$TARGET"; then
                echo "- [[$(page_slug "$f")]]"
                FOUND=1
            fi
        done < <(wiki_pages "$WIKI_ROOT" | sort -z)
        [ "$FOUND" -eq 0 ] && echo "*No page cites this source.*"
        ;;

    unsourced)
        echo "# Pages with no recorded sources"
        echo ""
        FOUND=0
        while IFS= read -r -d '' f; do
            fm="$(extract_frontmatter "$f")"
            ptype="$(fm_field "$fm" type)"
            # A synthesis rests on other wiki pages by design, so it is not
            # unsourced merely for lacking external references.
            [ "$ptype" = "synthesis" ] && continue
            if [ -z "$(fm_list "$fm" references)" ]; then
                echo "- $(page_slug "$f") ($ptype)"
                FOUND=1
            fi
        done < <(wiki_pages "$WIKI_ROOT" | sort -z)
        [ "$FOUND" -eq 0 ] && echo "*Every page records at least one source.*"
        ;;

    summary)
        TOTAL=0; SOURCED=0
        while IFS= read -r -d '' f; do
            TOTAL=$((TOTAL + 1))
            [ -n "$(fm_list "$(extract_frontmatter "$f")" references)" ] && SOURCED=$((SOURCED + 1))
        done < <(wiki_pages "$WIKI_ROOT")
        ENTRIES=0
        [ -f "$BIB" ] && ENTRIES="$(grep -c '^[[:space:]]*@' "$BIB" || true)"

        echo "# Provenance Summary"
        echo ""
        echo "- **Pages:** $TOTAL"
        echo "- **Pages citing at least one source:** $SOURCED"
        echo "- **Bibliography entries:** $ENTRIES"
        echo ""
        MANIFEST="$WIKI_ROOT/.llm-wiki/cache/source-manifest.json"
        if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
            N="$(jq 'length' "$MANIFEST" 2>/dev/null || echo 0)"
            echo "- **Ingested sources on record:** $N"
            if [ "$N" -gt 0 ]; then
                echo ""
                echo "| Source | Ingested | Pages created |"
                echo "|--------|----------|---------------|"
                jq -r 'to_entries[] | "| \(.value.name // .key) | \(.value.date // "—") | \((.value.pages_created // []) | length) |"' \
                    "$MANIFEST" 2>/dev/null || true
            fi
        fi
        echo ""
        echo "Run with --page <slug>, --source <citekey> or --unsourced for detail."
        ;;
esac
