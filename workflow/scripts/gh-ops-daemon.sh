#!/bin/bash
# GitHub Operations Daemon
# Runs in the background to monitor git state and suggest actions

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$WORKFLOW_ROOT")"

LOG_FILE="$WORKFLOW_ROOT/context/gh-ops.log"
NOTIFY_FILE="$WORKFLOW_ROOT/context/GH_OPS_NOTIFY.md"

# Colors for log
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BRANCH_MAP=(
  "feature/easycv:src/components/EasyCv|src/components/FeatureHints"
  "feature/auth:src/contexts/Auth|api/middleware/auth"
  "feature/extension:chrome-extension|extension-dist"
  "feature/api:api/routes|api/services|api/controllers"
  "feature/tests:tests/|api/__tests__"
  "feature/infra:.devcontainer|.ai-workflow|docker-compose|ci/"
)

log_msg() {
    local color=$1
    local msg=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${color}[${timestamp}] ${msg}${NC}" | tee -a "$LOG_FILE"
}

notify_user() {
    local msg=$1
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "### [${timestamp}] GH Ops Notification

${msg}

---
" >> "$NOTIFY_FILE"
}

# Ensure context dir exists
mkdir -p "$(dirname "$LOG_FILE")"

# Touch notification file if it doesn't exist
touch "$NOTIFY_FILE"

cd "$PROJECT_ROOT" || exit 1

log_msg "$GREEN" "GH Ops Daemon Started"

# --- Startup Checks ---
log_msg "$BLUE" "Running startup checks..."

# Check auth
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    GH_AUTH=true
else
    GH_AUTH=false
    log_msg "$YELLOW" "gh CLI not authenticated. Skipping GitHub-specific checks."
fi

# Sync remote
log_msg "$BLUE" "Fetching from remote..."
git fetch --all --prune &>> "$LOG_FILE"

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)

if [ -n "$CURRENT_BRANCH" ]; then
    # Check if remote exists
    if ! git ls-remote --heads origin "$CURRENT_BRANCH" | grep -q "$CURRENT_BRANCH"; then
        if git rev-parse --verify --quiet "origin/$CURRENT_BRANCH" > /dev/null; then
           # It exists on origin
           :
        else
           log_msg "$YELLOW" "Current branch '$CURRENT_BRANCH' has no remote tracking branch on origin."
        fi
    else
        # Try to pull if behind
        BEHIND=$(git rev-list --count HEAD..origin/"$CURRENT_BRANCH" 2>/dev/null || echo 0)
        if [ "$BEHIND" -gt 0 ]; then
            log_msg "$YELLOW" "Branch is behind origin by $BEHIND commits. Attempting pull --rebase..."
            if git pull --rebase &>> "$LOG_FILE"; then
                log_msg "$GREEN" "Successfully updated branch."
            else
                log_msg "$RED" "Pull failed. Reverting..."
                git rebase --abort &>> "$LOG_FILE" || true
                notify_user "⚠️ **Branch Behind Remote & Pull Failed**

Your branch `$CURRENT_BRANCH` is behind remote, and auto-pull failed (likely conflicts). Run:
```bash
git pull --rebase
```
and resolve conflicts."
            fi
        fi
    fi
fi

if [ "$1" = "--once" ]; then
    log_msg "$GREEN" "Ran startup checks. Exiting due to --once flag."
    exit 0
fi

# --- Polling Loop ---
log_msg "$GREEN" "Entering polling loop..."

while true; do
    sleep 60

    CURRENT_BRANCH=$(git branch --show-current)

    # a) Detect uncommitted changes and their age
    if ! git diff-index --quiet HEAD --; then
        # Changes exist. We can check age roughly by finding the oldest modified tracked file in work tree
        OLDEST_CHANGE=$(git ls-files -m | while read file; do stat -c %Y "$file" 2>/dev/null; done | sort -n | head -1)
        if [ -n "$OLDEST_CHANGE" ]; then
            NOW=$(date +%s)
            AGE=$((NOW - OLDEST_CHANGE))
            if [ "$AGE" -gt 1800 ]; then # 30 mins
                # Don't spam notifications
                if ! grep -q "Uncommitted changes > 30 mins old" "$NOTIFY_FILE" 2>/dev/null; then
                    log_msg "$YELLOW" "Uncommitted changes detected > 30 mins old."
                    notify_user "🕒 **Uncommitted changes > 30 mins old**

