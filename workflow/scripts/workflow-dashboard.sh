#!/bin/bash
# Workflow Dashboard — Combined HUD + Audit Watch
# Persistent terminal showing live status + auto-auditing file changes.
#
# Replaces the separate workflow-hud.sh and audit-watch.sh terminals.
#
# Features:
#   - Live dashboard with auto-refresh every 5s
#   - Background file watcher (inotifywait) triggers audits on save
#   - Keyboard shortcuts for relay/audit/health/builder/prompts
#   - Audit results shown inline in the dashboard
#
# Usage: bash .ai-workflow/scripts/workflow-dashboard.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
CONTEXT_DIR="$WORKFLOW_ROOT/context"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"

# State files
RELAY_MODE_FILE="$CONTEXT_DIR/RELAY_MODE"
AUDIT_MODE_FILE="$CONTEXT_DIR/AUDIT_WATCH_MODE"
WORKFLOW_PENDING_FILE="$CONTEXT_DIR/WORKFLOW_CHANGE_PENDING"
DOC_SYNC_FLAG="$CONTEXT_DIR/DOC_SYNC_STALE"
TRACKER_LOG="$CONTEXT_DIR/PROMPT_TRACKER.log"
PID_FILE="$CONTEXT_DIR/.dashboard.pid"

# Audit event queue (temp file for inotifywait output)
AUDIT_EVENTS_FILE=$(mktemp /tmp/dashboard-events.XXXXXX)
# Audit result display files
AUDIT_LAST_FILE="$CONTEXT_DIR/.audit-last-file"
AUDIT_LAST_EXIT="$CONTEXT_DIR/.audit-last-exit"
AUDIT_LAST_OUTPUT="$CONTEXT_DIR/.audit-last-output"
AUDIT_LAST_TIME="$CONTEXT_DIR/.audit-last-time"

# Watcher state
WATCH_PID=0
LAST_AUDIT_RUN=0
DEBOUNCE_SECONDS=3

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_PURPLE='\033[45m'
BG_RED='\033[41m'
NC='\033[0m'

# Agents section toggle (collapsed by default)
SHOW_AGENTS=false

# Action message (shown briefly after keypress)
ACTION_MSG=""
ACTION_EXPIRE=0

# ── Cleanup ──────────────────────────────────────────────

cleanup() {
  [[ $WATCH_PID -gt 0 ]] && kill "$WATCH_PID" 2>/dev/null
  rm -f "$AUDIT_EVENTS_FILE" "$PID_FILE" 2>/dev/null
  printf '\033[?25h'
  exit 0
}
trap cleanup EXIT INT TERM

# Prevent duplicate instances
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Dashboard already running (PID $OLD_PID). Kill it first or remove $PID_FILE"
    exit 1
  fi
fi
echo $$ > "$PID_FILE"

# ── Helpers ──────────────────────────────────────────────

get_relay_mode() {
  if [ -f "$RELAY_MODE_FILE" ]; then
    tr -d '[:space:]' < "$RELAY_MODE_FILE"
  else
    echo "review"
  fi
}

get_audit_mode() {
  if [ -f "$AUDIT_MODE_FILE" ]; then
    tr -d '[:space:]' < "$AUDIT_MODE_FILE"
  else
    echo "on"
  fi
}

tmux_dot() {
  local session="$1"
  if tmux has-session -t "$session" 2>/dev/null; then
    echo -e "${GREEN}●${NC}"
  else
    echo -e "${RED}○${NC}"
  fi
}

docker_dot() {
  local svc="$1"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "cvstomize[-_]${svc}"; then
    echo -e "${GREEN}●${NC}"
  else
    echo -e "${RED}○${NC}"
  fi
}

get_branch() {
  git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

get_git_status() {
  local staged unstaged untracked ahead behind
  staged=$(git -C "$PROJECT_ROOT" diff --cached --numstat 2>/dev/null | wc -l)
  unstaged=$(git -C "$PROJECT_ROOT" diff --numstat 2>/dev/null | wc -l)
  untracked=$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null | wc -l)
  ahead=$(git -C "$PROJECT_ROOT" rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
  behind=$(git -C "$PROJECT_ROOT" rev-list --count HEAD..@{u} 2>/dev/null || echo "0")

  local parts=()
  [ "$staged" -gt 0 ] && parts+=("${GREEN}+${staged} staged${NC}")
  [ "$unstaged" -gt 0 ] && parts+=("${YELLOW}~${unstaged} modified${NC}")
  [ "$untracked" -gt 0 ] && parts+=("${DIM}?${untracked} new${NC}")
  [ "$ahead" -gt 0 ] && parts+=("${CYAN}↑${ahead}${NC}")
  [ "$behind" -gt 0 ] && parts+=("${RED}↓${behind}${NC}")

  if [ ${#parts[@]} -eq 0 ]; then
    echo -e "${GREEN}clean${NC}"
  else
    local IFS='  '
    echo -e "${parts[*]}"
  fi
}

get_time_since_commit() {
  local ts
  ts=$(git -C "$PROJECT_ROOT" log -1 --format=%ct 2>/dev/null)
  if [ -z "$ts" ]; then
    echo "never"
    return
  fi
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - ts))
  if [ "$elapsed" -lt 60 ]; then
    echo "${elapsed}s ago"
  elif [ "$elapsed" -lt 3600 ]; then
    echo "$((elapsed / 60))m ago"
  elif [ "$elapsed" -lt 86400 ]; then
    echo "$((elapsed / 3600))h $((elapsed % 3600 / 60))m ago"
  else
    echo "$((elapsed / 86400))d ago"
  fi
}

get_last_commit_short() {
  git -C "$PROJECT_ROOT" log -1 --pretty="%h %s" 2>/dev/null | head -c 50
}

# ── Agent Activity Helpers ──────────────────────────────

# Detect which CLI is running inside a tmux session
detect_cli() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo ""
    return
  fi
  local pane_pid
  pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -z "$pane_pid" ] && { echo ""; return; }
  # Check full command line of child processes (catches node-based CLIs like gemini/claude)
  local child_args
  child_args=$(ps --ppid "$pane_pid" -o args= 2>/dev/null 2>/dev/null)
  if echo "$child_args" | grep -qiE 'gemini'; then
    echo "Gemini CLI"
    return
  elif echo "$child_args" | grep -qiE 'claude'; then
    echo "Claude CLI"
    return
  fi
  local child_cmd
  child_cmd=$(ps --ppid "$pane_pid" -o comm= 2>/dev/null | head -1)
  case "$child_cmd" in
    *bash*|*sh*) echo "shell" ;;
    *node*) echo "node" ;;
    "") echo "" ;;
    *) echo "$child_cmd" ;;
  esac
}

