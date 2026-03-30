#!/bin/bash
# Claude Code Smart Review - Configurable model selection with auto-escalation
# Uses models.conf for configuration
# Replaces the former Copilot CLI review (copilot → claude)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
CONTEXT_DIR="$(dirname "$SCRIPT_DIR")/context"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load configuration
CONFIG_FILE="$CONFIG_DIR/models.conf"
if [ -f "$CONFIG_FILE" ]; then
    # Safe config parsing (no shell execution)
    REVIEW_MODEL_DEFAULT=$(grep '^REVIEW_MODEL_DEFAULT=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    REVIEW_MODEL_DEEP=$(grep '^REVIEW_MODEL_DEEP=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    REVIEW_MODEL_PR=$(grep '^REVIEW_MODEL_PR=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    ESCALATION_LINE_THRESHOLD=$(grep '^ESCALATION_LINE_THRESHOLD=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    ESCALATION_SECURITY_PATTERNS=$(grep '^ESCALATION_SECURITY_PATTERNS=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    ESCALATION_COMPLEXITY_THRESHOLD=$(grep '^ESCALATION_COMPLEXITY_THRESHOLD=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    ESCALATION_COMPLEXITY_PATTERNS=$(grep '^ESCALATION_COMPLEXITY_PATTERNS=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    AUTO_ESCALATION_ENABLED=$(grep '^AUTO_ESCALATION_ENABLED=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
    SHOW_MODEL_INFO=$(grep '^SHOW_MODEL_INFO=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
else
    # Defaults if no config
    REVIEW_MODEL_DEFAULT="claude-sonnet-4-6"
    REVIEW_MODEL_DEEP="claude-opus-4-6"
    REVIEW_MODEL_PR="claude-sonnet-4-6"
    ESCALATION_LINE_THRESHOLD=100
    ESCALATION_SECURITY_PATTERNS="password|secret|api[_-]?key|token|credential|private[_-]?key|auth"
    ESCALATION_COMPLEXITY_THRESHOLD=5
    ESCALATION_COMPLEXITY_PATTERNS="async|await|Promise|Observable|useEffect|useMemo|useCallback"
    AUTO_ESCALATION_ENABLED="true"
    SHOW_MODEL_INFO="true"
    INTERACTIVE_MODEL_SELECT="false"
fi

# Usage
usage() {
    echo "Usage: $0 [options] [file|diff]"
    echo ""
    echo "Options:"
    echo "  -d, --diff         Review staged git diff (default)"
    echo "  -f, --file FILE    Review specific file"
    echo "  -c, --commit SHA   Review specific commit"
    echo "  -p, --pr NUMBER    Review pull request"
    echo "  -m, --model MODEL  Use specific model (overrides config)"
    echo "  --deep             Force deep analysis model"
    echo "  --quick            Force quick/default model"
    echo "  --list-models      Show available models"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Models (from config: $CONFIG_FILE):"
    echo "  Default: $REVIEW_MODEL_DEFAULT"
    echo "  Deep:    $REVIEW_MODEL_DEEP"
    echo "  PR:      $REVIEW_MODEL_PR"
    echo ""
    echo "Examples:"
    echo "  $0                           # Review staged changes"
    echo "  $0 -f src/App.js             # Review specific file"
    echo "  $0 --model gpt-5.2-codex     # Use specific model"
    echo "  $0 --deep -d                 # Force deep model for diff"
}

# List available models
list_models() {
    echo -e "${CYAN}Available Models (Claude Code CLI):${NC}"
    echo ""
    echo -e "${PURPLE}Claude (Anthropic):${NC}"
    echo "  claude-opus-4-6       - Most capable, best for complex reasoning"
    echo "  claude-sonnet-4-6     - Balanced speed and capability (recommended)"
    echo "  claude-haiku-4-5      - Fastest, best for simple tasks"
    echo ""
    echo -e "${YELLOW}Current Config:${NC}"
    echo "  Default Review: $REVIEW_MODEL_DEFAULT"
    echo "  Deep Review:    $REVIEW_MODEL_DEEP"
    echo "  PR Review:      $REVIEW_MODEL_PR"
    echo ""
    echo "Edit: $CONFIG_FILE"
}

# Detect complexity to decide model
detect_complexity() {
    local content="$1"
    local lines=$(echo "$content" | wc -l)
    local has_security=$(echo "$content" | grep -iE "$ESCALATION_SECURITY_PATTERNS" | wc -l)
    local has_complex_patterns=$(echo "$content" | grep -E "$ESCALATION_COMPLEXITY_PATTERNS" | wc -l)

    # Check if auto-escalation is enabled
    if [ "$AUTO_ESCALATION_ENABLED" != "true" ]; then
        echo "default"
        return
    fi

    # Escalate to deep model if:
    # 1. Large diff (exceeds threshold)
    # 2. Security-related changes
    # 3. Complex patterns exceed threshold
    if [ "$lines" -gt "$ESCALATION_LINE_THRESHOLD" ] || [ "$has_security" -gt 0 ]; then
        echo "deep"
        return
    fi

    if [ "$has_complex_patterns" -gt "$ESCALATION_COMPLEXITY_THRESHOLD" ]; then
        echo "deep"
        return
    fi

    echo "default"
}

# Build review prompt based on content type
build_prompt() {
    local review_type="$1"
    local content="$2"

    case "$review_type" in
        diff)
            echo "Review this git diff for:
1. Security issues (secrets, injection, auth bypass)
2. Bugs and logic errors
3. Performance problems
4. Code quality and best practices

Be concise. List issues with severity (CRITICAL/WARNING/INFO).

\`\`\`diff
$content
\`\`\`"
            ;;
        file)
            echo "Review this file for issues:
1. Security vulnerabilities
2. Bugs and edge cases
3. Performance issues
4. Code quality

Be concise. List issues with line numbers and severity.

\`\`\`
$content
\`\`\`"
            ;;
        pr)
            echo "Review this pull request:
1. Overall architecture and approach
2. Security concerns
3. Breaking changes
4. Test coverage gaps

Provide actionable feedback.

$content"
            ;;
    esac
}

# Run the review
run_review() {
    local model_type="$1"
    local prompt="$2"
    local explicit_model="$3"
    local model_name=""

    # Use explicit model if provided, otherwise use config
    if [ -n "$explicit_model" ]; then
        model_name="$explicit_model"
        echo -e "${CYAN}🎯 Using specified model: $model_name${NC}"
    elif [ "$model_type" = "deep" ]; then
        model_name="$REVIEW_MODEL_DEEP"
        if [ "$SHOW_MODEL_INFO" = "true" ]; then
            echo -e "${PURPLE}🧠 Using deep model: $model_name${NC}"
        fi
    elif [ "$model_type" = "pr" ]; then
        model_name="$REVIEW_MODEL_PR"
        if [ "$SHOW_MODEL_INFO" = "true" ]; then
            echo -e "${GREEN}🔀 Using PR model: $model_name${NC}"
        fi
    else
        model_name="$REVIEW_MODEL_DEFAULT"
        if [ "$SHOW_MODEL_INFO" = "true" ]; then
            echo -e "${BLUE}⚡ Using default model: $model_name${NC}"
        fi
    fi

    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if claude is available
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}❌ Claude Code CLI not installed. Run: npm install -g @anthropic-ai/claude-code${NC}"
        exit 1
    fi

    # Run claude in print mode (non-interactive)
    unset NODE_OPTIONS
    claude --model "$model_name" \
        --dangerously-skip-permissions \
        -p "$prompt" \
        --output-format text 2>&1 || {
            echo -e "${RED}❌ Review failed. Check claude CLI auth.${NC}"
            exit 1
        }

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Main
main() {
    local mode="diff"
    local target=""
    local force_model_type=""
    local explicit_model=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--diff)
                mode="diff"
                shift
                ;;
            -f|--file)
                mode="file"
                target="$2"
                shift 2
                ;;
            -c|--commit)
                mode="commit"
                target="$2"
                shift 2
                ;;
            -p|--pr)
                mode="pr"
                target="$2"
                shift 2
                ;;
            -m|--model)
                explicit_model="$2"
                shift 2
                ;;
            --deep|--opus)
                force_model_type="deep"
                shift
                ;;
            --quick|--sonnet)
                force_model_type="default"
                shift
                ;;
            --list-models)
                list_models
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done

    cd "$PROJECT_ROOT"

    # Get content based on mode
    local content=""
    local review_type=""

    case "$mode" in
        diff)
            content=$(git diff --staged 2>/dev/null)
            if [ -z "$content" ]; then
                content=$(git diff 2>/dev/null)
            fi
            if [ -z "$content" ]; then
                echo -e "${YELLOW}No changes to review.${NC}"
                exit 0
            fi
            review_type="diff"
            echo -e "${GREEN}📋 Reviewing staged/unstaged changes...${NC}"
            ;;
        file)
            if [ ! -f "$target" ]; then
                echo -e "${RED}❌ File not found: $target${NC}"
                exit 1
            fi
            content=$(cat "$target")
            review_type="file"
            echo -e "${GREEN}📄 Reviewing file: $target${NC}"
            ;;
        commit)
            content=$(git show "$target" 2>/dev/null)
            if [ -z "$content" ]; then
                echo -e "${RED}❌ Commit not found: $target${NC}"
                exit 1
            fi
            review_type="diff"
            echo -e "${GREEN}📝 Reviewing commit: $target${NC}"
            ;;
        pr)
            # Use gh CLI to get PR info
            content=$(gh pr view "$target" --json title,body,files,additions,deletions 2>/dev/null)
            if [ -z "$content" ]; then
                echo -e "${RED}❌ PR not found: $target${NC}"
                exit 1
            fi
            review_type="pr"
            echo -e "${GREEN}🔀 Reviewing PR #$target${NC}"
            ;;
    esac

    # Determine model type
    local model_type="default"
    if [ -n "$force_model_type" ]; then
        model_type="$force_model_type"
        if [ "$model_type" = "deep" ]; then
            echo -e "${PURPLE}🔍 Forced deep analysis mode${NC}"
        fi
    elif [ "$review_type" = "pr" ]; then
        model_type="pr"
    else
        model_type=$(detect_complexity "$content")
        if [ "$model_type" = "deep" ]; then
            echo -e "${PURPLE}🔍 Complexity detected - auto-escalating${NC}"
        fi
    fi

    # Build and run
    local prompt=$(build_prompt "$review_type" "$content")
    run_review "$model_type" "$prompt" "$explicit_model"

    # Show architect test steps after every review
    bash "$SCRIPT_DIR/test-steps.sh"
}

main "$@"
