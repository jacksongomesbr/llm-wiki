#!/bin/bash
# build-graph.sh — Generate the knowledge graph (graph.json + graph.html)
# Usage: build-graph.sh [wiki_root] [--quiet] [--no-html]
# Exit: 0 on success, 1 on error
#
# The graph is derived data, like the index. It used to be hand-written by the
# LLM on every invocation, which made it non-deterministic, untestable, and free
# to disagree with the rest of the toolchain about what links to what.
#
# It reuses `extract_links`, `extract_citations` and the frontmatter helpers from
# _utils.sh, so the graph agrees with build-index.sh and find-orphans.sh by
# construction rather than by coincidence. The test suite asserts that agreement.
#
# Pinned node positions in an existing graph.json are preserved: regenerating
# should not scramble a layout you arranged by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/graph.html"

QUIET=false
NO_HTML=false
WIKI_ROOT=""

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: build-graph.sh [wiki_root] [--quiet] [--no-html]"
            echo "Generate .llm-wiki/graph.json and .llm-wiki/graph.html."
            echo "  --quiet     Only print errors"
            echo "  --no-html   Write graph.json only"
            exit 0 ;;
        --quiet)   QUIET=true ;;
        --no-html) NO_HTML=true ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then WIKI_ROOT="$arg"
            else echo "Unknown option: $arg (use --help for usage)" >&2; exit 1; fi ;;
    esac
done

if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi
[ -d "$WIKI_ROOT" ] || { echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2; exit 1; }

META_DIR="$WIKI_ROOT/.llm-wiki"
mkdir -p "$META_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Tab is IFS *whitespace*, so `read` collapses runs of tabs and empty fields
# silently disappear — shifting every later column. Records use the ASCII unit
# separator instead, which `read` treats as a real delimiter.
SEP=$'\037'

NODES="$TMP/nodes.tsv"
EDGES="$TMP/edges.tsv"
SLUGS="$TMP/slugs.txt"
ALIASES="$TMP/aliases.tsv"
: > "$NODES"; : > "$EDGES"; : > "$SLUGS"; : > "$ALIASES"

# ── Pass 1: slugs and aliases ───────────────────────────────────────────────

while IFS= read -r -d '' file; do
    slug="$(page_slug "$file")"
    echo "$slug" >> "$SLUGS"
    fm_list "$(extract_frontmatter "$file")" aliases | while IFS= read -r a; do
        if [ -n "$a" ]; then printf '%s\t%s\n' "$a" "$slug" >> "$ALIASES"; fi
    done
done < <(wiki_pages "$WIKI_ROOT" | sort -z)

# ── Pass 2: node records and edges ──────────────────────────────────────────

resolve() {
    # resolve <target> -> slug, or empty when it points nowhere
    if grep -qFx "$1" "$SLUGS"; then printf '%s' "$1"; return; fi
    [ -s "$ALIASES" ] && awk -F'\t' -v a="$1" '$1 == a { print $2; exit }' "$ALIASES"
}

while IFS= read -r -d '' file; do
    slug="$(page_slug "$file")"
    fm="$(extract_frontmatter "$file")"
    rel="${file#"$WIKI_ROOT"/}"

    title="$(fm_field "$fm" title)";        [ -z "$title" ] && title="$slug"
    ptype="$(fm_field "$fm" type)";         [ -z "$ptype" ] && ptype="concept"
    pclass="$(fm_field "$fm" class)"
    pstatus="$(fm_field "$fm" status)"
    summary="$(fm_field "$fm" summary)"
    lang="$(fm_field "$fm" language)"
    modified="$(fm_field "$fm" modified)"
    parea="$(fm_field "$fm" area)"
    created="$(fm_field "$fm" created)"
    tags="$(fm_list "$fm" tags | tr '\n' ',' | sed 's/,$//')"
    refs="$(fm_list "$fm" references | tr '\n' ',' | sed 's/,$//')"

    printf '%s\n' \
        "$slug$SEP$ptype$SEP$pclass$SEP$pstatus$SEP$title$SEP$summary$SEP$tags$SEP$lang$SEP$modified$SEP$parea$SEP$refs$SEP$created$SEP$rel" >> "$NODES"

    # Page-to-page edges. Self-links are dropped: a page pointing at itself is
    # not a relationship, and counting it would mask an orphan.
    extract_links "$file" | while IFS= read -r target; do
        [ -z "$target" ] && continue
        r="$(resolve "$target")"
        if [ -n "$r" ] && [ "$r" != "$slug" ]; then
            printf '%s\t%s\tlink\n' "$slug" "$r" >> "$EDGES"
        fi
    done

    # Citation edges into bibliography keys, drawn as a separate layer.
    printf '%s\n' "$refs" | tr ',' '\n' | while IFS= read -r k; do
        if [ -n "$k" ]; then
            printf '%s\tbib:%s\tcite\n' "$slug" "$k" >> "$EDGES"
        fi
    done
