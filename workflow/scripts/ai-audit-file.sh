#!/bin/bash
# AI Audit File - Sends a file diff to the reviewer tmux session

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"
SESSION_NAME="reviewer"
LOG_DIR="$WORKFLOW_ROOT/context/audit-logs"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ai-audit-latest.json"

FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Reviewer session is not running."
    exit 0
fi

# Get diff or full file content
DIFF=$(git diff HEAD -- "$FILE_PATH" 2>/dev/null)
if [ -z "$DIFF" ]; then
    DIFF=$(cat "$FILE_PATH" 2>/dev/null)
    if [ -z "$DIFF" ]; then
        echo "Could not read file: $FILE_PATH"
        exit 0
    fi
    DIFF="NEW FILE CONTENT:
$DIFF"
fi

# Ensure diff isn't too large (basic safety)
if [ $(echo -e "$DIFF" | wc -c) -gt 50000 ]; then
    echo '{"severity": "warn", "summary": "File diff too large to audit", "issues": []}' > "$LOG_FILE"
    echo "File $FILE_PATH is too large for real-time AI audit."
    exit 0
fi

# Clear previous pane content to capture just the next output
tmux clear-history -t "$SESSION_NAME"

# Send the diff to gemini
PROMPT="Review the following changes for file: $FILE_PATH

$DIFF"

# Write prompt to a temp file and send via pbpaste or similar to avoid bash escaping issues
TEMP_PROMPT=$(mktemp)
echo -e "$PROMPT" > "$TEMP_PROMPT"

# Assuming the gemini CLI accepts multi-line input or we can feed it via a heredoc trick
# Let's use a simpler approach: paste the content into the tmux pane.
# We'll use tmux load-buffer and paste-buffer
tmux load-buffer "$TEMP_PROMPT"
tmux paste-buffer -t "$SESSION_NAME"
tmux send-keys -t "$SESSION_NAME" C-m

rm "$TEMP_PROMPT"

# Wait for gemini to process (polling the pane for JSON response)
# This is a naive polling loop for demonstration.
for i in {1..30}; do
    sleep 2
    PANE_OUT=$(tmux capture-pane -p -t "$SESSION_NAME")
    # Check if the output contains valid JSON (ends with } and starts with { somewhere)
    if echo "$PANE_OUT" | grep -q '{"severity"'; then
        # Extract the JSON block
        JSON_OUT=$(echo "$PANE_OUT" | grep -o '{"severity".*}' | tail -1)
        if [ -n "$JSON_OUT" ]; then
            echo "$JSON_OUT" > "$LOG_FILE"

            # Print human-readable summary
            SEVERITY=$(echo "$JSON_OUT" | grep -o '"severity": *"[^"]*"' | head -1 | cut -d'"' -f4)
            SUMMARY=$(echo "$JSON_OUT" | grep -o '"summary": *"[^"]*"' | head -1 | cut -d'"' -f4)

            if [ "$SEVERITY" = "fail" ]; then
                echo -e "\033[0;31m❌ AI Audit Failed: $SUMMARY\033[0m"
                exit 1
            elif [ "$SEVERITY" = "warn" ]; then
                echo -e "\033[1;33m⚠️ AI Audit Warn: $SUMMARY\033[0m"
            else
                echo -e "\033[0;32m✅ AI Audit Passed: $SUMMARY\033[0m"
            fi
            exit 0
        fi
    fi
done

echo '{"severity": "warn", "summary": "Reviewer timed out", "issues": []}' > "$LOG_FILE"
echo "Reviewer timed out."
exit 0
