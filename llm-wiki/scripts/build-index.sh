#!/bin/bash
# build-index.sh — Regenerate .llm-wiki/index.md from the wiki pages
# Usage: build-index.sh [wiki_root] [--quiet]
# Exit: 0 on success, 1 on error
#
# The index is a derived artifact: page catalog, tag groupings, orphan list and
# review queue, all recomputed from the pages themselves. It is the single
# highest-traffic file in the wiki (every query reads it, every write
# invalidates it), which is exactly why it should not be assembled by hand.
#
# Also writes cache/index-hash.txt so check-stale.sh has a baseline to compare
# against.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

QUIET=false
WIKI_ROOT=""

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: build-index.sh [wiki_root] [--quiet]"
            echo "Regenerate .llm-wiki/index.md from the wiki pages."
            echo "  wiki_root   Wiki directory (default: auto-detected, else ./wiki)"
            echo "  --quiet     Only print errors"
            echo "  --help, -h  Show this help message"
            exit 0 ;;
        --quiet) QUIET=true ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then
                WIKI_ROOT="$arg"
            else
                echo "Unknown option: $arg (use --help for usage)" >&2; exit 1
            fi ;;
    esac
done

if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 1
fi

META_DIR="$WIKI_ROOT/.llm-wiki"
mkdir -p "$META_DIR/cache"

# The wiki keeps its own copy of the schema so it stays readable without the
# skill installed. It is a copy, so it drifts every time the skill is upgraded
# — refresh it here rather than leaving a stale contract in place.
SCHEMA_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/WIKI_SCHEMA.md"
if [ -f "$SCHEMA_SRC" ] && ! cmp -s "$SCHEMA_SRC" "$META_DIR/schema.md"; then
    cp "$SCHEMA_SRC" "$META_DIR/schema.md"
    SCHEMA_REFRESHED=true
else
    SCHEMA_REFRESHED=false
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

META="$TMP/meta.tsv"        # slug \t type \t lang \t title \t summary \t modified \t tags \t class \t status \t area
TAGS="$TMP/tags.tsv"        # tag \t slug
EDGES="$TMP/edges.tsv"      # source_slug \t raw_target
ALIASES="$TMP/aliases.tsv"  # alias \t slug
: > "$META"; : > "$TAGS"; : > "$EDGES"; : > "$ALIASES"

# ── Pass 1: collect metadata, tags, aliases and raw links ───────────────────

PAGE_COUNT=0
while IFS= read -r -d '' file; do
    slug="$(page_slug "$file")"
    fm="$(extract_frontmatter "$file")"

    # One awk pass for every scalar field; reading them individually spawned a
    # subshell and an awk per field per page.
    {
        IFS= read -r title; IFS= read -r ptype; IFS= read -r lang
        IFS= read -r summary; IFS= read -r modified; IFS= read -r pclass
        IFS= read -r pstatus; IFS= read -r parea
    } < <(fm_fields "$fm" title type language summary modified class status area)
    [ -z "$title" ] && title="$slug"
    [ -z "$ptype" ] && ptype="unknown"
    [ -z "$lang" ] && lang="—"
    [ -z "$modified" ] && modified="—"
    [ -z "$pclass" ] && pclass="—"
    [ -z "$pstatus" ] && pstatus="—"
    [ -z "$parea" ] && parea="—"

    # Pipes would break the markdown table; escape them.
    title="${title//|/\\|}"
    summary="${summary//|/\\|}"

    tag_list="$(fm_list "$fm" tags | tr '\n' ',' | sed 's/,$//')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slug" "$ptype" "$lang" "$title" "$summary" "$modified" "$tag_list" \
        "$pclass" "$pstatus" "$parea" >> "$META"

    fm_list "$fm" tags | while IFS= read -r tag; do
        [ -n "$tag" ] && printf '%s\t%s\n' "$tag" "$slug" >> "$TAGS"
    done

    fm_list "$fm" aliases | while IFS= read -r alias; do
        [ -n "$alias" ] && printf '%s\t%s\n' "$alias" "$slug" >> "$ALIASES"
    done

    extract_links "$file" | while IFS= read -r target; do
        [ -n "$target" ] && printf '%s\t%s\n' "$slug" "$target" >> "$EDGES"
    done

    PAGE_COUNT=$((PAGE_COUNT + 1))
done < <(wiki_pages "$WIKI_ROOT" | sort -z)

# ── Pass 2: resolve link targets to slugs, compute inbound links ────────────

# A link target is either a slug or an alias of one. Anything else is broken
# and belongs to find-broken-links.sh, not here.
INBOUND="$TMP/inbound.txt"
: > "$INBOUND"

if [ -s "$EDGES" ]; then
    while IFS="$(printf '\t')" read -r src target; do
        [ -z "$target" ] && continue
        resolved=""
        if cut -f1 "$META" | grep -qFx "$target"; then
            resolved="$target"
        elif [ -s "$ALIASES" ]; then
            resolved="$(awk -F'\t' -v a="$target" '$1 == a { print $2; exit }' "$ALIASES")"
        fi
        # Self-links do not rescue a page from being an orphan.
        if [ -n "$resolved" ] && [ "$resolved" != "$src" ]; then
            echo "$resolved" >> "$INBOUND"
        fi
    done < "$EDGES"
fi

