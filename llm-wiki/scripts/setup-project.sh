#!/bin/bash
# setup-project.sh — Set up LLM Wiki in a project directory
# Usage: setup-project.sh [wiki-path] [--with-hooks]
#   wiki-path     Path to create wiki at (default: ./wiki)
#   --with-hooks  Also configure SessionStart hook in settings
# Exit: 0 on success, 1 on error

set -euo pipefail

WITH_HOOKS=false
WIKI_PATH=""

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: setup-project.sh [wiki-path] [--with-hooks]"
            echo ""
            echo "Set up LLM Wiki in your project:"
            echo "  1. Bootstraps the wiki directory with init-wiki.sh"
            echo "  2. Creates or updates CLAUDE.md with wiki instructions"
            echo "  3. Creates .raw/ directory for source documents"
            echo ""
            echo "Options:"
            echo "  wiki-path      Path for the wiki (default: ./wiki)"
            echo "  --with-hooks   Configure SessionStart hook in .claude/settings.local.json"
            echo "  --help, -h     Show this help"
            exit 0 ;;
        --with-hooks) WITH_HOOKS=true ;;
        *)
            if [ -z "$WIKI_PATH" ]; then
                WIKI_PATH="$arg"
            else
                echo "Unknown option: $arg (use --help for usage)" >&2; exit 1
            fi ;;
    esac
done

# Default wiki path
WIKI_PATH="${WIKI_PATH:-./wiki}"

# Resolve skill directory
SKILL_DIR="$HOME/.claude/skills/llm-wiki"
if [ ! -d "$SKILL_DIR" ]; then
    echo "ERROR: LLM Wiki skill not installed." >&2
    echo "Run install.sh first: cd llm-wiki && ./install.sh" >&2
    exit 1
fi

echo "=== LLM Wiki Project Setup ==="
echo ""

# Step 1: Initialize wiki directory
echo "1. Initializing wiki at $WIKI_PATH..."
if [ -d "$WIKI_PATH/.llm-wiki" ]; then
    echo "   ✓ Wiki already exists at $WIKI_PATH"
else
    "$SKILL_DIR/scripts/init-wiki.sh" "$WIKI_PATH"
    echo "   ✓ Wiki initialized"
fi

# Step 2: Create .raw/ directory
if [ ! -d "./.raw" ]; then
    mkdir -p ./.raw
    echo "   ✓ Created ./.raw/ for source documents"
fi

# Step 3: Wire the wiki instructions into CLAUDE.md
echo ""
echo "2. Setting up CLAUDE.md..."

CLAUDE_MD="./CLAUDE.md"
WIKI_MD="$SKILL_DIR/WIKI.md"
PROJECT_WIKI_MD="$WIKI_PATH/.llm-wiki/WIKI.md"
IMPORT_LINE="@${PROJECT_WIKI_MD#./}"

# The instructions live in the wiki, and CLAUDE.md imports them with a single
# `@path` line. That keeps the user's own CLAUDE.md intact — the previous
# behaviour pasted the whole file in, which made the instructions impossible to
# update and mixed generated content into a hand-written file.
sed "s|\./wiki/|${WIKI_PATH%/}/|g" "$WIKI_MD" > "$PROJECT_WIKI_MD"
echo "   ✓ Wiki instructions written to $PROJECT_WIKI_MD"

if [ -f "$CLAUDE_MD" ]; then
    if grep -qF "$IMPORT_LINE" "$CLAUDE_MD" 2>/dev/null; then
        echo "   ✓ CLAUDE.md already imports the wiki instructions"
    elif grep -q "LLM Wiki" "$CLAUDE_MD" 2>/dev/null; then
        echo "   ✓ CLAUDE.md already mentions the wiki — leaving it alone"
        echo "     (to use the maintained version, add this line: $IMPORT_LINE)"
    else
        {
            echo ""
            echo "# LLM Wiki"
            echo ""
            echo "$IMPORT_LINE"
        } >> "$CLAUDE_MD"
        echo "   ✓ Appended wiki import to your existing CLAUDE.md"
    fi
else
    {
        echo "# Project Instructions"
        echo ""
        echo "# LLM Wiki"
        echo ""
        echo "$IMPORT_LINE"
    } > "$CLAUDE_MD"
    echo "   ✓ Created CLAUDE.md importing the wiki instructions"
fi

# Step 4: Optionally configure hooks
if [ "$WITH_HOOKS" = true ]; then
    echo ""
    echo "3. Configuring SessionStart hook..."

    SETTINGS_FILE=".claude/settings.local.json"

    # Claude Code expects each event to hold a list of matcher groups, and each
    # group to hold a list of {type, command} entries:
    #
    #   "SessionStart": [ { "hooks": [ { "type": "command", "command": "…" } ] } ]
    #
    # A flat {"matcher": "", "command": "…"} object — what this script used to
    # write — is silently ignored, so --with-hooks did nothing at all.
    #
    # The end-of-session event is `SessionEnd`; there is no `SessionStop` event,
    # despite the script name.
    if command -v jq >/dev/null 2>&1; then
        mkdir -p .claude
        [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

        jq --arg start "$SKILL_DIR/hooks/session-start.sh" \
           --arg end   "$SKILL_DIR/hooks/session-stop.sh" \
           '.hooks //= {}
            | .hooks.SessionStart = [{"hooks": [{"type": "command", "command": $start}]}]
            | .hooks.SessionEnd   = [{"hooks": [{"type": "command", "command": $end}]}]' \
           "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && \
        mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE" && \
        echo "   ✓ SessionStart + SessionEnd hooks configured in $SETTINGS_FILE"
    else
        echo "   ⚠ jq not found — add this to .claude/settings.local.json by hand:"
        echo ""
        echo '   {'
        echo '     "hooks": {'
        echo '       "SessionStart": [{"hooks": [{"type": "command", "command":'
        echo "         \"$SKILL_DIR/hooks/session-start.sh\"}]}],"
        echo '       "SessionEnd": [{"hooks": [{"type": "command", "command":'
        echo "         \"$SKILL_DIR/hooks/session-stop.sh\"}]}]"
        echo '     }'
        echo '   }'
    fi
else
    echo ""
    echo "3. (Optional) Configure session hooks for richer startup context:"
    echo "   Re-run with --with-hooks, or add to .claude/settings.local.json:"
    echo ""
    echo '   {'
    echo '     "hooks": {'
    echo '       "SessionStart": [{"hooks": [{"type": "command", "command":'
    echo "         \"$SKILL_DIR/hooks/session-start.sh\"}]}],"
    echo '       "SessionEnd": [{"hooks": [{"type": "command", "command":'
    echo "         \"$SKILL_DIR/hooks/session-stop.sh\"}]}]"
    echo '     }'
    echo '   }'
fi

# CLAUDE.md is deliberately NOT added to .gitignore. It is the user's file —
# this script only appends a one-line import to it — and a project's CLAUDE.md
# is normally committed so the whole team shares it.

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Wiki is ready at: $WIKI_PATH"
echo "Drop source documents in ./.raw/ then use:"
echo "  /wiki-ingest .raw/your-file.md"
echo ""
echo "Ask questions naturally — Claude will check the wiki first!"