You have uncommitted changes that are getting old. Consider committing them:
```bash
git add .
git commit -m "wip: saving progress"
```"
                fi
            fi
        fi
    fi

    # b & c) Detect if behind or diverged
    if [ -n "$CURRENT_BRANCH" ] && git rev-parse --verify --quiet "origin/$CURRENT_BRANCH" > /dev/null; then
        git fetch origin "$CURRENT_BRANCH" &> /dev/null
        BEHIND=$(git rev-list --count HEAD..origin/"$CURRENT_BRANCH" 2>/dev/null || echo 0)
        AHEAD=$(git rev-list --count origin/"$CURRENT_BRANCH"..HEAD 2>/dev/null || echo 0)

        if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -eq 0 ]; then
            if git pull --rebase &> /dev/null; then
                log_msg "$GREEN" "Auto-pulled updates for $CURRENT_BRANCH."
            fi
        elif [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
            if ! grep -q "Branch diverged from remote" "$NOTIFY_FILE" 2>/dev/null; then
               log_msg "$RED" "Branch diverged from remote."
               notify_user "⚠️ **Branch Diverged**

Your branch `$CURRENT_BRANCH` has diverged from the remote. You should rebase:
```bash
git pull --rebase
```"
            fi
        fi
    fi

    # d) Suggest branch creation for mixed-scope changes
    # Simple check: look at staged files
    STAGED_FILES=$(git diff --name-only --cached)
    if [ -n "$STAGED_FILES" ]; then
        frontend_changes=0
        backend_changes=0
        for file in $STAGED_FILES; do
            if [[ "$file" == src/* ]]; then frontend_changes=1; fi
            if [[ "$file" == api/* ]]; then backend_changes=1; fi
        done
        if [ "$frontend_changes" -eq 1 ] && [ "$backend_changes" -eq 1 ]; then
            # Check if recently notified
            if ! grep -q "Mixed scope changes detected" "$NOTIFY_FILE" 2>/dev/null; then
                log_msg "$YELLOW" "Mixed scope changes detected in staged files."
                notify_user "💡 **Mixed Scope Changes**

You have both frontend (`src/`) and backend (`api/`) changes staged. Consider splitting them into separate commits or branches if they are unrelated features."
            fi
        fi
    fi

    # e) Suggest switching branches when working on wrong files
    if [ -n "$CURRENT_BRANCH" ]; then
        MODIFIED_FILES=$(git ls-files -m)
        if [ -n "$MODIFIED_FILES" ]; then
            for file in $MODIFIED_FILES; do
                for map_entry in "${BRANCH_MAP[@]}"; do
                    branch_pattern="${map_entry%%:*}"
                    path_pattern="${map_entry#*:}"

                    if echo "$file" | grep -qE "$path_pattern"; then
                        # File matches a path pattern. Are we on the right branch?
                        if [[ ! "$CURRENT_BRANCH" == $branch_pattern* ]]; then
                           # Notify
                           if ! grep -q "Possible wrong branch" "$NOTIFY_FILE" 2>/dev/null; then
                               log_msg "$YELLOW" "Editing $file on branch $CURRENT_BRANCH instead of $branch_pattern."
                               notify_user "💡 **Possible Wrong Branch**

You are editing `$file` on branch `$CURRENT_BRANCH`. Based on project conventions, this file usually belongs in a `$branch_pattern*` branch.

To stash and switch:
```bash
git stash
git checkout -b $branch_pattern-your-feature
git stash pop
```"
                           fi
                        fi
                    fi
                done
            done
        fi
    fi

    # f) Monitor for stale branches
    STALE_BRANCHES=$(git for-each-ref --sort=-committerdate refs/heads/ --format='%(refname:short) %(committerdate:unix)' | while read branch date; do
        NOW=$(date +%s)
        AGE=$((NOW - date))
        if [ "$AGE" -gt 604800 ] && [ "$branch" != "main" ] && [ "$branch" != "master" ] && [ "$branch" != "staging" ]; then # 7 days
            echo "$branch"
        fi
    done)

    if [ -n "$STALE_BRANCHES" ]; then
        if ! grep -q "Stale Branches Detected" "$NOTIFY_FILE" 2>/dev/null; then
            log_msg "$YELLOW" "Stale branches detected."
            msg="🧹 **Stale Branches Detected**

The following local branches haven't been updated in over 7 days:
"
            for b in $STALE_BRANCHES; do
                msg="$msg- `$b`
"
            done
            msg="$msg
To delete a branch:
```bash
git branch -D <branch-name>
```"
            notify_user "$msg"
        fi
    fi

done