sort -u -o "$INBOUND" "$INBOUND"

# ── Write the index ─────────────────────────────────────────────────────────

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FM_HASH="$(wiki_frontmatter_hash "$WIKI_ROOT")"
INDEX="$META_DIR/index.md"

{
    echo "# Wiki Index"
    echo "<!-- AUTO-GENERATED BY build-index.sh — DO NOT EDIT BY HAND -->"
    echo "**Last generated:** $NOW"
    echo "**Source hash:** $FM_HASH"
    echo "**Total pages:** $PAGE_COUNT"
    echo ""

    echo "## All Pages"
    echo ""
    if [ "$PAGE_COUNT" -eq 0 ]; then
        echo "*No pages yet — use /wiki-ingest to add your first source.*"
    else
        echo "| Slug | Title | Kind | Status | Lang | Tags | Summary | Modified |"
        echo "|------|-------|------|--------|------|------|---------|----------|"
        while IFS="$(printf '\t')" read -r slug ptype lang title summary modified tag_list pclass pstatus _parea; do
            kind="$ptype"
            [ "$pclass" != "—" ] && kind="$ptype/$pclass"
            printf '| [[%s]] | %s | %s | %s | %s | %s | %s | %s |\n' \
                "$slug" "$title" "$kind" "$pstatus" "$lang" "${tag_list//,/, }" "$summary" "$modified"
        done < "$META"
    fi
    echo ""

    echo "## By Tag"
    echo ""
    if [ -s "$TAGS" ]; then
        sort -u "$TAGS" | cut -f1 | sort -u | while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            n="$(awk -F'\t' -v t="$tag" '$1 == t' "$TAGS" | sort -u | wc -l | tr -d ' ')"
            echo "### $tag ($n pages)"
            echo ""
            awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$TAGS" | sort -u | while IFS= read -r slug; do
                summary="$(awk -F'\t' -v s="$slug" '$1 == s { print $5; exit }' "$META")"
                echo "- [[$slug]] — $summary"
            done
            echo ""
        done
    else
        echo "*No tags yet.*"
        echo ""
    fi

    echo "## By Kind"
    echo ""
    if [ "$PAGE_COUNT" -gt 0 ]; then
        cut -f2,8 "$META" | sort | uniq -c | sort -rn | while read -r n t c; do
            label="$t"
            [ "$c" != "—" ] && label="$t / $c"
            echo "- **$label** — $n"
        done
    else
        echo "*No pages yet.*"
    fi
    echo ""

    # An operating-system view: what is actually in flight. Absent when the
    # wiki holds no projects, so a purely encyclopedic wiki is not cluttered.
    if awk -F'\t' '$2 == "project"' "$META" | grep -q .; then
        echo "## Projects"
        echo ""
        echo "| Project | Status | Area | Summary |"
        echo "|---------|--------|------|---------|"
        # `area` is read from the metadata table, not by rebuilding a path from
        # the slug: pages may live in subdirectories such as topics/, where
        # "$WIKI_ROOT/$slug.md" does not exist and the area silently came back
        # empty.
        while IFS="$(printf '\t')" read -r slug ptype _lang _title summary _modified _tags _class pstatus parea; do
            [ "$ptype" = "project" ] || continue
            printf '| [[%s]] | %s | %s | %s |\n' "$slug" "$pstatus" "$parea" "$summary"
        done < "$META"
        echo ""
    fi

    echo "## Orphan Pages"
    echo ""
    ORPHAN_COUNT=0
    if [ "$PAGE_COUNT" -gt 0 ]; then
        while IFS="$(printf '\t')" read -r slug _ptype _lang _title summary _modified _tags _class _status _area; do
            if ! grep -qFx "$slug" "$INBOUND" 2>/dev/null; then
                echo "- [[$slug]] — $summary (no incoming links)"
                ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            fi
        done < "$META"
    fi
    [ "$ORPHAN_COUNT" -eq 0 ] && echo "*None.*"
    echo ""

    echo "## Review Queue"
    echo ""
    REVIEW_JSON="$META_DIR/review.json"
    PRINTED_REVIEW=false
    if [ -f "$REVIEW_JSON" ] && command -v jq >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "- $line"
            PRINTED_REVIEW=true
        done < <(jq -r '
            (.pending // [])[]
            | "⚠️ [" + (.severity // "info") + "] "
              + ((.pages // []) | map("[[" + . + "]]") | join(", "))
              + " — " + (.description // "no description")
        ' "$REVIEW_JSON" 2>/dev/null || true)
    fi
    [ "$PRINTED_REVIEW" = false ] && echo "*No pending reviews.*"
} > "$INDEX"

# The index is now consistent with the pages: record the baseline.
echo "$FM_HASH" > "$META_DIR/cache/index-hash.txt"

if [ "$QUIET" = false ]; then
    ORPHANS="$(grep -c '^- \[\[' <<< "$(sed -n '/^## Orphan Pages/,/^## Review Queue/p' "$INDEX")" || true)"
    echo "Index written: $INDEX"
    echo "  Pages:   $PAGE_COUNT"
    echo "  Orphans: ${ORPHANS:-0}"
    echo "  Hash:    $FM_HASH"
    if [ "$SCHEMA_REFRESHED" = true ]; then
        echo "  Schema:  refreshed from the installed skill"
    fi
fi
