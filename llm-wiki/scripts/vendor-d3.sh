#!/bin/bash
# vendor-d3.sh — Download D3 into the wiki so the knowledge graph works offline
# Usage: vendor-d3.sh [wiki_root]
# Exit: 0 on success, 1 on error
#
# graph.html otherwise loads D3 from a CDN, which means the "self-contained"
# graph does not open on a plane, and a compromised CDN would execute arbitrary
# code in a file the user trusts. Vendoring once removes both problems; the CDN
# fallback in graph.html is pinned with Subresource Integrity for anyone who
# skips this.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

D3_URL="https://d3js.org/d3.v7.min.js"
D3_SRI="sha384-CjloA8y00+1SDAUkjs099PVfnY2KmDC2BZnws9kh8D/lX1s46w6EPhpXdqMfjK6i"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: vendor-d3.sh [wiki_root]"
    echo "Download D3 v7 into <wiki_root>/.llm-wiki/vendor/ for offline graphs."
    echo "Verifies the download against a pinned SHA-384."
    exit 0
fi

WIKI_ROOT="${1:-}"
if [ -z "$WIKI_ROOT" ]; then
    WIKI_ROOT="$(find_wiki_root)"
    WIKI_ROOT="${WIKI_ROOT:-./wiki}"
fi
[ -d "$WIKI_ROOT" ] || { echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

VENDOR="$WIKI_ROOT/.llm-wiki/vendor"
mkdir -p "$VENDOR"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Downloading $D3_URL ..."
curl -sSL --max-time 60 "$D3_URL" -o "$TMP"

GOT="sha384-$(openssl dgst -sha384 -binary "$TMP" | openssl base64 -A)"
if [ "$GOT" != "$D3_SRI" ]; then
    echo "ERROR: integrity check failed — refusing to vendor the file." >&2
    echo "  expected: $D3_SRI" >&2
    echo "  got:      $GOT" >&2
    exit 1
fi

mv "$TMP" "$VENDOR/d3.v7.min.js"
trap - EXIT
echo "Vendored: $VENDOR/d3.v7.min.js"
echo "Integrity verified against the pinned SHA-384."
echo "Regenerate the graph with /wiki-graph to use it."