done < <(wiki_pages "$WIKI_ROOT" | sort -z)

sort -u -o "$EDGES" "$EDGES"

# ── Pass 3: degrees and connected components ────────────────────────────────

# Components are computed over page-to-page links only, by union-find. This is
# the one graph statistic nothing else in the toolchain reports, and it answers
# a real question: is this one body of knowledge, or several islands?
COMPONENTS="$(awk -F'\t' '
    function find(x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x] } return x }
    function union(a, b,   ra, rb) { ra = find(a); rb = find(b); if (ra != rb) parent[ra] = rb }
    NR == FNR { parent[$1] = $1; nodes[$1] = 1; next }
    $3 == "link" && ($1 in parent) && ($2 in parent) { union($1, $2) }
    END {
        for (n in nodes) roots[find(n)] = 1
        c = 0; for (r in roots) c++
        print c
    }
' "$SLUGS" "$EDGES")"
[ -z "$COMPONENTS" ] && COMPONENTS=0

indeg()  { awk -F'\t' -v s="$1" '$3=="link" && $2==s' "$EDGES" | wc -l | tr -d ' '; }
outdeg() { awk -F'\t' -v s="$1" '$3=="link" && $1==s' "$EDGES" | wc -l | tr -d ' '; }

# ── Preserve pinned positions ───────────────────────────────────────────────

PINS="$TMP/pins.tsv"
: > "$PINS"
if [ -f "$META_DIR/graph.json" ] && command -v jq >/dev/null 2>&1; then
    jq -r '(.nodes // [])[] | select(.fx != null) | "\(.id)\t\(.fx)\t\(.fy)"' \
        "$META_DIR/graph.json" 2>/dev/null > "$PINS" || : > "$PINS"
fi

# ── Emit graph.json ─────────────────────────────────────────────────────────

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NODE_COUNT="$(wc -l < "$NODES" | tr -d ' ')"
JSON="$TMP/graph.json"

