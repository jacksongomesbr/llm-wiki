#!/bin/bash
# convert-source.sh — Convert a non-markdown source into markdown for ingestion
# Usage: convert-source.sh <file> [--out <path>] [--raw-dir <dir>]
# Output: the path of the converted markdown file
# Exit: 0 on success, 1 on error, 2 if no converter is available
#
# `/wiki-ingest` reads markdown. Until now anything else — a PDF, a Word
# document, an EPUB, an HTML page saved to disk — was met with "convert it
# yourself first", which is the single largest piece of friction in getting real
# material into a wiki.
#
# This shells out to whichever converter is installed rather than bundling one:
#
#   .pdf          pdftotext (poppler), else pandoc
#   .docx .odt    pandoc
#   .epub         pandoc
#   .html .htm    pandoc
#   .rtf .tex     pandoc
#   .txt .md      copied through unchanged
#
# It deliberately does NOT fetch anything or install anything. If no converter
# is present it says exactly which one to install and exits 2, so a caller can
# distinguish "cannot" from "failed".

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

SRC=""
OUT=""
RAW_DIR="./.raw"

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            cat <<'USAGE'
Usage: convert-source.sh <file> [--out <path>] [--raw-dir <dir>]

Convert a non-markdown source into markdown so /wiki-ingest can read it.

Options:
  --out <path>     Write here instead of <raw-dir>/<name>.md
  --raw-dir <dir>  Destination directory (default: ./.raw)
  --help, -h       Show this help

Supported: pdf, docx, odt, epub, html, rtf, tex, txt, md
Requires pandoc (and pdftotext for the best PDF results).
Exit: 0 converted, 1 error, 2 no converter available
USAGE
            exit 0 ;;
        --out)     OUT="${2:-}"; shift 2 ;;
        --raw-dir) RAW_DIR="${2:-}"; shift 2 ;;
        *)
            if [ -z "$SRC" ]; then SRC="$1"; shift
            else echo "Unknown option: $1 (use --help for usage)" >&2; exit 1; fi ;;
    esac
done

[ -n "$SRC" ] || { echo "ERROR: no input file given (use --help)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "ERROR: '$SRC' does not exist" >&2; exit 1; }

BASE="$(basename "$SRC")"
STEM="${BASE%.*}"
EXT="$(printf '%s' "${BASE##*.}" | tr '[:upper:]' '[:lower:]')"

if [ -z "$OUT" ]; then
    mkdir -p "$RAW_DIR"
    OUT="$RAW_DIR/$(date -u +%Y-%m-%d)-$(printf '%s' "$STEM" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-60).md"
fi
mkdir -p "$(dirname "$OUT")"

have() { command -v "$1" >/dev/null 2>&1; }

need() {
    echo "ERROR: converting .$EXT requires $1, which is not installed." >&2
    echo "  install it, or convert the file by hand and drop the markdown in $RAW_DIR/" >&2
    exit 2
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

case "$EXT" in
    md|markdown|txt|text)
        cat "$SRC" > "$TMP"
        ;;
    pdf)
        # pdftotext -layout preserves column structure far better than pandoc's
        # PDF handling, which is why it is preferred here.
        if have pdftotext; then
            pdftotext -layout -enc UTF-8 "$SRC" "$TMP" || { echo "ERROR: pdftotext failed" >&2; exit 1; }
        elif have pandoc; then
            pandoc -f pdf -t markdown "$SRC" -o "$TMP" || { echo "ERROR: pandoc failed on the PDF" >&2; exit 1; }
        else
            need "pdftotext (poppler) or pandoc"
        fi
        ;;
    docx|odt|epub|rtf|tex|latex)
        have pandoc || need pandoc
        pandoc -t markdown --wrap=none "$SRC" -o "$TMP" || { echo "ERROR: pandoc failed" >&2; exit 1; }
        ;;
    html|htm)
        have pandoc || need pandoc
        pandoc -f html -t markdown --wrap=none "$SRC" -o "$TMP" || { echo "ERROR: pandoc failed" >&2; exit 1; }
        ;;
    *)
        echo "ERROR: no converter for '.$EXT'." >&2
        echo "  supported: pdf docx odt epub html rtf tex txt md" >&2
        exit 2
        ;;
esac

if [ ! -s "$TMP" ]; then
    echo "ERROR: conversion produced no text — the source may be a scanned image needing OCR" >&2
    exit 1
fi

# Provenance frontmatter, matching what archive-source.sh writes, so the
# converted file is an ordinary .raw source from here on.
{
    echo "---"
    echo "retrieved: $(date -u +%Y-%m-%d)"
    echo "retrieved_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "retrieved_by: /wiki-ingest (converted)"
    echo "topic: \"$STEM\""
    echo "sources:"
    echo "  - file://$(cd "$(dirname "$SRC")" && pwd)/$BASE"
    echo "converted_from: \"$EXT\""
    echo "original_sha256: \"$(sha256_file "$SRC")\""
    echo "---"
    echo ""
    cat "$TMP"
} > "$OUT"

# Path then hash, matching archive-source.sh. A caller piping to `head -1`
# closes stdout early; that SIGPIPE is expected, not an error.
{ echo "$OUT"; sha256_file "$OUT"; } 2>/dev/null || true
