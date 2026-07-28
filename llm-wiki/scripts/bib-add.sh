#!/bin/bash
# bib-add.sh — Add a source to the wiki bibliography, or return its existing key
# Usage: bib-add.sh --title <t> (--url <u> | --doi <d>) [options]
# Output: the citation key, on stdout
# Exit: 0 on success, 1 on error
#
# This is the ONLY writer of references.bib. Everything else reads it.
#
# Adding is idempotent: a source is identified by its DOI, or failing that by
# its normalised URL. If that identity is already present the existing key is
# printed and the file is left byte-identical. Re-running research over a
# source the wiki has already seen therefore cannot create a duplicate entry —
# the same guarantee the .done sentinels give ingest.
#
# Keys are never recomputed once emitted. Wiki pages cite them, so a key that
# shifted would silently break every page that used it.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

TYPE="online"
AUTHOR=""
TITLE=""
DATE=""
YEAR=""
URL=""
DOI=""
URLDATE=""
KEYWORDS=""
NOTE=""
INSTITUTION=""
GENRE=""
BIB=""
WIKI_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            cat <<'USAGE'
Usage: bib-add.sh --title <title> (--url <url> | --doi <doi>) [options]

Add a source to the wiki bibliography, or return the key it already has.
Prints the citation key on stdout.

Required:
  --title <text>     Source title
  --url <url>        Source URL          (one of --url / --doi required)
  --doi <doi>        DOI, without the https://doi.org/ prefix

Options:
  --type <type>      BibLaTeX entry type (default: online)
                     online | article | book | report | inproceedings | misc
  --author <text>    Author. Corporate names are brace-protected automatically
  --date <ISO>       Publication date, YYYY-MM-DD or YYYY-MM or YYYY
  --year <YYYY>      Publication year (used when --date is unknown)
  --urldate <ISO>    Retrieval date (default: today)
  --keywords <text>  Comma-separated, e.g. "primary-source"
  --institution <t>  Issuing body. BibLaTeX requires it for @report/@thesis
  --genre <text>     Report/thesis kind, e.g. "research guide". Defaults to the
                     entry type, which @report also requires
  --note <text>      Free-text note
  --bib <path>       Bibliography file (default: <wiki-root>/references.bib)
  --wiki-root <dir>  Wiki root (default: auto-detected, else ./wiki)
  --help, -h         Show this help
USAGE
            exit 0 ;;
        --type)      TYPE="${2:-}"; shift 2 ;;
        --author)    AUTHOR="${2:-}"; shift 2 ;;
        --title)     TITLE="${2:-}"; shift 2 ;;
        --date)      DATE="${2:-}"; shift 2 ;;
        --year)      YEAR="${2:-}"; shift 2 ;;
        --url)       URL="${2:-}"; shift 2 ;;
        --doi)       DOI="${2:-}"; shift 2 ;;
        --urldate)   URLDATE="${2:-}"; shift 2 ;;
        --keywords)  KEYWORDS="${2:-}"; shift 2 ;;
        --note)        NOTE="${2:-}"; shift 2 ;;
        --institution) INSTITUTION="${2:-}"; shift 2 ;;
        --genre)       GENRE="${2:-}"; shift 2 ;;
        --bib)       BIB="${2:-}"; shift 2 ;;
        --wiki-root) WIKI_ROOT="${2:-}"; shift 2 ;;
        *) echo "Unknown option: $1 (use --help for usage)" >&2; exit 1 ;;
    esac
done

if [ -z "$TITLE" ]; then
    echo "ERROR: --title is required" >&2
    exit 1
fi
if [ -z "$URL" ] && [ -z "$DOI" ]; then
    echo "ERROR: one of --url or --doi is required" >&2
    exit 1
fi

if [ -z "$BIB" ]; then
    if [ -z "$WIKI_ROOT" ]; then
        WIKI_ROOT="$(find_wiki_root)"
        WIKI_ROOT="${WIKI_ROOT:-./wiki}"
    fi
    BIB="$WIKI_ROOT/references.bib"
fi

mkdir -p "$(dirname "$BIB")"
if [ ! -f "$BIB" ]; then
    cat > "$BIB" <<'BIBEOF'
% references.bib — every external source this wiki draws on.
%
% Managed by llm-wiki/scripts/bib-add.sh. Entry contents may be edited by hand
% and will be preserved, but do NOT rename a citation key: wiki pages cite
% these keys, and validate-bib.sh will report the orphaned citations.

BIBEOF
fi

