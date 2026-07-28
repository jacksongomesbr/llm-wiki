#!/bin/bash
# validate-frontmatter.sh — Check required frontmatter fields in wiki pages
# Usage: validate-frontmatter.sh <wiki_root>
# Output: one line per issue found
# Exit: 0 = all valid, 1 = issues found, 2 = error

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: validate-frontmatter.sh [wiki_root]"
    echo "Check required frontmatter fields in all wiki pages."
    echo "  wiki_root   Wiki directory (default: ./wiki)"
    echo "Exit: 0 = all valid, 1 = issues found, 2 = error"
    exit 0
fi

WIKI_ROOT="${1:-./wiki}"

if [ ! -d "$WIKI_ROOT" ]; then
    echo "ERROR: Wiki root '$WIKI_ROOT' does not exist" >&2
    exit 2
fi

# `tags` is a list and the rest are scalars — different emptiness tests, so
# they are checked separately below.
SCALAR_FIELDS=("title" "type" "language" "created" "modified" "summary")

# `type` is the document's structure; `class` is what an entity actually is.
# Conflating them is why `concept` became a junk drawer holding ideas, tools
# and organisations alike.
VALID_TYPES=("note" "concept" "entity" "project" "area" "synthesis")
VALID_CLASSES=("person" "organization" "tool" "place" "work" "event")

# Accepted, but superseded. Reported as a warning with the migration, never as
# an error — an existing wiki must keep validating after a skill upgrade.
LEGACY_TYPES=("article" "person")

# Lifecycle. Optional; it is what makes the wiki operable rather than purely
# encyclopedic.
VALID_STATUSES=("active" "reference" "someday" "archived" "stub")

VALID_LANGUAGES=("en" "zh" "bilingual")

ISSUES_FOUND=0

check_page() {
    local file="$1"
    local rel="${file#"$WIKI_ROOT"/}"
    local frontmatter

    frontmatter="$(extract_frontmatter "$file")"

    if [ -z "$frontmatter" ]; then
        echo "ERROR: $rel — No frontmatter found (missing --- delimiters on line 1)"
        ISSUES_FOUND=1
        return
    fi

    local field val
    for field in "${SCALAR_FIELDS[@]}"; do
        val="$(fm_field "$frontmatter" "$field")"
        if [ -z "$val" ]; then
            echo "ERROR: $rel — Missing required field '$field'"
            ISSUES_FOUND=1
        fi
    done

    # `tags` must be present and non-empty. The previous condition was
    #   [ -z "$val" ] || [ "$val" = "[]" ] && [ "$field" != "tags" ]
    # which parses as (A || B) && C, so for field=tags it was always false —
    # tags were never validated at all.
    if ! printf '%s\n' "$frontmatter" | grep -qE '^tags:'; then
        echo "ERROR: $rel — Missing required field 'tags'"
        ISSUES_FOUND=1
    elif [ -z "$(fm_list "$frontmatter" tags)" ]; then
        echo "ERROR: $rel — Field 'tags' is empty"
        ISSUES_FOUND=1
    fi

    local ptype valid vt lt
    ptype="$(fm_field "$frontmatter" type)"
    if [ -n "$ptype" ]; then
        valid=0
        for vt in "${VALID_TYPES[@]}"; do
            [ "$ptype" = "$vt" ] && valid=1
        done
        if [ "$valid" -eq 0 ]; then
            local legacy=0
            for lt in "${LEGACY_TYPES[@]}"; do
                [ "$ptype" = "$lt" ] && legacy=1
            done
            if [ "$legacy" -eq 1 ]; then
                case "$ptype" in
                    article) echo "WARNING: $rel — type 'article' is superseded by 'note'" ;;
                    person)  echo "WARNING: $rel — type 'person' is superseded by 'entity' with 'class: person'" ;;
                esac
                ISSUES_FOUND=1
            else
                echo "ERROR: $rel — Invalid type '$ptype' (must be one of: ${VALID_TYPES[*]})"
                ISSUES_FOUND=1
            fi
        fi
    fi

    # `class` says what kind of thing an entity is. Required for entities,
    # meaningless for anything else.
    local pclass vc
    pclass="$(fm_field "$frontmatter" class)"
    if [ "$ptype" = "entity" ]; then
        if [ -z "$pclass" ]; then
            echo "ERROR: $rel — type 'entity' requires a 'class' (one of: ${VALID_CLASSES[*]})"
            ISSUES_FOUND=1
        else
            valid=0
            for vc in "${VALID_CLASSES[@]}"; do
                [ "$pclass" = "$vc" ] && valid=1
            done
            if [ "$valid" -eq 0 ]; then
                echo "ERROR: $rel — Invalid class '$pclass' (must be one of: ${VALID_CLASSES[*]})"
                ISSUES_FOUND=1
            fi
        fi
    elif [ -n "$pclass" ]; then
        echo "WARNING: $rel — 'class' is only meaningful on type 'entity' (this page is '$ptype')"
        ISSUES_FOUND=1
    fi

    # `status` is optional everywhere, but a project without one cannot be
    # triaged, which defeats the point of having projects.
    local pstatus vs
    pstatus="$(fm_field "$frontmatter" status)"
    if [ -n "$pstatus" ]; then
        valid=0
        for vs in "${VALID_STATUSES[@]}"; do
            [ "$pstatus" = "$vs" ] && valid=1
        done
        if [ "$valid" -eq 0 ]; then
            echo "ERROR: $rel — Invalid status '$pstatus' (must be one of: ${VALID_STATUSES[*]})"
            ISSUES_FOUND=1
        fi
    elif [ "$ptype" = "project" ]; then
        echo "WARNING: $rel — type 'project' should declare a 'status'"
        ISSUES_FOUND=1
    fi

    local lang vl
    lang="$(fm_field "$frontmatter" language)"
    if [ -n "$lang" ]; then
        valid=0
        for vl in "${VALID_LANGUAGES[@]}"; do
            [ "$lang" = "$vl" ] && valid=1
        done
        if [ "$valid" -eq 0 ]; then
            echo "ERROR: $rel — Invalid language '$lang' (must be one of: ${VALID_LANGUAGES[*]})"
            ISSUES_FOUND=1
        fi
    fi

    local created modified date_val
    created="$(fm_field "$frontmatter" created)"
    modified="$(fm_field "$frontmatter" modified)"
    for date_val in "$created" "$modified"; do
        if [ -n "$date_val" ] && ! echo "$date_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            echo "ERROR: $rel — Invalid date format '$date_val' (must be YYYY-MM-DD)"
            ISSUES_FOUND=1
            break
        fi
    done
}

while IFS= read -r -d '' file; do
    check_page "$file"
done < <(wiki_pages "$WIKI_ROOT")

if [ "$ISSUES_FOUND" -eq 0 ]; then
    echo "OK: All pages have valid frontmatter."
fi

exit "$ISSUES_FOUND"