# Get last meaningful output line from a tmux pane (strips blanks, chrome, prompts)
tmux_last_line() {
  local session="$1"
  tmux has-session -t "$session" 2>/dev/null || return
  local lines
  lines=$(tmux capture-pane -t "$session" -p -S -20 2>/dev/null)
  # Strip ANSI codes, then filter out noise
  echo "$lines" \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -v '^[[:space:]]*$' \
    | grep -v '^[═▄▀─▌▐│╔╗╚╝╠╣║▖▗▘▙▚▛▜▝▞▟█░▒▓]' \
    | grep -v 'Type your message' \
    | grep -v 'workspace (/directory)' \
    | grep -v '/workspaces/cvstomize' \
    | grep -v 'Shift+Tab' \
    | grep -v '? for shortcuts' \
    | grep -v 'MCP servers' \
    | grep -v 'GEMINI.md file' \
    | grep -v 'no sandbox' \
    | grep -v '^\s*>\s*$' \
    | grep -v 'node ➜' \
    | grep -v '^\$' \
    | tail -1 \
    | sed 's/^[[:space:]]*//'
}

# Determine agent state from tmux pane content: active / idle / waiting / error
agent_state() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "stopped"
    return
  fi
  local output
  output=$(tmux capture-pane -t "$session" -p -S -5 2>/dev/null)
  # Check for error signals
  if echo "$output" | grep -qiE 'Error:|FAILED|SyntaxError|TypeError'; then
    echo "error"
    return
  fi
  # Check for active signals (writing code, generating)
  if echo "$output" | grep -qiE 'Generating|Writing|Editing|Creating|Updating|Building|Running|Applying'; then
    echo "active"
    return
  fi
  # Check for idle/prompt signals
  if echo "$output" | grep -qE '^\s*>|Type your message|^❯|^claude>|^gemini>'; then
    echo "idle"
    return
  fi
  # Check CPU as fallback
  local pane_pid child_pid cpu
  pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -n "$pane_pid" ]; then
    child_pid=$(ps --ppid "$pane_pid" -o pid= 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$child_pid" ]; then
      cpu=$(ps -p "$child_pid" -o %cpu= 2>/dev/null | tr -d ' ')
      if awk "BEGIN {exit !(${cpu:-0} > 5)}" 2>/dev/null; then
        echo "active"
        return
      fi
    fi
  fi
  echo "idle"
}

# Format a state into a colored badge
state_badge() {
  local state="$1"
  case "$state" in
    active)  echo -e "${BG_GREEN}${WHITE}${BOLD} ACTIVE ${NC}" ;;
    idle)    echo -e "${YELLOW}IDLE${NC}" ;;
    waiting) echo -e "${CYAN}WAITING${NC}" ;;
    error)   echo -e "${RED}ERROR${NC}" ;;
    stopped) echo -e "${RED}STOPPED${NC}" ;;
    *)       echo -e "${DIM}—${NC}" ;;
  esac
}

