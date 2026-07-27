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
# Summary
# ════════════════════════════════════════════════════════════════════════════

printf '\n\033[1mResults\033[0m\n'
printf '  \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf '\nFailures:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
