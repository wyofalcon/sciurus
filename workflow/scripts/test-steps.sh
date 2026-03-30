#!/bin/bash
# Quick architect test steps — shown after each build

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

cd "$PROJECT_ROOT" || exit 1

COMMIT_MSG=$(git log --oneline -1 2>/dev/null | sed 's/^[a-f0-9]* //')
CHANGED_FILES=$(git diff HEAD~1 --name-only 2>/dev/null)

echo ""
echo -e "${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}🧪 Test it${NC}  ${DIM}($COMMIT_MSG)${NC}"
echo -e "${CYAN}─────────────────────────────────────────────${NC}"

STEPS=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  case "$f" in
    *EasyCvWizard*)
      STEPS+=("localhost:3000/easy-cv — step through wizard, check live preview updates")
      ;;
    *ResumePage*)
      STEPS+=("localhost:3000/resume — check 'Tailored Resumes' tab and 'Uploaded Resumes' tab")
      ;;
    *UploadResumeModal*)
      STEPS+=("localhost:3000/easy-cv → 'Upload Existing Resume' btn — try PDF, DOCX, TXT")
      STEPS+=("localhost:3000/resume → 'Uploaded Resumes' tab — upload directly from there too")
      ;;
    *ImportResumesModal*)
      STEPS+=("localhost:3000/resume → 'Uploaded Resumes' tab → 'Import to Profile' btn")
      ;;
    *ProfilePage*|*Profile.js*)
      STEPS+=("localhost:3000/profile — verify profile fields display and update correctly")
      ;;
    *Dashboard*)
      STEPS+=("localhost:3000/dashboard — check layout and feature tiles")
      ;;
    *TailorResume*|*tailor*)
      STEPS+=("localhost:3000/tailor-resume — paste a job description and generate output")
      ;;
    *GoldStandard*|*gold*)
      STEPS+=("localhost:3000/gold-standard — verify scoring and feedback display")
      ;;
    *LandingPage*|*Landing*)
      STEPS+=("localhost:3000 (logged out) — check landing page renders correctly")
      ;;
    *Login*|*Signup*|*Auth*)
      STEPS+=("localhost:3000/login and /signup — test auth flow")
      ;;
    *resumeParser*|*parse-resume*)
      STEPS+=("localhost:3000/easy-cv → 'Upload Existing Resume' — upload each type (PDF, DOCX, TXT, RTF)")
      STEPS+=("localhost:3000/resume → Uploaded Resumes tab → upload — confirm parse result")
      ;;
    *geminiService*|*vertex*|*ai-service*)
      STEPS+=("localhost:3000/tailor-resume — trigger AI generation, confirm response")
      STEPS+=("localhost:3000/easy-cv — complete wizard, check AI-generated summary")
      ;;
    *profileAnalyzer*)
      STEPS+=("localhost:3000/profile — add data, confirm completeness score updates")
      ;;
    api/routes/profile.js)
      STEPS+=("localhost:3000/profile — upload resume, check profile sync")
      STEPS+=("localhost:3000/resume → Uploaded Resumes tab — verify list loads")
      ;;
    api/routes/resume.js)
      STEPS+=("localhost:3000/resume — generate and view a resume")
      STEPS+=("localhost:3000/tailor-resume — tailor to a job posting")
      ;;
    api/routes/*.js)
      ROUTE=$(basename "$f" .js)
      STEPS+=("Test ${ROUTE} endpoint — check backend logs: docker compose logs backend --tail 20")
      ;;
    api/services/*.js)
      SVC=$(basename "$f" .js)
      STEPS+=("Exercise the ${SVC} service through the UI — check backend logs for errors")
      ;;
    api/prisma/schema.prisma|api/prisma/migrations/*)
      STEPS+=("Run: docker exec cvstomize-api-local npx prisma migrate deploy")
      ;;
    src/components/*.js)
      COMP=$(basename "$f" .js)
      STEPS+=("localhost:3000 — find and exercise ${COMP}")
      ;;
  esac
done <<< "$CHANGED_FILES"

# Deduplicate and print
printf '%s\n' "${STEPS[@]}" | awk '!seen[$0]++' | while IFS= read -r step; do
  echo -e "  ${YELLOW}→${NC} $step"
done

echo -e "  ${YELLOW}→${NC} ${DIM}cd api && npm test${NC}"
echo -e "${CYAN}─────────────────────────────────────────────${NC}"
echo ""