# Get last gh-ops log line (strip ANSI, return message part only)
ghops_last_activity() {
  local logfile="$CONTEXT_DIR/gh-ops.log"
  [ -f "$logfile" ] || return
  local line
  line=$(tail -1 "$logfile" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
  # Extract the message after the timestamp: [2026-03-27 20:50:09] message
  echo "$line" | sed 's/^\[[0-9 :-]*\] *//'
}


# ── Keyboard Actions ─────────────────────────────────────

toggle_relay() {
  local current
  current=$(get_relay_mode)
  if [ "$current" = "auto" ]; then
    echo "review" > "$RELAY_MODE_FILE"
    ACTION_MSG="Relay → REVIEW"
  else
    echo "auto" > "$RELAY_MODE_FILE"
    ACTION_MSG="Relay → AUTO-INJECT"
  fi
  ACTION_EXPIRE=$(($(date +%s) + 3))
}

toggle_audit() {
  local current
  current=$(get_audit_mode)
  if [ "$current" = "on" ]; then
    echo "off" > "$AUDIT_MODE_FILE"
    ACTION_MSG="Audit → OFF (file watching paused)"
  else
    echo "on" > "$AUDIT_MODE_FILE"
    ACTION_MSG="Audit → ON (file watching active)"
  fi
  ACTION_EXPIRE=$(($(date +%s) + 3))
}

toggle_agents() {
  if [ "$SHOW_AGENTS" = true ]; then
    SHOW_AGENTS=false
    ACTION_MSG="Agents panel collapsed"
  else
    SHOW_AGENTS=true
    ACTION_MSG="Agents panel expanded"
  fi
  ACTION_EXPIRE=$(($(date +%s) + 3))
}

show_help() {
  clear
  local W
  W=$(tput cols 2>/dev/null || echo 80)
  [ "$W" -lt 40 ] && W=40

  local HR
  HR=$(printf '─%.0s' $(seq 1 $((W - 4))))

  echo ""
  echo -e "  ${BOLD}${CYAN}AI Dev Workflow Dashboard — Help${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo ""
  echo -e "  ${BOLD}How the Workflow Works${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo -e "  You describe what you want → Architect (Claude Sonnet) decides the approach:"
  echo ""
  echo -e "    ${GREEN}Small task${NC}  → Architect handles it directly"
  echo -e "    ${CYAN}Large task${NC}  → Architect refines a prompt → sends to Builder (Claude Opus)"
  echo ""
  echo -e "  All changes are audited before commit, regardless of who wrote them."
  echo ""
  echo -e "  ${BOLD}Dashboard Sections${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo -e "  ${BOLD}AI Workflow${NC}    Relay mode, audit watch, and builder status at a glance"
  echo -e "  ${BOLD}Project${NC}        Current branch, last commit, git status, docker services"
  echo -e "  ${BOLD}Last Audit${NC}     Result of the most recent file audit (pass/fail + details)"
  echo ""
  echo -e "  ${BOLD}Keyboard Controls${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo -e "  ${PURPLE}${BOLD}[^A]${NC} Agents   Toggle agents panel (Ctrl+A)"
  echo ""
  echo -e "  ${WHITE}${BOLD}[R]${NC} Relay     Toggle relay mode between ${GREEN}auto${NC} and ${YELLOW}review${NC}"
  echo -e "                ${DIM}auto = prompts go straight to Builder${NC}"
  echo -e "                ${DIM}review = prompts saved to PROMPT.md for you to confirm${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}[A]${NC} Audit     Toggle audit-on-save (watches files with inotifywait)"
  echo -e "                ${DIM}When ON, saving a file auto-runs the screener on it${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}[B]${NC} Builder   Show detailed builder process status"
  echo -e "                ${DIM}PID, CPU, memory, last commit, context size${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}[P]${NC} Prompts   Show prompt history (what was sent to the builder)${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}[F]${NC} Flow      Show the pipeline flow diagram (who does what, in order)"
  echo ""
  echo -e "  ${WHITE}${BOLD}[H]${NC} Health    Run full health check (docker, db, git hooks, tools)"
  echo -e "                ${DIM}Offers quick-fix commands for any issues found${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}[?]${NC} Help      This screen"
  echo ""
  echo -e "  ${WHITE}${BOLD}[Q]${NC} Quit      Exit the dashboard"
  echo ""
  echo -e "  ${BOLD}Tips${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo -e "  • The dashboard auto-refreshes every 5 seconds"
  echo -e "  • If docker services show ${RED}red${NC}, run: ${CYAN}docker compose up -d${NC}"
  echo -e "  • Start the builder: ${CYAN}.ai-workflow/scripts/start-builder-tmux.sh${NC}"
  echo -e "  • Send a prompt:     ${CYAN}.ai-workflow/scripts/smart-inject.sh \"your prompt\"${NC}"
  echo ""
  echo -e "  ${DIM}Press any key to return to dashboard...${NC}"
  read -rsn1
}

run_health_check() {
  ACTION_MSG="Running health check..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""

  local tmpfile
  tmpfile=$(mktemp)
  bash "$SCRIPT_DIR/ensure-workflow.sh" 2>&1 | tee "$tmpfile" || true

  # Extract "— run: <command>" patterns for quick-fix menu
  local -a cmds=()
  local -A seen=()
  local stripped
  stripped=$(sed 's/\x1b\[[0-9;]*m//g' "$tmpfile")
  while IFS= read -r line; do
    local cmd=""
    if [[ "$line" =~ —\ run:\ (.+)$ ]]; then
      cmd="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ --\ run:\ (.+)$ ]]; then
      cmd="${BASH_REMATCH[1]}"
    fi
    if [ -n "$cmd" ]; then
      cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -z "${seen[$cmd]:-}" ]; then
        seen[$cmd]=1
        cmds+=("$cmd")
      fi
    fi
  done <<< "$stripped"
  rm -f "$tmpfile"

  echo ""
  if [ ${#cmds[@]} -gt 0 ]; then
    echo -e "${BOLD}🔧 Quick fixes available:${NC}"
    for i in "${!cmds[@]}"; do
      local num=$((i+1))
      echo -e "  ${GREEN}${BOLD}[$num]${NC} ${CYAN}${cmds[$i]}${NC}"
    done
    echo -e "  ${DIM}[Enter] Return to dashboard${NC}"
    echo ""
    echo -ne "${BOLD}Run a fix (1-${#cmds[@]}) or press Enter to skip: ${NC}"
    read -r choice
    if [[ "${choice:-}" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#cmds[@]}" ] 2>/dev/null; then
      local idx=$((choice-1))
      echo ""
      echo -e "${CYAN}▶ Running: ${cmds[$idx]}${NC}"
      echo ""
      (cd "$PROJECT_ROOT" && bash -c "${cmds[$idx]}") || true
      echo ""
      echo -e "${GREEN}✓ Done${NC}"
      echo -e "${DIM}Press any key to return to dashboard...${NC}"
      read -rsn1
    fi
  else
    echo -e "${DIM}Press any key to return to dashboard...${NC}"
    read -rsn1
  fi
  ACTION_MSG=""
}

show_prompt_log() {
  ACTION_MSG="Showing prompt log..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""
  if [ -x "$SCRIPT_DIR/prompt-tracker.sh" ]; then
    bash "$SCRIPT_DIR/prompt-tracker.sh" show 2>&1
  else
    echo -e "${DIM}Prompt tracker not available${NC}"
  fi
  echo ""
  echo -e "${DIM}Press any key to return to dashboard...${NC}"
  read -rsn1
  ACTION_MSG=""
}

show_flow() {
  clear
  local W
  W=$(tput cols 2>/dev/null || echo 80)
  [ "$W" -lt 50 ] && W=50

  local HR
  HR=$(printf '─%.0s' $(seq 1 $((W - 4))))

  # ── Gather live state ──
  local relay_mode builder_st builder_cli reviewer_st reviewer_cli
  local ghops_st shell_st screener_ok reviewer_model audit_mode

  relay_mode=$(get_relay_mode)
  audit_mode=$(get_audit_mode)
  builder_st=$(agent_state builder)
  builder_cli=$(detect_cli builder)
  reviewer_st=$(agent_state reviewer)
  reviewer_cli=$(detect_cli reviewer)

  # Screener: check if script exists
  screener_ok="false"
  [ -f "$PROJECT_ROOT/.ai-workflow/scripts/local-audit.py" ] && screener_ok="true"

  # GH Ops / Shell
  ghops_st="stopped"
  tmux has-session -t gh-ops 2>/dev/null && ghops_st="running"
  shell_st="stopped"
  tmux has-session -t shell 2>/dev/null && shell_st="running"

  # Reviewer model from config
  reviewer_model="Gemini Flash"
  if [ -f "$PROJECT_ROOT/.ai-workflow/config/models.conf" ]; then
    local m
    m=$(grep '^REVIEWER_MODEL=' "$PROJECT_ROOT/.ai-workflow/config/models.conf" 2>/dev/null | cut -d= -f2 | tr -d '"'"'" | head -1)
    [ -n "$m" ] && reviewer_model="$m"
  fi

  # Builder CLI label
  local builder_label="Claude Opus"
  [ -n "$builder_cli" ] && builder_label="$builder_cli"

  # ── Badge helpers for flow boxes ──
  flow_badge() {
    case "$1" in
      active)  echo -e "${BG_GREEN}${WHITE} ACTIVE ${NC}" ;;
      idle)    echo -e "${YELLOW} IDLE ${NC}" ;;
      error)   echo -e "${RED} ERROR ${NC}" ;;
      stopped) echo -e "${RED} STOPPED ${NC}" ;;
      running) echo -e "${GREEN} ON ${NC}" ;;
      ready)   echo -e "${GREEN} READY ${NC}" ;;
      missing) echo -e "${RED} MISSING ${NC}" ;;
      *)       echo -e "${DIM} — ${NC}" ;;
    esac
  }

  # ── Render ──
  echo ""
  echo -e "  ${BOLD}${CYAN}Pipeline Flow${NC}  ${DIM}(live)${NC}"
  echo -e "  ${DIM}${HR}${NC}"
  echo ""

  # 1. Huminloop
  echo -e "  ${BOLD}${GREEN}┌───────────────┐${NC}"
  echo -e "  ${BOLD}${GREEN}│  Huminloop    │${NC}  ${BG_GREEN}${WHITE} ACTIVE ${NC}  You"
  echo -e "  ${BOLD}${GREEN}└───────┬───────┘${NC}"
  echo -e "          ${DIM}│${NC}  ${DIM}start with ! → Architect sends to Builder${NC}"
  echo -e "          ${DIM}│${NC}  ${DIM}no ! → Architect handles it directly${NC}"

  # 2. Architect
  echo -e "  ${BOLD}${PURPLE}┌───────┴───────┐${NC}"
  echo -e "  ${BOLD}${PURPLE}│  Architect    │${NC}  ${BG_PURPLE}${WHITE} CLAUDE ${NC}  Relay: ${BOLD}$([ "$relay_mode" = "auto" ] && echo -e "${GREEN}auto${NC}" || echo -e "${YELLOW}review${NC}")${NC}"
  echo -e "  ${BOLD}${PURPLE}└───────┬───────┘${NC}"
  echo -e "          ${DIM}│${NC}  ${DIM}structured prompt${NC}"

  # 3. Builder
  local b_badge
  b_badge=$(flow_badge "$builder_st")
  echo -e "  ${BOLD}${CYAN}┌───────┴───────┐${NC}"
  echo -e "  ${BOLD}${CYAN}│  Builder      │${NC}  ${b_badge}  ${DIM}${builder_label}${NC}"
  echo -e "  ${BOLD}${CYAN}└───────┬───────┘${NC}"
  echo -e "          ${DIM}│${NC}  ${DIM}git commit${NC}"

  # 4. Screener
  local s_badge
  [ "$screener_ok" = "true" ] && s_badge=$(flow_badge "ready") || s_badge=$(flow_badge "missing")
  echo -e "  ${BOLD}${YELLOW}┌───────┴───────┐${NC}"
  echo -e "  ${BOLD}${YELLOW}│  Screener     │${NC}  ${s_badge}  ${DIM}pattern + AI analysis${NC}"
  echo -e "  ${BOLD}${YELLOW}└───────┬───────┘${NC}"
  echo -e "          ${DIM}│${NC}  ${DIM}commit lands${NC}"

  # 5. Reviewer
  local r_badge
  r_badge=$(flow_badge "$reviewer_st")
  echo -e "  ${BOLD}${RED}┌───────┴───────┐${NC}"
  echo -e "  ${BOLD}${RED}│  Reviewer     │${NC}  ${r_badge}  ${DIM}${reviewer_model}${NC}"
  echo -e "  ${BOLD}${RED}└───────┬───────┘${NC}"
  echo -e "          ${DIM}│${NC}"

  # 6. Huminloop (end)
  echo -e "  ${BOLD}${GREEN}┌───────┴───────┐${NC}"
  echo -e "  ${BOLD}${GREEN}│  Huminloop    │${NC}  Reviews diff → approves → push/PR"
  echo -e "  ${BOLD}${GREEN}└───────────────┘${NC}"

  echo ""
  echo -e "  ${DIM}${HR}${NC}"
  echo -e "  ${BOLD}Services${NC} ${DIM}(automation, no LLM)${NC}"
  echo -e "  ${DIM}${HR}${NC}"

  local go_badge sh_badge aw_badge
  go_badge=$(flow_badge "$ghops_st")
  sh_badge=$(flow_badge "$shell_st")
  [ "$audit_mode" = "on" ] && aw_badge="${GREEN}ON${NC}" || aw_badge="${YELLOW}OFF${NC}"

  echo -e "  ${WHITE}GH Ops${NC}       ${go_badge}  Auto-fetch, stale branch warnings"
  echo -e "  ${WHITE}Shell${NC}        ${sh_badge}  Git, Docker, npm commands"
  echo -e "  ${WHITE}Audit Watch${NC}  ${aw_badge}      Auto-audits on file save"

  echo ""
  echo -e "  ${DIM}Press any key to return to dashboard...${NC}"
  read -rsn1
}

