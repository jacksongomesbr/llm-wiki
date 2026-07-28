#!/bin/bash
# _utils.sh — Shared utility functions for LLM Wiki scripts
# Source this file from other scripts to avoid duplicating common functions.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"
#
# Everything here targets bash 3.2 (the macOS default) — no associative
# arrays, no `mapfile`, no `${var^^}`.

# ── Wiki discovery ──────────────────────────────────────────────────────────

# find_wiki_root — Locate the wiki directory
# Order: $LLM_WIKI_ROOT, then walk up from $PWD looking for `wiki/.llm-wiki`
# or a bare `.llm-wiki` marker. Walking up keeps scripts and hooks working when
# they are invoked from a subdirectory of the project.
# Returns the wiki root path on stdout, or empty string if not found.
find_wiki_root() {
    if [ -n "${LLM_WIKI_ROOT:-}" ] && [ -d "$LLM_WIKI_ROOT/.llm-wiki" ]; then
        echo "$LLM_WIKI_ROOT"
        return 0
    fi

    local dir
    dir="$(pwd -P)"
    while [ -n "$dir" ]; do
        if [ -d "$dir/wiki/.llm-wiki" ]; then
            echo "$dir/wiki"
            return 0
        fi
        if [ -d "$dir/.llm-wiki" ]; then
            echo "$dir"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done

    echo ""
}

# ── Hashing (portable) ──────────────────────────────────────────────────────

# sha256_stdin — Read stdin, print the SHA-256 hex digest.
# A stock macOS install has no `sha256sum`; `shasum -a 256` is always present.
sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        echo "ERROR: neither sha256sum nor shasum is available" >&2
        return 1
    fi
}

# sha256_file <file> — SHA-256 of a single file's contents.
sha256_file() {
    sha256_stdin < "$1"
}

# ── Page enumeration ────────────────────────────────────────────────────────

# wiki_pages <wiki_root> — Print NUL-delimited paths of all wiki pages.
#
# Prunes `.llm-wiki/` (metadata, not content) and skips `index.md`. The
# `-type f` test also excludes a symlinked index regardless of its name: an
# index symlinked into the wiki root used to be scanned as a content page, and
# because the index links every page under "By Tag", that silently defeated
# orphan detection entirely.
#
# Pages in subdirectories (e.g. `topics/`) are included; slugs stay flat.
wiki_pages() {
    local root="${1:-.}"
    find "$root" \
        -name '.llm-wiki' -type d -prune -o \
        -type f -name '*.md' ! -name 'index.md' -print0 2>/dev/null
}

# page_slug <file> — Filename minus directory and `.md`.
page_slug() {
    basename "$1" .md
}

# ── Frontmatter ─────────────────────────────────────────────────────────────

# extract_frontmatter <file> — Print the YAML frontmatter block, without the
# `---` fences.
#
# Only a block starting on line 1 counts. A range-based `sed -n '/^---$/,/^---$/p'`
# re-triggers on every `---` in the body — and a markdown horizontal rule is
# `---` — so body text parsed as frontmatter fields.
extract_frontmatter() {
    awk '
        NR == 1 && /^---[[:space:]]*$/ { inblock = 1; next }
        inblock && /^---[[:space:]]*$/ { exit }
        inblock { print }
    ' "$1" 2>/dev/null
}

