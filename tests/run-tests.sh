#!/bin/bash
# run-tests.sh — Behavioural test suite for the LLM Wiki scripts
# Usage: ./tests/run-tests.sh [name-filter]
# Exit: 0 = all passed, 1 = one or more failed
#
# No external dependencies (no bats) so CI and contributors can run it as-is.
#
# Every test builds a throwaway wiki that is *supposed* to fail a check, then
# asserts the check actually reports it. The previous CI only ran each script
# against a valid wiki and asserted exit 0 — which is why orphan detection,
# multi-link parsing, the tags check and the staleness baseline could all be
# completely broken while the pipeline stayed green.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PROJECT_ROOT/llm-wiki/scripts"
FILTER="${1:-}"

PASS=0
FAIL=0
FAILED_NAMES=""

# ── Assertions ──────────────────────────────────────────────────────────────

fail() {
    printf '  \033[0;31m✗\033[0m %s\n' "$1"
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES
  - $CURRENT_TEST: $1"
}

pass() {
    printf '  \033[0;32m✓\033[0m %s\n' "$1"
    PASS=$((PASS + 1))
}

assert_contains() {
    # assert_contains <haystack> <needle> <description>
    case "$1" in
        *"$2"*) pass "$3" ;;
        *)      fail "$3 — expected output to contain '$2', got: $(printf '%s' "$1" | head -5 | tr '\n' '/')" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3 — output unexpectedly contains '$2'" ;;
        *)      pass "$3" ;;
    esac
}

assert_eq() {
    # assert_eq <actual> <expected> <description>
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 — expected '$2', got '$1'"
    fi
}