run_builder_status() {
  ACTION_MSG="Checking builder..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""

  if [ ! -x "$SCRIPT_DIR/builder-status.sh" ]; then
    echo -e "${DIM}Builder status script not available${NC}"
    echo ""
    echo -e "${DIM}Press any key to return to dashboard...${NC}"
    read -rsn1
    ACTION_MSG=""
    return
  fi

  local json
  json=$(bash "$SCRIPT_DIR/builder-status.sh" 2>/dev/null)

  # Parse JSON fields (lightweight — no jq dependency)
  _jval() { echo "$json" | grep -oP "\"$1\":\s*\"?\K[^\",}]+" | head -1; }

  local status source pid cpu mem tty needs_reset last_commit context_size error_msg
  status=$(_jval status)
  source=$(_jval source)
  pid=$(_jval pid)
  cpu=$(_jval cpu)
  mem=$(_jval memMB)
  tty=$(_jval tty)
  needs_reset=$(_jval needsReset)
  last_commit=$(_jval lastCommit)
  context_size=$(_jval contextSize)
  error_msg=$(_jval error)

  # Status badge
  local badge
  case "$status" in
    active)    badge="${BG_GREEN}${WHITE}${BOLD} ACTIVE ${NC}" ;;
    idle)      badge="${BG_YELLOW}${WHITE}${BOLD} IDLE ${NC}" ;;
    completed) badge="${GREEN}${BOLD} COMPLETED ${NC}" ;;
    error)     badge="${BG_RED}${WHITE}${BOLD} ERROR ${NC}" ;;
    frozen)    badge="${RED}${BOLD} FROZEN ${NC}" ;;
    stopped)   badge="${RED}${BOLD} STOPPED ${NC}" ;;
    *)         badge="${DIM}UNKNOWN${NC}" ;;
  esac

  echo -e "${BOLD}  Builder Status${NC}"
  echo -e "  ─────────────────────────────────────"
  echo -e "  Status     ${badge}"
  [ -n "$source" ]       && echo -e "  Source     ${DIM}${source}${NC}"
  [ -n "$pid" ]          && echo -e "  PID        ${CYAN}${pid}${NC}"
  [ -n "$cpu" ]          && echo -e "  CPU        ${cpu}"
  [ -n "$mem" ]          && echo -e "  Memory     ${mem} MB"
  [ -n "$tty" ]          && echo -e "  TTY        ${DIM}${tty}${NC}"
  [ -n "$context_size" ] && echo -e "  Context    ${context_size}"
  [ -n "$last_commit" ]  && echo -e "  Last commit  ${DIM}${last_commit}${NC}"

  if [ "$needs_reset" = "true" ]; then
    echo ""
    echo -e "  ${YELLOW}⚠ Context too large — run /new to reset${NC}"
  fi
  if [ -n "$error_msg" ]; then
    echo ""
    echo -e "  ${RED}Error: ${error_msg}${NC}"
  fi
  if [ "$status" = "stopped" ]; then
    echo ""
    echo -e "  ${DIM}No builder CLI (Gemini/Claude) process found.${NC}"
    echo -e "  ${DIM}Start one with: gemini  or  claude${NC}"
  fi

  echo ""
  echo -e "  ─────────────────────────────────────"
  echo -e "${DIM}  Press any key to return to dashboard...${NC}"
  read -rsn1
  ACTION_MSG=""
}