# ── Identity lookup ─────────────────────────────────────────────────────────

# Return the key of the entry matching this DOI or normalised URL, if any.
existing_key() {
    local want_doi="$1" want_url="$2"
    awk -v want_doi="$want_doi" -v want_url="$want_url" '
        /^[[:space:]]*@/ {
            # awk runs END even after exit, so clear the flag before leaving or
            # the key is printed twice.
            if (key != "" && matched) { print key; matched = 0; exit }
            key = $0
            sub(/^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*/, "", key)
            sub(/[[:space:]]*,.*$/, "", key)
            matched = 0
            next
        }
        /^[[:space:]]*doi[[:space:]]*=/ {
            v = $0
            sub(/^[^{]*\{/, "", v); sub(/\}.*$/, "", v)
            if (want_doi != "" && tolower(v) == tolower(want_doi)) matched = 1
            next
        }
        /^[[:space:]]*url[[:space:]]*=/ {
            v = $0
            sub(/^[^{]*\{/, "", v); sub(/\}.*$/, "", v)
            if (want_doi == "" && want_url != "" && v == want_url) matched = 1
            next
        }
        END { if (key != "" && matched) print key }
    ' "$BIB"
}

NORM_URL=""
[ -n "$URL" ] && NORM_URL="$(normalise_url "$URL")"

FOUND="$(existing_key "$DOI" "$NORM_URL")"
if [ -n "$FOUND" ]; then
    echo "$FOUND"
    exit 0
fi

# ── Key derivation ──────────────────────────────────────────────────────────

# ASCII-fold, strip everything that is not a letter or digit, lowercase.
slugify() {
    printf '%s' "${1:-}" \
        | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "${1:-}"
}
clean() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# Registrable name of a host: "news.microsoft.com" -> microsoft,
# "en.wikipedia.org" -> wikipedia, "example.co.uk" -> example.
#
# Strip the public suffix, then take the LAST remaining label — that is the
# registered name. Taking the first label yields the subdomain instead ("en").
host_name() {
    local host="$1" rest
    rest="${host%.*}"                       # drop the TLD
    case "$rest" in
        # A second-level public suffix (example.co.uk, foo.com.br): drop it too,
        # but only when something would remain.
        *.co|*.com|*.org|*.net|*.ac|*.gov|*.edu) rest="${rest%.*}" ;;
    esac
    [ -z "$rest" ] && rest="$host"
    printf '%s' "${rest##*.}"
}

# Author part: surname for a personal name, the leading word for an
# organisation, else the host's registrable name.
key_author() {
    local a
    a="$(slugify "$AUTHOR")"
    if [ -n "$a" ]; then
        if printf '%s' "$a" | grep -q ','; then
            # "Lastname, Firstname" — the surname is what matters.
            clean "${a%%,*}"
        elif printf '%s' "$a" \
            | grep -qiE '\b(corp|corporation|inc|incorporated|ltd|limited|llc|plc|gmbh|company|co|foundation|institute|university|college|press|news|group|association|society|council|committee|department|ministry|agency|bureau|office|centre|center|museum|library|organization|organisation|labs?|team|project|contributors|editors|staff|authors|collective|network|media|times|post|journal|review|magazine)\b\.?$'
        then
            # An organisation, however many words: "Microsoft Corporation" ->
            # microsoft. A two-word org would otherwise look like "First Last"
            # and yield the trailing word ("corporation").
            clean "${a%% *}"
        elif printf '%s' "$a" | grep -qE '^[A-Za-z.'"'"'-]+ [A-Za-z.'"'"'-]+$'; then
            # "Firstname Lastname" -> Lastname
            clean "${a##* }"
        else
            clean "${a%% *}"
        fi
        return
    fi
    if [ -n "$NORM_URL" ]; then
        local host
        host="$(printf '%s' "$NORM_URL" | sed 's|^https://||; s|/.*$||')"
        clean "$(host_name "$host")"
        return
    fi
    echo "anon"
}

key_year() {
    local y=""
    [ -n "$DATE" ] && y="$(printf '%s' "$DATE" | cut -c1-4)"
    [ -z "$y" ] && y="$YEAR"
    [ -z "$y" ] && y="$(printf '%s' "${URLDATE:-$(date -u +%Y)}" | cut -c1-4)"
    printf '%s' "$y" | tr -cd '0-9'
}

# First title word that carries meaning — skip articles and prepositions, and
# prefer a word of at least three characters so that a title like
# "R&D at 100%" yields "cost" rather than a bare "r".
key_word() {
    local words
    words="$(printf '%s' "$(slugify "$TITLE")" \
        | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | tr ' ' '\n' \
        | grep -vxE 'a|an|the|of|on|in|at|to|for|and|or|is|are|with|from|by|its|it' \
        | grep -vx '')"
    # Drop a leading word identical to the author part — "microsoft1997microsoft"
    # carries no more information than "microsoft1997".
    local author_part="$1"
    if [ -n "$author_part" ]; then
        words="$(printf '%s\n' "$words" | grep -vix "$author_part" || true)"
    fi

    local w
    # Prefer an alphabetic word of three or more characters, so a title like
    # "R&D at 100% cost_basis" gives "cost" rather than "100".
    w="$(printf '%s\n' "$words" | grep -E '^[a-z].{2,}$' | head -1)"
    [ -z "$w" ] && w="$(printf '%s\n' "$words" | grep -E '^.{3,}$' | head -1)"
    [ -z "$w" ] && w="$(printf '%s\n' "$words" | head -1)"
    printf '%s' "$w" | tr -cd 'a-z0-9'
}

AUTHOR_PART="$(key_author)"
BASE="$AUTHOR_PART$(key_year)$(key_word "$AUTHOR_PART")"
[ -z "$BASE" ] && BASE="source$(key_year)"

# Collision handling: append a, b, c … (biblatex convention). Only reached for
# a genuinely different source, since an identical one returned above.
key_taken() {
    grep -qE "^[[:space:]]*@[A-Za-z]+[[:space:]]*\{[[:space:]]*$1[[:space:]]*," "$BIB"
}

KEY="$BASE"
if key_taken "$KEY"; then
    for suffix in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
        if ! key_taken "$BASE$suffix"; then
            KEY="$BASE$suffix"
            break
        fi
    done
    if key_taken "$KEY"; then
        echo "ERROR: cannot find a free key for '$BASE' (a-z exhausted)" >&2
        exit 1
    fi
fi

# ── Emit ────────────────────────────────────────────────────────────────────

# BibTeX treats these as syntax; a raw & or % in a title breaks the file.
bibescape() {
    printf '%s' "${1:-}" | sed 's/\\/\\textbackslash{}/g; s/&/\\&/g; s/%/\\%/g; s/\$/\\$/g; s/#/\\#/g; s/_/\\_/g'
}

# A name with no comma and more than two words is an organisation, not a
# person. Double braces stop BibLaTeX parsing "Microsoft Corporation" as a
# first name and a surname.
format_author() {
    local a="$1"
    if printf '%s' "$a" | grep -q ','; then
        printf '%s' "$(bibescape "$a")"
    else
        printf '{%s}' "$(bibescape "$a")"
    fi
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat "$BIB" > "$TMP"

{
    echo "@$TYPE{$KEY,"
    [ -n "$AUTHOR" ]  && printf '  author   = {%s},\n' "$(format_author "$AUTHOR")"
    printf '  title    = {%s},\n' "$(bibescape "$TITLE")"
    if [ -n "$DATE" ]; then
        printf '  date     = {%s},\n' "$DATE"
    elif [ -n "$YEAR" ]; then
        printf '  year     = {%s},\n' "$YEAR"
    fi
    # BibLaTeX's data model makes `type` and `institution` mandatory on
    # @report and @thesis. Fall back to the author as the issuing body rather
    # than emitting an entry that biber rejects.
    case "$TYPE" in
        report|thesis|techreport)
            printf '  type     = {%s},\n' "$(bibescape "${GENRE:-$TYPE}")"
            printf '  institution = {%s},\n' "$(format_author "${INSTITUTION:-${AUTHOR:-Unknown}}")"
            ;;
        *)
            [ -n "$INSTITUTION" ] && printf '  institution = {%s},\n' "$(format_author "$INSTITUTION")"
            ;;
    esac
    [ -n "$DOI" ]      && printf '  doi      = {%s},\n' "$DOI"
    [ -n "$NORM_URL" ] && printf '  url      = {%s},\n' "$NORM_URL"
    printf '  urldate  = {%s},\n' "${URLDATE:-$(date -u +%Y-%m-%d)}"
    [ -n "$KEYWORDS" ] && printf '  keywords = {%s},\n' "$KEYWORDS"
    [ -n "$NOTE" ]     && printf '  note     = {%s},\n' "$(bibescape "$NOTE")"
    echo "}"
    echo ""
} >> "$TMP"

mv "$TMP" "$BIB"
trap - EXIT

echo "$KEY"
