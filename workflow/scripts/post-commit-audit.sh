#!/bin/bash
# Post-Commit Audit — sends the full commit diff to reviewer for review
# Fires on EVERY commit regardless of whether it came through Copilot routing
#
# Also detects untracked commits (no matching prompt ID) and reminds the user
# to run `log-direct` for traceability.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"
SESSION_NAME="reviewer"
LOG_DIR="$WORKFLOW_ROOT/context/audit-logs"
TRACKER_LOG="$WORKFLOW_ROOT/context/PROMPT_TRACKER.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

# Get latest commit info
COMMIT_HASH=$(git -C "$PROJECT_ROOT" log -1 --format="%H" 2>/dev/null)
COMMIT_SHORT=$(git -C "$PROJECT_ROOT" log -1 --format="%h" 2>/dev/null)
COMMIT_MSG=$(git -C "$PROJECT_ROOT" log -1 --format="%s" 2>/dev/null)
COMMIT_AUTHOR=$(git -C "$PROJECT_ROOT" log -1 --format="%an" 2>/dev/null)
BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")

# ── 1. Check for untracked commits ──────────────────────────────────────────
check_prompt_tracking() {
    if [ ! -f "$TRACKER_LOG" ]; then
        return 1  # No tracker log exists
    fi

    # Extract scope from commit message (conventional commit format)
    # e.g. "feat(wizard): add buttons" → scope is "wizard"
    local scope=""
    local pattern='^[a-z]+\(([^)]+)\):'
    if [[ "$COMMIT_MSG" =~ $pattern ]]; then
        scope="${BASH_REMATCH[1]}"
    fi

    # Check if any CRAFTED/SENT/BUILDING prompt matches this scope
    # Or if the commit hash appears in the tracker
    local matched=false

    # Look for prompts with matching scope that are in active states
    if [ -n "$scope" ]; then
        if grep -q "${scope}:.*|\(CRAFTED\|SENT\|BUILDING\)|" "$TRACKER_LOG" 2>/dev/null; then
            matched=true
            # Auto-mark the most recent matching prompt as DONE
            local prompt_id
            prompt_id=$(grep "${scope}:.*|\(CRAFTED\|SENT\|BUILDING\)|" "$TRACKER_LOG" | tail -1 | cut -d'|' -f1)
            if [ -n "$prompt_id" ]; then
                "$SCRIPT_DIR/prompt-tracker.sh" status "$prompt_id" DONE 2>/dev/null
                echo -e "${GREEN}✅ Auto-marked prompt ${CYAN}${prompt_id}${NC} as DONE (matched commit scope '${scope}')${NC}"
            fi
        fi
    fi

    if [ "$matched" = false ]; then
        # Check if any active prompt exists at all
        local has_active
        has_active=$(grep -c "|\(CRAFTED\|SENT\|BUILDING\)|" "$TRACKER_LOG" 2>/dev/null || echo "0")
        if [ "$has_active" -gt 0 ]; then
            # There are active prompts but none match this commit's scope
            echo -e "${YELLOW}⚠️  Commit doesn't match any tracked prompt scope${NC}"
            echo -e "${YELLOW}   Commit: ${COMMIT_SHORT} ${COMMIT_MSG}${NC}"
            echo -e "${YELLOW}   Run: ${CYAN}.ai-workflow/scripts/prompt-tracker.sh log-direct \"${scope:-unknown}\" \"${COMMIT_MSG}\"${NC}"
            return 1
        else
            # No active prompts — this is a direct builder commit
            echo -e "${YELLOW}📝 Untracked commit detected (no active prompts in tracker)${NC}"
            echo -e "${YELLOW}   Commit: ${COMMIT_SHORT} ${COMMIT_MSG}${NC}"
            echo -e "${YELLOW}   Run: ${CYAN}.ai-workflow/scripts/prompt-tracker.sh log-direct \"${scope:-unknown}\" \"${COMMIT_MSG}\"${NC}"
            return 1
        fi
    fi

    return 0
}