# ── File Watcher ─────────────────────────────────────────

start_watcher() {
  local audit_mode
  audit_mode=$(get_audit_mode)
  [ "$audit_mode" != "on" ] && return

  # Ensure inotifywait is available
  if ! command -v inotifywait &>/dev/null; then
    echo -e "${YELLOW}Installing inotify-tools for file watching...${NC}"
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
    sudo apt-get update -qq && sudo apt-get install -y -qq inotify-tools 2>/dev/null
  fi

  if ! command -v inotifywait &>/dev/null; then
    echo -e "${RED}inotifywait not available — file watching disabled${NC}"
    return
  fi

  # Kill existing watcher
  [[ $WATCH_PID -gt 0 ]] && kill "$WATCH_PID" 2>/dev/null

  # Start inotifywait directly in background, appending file paths to events file
  inotifywait -m -r --format '%w%f' \
    --exclude '(node_modules|\.git|coverage|dist|build|__pycache__)' \
    -e modify,create \
    "$PROJECT_ROOT/src" "$PROJECT_ROOT/api" "$PROJECT_ROOT/scripts" \
    "$PROJECT_ROOT/.gemini" "$PROJECT_ROOT/.ai-workflow/config" \
    >> "$AUDIT_EVENTS_FILE" 2>/dev/null &
  WATCH_PID=$!
}

