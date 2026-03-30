#!/bin/bash
# Update ROADMAP.md after each commit
# Called automatically from local-audit.py post-commit
# Appends the latest commit to the Completed section under a date header.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ROADMAP="$PROJECT_ROOT/ROADMAP.md"

if [ ! -f "$ROADMAP" ]; then
    exit 0
fi

# ── Get commit details ──────────────────────────────────────────────────────
COMMIT_HASH=$(git -C "$PROJECT_ROOT" log -1 --format="%h" 2>/dev/null)
COMMIT_MSG=$(git -C "$PROJECT_ROOT" log -1 --format="%s" 2>/dev/null)
TODAY=$(date "+%Y-%m-%d")

[ -z "$COMMIT_HASH" ] || [ -z "$COMMIT_MSG" ] && exit 0

# Skip merge commits and workflow-only commits
if echo "$COMMIT_MSG" | grep -qE "^(Merge|chore\(workflow\)|docs\(session\))"; then
    exit 0
fi

# ── Check if this hash is already logged ────────────────────────────────────
if grep -q "$COMMIT_HASH" "$ROADMAP" 2>/dev/null; then
    exit 0
fi

# ── Format the entry ─────────────────────────────────────────────────────────
# Derive a section hint from the commit type/scope
COMMIT_TYPE=$(echo "$COMMIT_MSG" | grep -oP '^[a-z]+(?=[\(:])' || echo "chore")
COMMIT_SCOPE=$(echo "$COMMIT_MSG" | grep -oP '(?<=\()[^)]+(?=\))' || echo "")
COMMIT_SUBJECT=$(echo "$COMMIT_MSG" | sed 's/^[a-z]*([^)]*): //' | sed 's/^[a-z]*: //')

case "$COMMIT_TYPE" in
    feat)    EMOJI="✨" ;;
    fix)     EMOJI="🐛" ;;
    docs)    EMOJI="📝" ;;
    chore)   EMOJI="🔧" ;;
    refactor) EMOJI="♻️" ;;
    perf)    EMOJI="⚡" ;;
    test)    EMOJI="🧪" ;;
    style)   EMOJI="💅" ;;
    *)       EMOJI="📦" ;;
esac

SCOPE_DISPLAY=""
[ -n "$COMMIT_SCOPE" ] && SCOPE_DISPLAY=" \`$COMMIT_SCOPE\`"

ENTRY="- [x] ${EMOJI}${SCOPE_DISPLAY} ${COMMIT_SUBJECT} (\`${COMMIT_HASH}\` · ${TODAY})"

# ── Find the Completed section and insert under a date header ────────────────
DATE_HEADER="### ${TODAY}"

# Check if today's date header already exists under Completed
if grep -q "^$DATE_HEADER$" "$ROADMAP" 2>/dev/null; then
    # Insert entry after the existing date header
    # Use awk to insert after the first occurrence of the date header
    awk -v entry="$ENTRY" -v header="$DATE_HEADER" '
        placed == 0 && $0 == header {
            print $0
            print entry
            placed = 1
            next
        }
        { print }
    ' "$ROADMAP" > "${ROADMAP}.tmp" && mv "${ROADMAP}.tmp" "$ROADMAP"
else
    # Insert a new date header + entry right after the "## ✅ Completed" line
    awk -v entry="$ENTRY" -v header="$DATE_HEADER" '
        /^## ✅ Completed/ && placed == 0 {
            print $0
            print ""
            print header
            print entry
            placed = 1
            next
        }
        { print }
    ' "$ROADMAP" > "${ROADMAP}.tmp" && mv "${ROADMAP}.tmp" "$ROADMAP"
fi

echo "   📋 ROADMAP.md updated: ${COMMIT_HASH} → Completed"
