#!/bin/bash
# ensure-workflow.sh — Quick health check for the AI dev workflow.
# Validates that critical pieces are in place and executable.
# Exit 0 = healthy, exit 1 = issues found (printed to stderr).
#
# Called by:
#   - Claude Code SessionStart hook (.claude/settings.json)
#   - Workflow HUD 'h' key
#   - Can be run manually: bash .ai-workflow/scripts/ensure-workflow.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

ISSUES=0
FIXES=()

check() {
  local label="$1" ok="$2" fix="$3"
  if eval "$ok" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label"
    if [ -n "$fix" ]; then
      echo -e "    ${DIM}— run: $fix${NC}"
      FIXES+=("$fix")
    fi
    ISSUES=$((ISSUES + 1))
  fi
}

echo -e "${YELLOW}Workflow Health Check${NC}"
echo ""

# ── Scripts executable ──
check "Workflow scripts executable" \
  "[ -x '$SCRIPT_DIR/audit-watch.sh' ] && [ -x '$SCRIPT_DIR/start-builder-tmux.sh' ]" \
  "chmod +x $SCRIPT_DIR/*.sh $WORKFLOW_ROOT/hooks/*"

# ── Post-commit hook installed ──
GIT_HOOK="$PROJECT_ROOT/.git/hooks/post-commit"
check "Post-commit hook installed" \
  "[ -x '$GIT_HOOK' ] && grep -q 'SESSION' '$GIT_HOOK' 2>/dev/null" \
  "cp $WORKFLOW_ROOT/hooks/post-commit $GIT_HOOK && chmod +x $GIT_HOOK"

# ── SESSION.md exists ──
check "SESSION.md exists" \
  "[ -f '$WORKFLOW_ROOT/context/SESSION.md' ]"

# ── Docker running ──
check "Docker daemon accessible" \
  "docker info >/dev/null 2>&1" \
  "sudo service docker start"

# ── Key containers ──
check "Database container running" \
  "docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'cvstomize.*db'" \
  "cd $PROJECT_ROOT && docker compose up -d"

# ── inotify-tools for audit-watch ──
check "inotify-tools installed" \
  "command -v inotifywait >/dev/null 2>&1" \
  "sudo apt-get install -y -qq inotify-tools"

# ── tmux for builder sessions ──
check "tmux installed" \
  "command -v tmux >/dev/null 2>&1" \
  "sudo apt-get install -y -qq tmux"

# ── tasks.json references only existing scripts ──
if [ -f "$PROJECT_ROOT/.vscode/tasks.json" ]; then
  MISSING_SCRIPTS=0
  while IFS= read -r script; do
    # Extract just the file path (strip arguments after .sh)
    script_file=$(echo "$script" | sed 's/\(\.sh\).*/\1/')
    script_path="$PROJECT_ROOT/$script_file"
    if [ ! -f "$script_path" ]; then
      MISSING_SCRIPTS=$((MISSING_SCRIPTS + 1))
      echo -e "    ${RED}missing: $script_file${NC}" >&2
    fi
  done < <(grep -oP '\$\{workspaceFolder\}/\K[^"]+' "$PROJECT_ROOT/.vscode/tasks.json" 2>/dev/null | sort -u)

  check "tasks.json references valid scripts" \
    "[ $MISSING_SCRIPTS -eq 0 ]"
fi

echo ""
if [ "$ISSUES" -eq 0 ]; then
  echo -e "${GREEN}All checks passed.${NC}"
else
  echo -e "${RED}$ISSUES issue(s) found.${NC}"
fi

exit $ISSUES