stop_watcher() {
  if [[ $WATCH_PID -gt 0 ]] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null
    WATCH_PID=0
  fi
}

process_file_events() {
  [ ! -s "$AUDIT_EVENTS_FILE" ] && return

  local now
  now=$(date +%s)
  # Debounce: skip if we just ran
  (( now - LAST_AUDIT_RUN < DEBOUNCE_SECONDS )) && return
  LAST_AUDIT_RUN=$now

  # Snapshot events and clear (truncate in place so inotifywait's fd stays valid)
  local events_snapshot="${AUDIT_EVENTS_FILE}.snap"
  cp "$AUDIT_EVENTS_FILE" "$events_snapshot" 2>/dev/null
  > "$AUDIT_EVENTS_FILE"

  # Get last unique changed file
  local last_file
  last_file=$(sort -u "$events_snapshot" 2>/dev/null | tail -1)
  rm -f "$events_snapshot"

  [ -z "$last_file" ] && return

  # Filter: skip irrelevant files
  [[ "$last_file" =~ node_modules|\.git/|coverage|dist|build|__pycache__|\.pyc ]] && return
  [[ ! "$last_file" =~ \.(js|jsx|ts|tsx|py|json|md)$ ]] && return

  # Run pattern-based audit
  local output exit_code
  cd "$PROJECT_ROOT" || return
  if [ -f "$SCRIPT_DIR/audit-file.py" ]; then
    output=$(python3 "$SCRIPT_DIR/audit-file.py" "$last_file" 2>&1) || true
    exit_code=$?
  else
    output="(audit-file.py not found)"
    exit_code=0
  fi

  # Store results for HUD display
  echo "$last_file" > "$AUDIT_LAST_FILE"
  echo "$exit_code" > "$AUDIT_LAST_EXIT"
  echo "$output" > "$AUDIT_LAST_OUTPUT"
  date +%s > "$AUDIT_LAST_TIME"

  # AI audit if reviewer tmux session exists
  if tmux has-session -t reviewer 2>/dev/null && [ -x "$SCRIPT_DIR/ai-audit-file.sh" ]; then
    "$SCRIPT_DIR/ai-audit-file.sh" "$last_file" 2>/dev/null &
  fi
}

# ── Render ───────────────────────────────────────────────

