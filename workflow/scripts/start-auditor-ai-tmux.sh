#!/bin/bash
# Start Reviewer Delegate in a background tmux session
# Session name: reviewer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"
SESSION_NAME="reviewer"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "$PROJECT_ROOT" || exit 1

# Check if tmux session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ Reviewer session already running (detached)${NC}"
    exit 0
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🧠 Starting Reviewer Delegate in tmux session${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Source config if exists
if [ -f "$WORKFLOW_ROOT/config/models.conf" ]; then
    # Safe config parsing (no shell execution)
    REVIEWER_MODEL=$(grep '^REVIEWER_MODEL=' "$WORKFLOW_ROOT/config/models.conf" | cut -d= -f2 | tr -d '"')
fi

MODEL=${REVIEWER_MODEL:-"gemini-2.0-flash"}

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_ROOT"

# Send initial setup and prompt
tmux send-keys -t "$SESSION_NAME" "unset NODE_OPTIONS" Enter
tmux send-keys -t "$SESSION_NAME" "gemini --model $MODEL --sandbox=auto_edit" Enter

sleep 3 # wait for gemini to load

# Send initialization via send-keys + C-m (paste-buffer has multiline submission issues)
tmux send-keys -t "$SESSION_NAME" "You are a code reviewer. When I give you a diff, respond ONLY with a JSON object with these fields: severity (pass/warn/fail), issues (array of objects each with: type, severity, file, line, message, suggestion), and summary (one-line string). Flag hardcoded secrets as critical. Flag missing error handling, console.log in non-test files, missing data-testid on interactive elements, and memory leaks as warnings. No prose, no markdown fences. Acknowledge by saying: ready"
tmux send-keys -t "$SESSION_NAME" C-m

echo -e "${GREEN}✓ Reviewer session started (detached)${NC}"
