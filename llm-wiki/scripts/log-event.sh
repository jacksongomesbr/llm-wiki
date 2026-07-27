#!/bin/bash
# log-event.sh — Append an entry to the wiki's chronological log
# Usage: log-event.sh [wiki_root] --op <operation> --title <title> [--detail <text>]
# Exit: 0 on success, 1 on error
#
# index.md answers "what is in the wiki?"; log.md answers "what happened, and
# when?". The log is append-only and deliberately grep-friendly: every entry
# starts with `## [YYYY-MM-DD] op | title`, so
#
#   grep '^## \[' log.md | tail -5
#
# gives the five most recent events without any parsing.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

WIKI_ROOT=""
OP=""
TITLE=""
DETAIL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            echo "Usage: log-event.sh [wiki_root] --op <operation> --title <title> [--detail <text>]"
            echo "Append an entry to \$WIKI_ROOT/log.md."
            echo "  --op       Operation: ingest | query | lint | save | review | graph"
            echo "  --title    Short subject of the entry"
            echo "  --detail   Optional extra line"
            exit 0 ;;
        --op)     OP="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}"; shift 2 ;;
        --detail) DETAIL="${2:-}"; shift 2 ;;
        *)
            if [ -z "$WIKI_ROOT" ]; then
                WIKI_ROOT="$1"; shift
            else
                echo "Unknown option: $1 (use --help for usage)" >&2; exit 1
            fi ;;
    esac
done

if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi

if [ -z "$OP" ] || [ -z "$TITLE" ]; then
    echo "ERROR: --op and --title are required (use --help for usage)" >&2
    exit 1
fi

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 1
fi

LOG="$WIKI_ROOT/.llm-wiki/log.md"
mkdir -p "$(dirname "$LOG")"

if [ ! -f "$LOG" ]; then
    cat > "$LOG" << 'LOGEOF'
# Wiki Log / 维基日志
<!-- Append-only. Newest entries at the bottom. -->
<!-- Entry format: ## [YYYY-MM-DD] operation | title -->

LOGEOF
fi

{
    echo "## [$(date -u +%Y-%m-%d)] $OP | $TITLE"
    echo ""
    echo "- **Time:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    [ -n "$DETAIL" ] && echo "- $DETAIL"
    echo ""
} >> "$LOG"

echo "Logged: [$OP] $TITLE"
