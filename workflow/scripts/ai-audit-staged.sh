#!/bin/bash
# AI Audit Staged - Audits all staged files

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$WORKFLOW_ROOT/context/audit-logs"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ai-audit-staged.json"

STAGED_FILES=$(git diff --name-only --cached)

if [ -z "$STAGED_FILES" ]; then
    echo "No staged files to audit."
    exit 0
fi

FAILED=0
echo '{"results": [' > "$LOG_FILE"
FIRST=true

for file in $STAGED_FILES; do
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$LOG_FILE"
    fi
    
    echo "Auditing $file..."
    
    # We will use ai-audit-file.sh but need to handle its specific log output
    # Since ai-audit-file.sh overwrites ai-audit-latest.json, we can read it after
    bash "$SCRIPT_DIR/ai-audit-file.sh" "$file"
    EXIT_CODE=$?
    
    if [ -f "$LOG_DIR/ai-audit-latest.json" ]; then
        cat "$LOG_DIR/ai-audit-latest.json" >> "$LOG_FILE"
    else
        echo '{"severity": "warn", "summary": "Audit failed to produce output", "issues": []}' >> "$LOG_FILE"
    fi
    
    if [ $EXIT_CODE -ne 0 ]; then
        FAILED=1
    fi
done

echo ']}' >> "$LOG_FILE"

exit $FAILED