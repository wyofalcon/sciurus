#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Builder Status Check - Detect if Builder (Gemini/Claude CLI) is idle or active
# Checks tmux session first, then falls back to process detection
# Returns structured status for Copilot to act on
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# ─── Determine source: tmux session OR bare process ───
USE_TMUX=false
LAST_OUTPUT=""

if tmux has-session -t builder 2>/dev/null; then
    # Check if the tmux builder session actually has gemini/claude running
    TMUX_PANE_PID=$(tmux list-panes -t builder -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$TMUX_PANE_PID" ]; then
        # Check if gemini or claude is a child of the tmux pane shell
        TMUX_HAS_CLI=$(ps --ppid "$TMUX_PANE_PID" -o comm= 2>/dev/null | grep -qiE 'gemini|claude' && echo yes || echo no)
    fi
    if [ "$TMUX_HAS_CLI" = "yes" ]; then
        USE_TMUX=true
        LAST_OUTPUT=$(tmux capture-pane -t builder -p -S -5 2>/dev/null | tail -5)
    fi
fi

# If tmux builder isn't running a CLI, check for a bare gemini/claude process
if [ "$USE_TMUX" = "false" ]; then
    # Look for gemini or claude CLI processes (exclude vscode extension, reviewer)
    BUILDER_PID=$(ps aux | grep -E '/bin/gemini|/bin/claude' | grep -v grep | grep -v 'gemini-2.0-flash' | grep -v 'geminicodeassist' | grep -v reviewer | awk '{print $2}' | tail -1)

    if [ -z "$BUILDER_PID" ]; then
        echo '{"status":"stopped","idle":false,"message":"No builder CLI (Gemini/Claude) process found"}'
        exit 1
    fi

    # Builder is running but we can't read its terminal output (VS Code terminal)
    # Use process-level heuristics: CPU usage indicates active work
    BUILDER_CPU=$(ps -p "$BUILDER_PID" -o %cpu= 2>/dev/null | tr -d ' ')
    BUILDER_MEM_KB=$(ps -p "$BUILDER_PID" -o rss= 2>/dev/null | tr -d ' ')
    BUILDER_MEM_MB=$(awk "BEGIN {printf \"%.1f\", ${BUILDER_MEM_KB:-0}/1024}")
    BUILDER_TTY=$(ps -p "$BUILDER_PID" -o tty= 2>/dev/null | tr -d ' ')

    LAST_COMMIT_AGE=$(git -C "$PROJECT_ROOT" log -1 --format="%cr" 2>/dev/null)

    # Determine status from CPU: >5% = actively processing
    IS_ACTIVE=false
    if awk "BEGIN {exit !(${BUILDER_CPU:-0} > 5)}" 2>/dev/null; then
        IS_ACTIVE=true
    fi

    NEEDS_RESET=false
    if awk "BEGIN {exit !(${BUILDER_MEM_MB:-0} > 500)}" 2>/dev/null; then
        NEEDS_RESET=true
    fi

    if [ "$IS_ACTIVE" = true ]; then
        echo "{\"status\":\"active\",\"idle\":false,\"completed\":false,\"source\":\"process\",\"pid\":$BUILDER_PID,\"cpu\":\"${BUILDER_CPU}%\",\"memMB\":\"${BUILDER_MEM_MB}\",\"tty\":\"$BUILDER_TTY\",\"needsReset\":$NEEDS_RESET,\"lastCommit\":\"$LAST_COMMIT_AGE\"}"
    else
        echo "{\"status\":\"idle\",\"idle\":true,\"completed\":false,\"source\":\"process\",\"pid\":$BUILDER_PID,\"cpu\":\"${BUILDER_CPU}%\",\"memMB\":\"${BUILDER_MEM_MB}\",\"tty\":\"$BUILDER_TTY\",\"needsReset\":$NEEDS_RESET,\"lastCommit\":\"$LAST_COMMIT_AGE\"}"
    fi
    exit 0
fi

# ─── tmux-based detection (original logic, only reached if tmux builder is active) ───

# Detect idle patterns (CLI waiting for input)
# Check all last 5 lines, not just the very last one — the prompt cursor
# may not be on the final line captured by tmux
IDLE_PATTERNS=(
    "^[[:space:]]*>"              # Gemini CLI prompt (may have leading spaces)
    "Type your message"           # Gemini CLI prompt text
    "^❯"                         # Claude CLI prompt
    "^claude>"                    # Claude prompt
    "^gemini>"                    # Gemini prompt
    "^\\\$"                       # Shell prompt
    "waiting for"                 # Generic waiting
)

IS_IDLE=false
for pattern in "${IDLE_PATTERNS[@]}"; do
    if echo "$LAST_OUTPUT" | grep -qE "$pattern"; then
        IS_IDLE=true
        break
    fi
done

# Detect context size (Gemini shows "| XXX MB" in status bar)
CONTEXT_SIZE=""
CONTEXT_MB=0
if echo "$LAST_OUTPUT" | grep -qoP '\|\s*[\d.]+\s*MB'; then
    CONTEXT_SIZE=$(echo "$LAST_OUTPUT" | grep -oP '[\d.]+\s*MB' | tail -1)
    CONTEXT_MB=$(echo "$CONTEXT_SIZE" | grep -oP '[\d.]+')
fi

# Flag if context is dangerously large (>100MB = needs /new)
NEEDS_RESET=false
if [ -n "$CONTEXT_MB" ]; then
    if awk "BEGIN {exit !($CONTEXT_MB > 100)}" 2>/dev/null; then
        NEEDS_RESET=true
    fi
fi

# Detect completion signals in recent output
COMPLETION_SIGNALS=(
    "committed"
    "changes staged"
    "git add"
    "git commit"
    "Task complete"
    "Done!"
    "finished"
    "All changes"
)

HAS_COMPLETION=false
for signal in "${COMPLETION_SIGNALS[@]}"; do
    if echo "$LAST_OUTPUT" | grep -qi "$signal"; then
        HAS_COMPLETION=true
        break
    fi
done

# Detect error signals
ERROR_SIGNALS=(
    "Error:"
    "error:"
    "FAILED"
    "failed"
    "Cannot find"
    "Module not found"
    "SyntaxError"
    "TypeError"
)

HAS_ERROR=false
ERROR_MSG=""
for signal in "${ERROR_SIGNALS[@]}"; do
    if echo "$LAST_OUTPUT" | grep -qi "$signal"; then
        HAS_ERROR=true
        ERROR_MSG=$(echo "$LAST_OUTPUT" | grep -i "$signal" | tail -1 | tr '"' "'")
        break
    fi
done

# Check for new commits since last known state
LAST_COMMIT=$(git log -1 --format="%H %s" 2>/dev/null)
LAST_COMMIT_AGE=$(git log -1 --format="%cr" 2>/dev/null)

# Build JSON output
CONTEXT_FIELD=""
if [ -n "$CONTEXT_SIZE" ]; then
    CONTEXT_FIELD=",\"contextSize\":\"$CONTEXT_SIZE\",\"needsReset\":$NEEDS_RESET"
fi

if [ "$HAS_ERROR" = true ]; then
    echo "{\"status\":\"error\",\"idle\":$IS_IDLE,\"completed\":false,\"error\":\"$ERROR_MSG\",\"lastCommit\":\"$LAST_COMMIT_AGE\"$CONTEXT_FIELD}"
elif [ "$NEEDS_RESET" = true ] && [ "$IS_IDLE" = true ]; then
    echo "{\"status\":\"frozen\",\"idle\":true,\"completed\":false,\"message\":\"Context too large ($CONTEXT_SIZE) — run /new to reset\",\"lastCommit\":\"$LAST_COMMIT_AGE\"$CONTEXT_FIELD}"
elif [ "$HAS_COMPLETION" = true ] && [ "$IS_IDLE" = true ]; then
    echo "{\"status\":\"completed\",\"idle\":true,\"completed\":true,\"lastCommit\":\"$LAST_COMMIT_AGE\"$CONTEXT_FIELD}"
elif [ "$IS_IDLE" = true ]; then
    echo "{\"status\":\"idle\",\"idle\":true,\"completed\":false,\"lastCommit\":\"$LAST_COMMIT_AGE\"$CONTEXT_FIELD}"
else
    echo "{\"status\":\"active\",\"idle\":false,\"completed\":false,\"lastCommit\":\"$LAST_COMMIT_AGE\"$CONTEXT_FIELD}"
fi

exit 0
