#!/bin/bash
# archive-source.sh — Archive fetched web content into .raw/ with provenance
# Usage: archive-source.sh --topic <topic> --slug <slug> --url <url> [--url <url>...]
#                          [--raw-dir <dir>] [--note <text>] [--primary]
#        (content is read from stdin)
# Output: the archived path and its SHA-256, one per line
# Exit: 0 on success, 1 on error
#
# The wiki's three-layer model depends on `.raw/` holding immutable sources.
# Web research breaks that unless the fetched bytes are written down: a
# `source_url` alone rots, and there is nothing to hash, so ingest sentinels
# cannot make the operation idempotent.
#
# This writes the content to a dated file with provenance frontmatter and
# prints the hash, so /wiki-ingest can proceed exactly as it does for a file
# the user dropped in by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

TOPIC=""
SLUG=""
URLS=()
RAW_DIR="./.raw"
NOTE=""
PRIMARY=false
CITE_KEYS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            cat <<'USAGE'
Usage: archive-source.sh --topic <topic> --slug <slug> --url <url> [options]
       (content is read from stdin)

Archive fetched web content into .raw/ with provenance frontmatter.

Options:
  --topic <text>   Subject of the research (required)
  --slug <text>    Filename slug; the file becomes .raw/YYYY-MM-DD-<slug>.md (required)
  --url <url>      Source URL. Repeat for multiple sources (at least one required)
  --raw-dir <dir>  Destination directory (default: ./.raw)
  --note <text>    Retrieval caveat, e.g. "paywalled, abstract only"
  --primary        Mark this source as a primary document
  --cite-key <key> Bibliography key from bib-add.sh. Repeat for several.
  --help, -h       Show this help

Prints the archived path and its SHA-256.
USAGE
            exit 0 ;;
        --topic)   TOPIC="${2:-}"; shift 2 ;;
        --slug)    SLUG="${2:-}"; shift 2 ;;
        --url)     URLS+=("${2:-}"); shift 2 ;;
        --raw-dir) RAW_DIR="${2:-}"; shift 2 ;;
        --note)    NOTE="${2:-}"; shift 2 ;;
        --primary) PRIMARY=true; shift ;;
        --cite-key) CITE_KEYS+=("${2:-}"); shift 2 ;;
        *) echo "Unknown option: $1 (use --help for usage)" >&2; exit 1 ;;
    esac
done

if [ -z "$TOPIC" ] || [ -z "$SLUG" ] || [ "${#URLS[@]}" -eq 0 ]; then
    echo "ERROR: --topic, --slug and at least one --url are required" >&2
    exit 1
fi

if [ -t 0 ]; then
    echo "ERROR: no content on stdin — pipe the fetched text in" >&2
    exit 1
fi

# Normalise the slug so it can never escape the directory or collide with the
# date prefix convention.
SLUG="$(printf '%s' "$SLUG" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' \
    | cut -c1-60)"

if [ -z "$SLUG" ]; then
    echo "ERROR: --slug reduced to an empty string after normalisation" >&2
    exit 1
fi

mkdir -p "$RAW_DIR"
DATE="$(date -u +%Y-%m-%d)"
DEST="$RAW_DIR/$DATE-$SLUG.md"

CONTENT="$(cat)"
if [ -z "$CONTENT" ]; then
    echo "ERROR: stdin was empty" >&2
    exit 1
fi

{
    echo "---"
    echo "retrieved: $DATE"
    echo "retrieved_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "retrieved_by: /wiki-research"
    echo "topic: \"$TOPIC\""
    [ "$PRIMARY" = true ] && echo "primary_source: true"
    echo "sources:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
    if [ "${#CITE_KEYS[@]}" -gt 0 ]; then
        # Recorded so ingest can copy them into each page's `references:` list
        # without re-deriving anything.
        echo "cite_keys:"
        for k in "${CITE_KEYS[@]}"; do
            echo "  - $k"
        done
    fi
    [ -n "$NOTE" ] && echo "note: \"$NOTE\""
    echo "---"
    echo ""
    printf '%s\n' "$CONTENT"
} > "$DEST"

HASH="$(sha256_file "$DEST")"

echo "$DEST"
echo "$HASH"
