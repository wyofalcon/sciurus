#!/bin/bash
# Start AI Builder in a tmux session
# Session name: builder
#
# Behavior:
#   - From VS Code task (VSCODE_PID set): creates DETACHED session
#   - From interactive terminal: creates session and ATTACHES
#   - If session exists: reports status (or attaches if interactive)
#
# Also bootstraps: shell, gh-ops, reviewer sessions

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"
SESSION_NAME="builder"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Fix VS Code debugger bootloader issue
unset NODE_OPTIONS

cd "$PROJECT_ROOT" || exit 1

# Detect context: VS Code task vs interactive terminal
is_vscode_task() {
  [ -n "$VSCODE_PID" ] || [ -n "$VSCODE_GIT_IPC_HANDLE" ]
}

# Check if tmux session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Builder session already running${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # If interactive, attach to existing session
    if ! is_vscode_task && [ -t 0 ]; then
        echo -e "  ${CYAN}Attaching...${NC}"
        exec tmux attach -t "$SESSION_NAME"
    fi
else

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🤖 Starting AI Builder in tmux session${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Let user choose which CLI to use
CLI_CMD=""
if command -v whiptail &>/dev/null; then
    CLI_CMD=$(whiptail --title "AI Builder" --menu "Choose your builder CLI:" 12 50 3 \
        "claude" "Claude Code Opus 4.6 (Recommended)" \
        "gemini" "Gemini CLI (Vertex AI)" \
        3>&1 1>&2 2>&3) || true
fi
# Fallback: default to claude
if [ -z "$CLI_CMD" ]; then
    if command -v claude &>/dev/null; then
        CLI_CMD="claude"
    elif command -v gemini &>/dev/null; then
        CLI_CMD="gemini"
    else
        echo -e "${YELLOW}⚠ Neither claude nor gemini CLI found. Install one first.${NC}"
        exit 1
    fi
fi

echo -e "  CLI: ${CYAN}$CLI_CMD${NC}"
echo ""

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_ROOT"

# Send initial setup commands
tmux send-keys -t "$SESSION_NAME" "cd $PROJECT_ROOT" Enter
tmux send-keys -t "$SESSION_NAME" "clear" Enter
tmux send-keys -t "$SESSION_NAME" "echo '🤖 AI Builder Ready — Architect can inject prompts'" Enter
tmux send-keys -t "$SESSION_NAME" "echo ''" Enter

# Launch CLI with appropriate flags
if [ "$CLI_CMD" = "claude" ]; then
    tmux send-keys -t "$SESSION_NAME" "unset NODE_OPTIONS && claude --model opus --dangerously-skip-permissions" Enter
elif [ "$CLI_CMD" = "gemini" ]; then
    tmux send-keys -t "$SESSION_NAME" "unset NODE_OPTIONS && gemini --sandbox=auto_edit" Enter
fi

echo -e "${GREEN}✓ Builder session started ($CLI_CMD)${NC}"
fi

# Bootstrap support services
if ! tmux has-session -t shell 2>/dev/null; then
    echo -e "${BLUE}Creating shell session...${NC}"
    tmux new-session -d -s shell -c "$PROJECT_ROOT"
    tmux send-keys -t shell "cd $PROJECT_ROOT && clear" Enter
    tmux send-keys -t shell "echo '🐚 Shell session ready — git, docker, npm commands'" Enter
    echo -e "${GREEN}✓ Shell session started${NC}"
fi

if ! tmux has-session -t gh-ops 2>/dev/null; then
    echo -e "${BLUE}Creating gh-ops session...${NC}"
    bash "$SCRIPT_DIR/start-gh-ops-tmux.sh"
fi

if ! tmux has-session -t reviewer 2>/dev/null; then
    echo -e "${BLUE}Creating reviewer session...${NC}"
    bash "$SCRIPT_DIR/start-auditor-ai-tmux.sh"
fi

echo ""
echo -e "  Builder (${CLI_CMD}): ${CYAN}tmux attach -t builder${NC}"
echo -e "  Shell (Bash):     ${CYAN}tmux attach -t shell${NC}"
echo -e "  (Detach: Ctrl+B, then D)"
echo ""

# If interactive terminal, attach to builder
if ! is_vscode_task && [ -t 0 ]; then
    echo -e "${CYAN}Attaching to builder...${NC}"
    exec tmux attach -t "$SESSION_NAME"
fi

exit 0
