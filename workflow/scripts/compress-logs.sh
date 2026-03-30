#!/bin/bash
# Compress AI workflow context logs to prevent bloat.
#
# Triggers (whichever comes first):
#   • Every 5 commits since last compression
#   • Total lines across tracked logs exceeds 500
#
# What gets compressed:
#   audit.log          → keep last 100 lines, archive the rest
#   PROMPT_TRACKER.log → keep last 40 lines, archive the rest
#
# Archives are written to .ai-workflow/context/audit-logs/
# SESSION.md is intentionally NOT touched — it's manually curated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTEXT_DIR="$(dirname "$SCRIPT_DIR")/context"
ARCHIVE_DIR="$CONTEXT_DIR/audit-logs"
COUNTER_FILE="$CONTEXT_DIR/.compress-counter"

# ── Thresholds ──────────────────────────────────────────────────────────────
COMMIT_THRESHOLD=5     # compress after this many commits
LINE_THRESHOLD=500     # compress when total tracked lines exceed this
KEEP_AUDIT=100         # lines to keep in audit.log
KEEP_TRACKER=40        # lines to keep in PROMPT_TRACKER.log

# ── Tracked files ────────────────────────────────────────────────────────────
AUDIT_LOG="$CONTEXT_DIR/audit.log"
TRACKER_LOG="$CONTEXT_DIR/PROMPT_TRACKER.log"

mkdir -p "$ARCHIVE_DIR"

# ── Read / increment commit counter ─────────────────────────────────────────
current_count=0
if [ -f "$COUNTER_FILE" ]; then
    current_count=$(cat "$COUNTER_FILE" 2>/dev/null | tr -d '[:space:]' || echo 0)
    # Sanitize to integer
    [[ "$current_count" =~ ^[0-9]+$ ]] || current_count=0
fi
new_count=$((current_count + 1))

# ── Count total lines across tracked files ───────────────────────────────────
total_lines=0
for f in "$AUDIT_LOG" "$TRACKER_LOG"; do
    if [ -f "$f" ]; then
        count=$(wc -l < "$f" 2>/dev/null || echo 0)
        total_lines=$((total_lines + count))
    fi
done

# ── Decide whether to compress ───────────────────────────────────────────────
should_compress=false

if [ "$new_count" -ge "$COMMIT_THRESHOLD" ]; then
    should_compress=true
    trigger="commit threshold (${new_count}/${COMMIT_THRESHOLD})"
fi

if [ "$total_lines" -ge "$LINE_THRESHOLD" ]; then
    should_compress=true
    trigger="${trigger:-line count} (${total_lines} lines ≥ ${LINE_THRESHOLD})"
fi

if [ "$should_compress" = false ]; then
    # Just save the incremented counter and exit quietly
    echo "$new_count" > "$COUNTER_FILE"
    exit 0
fi

# ── Compress ─────────────────────────────────────────────────────────────────
STAMP=$(date "+%Y%m%d_%H%M%S")
archived=0

compress_file() {
    local file="$1"
    local keep="$2"
    local label="$3"

    [ -f "$file" ] || return 0

    local total
    total=$(wc -l < "$file" 2>/dev/null || echo 0)

    if [ "$total" -le "$keep" ]; then
        return 0
    fi

    local archive_file="$ARCHIVE_DIR/${label}_${STAMP}.archive"
    local excess=$(( total - keep ))

    # Write excess lines to archive
    head -n "$excess" "$file" >> "$archive_file"

    # Keep only the tail in the active file
    local tmp
    tmp=$(mktemp)
    tail -n "$keep" "$file" > "$tmp"
    mv "$tmp" "$file"

    echo "   🗜️  ${label}: archived ${excess} lines (kept ${keep}) → $(basename "$archive_file")"
    archived=$((archived + 1))
}

echo ""
echo "   ♻️  Log compression triggered by: ${trigger}"

compress_file "$AUDIT_LOG"    "$KEEP_AUDIT"   "audit"
compress_file "$TRACKER_LOG"  "$KEEP_TRACKER" "tracker"

# ── Reset counter ─────────────────────────────────────────────────────────────
echo "0" > "$COUNTER_FILE"

if [ "$archived" -gt 0 ]; then
    echo "   ✅ Compressed ${archived} file(s). Archives in .ai-workflow/context/audit-logs/"
else
    echo "   ✅ Files already within limits — counter reset."
fi