{
    printf '{\n  "generated": "%s",\n  "components": %s,\n  "nodes": [\n' "$NOW" "$COMPONENTS"
    first=true
    while IFS="$SEP" read -r slug ptype pclass pstatus title summary tags lang modified parea refs created rel; do
        [ -z "$slug" ] && continue
        i="$(indeg "$slug")"; o="$(outdeg "$slug")"
        hub=false; [ "$i" -ge 5 ] && hub=true
        [ "$first" = true ] && first=false || printf ',\n'
        printf '    {"id": "%s", "title": "%s", "type": "%s", "class": %s, "status": %s' \
            "$(json_escape "$slug")" "$(json_escape "$title")" "$(json_escape "$ptype")" \
            "$([ -n "$pclass" ] && printf '"%s"' "$(json_escape "$pclass")" || echo null)" \
            "$([ -n "$pstatus" ] && printf '"%s"' "$(json_escape "$pstatus")" || echo null)"
        printf ', "summary": "%s", "path": "../%s", "inDegree": %s, "outDegree": %s, "isHub": %s' \
            "$(json_escape "$summary")" "$(json_escape "$rel")" "$i" "$o" "$hub"
        printf ', "references": [%s]' \
            "$(printf '%s' "$refs" | awk -F',' '{ for (n=1; n<=NF; n++) if ($n != "") printf "%s\"%s\"", (n>1?", ":""), $n }')"
        printf ', "frontmatter": {"language": "%s", "created": "%s", "modified": "%s", "tags": "%s", "area": "%s"}' \
            "$(json_escape "$lang")" "$(json_escape "$created")" \
            "$(json_escape "$modified")" "$(json_escape "$tags")" "$(json_escape "$parea")"
        pin="$(awk -F'\t' -v s="$slug" '$1==s { printf ", \"fx\": %s, \"fy\": %s", $2, $3; exit }' "$PINS")"
        printf '%s}' "$pin"
    done < "$NODES"
    # Bibliography entries as a second node layer. Their ids are namespaced
    # `bib:` so they can never collide with a page slug.
    BIB="$WIKI_ROOT/references.bib"
    if [ -f "$BIB" ]; then
        while IFS="$SEP" read -r bkey btitle burl; do
            [ -z "$bkey" ] && continue
            [ "$first" = true ] && first=false || printf ',\n'
            printf '    {"id": "bib:%s", "title": "%s", "type": "source", "class": null, "status": null' \
                "$(json_escape "$bkey")" "$(json_escape "${btitle:-$bkey}")"
            printf ', "summary": "%s", "path": %s, "inDegree": %s, "outDegree": 0, "isHub": false' \
                "$(json_escape "$burl")" \
                "$([ -n "$burl" ] && printf '"%s"' "$(json_escape "$burl")" || echo null)" \
                "$(awk -F'\t' -v s="bib:$bkey" '$3=="cite" && $2==s' "$EDGES" | wc -l | tr -d ' ')"
            printf ', "references": [], "frontmatter": {"citekey": "%s", "url": "%s"}}' \
                "$(json_escape "$bkey")" "$(json_escape "$burl")"
        done < <(awk -v SEP="$SEP" '
            /^[[:space:]]*@/ {
                if (key != "") print key SEP title SEP url
                key = $0
                sub(/^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*/, "", key)
                sub(/[[:space:]]*,.*$/, "", key)
                title = ""; url = ""
                next
            }
            /^[[:space:]]*title[[:space:]]*=/ { v = $0; sub(/^[^{]*\{/, "", v); sub(/\}.*$/, "", v); title = v }
            /^[[:space:]]*url[[:space:]]*=/   { v = $0; sub(/^[^{]*\{/, "", v); sub(/\}.*$/, "", v); url = v }
            END { if (key != "") print key SEP title SEP url }
        ' "$BIB")
    fi

    printf '\n  ],\n  "edges": [\n'
    first=true
    while IFS="$(printf '\t')" read -r s t k; do
        [ -z "$s" ] && continue
        [ "$first" = true ] && first=false || printf ',\n'
        printf '    {"source": "%s", "target": "%s", "kind": "%s"}' \
            "$(json_escape "$s")" "$(json_escape "$t")" "$(json_escape "$k")"
    done < "$EDGES"
    printf '\n  ]\n}\n'
} > "$JSON"

if command -v jq >/dev/null 2>&1 && ! jq empty "$JSON" 2>/dev/null; then
    echo "ERROR: generated graph.json is not valid JSON" >&2
    exit 1
fi
cp "$JSON" "$META_DIR/graph.json"

# ── Render graph.html ───────────────────────────────────────────────────────

if [ "$NO_HTML" = false ]; then
    if [ ! -f "$TEMPLATE" ]; then
        echo "ERROR: template not found at $TEMPLATE" >&2
        exit 1
    fi

    # A vendored D3 is preferred: it works offline and executes no third-party
    # code. The CDN fallback is pinned with Subresource Integrity.
    if [ -f "$META_DIR/vendor/d3.v7.min.js" ]; then
        D3_TAG='<script src="vendor/d3.v7.min.js"></script>'
        D3_SOURCE="vendored"
    else
        D3_TAG='<script src="https://d3js.org/d3.v7.min.js" integrity="sha384-CjloA8y00+1SDAUkjs099PVfnY2KmDC2BZnws9kh8D/lX1s46w6EPhpXdqMfjK6i" crossorigin="anonymous"></script>'
        D3_SOURCE="CDN (run scripts/vendor-d3.sh to work offline)"
    fi

    WIKI_NAME="$(config_get "$WIKI_ROOT" wiki_name "Wiki")"

    # Substitution is done with awk rather than sed: the graph JSON contains
    # ampersands and slashes, which sed's replacement syntax would mangle.
    awk -v datafile="$JSON" -v d3tag="$D3_TAG" -v name="$WIKI_NAME" -v gen="$NOW" '
        {
            # Match the assignment line specifically. Matching the bare token
            # anywhere also fired on prose that merely named it, injecting the
            # whole graph a second time.
            if ($0 ~ /^window\.GRAPH = __GRAPH_DATA__;?$/ || index($0, "window.GRAPH = __GRAPH_DATA__")) {
                n = index($0, "__GRAPH_DATA__")
                printf "%s", substr($0, 1, n - 1)
                while ((getline line < datafile) > 0) print line
                close(datafile)
                print substr($0, n + length("__GRAPH_DATA__"))
                next
            }
            gsub(/__D3_SCRIPT_TAG__/, d3tag)
            gsub(/__WIKI_NAME__/, name)
            gsub(/__GENERATED__/, gen)
            print
        }
    ' "$TEMPLATE" > "$META_DIR/graph.html"
fi

if [ "$QUIET" = false ]; then
    EDGE_COUNT="$(awk -F'\t' '$3=="link"' "$EDGES" | wc -l | tr -d ' ')"
    CITE_COUNT="$(awk -F'\t' '$3=="cite"' "$EDGES" | wc -l | tr -d ' ')"
    echo "Graph written: $META_DIR/graph.json"
    [ "$NO_HTML" = false ] && echo "               $META_DIR/graph.html"
    echo "  Pages:      $NODE_COUNT"
    echo "  Links:      $EDGE_COUNT"
    echo "  Citations:  $CITE_COUNT"
    echo "  Components: $COMPONENTS"
    [ "$NO_HTML" = false ] && echo "  D3:         $D3_SOURCE"
fi