# Truncate a plain string to N chars, adding … if truncated
trunc() {
  local s="$1" n="$2"
  if (( ${#s} > n )); then
    echo "${s:0:$((n-1))}…"
  else
    echo "$s"
  fi
}

render() {
  # Auto-detect terminal width each render (handles resizes)
  local COLS
  COLS=$(tput cols 2>/dev/null || echo 60)
  (( COLS < 40 )) && COLS=40
  local CW=$((COLS - 2))  # content width between borders

  local buf=""
  local relay_mode audit_mode branch git_status time_since last_commit
  relay_mode=$(get_relay_mode)
  audit_mode=$(get_audit_mode)
  branch=$(get_branch)
  git_status=$(get_git_status)
  time_since=$(get_time_since_commit)
  last_commit=$(get_last_commit_short)

  # ── Helpers using cursor positioning for right border ──
  # \033[${COLS}G moves cursor to column COLS (right edge)
  local RB="\033[${COLS}G${BLUE}║${NC}"

  # Horizontal lines that fill the terminal width
  local hfill=""
  printf -v hfill '%*s' "$CW" ''
  hfill="${hfill// /═}"
  local HTOP="${BLUE}╔${hfill}╗${NC}\n"
  local HSEP="${BLUE}╠${hfill}╣${NC}\n"
  local HBOT="${BLUE}╚${hfill}╝${NC}\n"

  # Divider line (dashes inside box)
  local dfill=""
  printf -v dfill '%*s' "$CW" ''
  dfill="${dfill// /─}"
  local HDIV="${BLUE}║${NC}${DIM}${dfill}${NC}${RB}\n"

  # Row helper: prints left border + content + cursor-jumps to right border
  # Content can be any width — right border always lands at column COLS
  # row "decorated content"
  row() { buf+="${BLUE}║${NC}${1}${RB}\n"; }

  # ── Alert Banner (only if issues exist) ──
  if [ -f "$WORKFLOW_PENDING_FILE" ] || [ -f "$DOC_SYNC_FLAG" ]; then
    buf+="${BG_YELLOW}${WHITE}${BOLD}  ⚠  ALERTS${NC}\n"
    if [ -f "$WORKFLOW_PENDING_FILE" ]; then
      buf+="  ${YELLOW}⚠${NC}  Workflow change pending — confirm or revert\n"
    fi
    if [ -f "$DOC_SYNC_FLAG" ]; then
      local sync_info
      sync_info=$(head -1 "$DOC_SYNC_FLAG" 2>/dev/null)
      buf+="  ${RED}📄${NC} Docs out of sync ${DIM}($sync_info)${NC}\n"
    fi
    buf+="\n"
  fi

  # ── Header ──
  buf+="$HTOP"
  row "  ${BOLD}${WHITE}CVstomize Workflow Dashboard${NC}        ${DIM}$(date '+%H:%M:%S CT')${NC}  "
  buf+="$HSEP"

  # ── AGENTS section (collapsible — toggle with Ctrl+A) ──
  # Helper: render one agent row + optional activity sub-line
  # Usage: render_agent "Name" "$state" "$cli" "description" "session_name"
  render_agent() {
    local name="$1" state="$2" cli="$3" desc="$4" session="$5"
    local badge cli_col activity

    badge=$(state_badge "$state")
    if [ -n "$cli" ]; then
      cli_col=" ${CYAN}${cli}${NC}"
    else
      cli_col=""
    fi

    # Name column: fixed 10-char wide for visual alignment
    local pad=$(( 10 - ${#name} ))
    local spacing=""
    for ((i=0; i<pad; i++)); do spacing+=" "; done

    row "   ${BOLD}${name}${NC}${spacing}${badge}${cli_col}"
    row "   ${DIM}          ${desc}${NC}"

    # Activity sub-line for non-stopped agents
    if [ "$state" = "active" ] && [ -n "$session" ]; then
      activity=$(tmux_last_line "$session")
      [ -n "$activity" ] && row "   ${DIM}          └ $(trunc "$activity" $((CW - 18)))${NC}"
    elif [ "$state" = "error" ] && [ -n "$session" ]; then
      activity=$(tmux_last_line "$session")
      [ -n "$activity" ] && row "   ${RED}          └ $(trunc "$activity" $((CW - 18)))${NC}"
    elif [ "$state" = "idle" ] && [ -n "$session" ]; then
      case "$name" in
        Builder)  row "   ${DIM}          └ Waiting for prompt${NC}" ;;
        Reviewer) row "   ${DIM}          └ Waiting for file review${NC}" ;;
      esac
    fi
  }

  if [ "$SHOW_AGENTS" = true ]; then
    row "  ${BOLD}${PURPLE}🤖 AGENTS${NC}  ${DIM}(LLM-powered — Ctrl+A to collapse)${NC}"
    buf+="$HDIV"

    # -- Huminloop (User) --
    row "   ${BOLD}${GREEN}Huminloop${NC} ${BG_GREEN}${WHITE}${BOLD} ACTIVE ${NC}"
    row "   ${DIM}          You — drives the pipeline, reviews & approves${NC}"
    row ""

    # -- Architect (Claude Sonnet 4.6) --
    row "   ${BOLD}Architect${NC} ${BG_PURPLE}${WHITE}${BOLD} CLAUDE ${NC}"
    row "   ${DIM}          Orchestrates, refines prompts, reviews PRs${NC}"
    row ""

    # -- Builder (Claude Opus 4.6) --
    local builder_state builder_cli
    builder_state=$(agent_state builder)
    builder_cli=$(detect_cli builder)
    render_agent "Builder" "$builder_state" "$builder_cli" "Writes features & fixes (Claude Opus)" "builder"
    row ""

    # -- Screener (AI-powered pre-commit) --
    local screener_badge="${GREEN}READY${NC}"
    if [ -f "$PROJECT_ROOT/.ai-workflow/scripts/local-audit.py" ]; then
      screener_badge="${GREEN}READY${NC}"
    else
      screener_badge="${RED}MISSING${NC}"
    fi
    row "   ${BOLD}Screener${NC}  ${screener_badge}"
    row "   ${DIM}          Pre-commit pattern + AI analysis${NC}"
    row ""

    # -- Reviewer (Gemini) --
    local reviewer_state reviewer_cli
    reviewer_state=$(agent_state reviewer)
    reviewer_cli=$(detect_cli reviewer)
    render_agent "Reviewer" "$reviewer_state" "$reviewer_cli" "Post-commit AI review (Gemini)" "reviewer"

    buf+="$HDIV"
    row "  ${BOLD}${CYAN}🔧 SERVICES${NC}  ${DIM}(automation, no LLM)${NC}"
    buf+="$HDIV"

    # -- GH Ops --
    local ghops_state ghops_msg
    if tmux has-session -t gh-ops 2>/dev/null; then
      ghops_state="idle"
      ghops_msg=$(ghops_last_activity)
    else
      ghops_state="stopped"
      ghops_msg=""
    fi
    render_agent "GH Ops" "$ghops_state" "" "Git sync, branch warnings" ""
    if [ -n "$ghops_msg" ]; then
      row "   ${DIM}          └ $(trunc "$ghops_msg" $((CW - 18)))${NC}"
    fi
    row ""

    # -- Shell --
    local shell_state
    shell_state=$(agent_state shell)
    render_agent "Shell" "$shell_state" "" "Git, Docker, npm commands" ""

    buf+="$HDIV"
  fi

  # ── Workflow controls (relay, audit, prompt) ──
  # Relay mode
  if [ "$relay_mode" = "auto" ]; then
    row "   📤 Relay  ${BG_GREEN}${WHITE} AUTO ${NC}   prompts → builder"
  else
    row "   📤 Relay  ${BG_YELLOW}${WHITE} REVIEW ${NC} you paste the prompt"
  fi

  # Audit watcher
  if [ "$audit_mode" = "on" ]; then
    local watch_deco="${GREEN}ON${NC}"
    [[ $WATCH_PID -gt 0 ]] && kill -0 "$WATCH_PID" 2>/dev/null && watch_deco="${GREEN}ON${NC} ${DIM}(watching)${NC}"
    row "   🔍 Watch  ${watch_deco}  auto-auditing saves"
  else
    row "   🔍 Watch  ${YELLOW}OFF${NC}  file watching paused"
  fi

  # Last prompt
  local prompt_deco
  if [ -f "$TRACKER_LOG" ]; then
    local last
    last=$(tail -1 "$TRACKER_LOG" 2>/dev/null)
    if [ -n "$last" ]; then
      local id pstatus
      id=$(echo "$last" | cut -d'|' -f1)
      pstatus=$(echo "$last" | cut -d'|' -f2)
      prompt_deco="${CYAN}$id${NC} ${DIM}[$pstatus]${NC}"
    else
      prompt_deco="${DIM}none${NC}"
    fi
  else
    prompt_deco="${DIM}none${NC}"
  fi
  row "   🏷  Prompt ${prompt_deco}"

  # ── PROJECT section ──
  buf+="$HSEP"
  row "  ${BOLD}${CYAN}📦 PROJECT${NC}"
  buf+="$HDIV"

  # Docker services
  local db_d api_d fe_d docker_ok=true
  local docker_names
  docker_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
  echo "$docker_names" | grep -qE 'cvstomize[-_]db'       && db_d="${GREEN}●${NC}"  || { db_d="${RED}○${NC}"; docker_ok=false; }
  echo "$docker_names" | grep -qE 'cvstomize[-_]api'      && api_d="${GREEN}●${NC}" || { api_d="${RED}○${NC}"; docker_ok=false; }
  echo "$docker_names" | grep -qE 'cvstomize[-_]frontend' && fe_d="${GREEN}●${NC}"  || { fe_d="${RED}○${NC}"; docker_ok=false; }
  row "   ${BOLD}docker${NC} ${db_d} db  ${api_d} api  ${fe_d} frontend"
  if [ "$docker_ok" = false ]; then
    row "   ${YELLOW}⚠ Services down — run:${NC} ${CYAN}docker compose up -d${NC}"
  fi

  # Branch — truncate to fit
  local branch_trunc
  branch_trunc=$(trunc "$branch" $((CW - 14)))
  row "   🌿 Branch  ${CYAN}${branch_trunc}${NC}"

  # Git status
  row "   📝 Status  ${git_status}"

  # Last commit — truncate message to fit
  local commit_trunc
  commit_trunc=$(trunc "$last_commit" $((CW - 20)))
  row "   🕐 Commit  ${DIM}${time_since}${NC} ${DIM}— ${commit_trunc}${NC}"

  # ── LAST AUDIT section (shown for 30s after an audit) ──
  local audit_time
  audit_time=$(cat "$AUDIT_LAST_TIME" 2>/dev/null || echo "0")
  local now
  now=$(date +%s)
  if (( now - audit_time < 30 )); then
    local af ae ao
    af=$(cat "$AUDIT_LAST_FILE" 2>/dev/null || echo "")
    ae=$(cat "$AUDIT_LAST_EXIT" 2>/dev/null || echo "0")

    buf+="$HSEP"
    local display_file="${af#$PROJECT_ROOT/}"
    local file_trunc
    file_trunc=$(trunc "$display_file" $((CW - 18)))
    if [ "${ae:-0}" = "0" ]; then
      row "  ${GREEN}✅ AUDIT PASS${NC}  ${DIM}${file_trunc}${NC}"
    else
      row "  ${YELLOW}⚠️  AUDIT ISSUES${NC}  ${DIM}${file_trunc}${NC}"
      ao=$(head -5 "$AUDIT_LAST_OUTPUT" 2>/dev/null || echo "")
      if [ -n "$ao" ]; then
        while IFS= read -r line; do
          local line_trunc
          line_trunc=$(trunc "$line" $((CW - 4)))
          row "   ${DIM}${line_trunc}${NC}"
        done <<< "$ao"
      fi
    fi
  fi

  # ── Controls — full-word buttons ──
  buf+="$HSEP"
  row "  ${WHITE}${BOLD}[R]${NC} Relay  ${WHITE}${BOLD}[A]${NC} Audit  ${WHITE}${BOLD}[B]${NC} Builder  ${WHITE}${BOLD}[P]${NC} Prompts  ${WHITE}${BOLD}[F]${NC} Flow  ${WHITE}${BOLD}[?]${NC} Help  ${WHITE}${BOLD}[Q]${NC} Quit       ${PURPLE}${BOLD}[^A]${NC} ${PURPLE}Agents${NC}"

  # Action feedback bar
  if [ -n "$ACTION_MSG" ] && [ "$(date +%s)" -lt "$ACTION_EXPIRE" ]; then
    row "  ${GREEN}→ ${ACTION_MSG}${NC}"
  fi

  buf+="$HBOT"

  # Atomic: clear screen and print buffer
  printf '\033[?25l'
  clear
  echo -ne "$buf"
  printf '\033[?25h'
}

# ── Main ─────────────────────────────────────────────────

# Start file watcher (if audit mode is on)
start_watcher

# Initial render
render

while true; do
  # Process any pending file change events
  process_file_events

  # Manage watcher based on audit mode toggle
  current_audit=$(get_audit_mode)
  if [ "$current_audit" = "on" ]; then
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      start_watcher
    fi
  else
    if [[ $WATCH_PID -gt 0 ]] && kill -0 "$WATCH_PID" 2>/dev/null; then
      stop_watcher
    fi
  fi

  # Keyboard input with 5s timeout (doubles as refresh interval)
  if read -rsn1 -t 5 key 2>/dev/null; then
    case "$key" in
      $'\x01') toggle_agents ;;  # Ctrl+A
      r|R) toggle_relay ;;
      a|A) toggle_audit ;;
      h|H) run_health_check ;;
      p|P) show_prompt_log ;;
      b|B) run_builder_status ;;
      f|F) show_flow ;;
      "?") show_help ;;
      q|Q)
        printf '\033[?25h'
        clear
        echo "Dashboard closed."
        exit 0
        ;;
    esac
  fi

  render
done