# ── 2. Send commit diff to reviewer ─────────────────────────────────────────────
send_to_reviewer() {
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Reviewer session not running — skipping AI review${NC}"
        echo -e "${YELLOW}   Start it: bash .ai-workflow/scripts/start-auditor-ai-tmux.sh${NC}"
        return 1
    fi

    # Get the full commit diff
    local diff
    diff=$(git -C "$PROJECT_ROOT" diff-tree -p --no-color "$COMMIT_HASH" 2>/dev/null)

    if [ -z "$diff" ]; then
        echo -e "${YELLOW}⚠️  Empty diff for commit ${COMMIT_SHORT} — skipping AI review${NC}"
        return 0
    fi

    # Truncate if too large (>80KB)
    local diff_size
    diff_size=$(echo "$diff" | wc -c)
    if [ "$diff_size" -gt 80000 ]; then
        # Get stat summary instead of full diff
        local stat_summary
        stat_summary=$(git -C "$PROJECT_ROOT" diff-tree --stat --no-color "$COMMIT_HASH" 2>/dev/null)
        diff="DIFF TRUNCATED (${diff_size} bytes > 80KB limit). Stat summary:

${stat_summary}

First 2000 lines of diff:
$(echo "$diff" | head -2000)"
    fi

    # Filter out node_modules and build artifacts from diff
    diff=$(echo "$diff" | awk '
        /^diff --git.*node_modules/ { skip=1; next }
        /^diff --git.*build\// { skip=1; next }
        /^diff --git.*coverage\// { skip=1; next }
        /^diff --git/ { skip=0 }
        !skip { print }
    ')

    if [ -z "$diff" ]; then
        echo -e "${GREEN}✅ Commit only touched node_modules/build — skipping AI review${NC}"
        return 0
    fi

    # Build the review prompt
    local prompt="POST-COMMIT REVIEW — Please review this complete commit diff.

Commit: ${COMMIT_SHORT} by ${COMMIT_AUTHOR}
Branch: ${BRANCH}
Message: ${COMMIT_MSG}
Time: ${TIMESTAMP}

Focus on:
1. Security issues (leaked secrets, hardcoded credentials)
2. Code quality (console.log left in, missing error handling)
3. Logic errors or potential bugs
4. Missing test IDs (data-testid) on new UI elements
5. Any regressions or breaking changes

Respond with JSON: {\"severity\": \"pass|warn|fail\", \"summary\": \"brief summary\", \"issues\": [{\"file\": \"path\", \"line\": N, \"severity\": \"info|warn|critical\", \"message\": \"description\"}]}

DIFF:
${diff}"

    # Write to temp file (avoids bash escaping nightmares)
    local temp_prompt
    temp_prompt=$(mktemp)
    echo "$prompt" > "$temp_prompt"

    # Clear previous pane output for clean capture
    tmux clear-history -t "$SESSION_NAME" 2>/dev/null

    # Send to reviewer
    tmux load-buffer "$temp_prompt"
    tmux paste-buffer -t "$SESSION_NAME"
    tmux send-keys -t "$SESSION_NAME" C-m

    rm -f "$temp_prompt"

    echo -e "${PURPLE}🧠 Sent commit ${CYAN}${COMMIT_SHORT}${NC} to reviewer for review...${NC}"

    # Poll for response (up to 60 seconds for commit-level review)
    local audit_log="$LOG_DIR/${TIMESTAMP}_${COMMIT_SHORT}_post-commit.log"
    for i in {1..30}; do
        sleep 2
        local pane_out
        pane_out=$(tmux capture-pane -p -t "$SESSION_NAME" -S -100 2>/dev/null)

        # Check for JSON response (preferred)
        if echo "$pane_out" | grep -q '"severity"'; then
            local json_out
            json_out=$(echo "$pane_out" | grep -o '{"severity".*}' | tail -1)
            if [ -n "$json_out" ]; then
                echo "$json_out" > "$audit_log"

                local severity summary
                severity=$(echo "$json_out" | grep -o '"severity": *"[^"]*"' | head -1 | cut -d'"' -f4)
                summary=$(echo "$json_out" | grep -o '"summary": *"[^"]*"' | head -1 | cut -d'"' -f4)

                case "$severity" in
                    pass)
                        echo -e "${GREEN}✅ Post-Commit Audit PASSED: ${summary}${NC}"
                        ;;
                    warn)
                        echo -e "${YELLOW}⚠️  Post-Commit Audit WARNING: ${summary}${NC}"
                        ;;
                    fail)
                        echo -e "${RED}❌ Post-Commit Audit FAILED: ${summary}${NC}"
                        echo -e "${RED}   Review: cat ${audit_log}${NC}"
                        ;;
                esac

                ln -sf "$audit_log" "$LOG_DIR/post-commit-latest.log"
                return 0
            fi
        fi

        # Check for non-JSON response (reviewer replied in plain text)
        # Look for common audit response patterns from the AI
        if echo "$pane_out" | grep -qiE '(no issues|looks good|LGTM|all clear|no problems|review complete|no concerns)'; then
            echo '{"severity": "pass", "summary": "AI review found no issues (plain text response)", "issues": []}' > "$audit_log"
            echo -e "${GREEN}✅ Post-Commit Audit PASSED (reviewer responded in plain text)${NC}"
            # Also save the raw response
            echo "$pane_out" >> "$audit_log"
            ln -sf "$audit_log" "$LOG_DIR/post-commit-latest.log"
            return 0
        fi
        if echo "$pane_out" | grep -qiE '(critical|security|leaked|hardcoded|vulnerability)'; then
            echo '{"severity": "fail", "summary": "AI review flagged critical issues (plain text response)", "issues": []}' > "$audit_log"
            echo -e "${RED}❌ Post-Commit Audit FLAGGED ISSUES (check reviewer output)${NC}"
            echo "$pane_out" >> "$audit_log"
            ln -sf "$audit_log" "$LOG_DIR/post-commit-latest.log"
            return 0
        fi
    done

    # Timeout — capture whatever the reviewer has so far
    local final_output
    final_output=$(tmux capture-pane -p -t "$SESSION_NAME" -S -100 2>/dev/null)
    echo '{"severity": "warn", "summary": "Post-commit audit timed out", "issues": []}' > "$audit_log"
    if [ -n "$final_output" ]; then
        echo "" >> "$audit_log"
        echo "=== RAW REVIEWER OUTPUT ===" >> "$audit_log"
        echo "$final_output" >> "$audit_log"
    fi
    ln -sf "$audit_log" "$LOG_DIR/post-commit-latest.log"
    echo -e "${YELLOW}⏱️  Reviewer timed out (60s). Raw output saved to: ${audit_log}${NC}"
    echo -e "${YELLOW}   Check manually: tmux attach -t reviewer${NC}"
    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${PURPLE}🔍 POST-COMMIT AUDIT${NC} — ${CYAN}${COMMIT_SHORT}${NC} ${COMMIT_MSG}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Step 1: Check prompt tracking
check_prompt_tracking

# Step 2: Send to reviewer for full diff review
send_to_reviewer

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
