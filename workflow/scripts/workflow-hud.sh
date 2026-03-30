#!/bin/bash
# Workflow HUD — persistent dashboard for the AI dev workflow.
# Runs in its own dedicated VS Code terminal (group: hud-panel).
#
# Features:
#   - Auto-refreshes every 5 seconds
#   - Live git status (staged/unstaged/ahead/behind)
#   - Docker service health indicators
#   - Time since last commit
#   - Alert banner for workflow changes + stale docs
#   - Keyboard shortcuts for common actions
#

# Restore cursor on any exit (normal, interrupt, kill)
trap 'printf "\033[?25h"' EXIT
# Usage: bash .ai-workflow/scripts/workflow-hud.sh

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
BG_RED='\033[41m'
BG_BLUE='\033[44m'
NC='\033[0m'

# Track last action message (shown briefly after a keypress)
ACTION_MSG=""
ACTION_EXPIRE=0

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
  local now elapsed m h
  now=$(date +%s)
  elapsed=$((now - ts))
  if [ "$elapsed" -lt 60 ]; then
    echo "${elapsed}s ago"
  elif [ "$elapsed" -lt 3600 ]; then
    m=$((elapsed / 60))
    echo "${m}m ago"
  elif [ "$elapsed" -lt 86400 ]; then
    h=$((elapsed / 3600))
    m=$(( (elapsed % 3600) / 60))
    echo "${h}h ${m}m ago"
  else
    echo "$(( elapsed / 86400 ))d ago"
  fi
}

get_last_commit_short() {
  git -C "$PROJECT_ROOT" log -1 --pretty="%h %s" 2>/dev/null | head -c 50
}

get_last_prompt() {
  if [ -f "$TRACKER_LOG" ]; then
    local last
    last=$(tail -1 "$TRACKER_LOG" 2>/dev/null)
    if [ -n "$last" ]; then
      local id status
      id=$(echo "$last" | cut -d'|' -f1)
      status=$(echo "$last" | cut -d'|' -f2)
      echo -e "${CYAN}$id${NC} ${DIM}[$status]${NC}"
    else
      echo -e "${DIM}none${NC}"
    fi
  else
    echo -e "${DIM}none${NC}"
  fi
}

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
    ACTION_MSG="Audit → OFF"
  else
    echo "on" > "$AUDIT_MODE_FILE"
    ACTION_MSG="Audit → ON"
  fi
  ACTION_EXPIRE=$(($(date +%s) + 3))
}

run_health_check() {
  ACTION_MSG="Running health check..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""

  # Run health check, display live, and capture output for command extraction
  local tmpfile
  tmpfile=$(mktemp)
  bash "$SCRIPT_DIR/ensure-workflow.sh" 2>&1 | tee "$tmpfile" || true

  # Strip ANSI codes and extract unique "— run: <command>" patterns
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
    echo -e "  ${DIM}[Enter] Return to HUD${NC}"
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
      echo -e "${DIM}Press any key to return to HUD...${NC}"
      read -rsn1
    fi
  else
    echo -e "${DIM}Press any key to return to HUD...${NC}"
    read -rsn1
  fi

  ACTION_MSG=""
}

run_doc_sync() {
  ACTION_MSG="Checking doc sync..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""
  bash "$SCRIPT_DIR/doc-sync-check.sh" 2>&1
  echo ""
  echo -e "${DIM}Press any key to return to HUD...${NC}"
  read -rsn1
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
  echo -e "${DIM}Press any key to return to HUD...${NC}"
  read -rsn1
  ACTION_MSG=""
}

run_builder_status() {
  ACTION_MSG="Checking builder..."
  ACTION_EXPIRE=$(($(date +%s) + 2))
  render
  echo ""
  if [ -x "$SCRIPT_DIR/builder-status.sh" ]; then
    bash "$SCRIPT_DIR/builder-status.sh" 2>&1
  else
    echo -e "${DIM}Builder status script not available${NC}"
  fi
  echo ""
  echo -e "${DIM}Press any key to return to HUD...${NC}"
  read -rsn1
  ACTION_MSG=""
}

# ── Render ───────────────────────────────────────────────