CURRENT_TEST=""
describe() {
    CURRENT_TEST="$1"
    printf '\n\033[1m%s\033[0m\n' "$1"
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

new_wiki() {
    # Prints the path of a fresh initialised wiki root.
    local dir
    dir="$(mktemp -d)"
    TMPDIRS="$TMPDIRS $dir"
    bash "$SCRIPTS/init-wiki.sh" "$dir/wiki" >/dev/null 2>&1
    echo "$dir/wiki"
}

valid_page() {
    # valid_page <root> <slug> <body>
    local root="$1" slug="$2" body="$3"
    cat > "$root/$slug.md" <<EOF
---
title: "${slug}"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "page ${slug}"
---
# ${slug}
${body}
EOF
}

TMPDIRS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { for d in $TMPDIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

should_run() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

# ════════════════════════════════════════════════════════════════════════════
# find-orphans.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "orphans"; then
describe "find-orphans.sh"

W="$(new_wiki)"
valid_page "$W" "hub" "Links to [[leaf]]."
valid_page "$W" "leaf" "A leaf."
valid_page "$W" "lonely" "Nobody links here."
OUT="$(bash "$SCRIPTS/find-orphans.sh" "$W" 2>&1)"
assert_contains "$OUT" "ORPHAN: lonely" "reports a page with no inbound links"
assert_not_contains "$OUT" "ORPHAN: leaf" "does not report a linked page"

# Regression: the generated index links every page under "By Tag". When the
# index was symlinked into the wiki root it was scanned as a link source, so
# every page looked reachable and this check silently always passed.
bash "$SCRIPTS/build-index.sh" "$W" --quiet
OUT="$(bash "$SCRIPTS/find-orphans.sh" "$W" 2>&1)"
assert_contains "$OUT" "ORPHAN: lonely" "still reports orphans after the index is generated"

W="$(new_wiki)"
valid_page "$W" "selfish" "I link to [[selfish]] myself."
OUT="$(bash "$SCRIPTS/find-orphans.sh" "$W" 2>&1)"
assert_contains "$OUT" "ORPHAN: selfish" "a self-link does not rescue a page from orphanhood"

W="$(new_wiki)"
valid_page "$W" "target" "I am reachable."
cat > "$W/aliased.md" <<'EOF'
---
title: "Aliased"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
aliases: [nickname]
summary: "reachable via alias"
---
# Aliased
EOF
valid_page "$W" "source" "Reaches [[nickname]] and [[target]]."
OUT="$(bash "$SCRIPTS/find-orphans.sh" "$W" 2>&1)"
assert_not_contains "$OUT" "ORPHAN: aliased" "a link via alias counts as inbound"
fi

# ════════════════════════════════════════════════════════════════════════════
# find-broken-links.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "broken"; then
describe "find-broken-links.sh"

W="$(new_wiki)"
valid_page "$W" "real" "I exist."
# Regression: a greedy `.*\[\[...\]\].*` sed only ever captured the LAST link
# on a line. The schema mandates multi-link rows (evidence tables, "Related"
# lists), so most broken links went unreported.
valid_page "$W" "table" "| [[gone-a]] | [[real]] | [[gone-b]] |"
OUT="$(bash "$SCRIPTS/find-broken-links.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "[[gone-a]]" "detects the FIRST broken link on a multi-link line"
assert_contains "$OUT" "[[gone-b]]" "detects the LAST broken link on a multi-link line"
assert_not_contains "$OUT" "[[real]]" "does not flag a valid link"
assert_eq "$RC" "1" "exits 1 when broken links are found"

W="$(new_wiki)"
valid_page "$W" "a" "Link to [[b]]."
valid_page "$W" "b" "Link to [[a]]."
OUT="$(bash "$SCRIPTS/find-broken-links.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "OK:" "reports OK on a clean wiki"
assert_eq "$RC" "0" "exits 0 on a clean wiki"

W="$(new_wiki)"
valid_page "$W" "labelled" "See [[real|a nicer label]] and [[real#a-section]]."
valid_page "$W" "real" "I exist."
OUT="$(bash "$SCRIPTS/find-broken-links.sh" "$W" 2>&1)"
assert_contains "$OUT" "OK:" "resolves [[slug|label]] and [[slug#anchor]] forms"

W="$(new_wiki)"
valid_page "$W" "real" "I exist."
cat > "$W/fenced.md" <<'EOF'
---
title: "Fenced"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "has a code block"
---
# Fenced
Links to [[real]].

```markdown
[[this-is-an-example-not-a-link]]
```
EOF
OUT="$(bash "$SCRIPTS/find-broken-links.sh" "$W" 2>&1)"
assert_not_contains "$OUT" "this-is-an-example" "ignores wikilinks inside fenced code blocks"
fi

# ════════════════════════════════════════════════════════════════════════════
# validate-frontmatter.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "frontmatter"; then
describe "validate-frontmatter.sh"

# Regression: the tags check was `[ -z "$val" ] || [ "$val" = "[]" ] && [ "$field" != "tags" ]`
# which parses as (A||B) && C — always false for tags, so tags were never checked.
W="$(new_wiki)"
cat > "$W/no-tags.md" <<'EOF'
---
title: "No Tags"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
summary: "missing the tags field entirely"
---
# No Tags
EOF
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "Missing required field 'tags'" "reports a missing tags field"

W="$(new_wiki)"
cat > "$W/empty-tags.md" <<'EOF'
---
title: "Empty Tags"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: []
summary: "tags present but empty"
---
# Empty Tags
EOF
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "'tags' is empty" "reports an empty tags list"

# Regression: `sed -n '/^---$/,/^---$/p'` re-triggers on every `---` in the
# body, and a markdown horizontal rule is `---`, so body text parsed as
# frontmatter fields.
W="$(new_wiki)"
cat > "$W/hrule.md" <<'EOF'
---
title: "Has A Horizontal Rule"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "valid page with a --- rule in the body"
---
# Has A Horizontal Rule

Some prose.

---

type: not-a-real-field
language: klingon
EOF
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "OK:" "a body horizontal rule is not parsed as frontmatter"
assert_eq "$RC" "0" "exits 0 for a valid page containing a horizontal rule"

W="$(new_wiki)"
cat > "$W/bad.md" <<'EOF'
---
title: "Bad"
type: wobbly
language: klingon
created: 01-01-2026
modified: 2026-01-01
tags: [test]
summary: "invalid enum values and date"
---
# Bad
EOF
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "Invalid type 'wobbly'" "rejects an unknown page type"
assert_contains "$OUT" "Invalid language 'klingon'" "rejects an unknown language"
assert_contains "$OUT" "Invalid date format" "rejects a non-ISO date"

W="$(new_wiki)"
printf '# No Frontmatter At All\n' > "$W/bare.md"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "No frontmatter found" "reports a page with no frontmatter"
fi

# ════════════════════════════════════════════════════════════════════════════
# check-stale.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "stale"; then
describe "check-stale.sh"

# Regression: nothing ever wrote cache/index-hash.txt, so this could only ever
# return exit 2 — "fresh" was unreachable.
W="$(new_wiki)"
valid_page "$W" "one" "Content."
bash "$SCRIPTS/build-index.sh" "$W" --quiet
OUT="$(bash "$SCRIPTS/check-stale.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "FRESH" "reports FRESH right after the index is built"
assert_eq "$RC" "0" "exits 0 when fresh"

valid_page "$W" "two" "Added after the index was built."
OUT="$(bash "$SCRIPTS/check-stale.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "STALE" "reports STALE after a page is added"
assert_eq "$RC" "1" "exits 1 when stale"

bash "$SCRIPTS/check-stale.sh" "$W" --store >/dev/null 2>&1
OUT="$(bash "$SCRIPTS/check-stale.sh" "$W" 2>&1)"
assert_contains "$OUT" "FRESH" "--store records a new baseline"

W="$(new_wiki)"
rm -f "$W/.llm-wiki/cache/index-hash.txt"
bash "$SCRIPTS/check-stale.sh" "$W" >/dev/null 2>&1
assert_eq "$?" "2" "exits 2 when no baseline has been recorded"
fi

# ════════════════════════════════════════════════════════════════════════════
# build-index.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "index"; then
describe "build-index.sh"

W="$(new_wiki)"
valid_page "$W" "hub" "Links to [[leaf]] and [[person-x]]."
valid_page "$W" "leaf" "A leaf."
cat > "$W/person-x.md" <<'EOF'
---
title: "Person X"
type: person
language: zh
created: 2026-01-01
modified: 2026-02-02
tags: [people, test]
summary: "a person"
---
# Person X
EOF
valid_page "$W" "lonely" "Nobody links here."
bash "$SCRIPTS/build-index.sh" "$W" --quiet
IDX="$(cat "$W/.llm-wiki/index.md")"

assert_contains "$IDX" "**Total pages:** 4" "counts every page"
assert_contains "$IDX" "| [[hub]] |" "lists pages in the All Pages table"
assert_contains "$IDX" "### people" "groups pages by tag"
assert_contains "$IDX" "[[lonely]]" "lists orphans"
assert_contains "$IDX" "person" "records the page type"
assert_contains "$IDX" "zh" "records the page language"

ORPHAN_SECTION="$(sed -n '/^## Orphan Pages/,/^## Review Queue/p' <<< "$IDX")"
assert_not_contains "$ORPHAN_SECTION" "[[leaf]]" "does not list a linked page as an orphan"

assert_eq "$([ -f "$W/.llm-wiki/cache/index-hash.txt" ] && echo yes || echo no)" "yes" \
    "writes the staleness baseline"

# The index must never appear in the wiki root — that is what defeated orphan
# detection in the first place.
assert_eq "$([ -e "$W/index.md" ] && echo present || echo absent)" "absent" \
    "does not create wiki/index.md"

W="$(new_wiki)"
bash "$SCRIPTS/build-index.sh" "$W" --quiet
IDX="$(cat "$W/.llm-wiki/index.md")"
assert_contains "$IDX" "**Total pages:** 0" "handles an empty wiki"

W="$(new_wiki)"
cat > "$W/piped.md" <<'EOF'
---
title: "Title | With A Pipe"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "summary | with a pipe"
---
# Piped
EOF
bash "$SCRIPTS/build-index.sh" "$W" --quiet
IDX="$(cat "$W/.llm-wiki/index.md")"
assert_contains "$IDX" 'Title \| With A Pipe' "escapes pipes so the markdown table survives"
fi

# ════════════════════════════════════════════════════════════════════════════
# _utils.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "utils"; then
describe "_utils.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../llm-wiki/scripts/_utils.sh
source "$SCRIPTS/_utils.sh"

D="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D"
cat > "$D/multi.md" <<'EOF'
---
title: "Multi"
---
| [[alpha]] | [[beta|label]] | [[gamma#sec]] |
EOF
LINKS="$(extract_links "$D/multi.md" | tr '\n' ' ')"
assert_eq "$LINKS" "alpha beta gamma " "extract_links returns every link on a line"

cat > "$D/fm.md" <<'EOF'
---
title: "Real Title"
tags: [a, b]
aliases:
  - first
  - "second one"
---
# Body

---

title: "Fake Title"
EOF
FM="$(extract_frontmatter "$D/fm.md")"
assert_eq "$(fm_field "$FM" title)" "Real Title" "extract_frontmatter stops at the first closing fence"
assert_eq "$(fm_list "$FM" tags | tr '\n' ' ')" "a b " "fm_list parses inline arrays"
assert_eq "$(fm_list "$FM" aliases | tr '\n' ' ')" "first second one " "fm_list parses block lists"

assert_eq "$(printf 'x' | sha256_stdin)" \
    "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" \
    "sha256_stdin matches the known digest of 'x'"

# find_wiki_root must work from a subdirectory, not just the project root.
D2="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D2"
mkdir -p "$D2/wiki/.llm-wiki" "$D2/deep/nested"
FOUND="$(cd "$D2/deep/nested" && find_wiki_root)"
assert_eq "$(basename "$FOUND")" "wiki" "find_wiki_root walks up from a subdirectory"
fi

# ════════════════════════════════════════════════════════════════════════════
# update-backlinks.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "backlinks"; then
describe "update-backlinks.sh"

W="$(new_wiki)"
valid_page "$W" "hub" "Links to [[leaf]] twice: [[leaf]] and [[leaf|again]]."
valid_page "$W" "leaf" "A leaf."
bash "$SCRIPTS/update-backlinks.sh" "$W" --quiet
assert_contains "$(cat "$W/leaf.md")" "- [[hub]]" "writes a backlink onto the linked page"
assert_contains "$(cat "$W/hub.md")" "No pages link here yet" "notes when a page has no backlinks"
assert_eq "$(grep -c '\[\[hub\]\]' "$W/leaf.md")" "1" "deduplicates repeated links from the same page"

# Regression: the generated Backlinks block must not itself be read as part of
# the link graph — otherwise A→B produces B→A and nothing is ever an orphan.
bash "$SCRIPTS/update-backlinks.sh" "$W" --quiet
OUT="$(bash "$SCRIPTS/update-backlinks.sh" "$W" --check 2>&1)"
RC=$?
assert_contains "$OUT" "OK:" "is idempotent on a second run"
assert_eq "$RC" "0" "--check exits 0 when nothing would change"

OUT="$(bash "$SCRIPTS/find-orphans.sh" "$W" 2>&1)"
assert_contains "$OUT" "ORPHAN: hub" "generated backlinks do not mask orphans"

valid_page "$W" "newcomer" "Also links to [[leaf]]."
OUT="$(bash "$SCRIPTS/update-backlinks.sh" "$W" --check 2>&1)"
RC=$?
assert_contains "$OUT" "OUTDATED: leaf" "--check reports a page whose backlinks drifted"
assert_eq "$RC" "1" "--check exits 1 when pages are out of date"

BEFORE="$(grep -c 'A leaf' "$W/leaf.md")"
bash "$SCRIPTS/update-backlinks.sh" "$W" --quiet
assert_eq "$(grep -c 'A leaf' "$W/leaf.md")" "$BEFORE" "rewriting the block leaves the rest of the page intact"
fi

# ════════════════════════════════════════════════════════════════════════════
# log-event.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "log"; then
describe "log-event.sh"

W="$(new_wiki)"
bash "$SCRIPTS/log-event.sh" "$W" --op ingest --title "source-a.md" --detail "3 pages" >/dev/null
bash "$SCRIPTS/log-event.sh" "$W" --op query --title "a question" >/dev/null
LOG="$W/.llm-wiki/log.md"
assert_eq "$([ -f "$LOG" ] && echo yes || echo no)" "yes" "creates log.md on first use"
assert_eq "$(grep -c '^## \[' "$LOG")" "2" "appends one heading per event"
assert_contains "$(cat "$LOG")" "ingest | source-a.md" "records the operation and title"
assert_contains "$(cat "$LOG")" "3 pages" "records the optional detail"

bash "$SCRIPTS/log-event.sh" "$W" --op lint --title "third" >/dev/null
assert_contains "$(grep '^## \[' "$LOG" | tail -1)" "third" "newest entry is last (append-only)"

bash "$SCRIPTS/log-event.sh" "$W" --title "no op given" >/dev/null 2>&1
assert_eq "$?" "1" "requires --op"
fi

# ════════════════════════════════════════════════════════════════════════════
# archive-source.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "archive"; then
describe "archive-source.sh"

D="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D"
OUT="$(printf 'Fetched body text.\n' | bash "$SCRIPTS/archive-source.sh" \
    --topic "Test Topic" --slug "test-source" \
    --url "https://example.com/a" --url "https://example.com/b" \
    --raw-dir "$D/raw" --primary --note "partial fetch" 2>&1)"
ARCHIVED="$(printf '%s' "$OUT" | head -1)"
HASH="$(printf '%s' "$OUT" | tail -1)"

assert_eq "$([ -f "$ARCHIVED" ] && echo yes || echo no)" "yes" "writes the archived file"
assert_contains "$ARCHIVED" "-test-source.md" "names the file with a date prefix and slug"
BODY="$(cat "$ARCHIVED")"
assert_contains "$BODY" "Fetched body text." "preserves the piped content"
assert_contains "$BODY" "https://example.com/a" "records every source URL"
assert_contains "$BODY" "https://example.com/b" "records repeated --url flags"
assert_contains "$BODY" "primary_source: true" "marks primary sources"
assert_contains "$BODY" 'note: "partial fetch"' "records the retrieval note"
assert_eq "${#HASH}" "64" "prints a SHA-256 of the archived file"
assert_eq "$HASH" "$(bash -c "source '$SCRIPTS/_utils.sh'; sha256_file '$ARCHIVED'")" \
    "the printed hash matches the file (usable as an ingest sentinel)"

# The slug becomes a filename, so it must not be able to escape the directory.
printf 'x\n' | bash "$SCRIPTS/archive-source.sh" --topic T --slug "../../etc/passwd" \
    --url "https://example.com" --raw-dir "$D/raw2" >/dev/null 2>&1
assert_eq "$(find "$D/raw2" -name '*.md' | wc -l | tr -d ' ')" "1" "normalises a path-traversal slug"
assert_eq "$([ -e "$D/raw2/../../etc/passwd" ] && echo escaped || echo contained)" "contained" \
    "cannot write outside the raw directory"

printf '' | bash "$SCRIPTS/archive-source.sh" --topic T --slug s --url u --raw-dir "$D/raw3" >/dev/null 2>&1
assert_eq "$?" "1" "rejects empty stdin"

printf 'x\n' | bash "$SCRIPTS/archive-source.sh" --topic T --raw-dir "$D/raw4" >/dev/null 2>&1
assert_eq "$?" "1" "requires --slug and --url"
fi

# ════════════════════════════════════════════════════════════════════════════
# bib-add.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "bib-add"; then
describe "bib-add.sh"

D="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D"
F="$D/references.bib"
add() { bash "$SCRIPTS/bib-add.sh" --bib "$F" "$@"; }

K1="$(add --author "Microsoft Corporation" --title "Microsoft and Apple Affirm Commitment" \
        --date 1997-08-06 --url "https://news.microsoft.com/source/1997/08/06/ms-apple/")"
assert_eq "$K1" "microsoft1997apple" "corporate author yields authorYEARword"

K2="$(add --title "Steve Jobs" --date 2026 --url "https://en.wikipedia.org/wiki/Steve_Jobs")"
assert_eq "$K2" "wikipedia2026steve" "falls back to the host registrable name, not the subdomain"

K3="$(add --author "Doe, Jane" --title "A Study of Things" --year 2021 --url "https://example.com/study")"
assert_eq "$K3" "doe2021study" "surname-first personal author"

K4="$(add --author "Jane Doe" --title "Another Paper" --year 2022 --url "https://example.com/paper")"
assert_eq "$K4" "doe2022another" "firstname-lastname personal author"

# Idempotency is what stops re-running research from duplicating entries.
BEFORE="$(cat "$F")"
K2B="$(add --title "Steve Jobs" --date 2026 --url "http://www.en.wikipedia.org/wiki/Steve_Jobs/?utm_campaign=x")"
assert_eq "$K2B" "$K2" "re-adding the same URL returns the existing key"
assert_eq "$(cat "$F")" "$BEFORE" "re-adding writes nothing to the file"

KD1="$(add --title "Paper With DOI" --doi "10.1234/abc.def" --year 2019 --url "https://publisher.example/a")"
KD2="$(add --title "Paper With DOI, mirror" --doi "10.1234/ABC.DEF" --year 2019 --url "https://mirror.example/b")"
assert_eq "$KD2" "$KD1" "DOI wins over URL for identity, case-insensitively"

KC="$(add --title "Steve Jobs" --date 2026 --url "https://wikipedia.org/elsewhere/Steve_Jobs")"
assert_eq "$KC" "${K2}a" "a genuinely different source collides to an a-suffix"

KE="$(add --title "R&D at 100% cost_basis" --year 2020 --url "https://example.com/rd")"
assert_contains "$(cat "$F")" 'R\&D at 100\% cost\_basis' "escapes BibTeX special characters"
assert_eq "$KE" "example2020cost" "skips numeric and stopword title words"

assert_contains "$(cat "$F")" "author   = {{Microsoft Corporation}}" \
    "brace-protects corporate authors so BibLaTeX keeps them intact"
assert_contains "$(cat "$F")" "url      = {https://news.microsoft.com/source/1997/08/06/ms-apple}" \
    "stores the normalised URL"

bash "$SCRIPTS/bib-add.sh" --bib "$F" --title "No Locator" >/dev/null 2>&1
assert_eq "$?" "1" "requires --url or --doi"
fi

# ════════════════════════════════════════════════════════════════════════════
# validate-bib.sh
# ════════════════════════════════════════════════════════════════════════════

if should_run "validate-bib"; then
describe "validate-bib.sh"

W="$(new_wiki)"
KEY="$(bash "$SCRIPTS/bib-add.sh" --bib "$W/references.bib" --title "Steve Jobs" \
       --date 2026 --url "https://en.wikipedia.org/wiki/Steve_Jobs")"

cited_page() {
    cat > "$W/$1.md" <<EOF
---
title: "$1"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "page $1"
references: [$2]
---
# $1
$3
EOF
}

cited_page cites "$KEY" "A sourced claim [@$KEY]."
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "OK:" "clean wiki passes"
assert_eq "$RC" "0" "exits 0 when everything resolves"

cited_page dangling "nosuch2020key" "Cites nothing real [@nosuch2020key]."
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "has no entry" "reports a dangling citation"
assert_eq "$RC" "1" "exits 1 on a dangling citation"
rm "$W/dangling.md"

cited_page drift "" "Body cites [@$KEY] but frontmatter does not."
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W" 2>&1)"
assert_contains "$OUT" "missing from references:" "reports frontmatter/body drift"
rm "$W/drift.md"

bash "$SCRIPTS/bib-add.sh" --bib "$W/references.bib" --title "Nobody Cites Me" \
     --year 2020 --url "https://example.com/uncited" >/dev/null
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W" 2>&1)"
assert_contains "$OUT" "not cited by any page" "reports an orphan bibliography entry"

printf '@online{dupe,\n  title = {A},\n  url = {https://a.example},\n}\n@online{dupe,\n  title = {B},\n  url = {https://b.example},\n}\n' \
    >> "$W/references.bib"
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W" 2>&1)"
assert_contains "$OUT" "duplicate citation key" "reports duplicate keys"

W2="$(new_wiki)"
valid_page "$W2" "plain" "No citations at all."
OUT="$(bash "$SCRIPTS/validate-bib.sh" "$W2" 2>&1)"
RC=$?
assert_eq "$RC" "0" "a wiki with no citations is valid"

# Validate against the real BibLaTeX data model, not just our own parser.
# CI runners have no TeX distribution, so this is skipped when biber is absent
# — the same pattern ci-local.sh uses for shellcheck.
if command -v biber >/dev/null 2>&1; then
    W3="$(new_wiki)"
    bash "$SCRIPTS/bib-add.sh" --bib "$W3/references.bib" --type report \
        --author "Library of Congress" --institution "Library of Congress" \
        --genre "research guide" --title "A Report" --date 2024 \
        --url "https://example.gov/report" >/dev/null
    bash "$SCRIPTS/bib-add.sh" --bib "$W3/references.bib" \
        --author "Microsoft Corporation" --title "A Press Release" --date 1997-08-06 \
        --url "https://news.microsoft.com/x" >/dev/null
    BIBER_OUT="$(cd "$W3" && biber --tool --validate-datamodel --nolog \
        --output-file /dev/null references.bib 2>&1 || true)"
    assert_not_contains "$BIBER_OUT" "WARN - Datamodel" \
        "biber accepts the generated bibliography against the BibLaTeX data model"
else
    printf '  \033[1;33m-\033[0m biber not installed — skipping data-model validation\n'
fi
fi

# ════════════════════════════════════════════════════════════════════════════
# citation + URL helpers
# ════════════════════════════════════════════════════════════════════════════

if should_run "citations"; then
describe "_utils.sh citation helpers"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../llm-wiki/scripts/_utils.sh
source "$SCRIPTS/_utils.sh"

D="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D"
cat > "$D/c.md" <<'EOF'
---
title: "C"
---
One [@alpha1990x] and two [@beta2000y, p. 4], plus [see @gamma2010z].
Not a citation: contact foo(@example) here.
```
[@fenced2020ignored]
```
<!-- BACKLINKS:BEGIN -->
[@generated2020ignored]
<!-- BACKLINKS:END -->
EOF
CITES="$(extract_citations "$D/c.md" | tr '\n' ' ')"
assert_eq "$CITES" "alpha1990x beta2000y gamma2010z " "extract_citations finds every inline key"
assert_not_contains "$CITES" "fenced" "ignores citations in fenced code"
assert_not_contains "$CITES" "generated" "ignores citations in the Backlinks block"

assert_eq "$(normalise_url 'http://www.Example.COM/Path/')" "https://example.com/Path" \
    "normalise_url lowercases the host but preserves path case"
assert_eq "$(normalise_url 'https://e.com/p?utm_source=a&id=7#frag')" "https://e.com/p?id=7" \
    "normalise_url drops tracking params and fragments, keeps real query"
fi

# ════════════════════════════════════════════════════════════════════════════
# type / class / status model
# ════════════════════════════════════════════════════════════════════════════

if should_run "model"; then
describe "type / class / status model"

typed_page() {
    # typed_page <root> <slug> <frontmatter-extra>
    local root="$1" slug="$2" extra="$3"
    cat > "$root/$slug.md" <<EOF
---
title: "$slug"
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [test]
summary: "page $slug"
$extra
---
# $slug
Body.
EOF
}

W="$(new_wiki)"
typed_page "$W" "ok-entity" "type: entity
class: person
status: reference"
typed_page "$W" "ok-concept" "type: concept"
typed_page "$W" "ok-note" "type: note"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
RC=$?
assert_contains "$OUT" "OK:" "accepts the new type vocabulary"
assert_eq "$RC" "0" "exits 0 on a valid new-model wiki"

# The whole point of the split: an entity must say what kind of thing it is.
W="$(new_wiki)"
typed_page "$W" "classless" "type: entity"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "requires a 'class'" "an entity without a class is an error"

W="$(new_wiki)"
typed_page "$W" "badclass" "type: entity
class: gadget"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "Invalid class 'gadget'" "rejects an unknown class"

W="$(new_wiki)"
typed_page "$W" "misplaced" "type: concept
class: person"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "only meaningful on type 'entity'" "class on a non-entity is a warning"

# Legacy types must warn, never hard-fail: an existing wiki has to keep
# validating after the skill is upgraded under it.
W="$(new_wiki)"
typed_page "$W" "legacy-article" "type: article"
typed_page "$W" "legacy-person" "type: person"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "type 'article' is superseded by 'note'" "reports the article migration"
assert_contains "$OUT" "type 'person' is superseded by 'entity'" "reports the person migration"
assert_not_contains "$OUT" "Invalid type 'article'" "legacy types are not reported as invalid"

W="$(new_wiki)"
typed_page "$W" "badstatus" "type: concept
status: pending"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "Invalid status 'pending'" "rejects an unknown status"

W="$(new_wiki)"
typed_page "$W" "statusless-project" "type: project"
OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "should declare a 'status'" "a project without a status is a warning"
fi

# ════════════════════════════════════════════════════════════════════════════
# index: kind grouping and the projects view
# ════════════════════════════════════════════════════════════════════════════

if should_run "kind"; then
describe "build-index.sh kind grouping"

W="$(new_wiki)"
cat > "$W/jane.md" <<'EOF'
---
title: "Jane"
type: entity
class: person
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [people]
summary: "a person"
status: reference
---
# Jane
Works on [[ship-v2]].
EOF
cat > "$W/acme.md" <<'EOF'
---
title: "Acme"
type: entity
class: organization
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [orgs]
summary: "an organisation"
status: reference
---
# Acme
Employs [[jane]].
EOF
cat > "$W/ship-v2.md" <<'EOF'
---
title: "Ship v2"
type: project
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [work]
summary: "get v2 out"
status: active
area: "[[engineering]]"
outcome: "v2 in production"
---
# Ship v2
Serves [[engineering]], staffed by [[jane]] at [[acme]].
EOF
cat > "$W/engineering.md" <<'EOF'
---
title: "Engineering"
type: area
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [work]
summary: "ongoing engineering responsibility"
status: active
review_cadence: monthly
---
# Engineering
Covers [[ship-v2]].
EOF
bash "$SCRIPTS/build-index.sh" "$W" --quiet
IDX="$(cat "$W/.llm-wiki/index.md")"

assert_contains "$IDX" "## By Kind" "index has a By Kind section"
assert_contains "$IDX" "**entity / person**" "entities are broken out by class"
assert_contains "$IDX" "**entity / organization**" "each class is counted separately"
assert_contains "$IDX" "## Projects" "a wiki with projects gets a Projects view"
assert_contains "$IDX" "[[ship-v2]] | active" "the projects view shows status"
assert_contains "$IDX" "[[engineering]]" "the projects view shows the owning area"
assert_contains "$IDX" "entity/person" "the All Pages table shows type/class"

OUT="$(bash "$SCRIPTS/validate-frontmatter.sh" "$W" 2>&1)"
assert_contains "$OUT" "OK:" "the project/area fixture validates"

# A purely encyclopedic wiki should not carry an empty operations section.
W2="$(new_wiki)"
valid_page "$W2" "idea" "Just a concept."
bash "$SCRIPTS/build-index.sh" "$W2" --quiet
assert_not_contains "$(cat "$W2/.llm-wiki/index.md")" "## Projects" \
    "no Projects section when the wiki holds no projects"
fi

# ════════════════════════════════════════════════════════════════════════════
# regressions in generated output
# ════════════════════════════════════════════════════════════════════════════

if should_run "regress"; then
describe "build-index.sh regressions"

# A project page in a subdirectory had its `area` read back empty, because the
# Projects view rebuilt a path from the slug ("$WIKI_ROOT/$slug.md") instead of
# using the metadata already collected. Same defect class as the old
# -maxdepth 1 scans.
W="$(new_wiki)"
mkdir -p "$W/topics"
for loc in "topics/deep" "flat"; do
    cat > "$W/$loc.md" <<EOF
---
title: "$(basename "$loc")"
type: project
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [t]
summary: "project at $loc"
status: active
area: "[[ops]]"
---
# $(basename "$loc")
EOF
done
bash "$SCRIPTS/build-index.sh" "$W" --quiet
PROJECTS="$(sed -n '/^## Projects/,/^## Orphan/p' "$W/.llm-wiki/index.md")"
assert_contains "$PROJECTS" "[[flat]] | active | [[ops]]" "a root project keeps its area"
assert_contains "$PROJECTS" "[[deep]] | active | [[ops]]" "a subdirectory project keeps its area"

# The wiki's schema.md is a copy and drifted on every skill upgrade.
W="$(new_wiki)"
echo "STALE" > "$W/.llm-wiki/schema.md"
bash "$SCRIPTS/build-index.sh" "$W" --quiet
assert_eq "$(cmp -s "$PROJECT_ROOT/llm-wiki/WIKI_SCHEMA.md" "$W/.llm-wiki/schema.md" && echo same || echo differs)" \
    "same" "a drifted schema copy is refreshed on index rebuild"
fi

# ════════════════════════════════════════════════════════════════════════════
# config_get / provenance / convert-source
# ════════════════════════════════════════════════════════════════════════════

if should_run "config"; then
describe "config_get"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../llm-wiki/scripts/_utils.sh
source "$SCRIPTS/_utils.sh"

W="$(new_wiki)"
assert_eq "$(config_get "$W" wiki_name)" "My Wiki" "reads a quoted string"
assert_eq "$(config_get "$W" max_pages_to_read)" "5" "strips the trailing comment"
assert_eq "$(config_get "$W" language)" "en" "strips quotes even behind a comment"
assert_eq "$(config_get "$W" require_review)" "true" "reads a boolean"
assert_eq "$(config_get "$W" nope fallback)" "fallback" "returns the default for a missing key"

# The pre-0.5.0 layout put key: value lines in the body, between `---` markers
# placed mid-document. Not YAML, but existing wikis have it.
cat > "$W/.llm-wiki/config.md" <<'EOF'
# Wiki Configuration

---

## Query Settings
max_pages_to_read: 9         # Maximum pages to read per query
EOF
assert_eq "$(config_get "$W" max_pages_to_read)" "9" "still reads the legacy layout"
fi

if should_run "provenance"; then
describe "provenance.sh"

W="$(new_wiki)"
K="$(bash "$SCRIPTS/bib-add.sh" --bib "$W/references.bib" --title "A Source" \
     --year 2020 --url "https://example.com/s")"
cat > "$W/sourced.md" <<EOF
---
title: "Sourced"
type: concept
language: en
created: 2026-01-01
modified: 2026-01-01
tags: [t]
summary: "has a source"
references: [$K]
---
# Sourced
Claim [@$K].
EOF
valid_page "$W" "bare" "No references at all."

assert_contains "$(bash "$SCRIPTS/provenance.sh" "$W" --page sourced)" "A Source" \
    "--page resolves citation keys to titles"
assert_contains "$(bash "$SCRIPTS/provenance.sh" "$W" --source "$K")" "[[sourced]]" \
    "--source lists the pages resting on it"
assert_contains "$(bash "$SCRIPTS/provenance.sh" "$W" --unsourced)" "bare" \
    "--unsourced reports a page with no references"
assert_not_contains "$(bash "$SCRIPTS/provenance.sh" "$W" --unsourced)" "sourced (" \
    "--unsourced does not report a sourced page"
assert_contains "$(bash "$SCRIPTS/provenance.sh" "$W")" "**Bibliography entries:** 1" \
    "the summary counts bibliography entries"
fi

if should_run "convert"; then
describe "convert-source.sh"

D="$(mktemp -d)"; TMPDIRS="$TMPDIRS $D"
printf 'Plain source text.\n' > "$D/notes.txt"
OUT="$(bash "$SCRIPTS/convert-source.sh" "$D/notes.txt" --raw-dir "$D/raw" | head -1)"
assert_eq "$([ -f "$OUT" ] && echo yes || echo no)" "yes" "converts a plain text source"
BODY="$(cat "$OUT")"
assert_contains "$BODY" "Plain source text." "preserves the content"
assert_contains "$BODY" "original_sha256:" "records the original's hash for provenance"
assert_contains "$BODY" "converted_from:" "records the source format"

printf 'x' > "$D/thing.xyz"
bash "$SCRIPTS/convert-source.sh" "$D/thing.xyz" --raw-dir "$D/raw" >/dev/null 2>&1
assert_eq "$?" "2" "exits 2 for an unsupported format (cannot, not failed)"

if command -v pandoc >/dev/null 2>&1; then
    printf '<h1>Doc</h1><p>A <b>claim</b>.</p>' > "$D/page.html"
    OUT="$(bash "$SCRIPTS/convert-source.sh" "$D/page.html" --raw-dir "$D/raw" | head -1)"
    assert_contains "$(cat "$OUT")" "A **claim**." "converts HTML to markdown via pandoc"
else
    printf '  \033[1;33m-\033[0m pandoc not installed — skipping HTML conversion\n'
fi
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════

printf '\n\033[1mResults\033[0m\n'
printf '  \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf '\nFailures:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
