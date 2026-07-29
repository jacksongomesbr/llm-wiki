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

    # One awk pass for every scalar field. Reading them one at a time spawned a
    # subshell and an awk per field per page, which dominated the runtime.
    {
        IFS= read -r title; IFS= read -r ptype; IFS= read -r pclass
        IFS= read -r pstatus; IFS= read -r summary; IFS= read -r lang
        IFS= read -r modified; IFS= read -r parea; IFS= read -r created
    } < <(fm_fields "$fm" title type class status summary language modified area created)
    [ -z "$title" ] && title="$slug"
    [ -z "$ptype" ] && ptype="concept"
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

# All degrees in one pass. Scanning the edge file once per node was O(n^2):
# 150 pages meant 300 full scans.
DEGREES="$TMP/degrees.tsv"       # slug \t inDegree \t outDegree
awk -F'\t' '
    NR == FNR { slug[$1] = 1; next }
    $3 == "link" { out[$1]++; in_[$2]++ }
    END { for (s in slug) printf "%s\t%d\t%d\n", s, in_[s] + 0, out[s] + 0 }
' "$SLUGS" "$EDGES" | sort > "$DEGREES"

# Citation in-degree for bibliography nodes, same single-pass treatment.
CITEDEG="$TMP/citedeg.tsv"
awk -F'\t' '$3 == "cite" { c[$2]++ } END { for (t in c) printf "%s\t%d\n", t, c[t] }' \
    "$EDGES" | sort > "$CITEDEG"

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

# Bibliography entries, flattened once so the emitter can stream them.
BIBTSV="$TMP/bib.tsv"
: > "$BIBTSV"
if [ -f "$WIKI_ROOT/references.bib" ]; then
    awk -v SEP="$SEP" '
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
    ' "$WIKI_ROOT/references.bib" > "$BIBTSV"
fi

# The whole document is written by one awk program. The previous emitter called
# json_escape per field per node — roughly thirteen subshells for every page,
# which was the single largest cost in the script.
awk -v SEP="$SEP" -v now="$NOW" -v components="$COMPONENTS" \
    -v degfile="$DEGREES" -v pinfile="$PINS" -v citefile="$CITEDEG" \
    -v bibfile="$BIBTSV" -v edgefile="$EDGES" '
    function jesc(v) {
        gsub(/\\/, "\\\\", v)
        gsub(/"/, "\\\"", v)
        gsub(/\t/, "\\t", v)
        gsub(/\r/, "\\r", v)
        return v
    }
    function jstr(v) { return "\"" jesc(v) "\"" }
    function jornull(v) { return v == "" ? "null" : jstr(v) }
    function reflist(csv,   n, parts, i, out) {
        if (csv == "") return ""
        n = split(csv, parts, ",")
        for (i = 1; i <= n; i++)
            if (parts[i] != "") out = out (out == "" ? "" : ", ") jstr(parts[i])
        return out
    }
    BEGIN {
        FS = SEP
        while ((getline line < degfile) > 0) {
            split(line, d, "\t"); indeg[d[1]] = d[2]; outdeg[d[1]] = d[3]
        }
        close(degfile)
        while ((getline line < pinfile) > 0) {
            split(line, d, "\t"); fx[d[1]] = d[2]; fy[d[1]] = d[3]
        }
        close(pinfile)
        while ((getline line < citefile) > 0) {
            split(line, d, "\t"); citedeg[d[1]] = d[2]
        }
        close(citefile)

        printf "{\n  \"generated\": %s,\n  \"components\": %s,\n  \"nodes\": [\n", jstr(now), components
        first = 1
    }
    {
        slug = $1; ptype = $2; pclass = $3; pstatus = $4; title = $5; summary = $6
        tags = $7; lang = $8; modified = $9; parea = $10; refs = $11
        created = $12; rel = $13
        if (slug == "") next
        if (title == "") title = slug
        if (ptype == "") ptype = "concept"
        i = indeg[slug] + 0; o = outdeg[slug] + 0

        if (!first) printf ",\n"; first = 0
        printf "    {\"id\": %s, \"title\": %s, \"type\": %s, \"class\": %s, \"status\": %s",
            jstr(slug), jstr(title), jstr(ptype), jornull(pclass), jornull(pstatus)
        printf ", \"summary\": %s, \"path\": %s, \"inDegree\": %d, \"outDegree\": %d, \"isHub\": %s",
            jstr(summary), jstr("../" rel), i, o, (i >= 5 ? "true" : "false")
        printf ", \"references\": [%s]", reflist(refs)
        printf ", \"frontmatter\": {\"language\": %s, \"created\": %s, \"modified\": %s, \"tags\": %s, \"area\": %s}",
            jstr(lang), jstr(created), jstr(modified), jstr(tags), jstr(parea)
        if (slug in fx) printf ", \"fx\": %s, \"fy\": %s", fx[slug], fy[slug]
        printf "}"
    }
    END {
        # Bibliography entries as a second node layer, namespaced `bib:` so they
        # can never collide with a page slug.
        while ((getline line < bibfile) > 0) {
            split(line, b, SEP)
            if (b[1] == "") continue
            id = "bib:" b[1]
            btitle = (b[2] == "" ? b[1] : b[2])
            if (!first) printf ",\n"; first = 0
            printf "    {\"id\": %s, \"title\": %s, \"type\": \"source\", \"class\": null, \"status\": null",
                jstr(id), jstr(btitle)
            printf ", \"summary\": %s, \"path\": %s, \"inDegree\": %d, \"outDegree\": 0, \"isHub\": false",
                jstr(b[3]), jornull(b[3]), citedeg[id] + 0
            printf ", \"references\": [], \"frontmatter\": {\"citekey\": %s, \"url\": %s}}",
                jstr(b[1]), jstr(b[3])
        }
        close(bibfile)

        printf "\n  ],\n  \"edges\": [\n"
        efirst = 1
        while ((getline line < edgefile) > 0) {
            split(line, e, "\t")
            if (e[1] == "") continue
            if (!efirst) printf ",\n"; efirst = 0
            printf "    {\"source\": %s, \"target\": %s, \"kind\": %s}",
                jstr(e[1]), jstr(e[2]), jstr(e[3])
        }
        close(edgefile)
        printf "\n  ]\n}\n"
    }
' "$NODES" > "$JSON"

if command -v jq >/dev/null 2>&1 && ! jq empty "$JSON" 2>/dev/null; then
    echo "ERROR: generated graph.json is not valid JSON" >&2
    exit 1
fi
cp "$JSON" "$META_DIR/graph.json"

# Record what the graph was built from. Without this the graph rots silently:
# only /wiki-graph rebuilds it, while every other workflow rebuilds the index.
mkdir -p "$META_DIR/cache"
wiki_frontmatter_hash "$WIKI_ROOT" > "$META_DIR/cache/graph-hash.txt"

# ── Render graph.html ───────────────────────────────────────────────────────

if [ "$NO_HTML" = true ]; then
    # The data changed but the view did not. Saying so beats leaving a file that
    # silently disagrees with graph.json.
    if [ -f "$META_DIR/graph.html" ] && [ "$QUIET" = false ]; then
        echo "NOTE: graph.html was left untouched and no longer matches graph.json." >&2
        echo "      Re-run without --no-html to refresh it." >&2
    fi
fi

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