render() {
  # Build output into a buffer, then clear + print atomically to minimize flicker
  local buf=""
  local relay_mode audit_mode branch git_status time_since last_commit
  relay_mode=$(get_relay_mode)
  audit_mode=$(get_audit_mode)
  branch=$(get_branch)
  git_status=$(get_git_status)
  time_since=$(get_time_since_commit)
  last_commit=$(get_last_commit_short)

  # ── Alert Banner (only if issues exist) ──
  if [ -f "$WORKFLOW_PENDING_FILE" ] || [ -f "$DOC_SYNC_FLAG" ]; then
    buf+="${BG_YELLOW}${WHITE}${BOLD}  ⚠  ALERTS                                                ${NC}\n"
    if [ -f "$WORKFLOW_PENDING_FILE" ]; then
      buf+="  ${YELLOW}⚠${NC}  Workflow change pending — confirm or revert\n"
    fi
    if [ -f "$DOC_SYNC_FLAG" ]; then
      local sync_info
      sync_info=$(cat "$DOC_SYNC_FLAG" 2>/dev/null | head -1)
      buf+="  ${RED}📄${NC} Docs out of sync ${DIM}($sync_info)${NC} — press ${BOLD}d${NC}\n"
    fi
    buf+="\n"
  fi

  # ── Header ──
  buf+="${BLUE}╔══════════════════════════════════════════════════════════╗${NC}\n"
  buf+="${BLUE}║${NC}  ${BOLD}${WHITE}CVstomize Workflow HUD${NC}              ${DIM}$(date '+%H:%M:%S CT')${NC}  ${BLUE}║${NC}\n"
  buf+="${BLUE}╠══════════════════════════════════════════════════════════╣${NC}\n"

  # ── Copilot Prefixes ──
  buf+="${BLUE}║${NC}  ${BOLD}📋 COPILOT PREFIXES${NC}                                    ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}  ${DIM}─────────────────────────────────────────────────${NC}  ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}   ${GREEN}!${NC}  ${BOLD}Builder task${NC}     Architect refines → Builder     ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}   ${CYAN}!!${NC} ${BOLD}Direct build${NC}    Skip refinement → Builder        ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}   ${YELLOW}?${NC}  ${BOLD}Queue${NC}           Save for later (!drain to run)  ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}   ${PURPLE}\$${NC}  ${BOLD}Workflow edit${NC}   Change workflow files/scripts    ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}   ${DIM}(none)${NC} ${BOLD}Direct${NC}       Architect answers/runs commands  ${BLUE}║${NC}\n"

  # ── AI WORKFLOW section ──
  buf+="${BLUE}╠══════════════════════════════════════════════════════════╣${NC}\n"
  buf+="${BLUE}║${NC}  ${BOLD}${PURPLE}🤖 AI WORKFLOW${NC}                                         ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}  ${DIM}─────────────────────────────────────────────────${NC}  ${BLUE}║${NC}\n"

  # Tmux sessions
  buf+="${BLUE}║${NC}   ${BOLD}tmux${NC}   $(tmux_dot builder) builder  $(tmux_dot reviewer) reviewer  $(tmux_dot shell) shell       ${BLUE}║${NC}\n"

  # Relay mode
  if [ "$relay_mode" = "auto" ]; then
    buf+="${BLUE}║${NC}   📤 Relay  ${BG_GREEN}${WHITE} AUTO-INJECT ${NC}  prompts → builder tmux  ${BLUE}║${NC}\n"
  else
    buf+="${BLUE}║${NC}   📤 Relay  ${BG_YELLOW}${WHITE} REVIEW ${NC}      you paste the prompt      ${BLUE}║${NC}\n"
  fi

  # Audit mode
  if [ "$audit_mode" = "on" ]; then
    buf+="${BLUE}║${NC}   🔍 Audit  ${GREEN}ON${NC}            watching file changes        ${BLUE}║${NC}\n"
  else
    buf+="${BLUE}║${NC}   🔍 Audit  ${YELLOW}OFF${NC}           paused                       ${BLUE}║${NC}\n"
  fi

  # Last prompt
  buf+="${BLUE}║${NC}   🏷  Prompt $(get_last_prompt)\n"

  # ── PROJECT section ──
  buf+="${BLUE}╠══════════════════════════════════════════════════════════╣${NC}\n"
  buf+="${BLUE}║${NC}  ${BOLD}${CYAN}📦 PROJECT${NC}                                              ${BLUE}║${NC}\n"
  buf+="${BLUE}║${NC}  ${DIM}─────────────────────────────────────────────────${NC}  ${BLUE}║${NC}\n"

  # Docker services
  buf+="${BLUE}║${NC}   ${BOLD}docker${NC} $(docker_dot db) db  $(docker_dot api) api  $(docker_dot frontend) frontend                  ${BLUE}║${NC}\n"

  # Git info
  buf+="${BLUE}║${NC}   🌿 Branch  ${CYAN}${branch}${NC}\n"
  buf+="${BLUE}║${NC}   📝 Status  ${git_status}\n"
  buf+="${BLUE}║${NC}   🕐 Commit  ${DIM}${time_since}${NC} ${DIM}— ${last_commit}${NC}\n"

  # ── Controls ──
  buf+="${BLUE}╠══════════════════════════════════════════════════════════╣${NC}\n"
  buf+="${BLUE}║${NC}  ${BOLD}r${NC} relay  ${BOLD}a${NC} audit  ${BOLD}h${NC} health  ${BOLD}d${NC} docs  ${BOLD}p${NC} prompts  ${BOLD}q${NC} quit ${BLUE}║${NC}\n"

  # Action feedback bar
  if [ -n "$ACTION_MSG" ] && [ "$(date +%s)" -lt "$ACTION_EXPIRE" ]; then
    buf+="${BLUE}║${NC}  ${GREEN}→ ${ACTION_MSG}${NC}\n"
  fi

  buf+="${BLUE}╚══════════════════════════════════════════════════════════╝${NC}\n"

  # Atomic: clear screen and print buffer in one shot
  printf '\033[?25l'
  clear
  echo -ne "$buf"
  printf '\033[?25h'
}

# ── Main Loop ────────────────────────────────────────────

render

while true; do
  if read -rsn1 -t 5 key 2>/dev/null; then
    case "$key" in
      r|R) toggle_relay ;;
      a|A) toggle_audit ;;
      h|H) run_health_check ;;
      d|D) run_doc_sync ;;
      p|P) show_prompt_log ;;
      b|B) run_builder_status ;;
      q|Q)
        printf '\033[?25h'
        clear
        echo "HUD closed."
        exit 0
        ;;
    esac
  fi
  render
done
