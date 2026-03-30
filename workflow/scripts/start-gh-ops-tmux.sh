#!/bin/bash
# Start GitHub Operations Delegate in a background tmux session
# Session name: gh-ops

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"
SESSION_NAME="gh-ops"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "$PROJECT_ROOT" || exit 1

# Check if tmux session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ GH Ops session already running (detached)${NC}"
    exit 0
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🔄 Starting GH Operations Delegate in tmux session${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create tmux session and run the daemon
tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_ROOT"
tmux send-keys -t "$SESSION_NAME" "bash "$SCRIPT_DIR/gh-ops-daemon.sh"" Enter

echo -e "${GREEN}✓ GH Ops session started (detached)${NC}"