# fm_field <frontmatter_text> <field> — Print a scalar field value.
# Strips surrounding quotes. Prints nothing when the field is absent.
fm_field() {
    printf '%s\n' "$1" | awk -v key="$2" '
        index($0, key ":") == 1 {
            sub("^" key ":[[:space:]]*", "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    '
}

# fm_list <frontmatter_text> <field> — Print list items one per line.
# Handles inline (`tags: [a, b]`) and block (`tags:\n  - a\n  - b`) forms.
fm_list() {
    printf '%s\n' "$1" | awk -v key="$2" '
        index($0, key ":") == 1 && !seen {
            seen = 1
            sub("^" key ":[[:space:]]*", "")
            if ($0 ~ /^\[/) {
                gsub(/[][]/, "")
                n = split($0, parts, /,[[:space:]]*/)
                for (i = 1; i <= n; i++) {
                    gsub(/^[[:space:]]*["'"'"']?|["'"'"']?[[:space:]]*$/, "", parts[i])
                    if (parts[i] != "") print parts[i]
                }
            } else if ($0 != "") {
                gsub(/^["'"'"']|["'"'"']$/, "")
                print
            } else {
                inlist = 1
            }
            next
        }
        inlist && /^[[:space:]]*-[[:space:]]/ {
            sub(/^[[:space:]]*-[[:space:]]*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            if ($0 != "") print
            next
        }
        inlist && /^[^[:space:]]/ { inlist = 0 }
    '
}

# ── Wikilinks ───────────────────────────────────────────────────────────────

# extract_links <file> — Print every [[wikilink]] target in the file, one per
# line, deduplicated.
#
# `[[a|label]]` yields `a`; `[[a#section]]` yields `a`; bare `[[#section]]` and
# external URLs are skipped. Fenced code blocks are ignored so that schema and
# template examples do not register as real links.
#
# The generated Backlinks block is skipped too. It is derived *from* the link
# graph, so counting it as part of the graph creates a feedback loop: A links
# to B, B gets a generated backlink to A, and now A and B point at each other
# and neither can ever be an orphan.
#
# A `sed 's/.*\[\[\(...\)\]\].*/\1/p'` only ever yields the LAST link on a
# line, because the leading `.*` is greedy. The schema mandates multi-link
# lines (evidence tables, "Related" lists), so that dropped most of the graph.
extract_links() {
    awk '
        /BACKLINKS:BEGIN/ { generated = 1; next }
        /BACKLINKS:END/   { generated = 0; next }
        generated { next }
        /^[[:space:]]*```/ { fenced = !fenced; next }
        fenced { next }
        {
            line = $0
            while (match(line, /\[\[[^][]+\]\]/)) {
                target = substr(line, RSTART + 2, RLENGTH - 4)
                line = substr(line, RSTART + RLENGTH)
                sub(/\|.*$/, "", target)
                sub(/#.*$/, "", target)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
                if (target != "" && target !~ /:\/\//) print target
            }
        }
    ' "$1" 2>/dev/null | sort -u
}

# ── Citations ───────────────────────────────────────────────────────────────

# extract_citations <file> — Print every inline [@citekey] in the file, one per
# line, deduplicated.
#
# Skips fenced code blocks and the generated Backlinks block, for the same
# reasons `extract_links` does: examples in code fences are not real citations,
# and generated content must not feed back into what generates it.
#
# Handles `[@key]`, `[@key, p. 4]` and `[see @key]`. An email-looking `[@foo]`
# inside a URL is not matched because a `(` or `:` cannot precede the bracket.
extract_citations() {
    awk '
        /BACKLINKS:BEGIN/ { generated = 1; next }
        /BACKLINKS:END/   { generated = 0; next }
        generated { next }
        /^[[:space:]]*```/ { fenced = !fenced; next }
        fenced { next }
        {
            line = $0
            while (match(line, /\[[^][]*@[A-Za-z][A-Za-z0-9_:.-]*/)) {
                chunk = substr(line, RSTART, RLENGTH)
                line = substr(line, RSTART + RLENGTH)
                sub(/^.*@/, "", chunk)
                # Trailing punctuation is prose, not part of the key.
                sub(/[.,;:]+$/, "", chunk)
                if (chunk != "") print chunk
            }
        }
    ' "$1" 2>/dev/null | sort -u
}

# normalise_url <url> — Canonical form used to decide whether two sources are
# the same. Deduplication is only as good as this function.
#
# Forces https, drops a leading www., removes the fragment, strips tracking
# parameters, and removes a trailing slash.
normalise_url() {
    printf '%s' "${1:-}" | awk '
        {
            u = $0
            sub(/^http:\/\//, "https://", u)
            if (u !~ /^https:\/\//) u = "https://" u
            sub(/^https:\/\/www\./, "https://", u)
            sub(/#.*$/, "", u)

            # Hosts are case-insensitive, paths are not — lowercase only the
            # authority, or two spellings of the same host look like two
            # different sources.
            rest = substr(u, 9)
            slash = index(rest, "/")
            if (slash > 0) {
                host = substr(rest, 1, slash - 1)
                path = substr(rest, slash)
            } else {
                host = rest
                path = ""
            }
            u = "https://" tolower(host) path

            # Strip tracking params, keeping any meaningful query behind.
            if (match(u, /\?/)) {
                base = substr(u, 1, RSTART - 1)
                query = substr(u, RSTART + 1)
                n = split(query, parts, "&")
                keep = ""
                for (i = 1; i <= n; i++) {
                    if (parts[i] ~ /^(utm_[^=]*|fbclid|gclid|mc_[ce]id|ref|source)=/) continue
                    if (parts[i] == "") continue
                    keep = (keep == "" ? parts[i] : keep "&" parts[i])
                }
                u = (keep == "" ? base : base "?" keep)
            }

            sub(/\/+$/, "", u)
            print u
        }
    '
}

# ── Aggregate hashes ────────────────────────────────────────────────────────

# wiki_frontmatter_hash <wiki_root> — Stable hash over every page's
# frontmatter, used to detect whether the index is stale with respect to the
# pages. Sorted by path so the result is order-independent.
wiki_frontmatter_hash() {
    local root="${1:-.}"
    local file
    while IFS= read -r -d '' file; do
        printf '%s\n' "$(page_slug "$file")"
        extract_frontmatter "$file"
    done < <(wiki_pages "$root" | sort -z) | sha256_stdin
}
