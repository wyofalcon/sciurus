#!/usr/bin/env python3
"""
Screener Agent - Pre-commit code checks (pattern + AI)
Architect: Claude Sonnet 4.6 | Builder: Claude Opus 4.6

This script runs pattern checks, then AI analysis on staged changes.
"""
import subprocess
import sys
import os
import re
from datetime import datetime
from pathlib import Path

# Paths relative to this script's location
SCRIPT_DIR = Path(__file__).parent
WORKFLOW_ROOT = SCRIPT_DIR.parent  # .ai-workflow
CONTEXT_DIR = WORKFLOW_ROOT / "context"
AUDIT_LOG = CONTEXT_DIR / "audit.log"

def log_audit(status: str, target: str, details: str = ""):
    """Append audit result to log file."""
    try:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_line = f"[{timestamp}] [{status}] [{target}] {details}\n"
        with open(AUDIT_LOG, "a") as f:
            f.write(log_line)
    except Exception:
        pass  # Don't fail audit if logging fails

def get_staged_diff():
    """Retrieves the staged changes from git."""
    try:
        result = subprocess.run(
            ["git", "diff", "--staged"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        print("❌ Error: Failed to get staged diff. Is this a git repo?")
        sys.exit(1)

def check_skip_screener():
    """Check if screener should be skipped (Rapid Prototyping mode)."""
    return os.environ.get("SKIP_SCREENER", "").lower() in ("true", "1", "yes") or \
           os.environ.get("SKIP_AUDITOR", "").lower() in ("true", "1", "yes")

def audit_diff(diff):
    """Run pattern-based security and quality checks."""
    issues = {"critical": [], "warning": []}
    lines = diff.split('\n')

    for i, line in enumerate(lines):
        if not line.startswith('+') or line.startswith('+++'):
            continue

        line_content = line[1:]  # Remove the + prefix
        line_lower = line_content.lower()

        # CRITICAL: Hardcoded secrets
        secret_patterns = [
            (r'api[_-]?key\s*[=:]\s*["\'][^"\']{10,}["\']', "API key"),
            (r'password\s*[=:]\s*["\'][^"\']+["\']', "Password"),
            (r'secret\s*[=:]\s*["\'][^"\']{10,}["\']', "Secret"),
            (r'token\s*[=:]\s*["\'][^"\']{20,}["\']', "Token"),
            (r'private[_-]?key', "Private key"),
            (r'-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----', "Private key block"),
        ]

        for pattern, name in secret_patterns:
            if re.search(pattern, line_content, re.IGNORECASE):
                if 'process.env' not in line_content and 'example' not in line_lower and 'test' not in line_lower:
                    issues["critical"].append(f"🔐 Possible {name} found (line ~{i+1})")

        # CRITICAL: SQL injection patterns
        if re.search(r'\$\{.*\}.*(?:SELECT|INSERT|UPDATE|DELETE|DROP)', line_content, re.IGNORECASE):
            issues["critical"].append(f"💉 Possible SQL injection (line ~{i+1})")

        # WARNING: Console.log in non-test files
        if 'console.log' in line_content:
            if not any(x in line_lower for x in ['test', 'spec', 'debug']):
                issues["warning"].append(f"📝 console.log found (line ~{i+1})")

        # WARNING: Debugger statements
        if 'debugger' in line_content:
            issues["warning"].append(f"🐛 debugger statement (line ~{i+1})")

        # WARNING: TODO/FIXME/HACK
        if any(tag in line_content for tag in ['TODO:', 'FIXME:', 'HACK:', 'XXX:']):
            issues["warning"].append(f"📌 TODO/FIXME found (line ~{i+1})")

        # WARNING: Disabled eslint rules
        if 'eslint-disable' in line_content:
            issues["warning"].append(f"⚠️  ESLint disabled (line ~{i+1})")

    return issues

def ai_audit(diff):
    """Run AI-powered analysis on the staged diff using Gemini or Claude CLI."""
    import json as json_mod

    # Check if AI audit is enabled
    models_conf = WORKFLOW_ROOT / "config" / "models.conf"
    ai_enabled = True
    screener_model = "gemini-2.0-flash"

    if models_conf.exists():
        with open(models_conf) as f:
            for line in f:
                line = line.strip()
                if line.startswith("AI_AUDIT_ENABLED="):
                    ai_enabled = line.split("=", 1)[1].strip('"') == "true"
                if line.startswith("SCREENER_MODEL="):
                    screener_model = line.split("=", 1)[1].strip('"')

    if not ai_enabled:
        return {"verdict": "pass", "issues": [], "summary": "AI audit disabled"}

    # Load screener instructions
    instructions_file = WORKFLOW_ROOT / "instructions" / "SCREENER.md"
    if not instructions_file.exists():
        return {"verdict": "pass", "issues": [], "summary": "No screener instructions found"}

    instructions = instructions_file.read_text()

    # Truncate diff to avoid token limits (keep first 8000 chars)
    truncated_diff = diff[:8000]
    if len(diff) > 8000:
        truncated_diff += "\n\n[... diff truncated for AI analysis ...]"

    prompt = f"{instructions}\n\n---\n\nAnalyze this staged diff:\n\n```diff\n{truncated_diff}\n```"

    # Try gemini CLI first (faster for screening), fall back to claude
    cli_cmd = None
    if "gemini" in screener_model:
        import shutil
        if shutil.which("gemini"):
            cli_cmd = ["gemini", "--model", screener_model, "-p", prompt]
    if cli_cmd is None:
        import shutil
        if shutil.which("claude"):
            cli_cmd = ["claude", "--model", "haiku", "-p", prompt, "--output-format", "text"]

    if cli_cmd is None:
        return {"verdict": "pass", "issues": [], "summary": "No AI CLI available"}

    try:
        env = os.environ.copy()
        env.pop("NODE_OPTIONS", None)
        result = subprocess.run(
            cli_cmd,
            capture_output=True, text=True, timeout=60, env=env
        )
        if result.returncode != 0:
            return {"verdict": "pass", "issues": [], "summary": f"AI CLI error: {result.stderr[:100]}"}

        # Parse JSON from output (may have leading/trailing text)
        output = result.stdout.strip()
        # Find JSON object in output
        json_start = output.find("{")
        json_end = output.rfind("}") + 1
        if json_start >= 0 and json_end > json_start:
            parsed = json_mod.loads(output[json_start:json_end])
            return parsed

        return {"verdict": "pass", "issues": [], "summary": "AI returned non-JSON"}
    except subprocess.TimeoutExpired:
        return {"verdict": "pass", "issues": [], "summary": "AI audit timed out (60s)"}
    except (json_mod.JSONDecodeError, Exception) as e:
        return {"verdict": "pass", "issues": [], "summary": f"AI parse error: {str(e)[:80]}"}


def log_full_audit(status: str, issues: dict, diff: str = ""):
    """Write complete audit findings to a timestamped file in audit-logs/."""
    try:
        audit_logs_dir = CONTEXT_DIR / "audit-logs"
        audit_logs_dir.mkdir(exist_ok=True)

        timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")

        # Try to get current commit hash for filename
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=5
            )
            commit_hash = result.stdout.strip() if result.returncode == 0 else "unstaged"
        except Exception:
            commit_hash = "unstaged"

        log_path = audit_logs_dir / f"{timestamp}_{commit_hash}.log"

        # Gather staged file list
        try:
            files_result = subprocess.run(
                ["git", "diff", "--staged", "--name-only"],
                capture_output=True, text=True, timeout=5
            )
            staged_files = files_result.stdout.strip().splitlines() if files_result.returncode == 0 else []
        except Exception:
            staged_files = []

        with open(log_path, "w") as f:
            f.write(f"LOCAL AUDIT REPORT\n")
            f.write(f"==================\n")
            f.write(f"Timestamp : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"Status    : {status}\n")
            f.write(f"Commit    : {commit_hash}\n")
            f.write(f"\nStaged files ({len(staged_files)}):\n")
            for sf in staged_files:
                f.write(f"  {sf}\n")

            if issues["critical"]:
                f.write(f"\nCRITICAL ISSUES ({len(issues['critical'])}):\n")
                for issue in issues["critical"]:
                    f.write(f"  {issue}\n")

            if issues["warning"]:
                f.write(f"\nWARNINGS ({len(issues['warning'])}):\n")
                for issue in issues["warning"]:
                    f.write(f"  {issue}\n")

            if not issues["critical"] and not issues["warning"]:
                f.write("\nNo issues found.\n")

        # Keep a symlink/copy to latest full log for quick access
        latest_path = audit_logs_dir / "full-audit-latest.log"
        try:
            if latest_path.exists() or latest_path.is_symlink():
                latest_path.unlink()
            latest_path.symlink_to(log_path.name)
        except Exception:
            pass  # symlink may fail in some environments, not critical

    except Exception:
        pass  # Never block a commit due to logging failure


def main():
    print("")
    print("="*60)
    print("🔍 SCREENER (Pre-commit)")
    print("   Pattern checks + AI analysis")
    print("="*60)

    # Check if screener should be skipped (Rapid Prototyping mode)
    if check_skip_screener():
        print("⏭️  Screener skipped (SKIP_SCREENER=true / Rapid Prototyping)")
        print("="*60)
        sys.exit(0)

    # Get staged changes
    diff = get_staged_diff()

    if not diff:
        print("ℹ️  No staged changes to audit.")
        print("="*60)
        log_audit("SKIP", "staged-changes", "No staged changes")
        sys.exit(0)

    # Run audit
    issues = audit_diff(diff)

    # Report pattern findings
    if issues["critical"]:
        print("\n❌ CRITICAL ISSUES (must fix):")
        for issue in issues["critical"]:
            print(f"   {issue}")

    if issues["warning"]:
        print("\n⚠️  WARNINGS (consider fixing):")
        for issue in issues["warning"][:10]:
            print(f"   {issue}")
        if len(issues["warning"]) > 10:
            print(f"   ... and {len(issues['warning']) - 10} more")

    # AI analysis (only if pattern checks passed — don't waste time on obvious failures)
    ai_result = None
    if not issues["critical"]:
        print("\n🤖 Running AI analysis...")
        ai_result = ai_audit(diff)
        ai_verdict = ai_result.get("verdict", "pass")
        ai_issues = ai_result.get("issues", [])
        ai_summary = ai_result.get("summary", "")

        if ai_issues:
            ai_blocks = [i for i in ai_issues if i.get("severity") == "critical"]
            ai_warns = [i for i in ai_issues if i.get("severity") == "warning"]

            if ai_blocks:
                print(f"\n🤖 AI CRITICAL ({len(ai_blocks)}):")
                for item in ai_blocks:
                    print(f"   ❌ {item.get('file', '?')}:{item.get('line', '?')} — {item.get('message', '')}")
                issues["critical"].extend([f"🤖 {i.get('message', '')}" for i in ai_blocks])

            if ai_warns:
                print(f"\n🤖 AI WARNINGS ({len(ai_warns)}):")
                for item in ai_warns[:5]:
                    print(f"   ⚠️  {item.get('file', '?')}:{item.get('line', '?')} — {item.get('message', '')}")
                issues["warning"].extend([f"🤖 {i.get('message', '')}" for i in ai_warns])

        if ai_summary:
            print(f"\n   🤖 AI: {ai_summary}")
        elif ai_verdict == "pass" and not ai_issues:
            print("   🤖 AI: Clean")

    print("")
    print("="*60)

    # Save full findings to audit-logs/ before verdict
    if issues["critical"]:
        log_full_audit("FAIL", issues, diff)
    elif issues["warning"]:
        log_full_audit("WARN", issues, diff)
    else:
        log_full_audit("PASS", issues, diff)

    # Verdict
    if issues["critical"]:
        print("❌ AUDIT FAILED - Fix critical issues before committing")
        print("="*60)
        log_audit("FAIL", "staged-changes", f"Critical: {len(issues['critical'])}, Warnings: {len(issues['warning'])}")
        sys.exit(1)
    elif issues["warning"]:
        print("⚠️  AUDIT PASSED with warnings")
        print("="*60)
        log_audit("WARN", "staged-changes", f"Warnings: {len(issues['warning'])}")
        sys.exit(0)
    else:
        print("✅ AUDIT PASSED - No issues detected")
        print("="*60)
        log_audit("PASS", "staged-changes", "Clean")

        # Auto-update prompt tracker: mark most recent SENT/BUILDING prompt as DONE
        auto_complete_prompt()

        # Auto-update ROADMAP.md with the latest commit
        auto_update_roadmap()

        # Compress logs if commit threshold or line threshold is reached
        auto_compress_logs()

        sys.exit(0)

def auto_update_roadmap():
    """Update ROADMAP.md Completed section with the latest commit."""
    roadmap_script = SCRIPT_DIR / "update-roadmap.sh"
    if not roadmap_script.exists():
        return
    try:
        result = subprocess.run(
            ["bash", str(roadmap_script)],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip():
            print(result.stdout.strip())
    except Exception:
        pass  # Don't fail audit if roadmap update fails


def auto_compress_logs():
    """Compress workflow logs when commit threshold or line threshold is reached."""
    compress_script = SCRIPT_DIR / "compress-logs.sh"
    if not compress_script.exists():
        return
    try:
        result = subprocess.run(
            ["bash", str(compress_script)],
            capture_output=True, text=True, timeout=15
        )
        if result.stdout.strip():
            print(result.stdout.strip())
    except Exception:
        pass  # Don't fail audit if compression fails


def auto_complete_prompt():
    """If there's an active prompt (SENT or BUILDING), mark it DONE after successful commit."""
    tracker_file = CONTEXT_DIR / "PROMPT_TRACKER.log"
    tracker_script = SCRIPT_DIR / "prompt-tracker.sh"
    if not tracker_file.exists() or not tracker_script.exists():
        return
    try:
        with open(tracker_file, "r") as f:
            lines = f.readlines()
        # Find the most recent CRAFTED, SENT, or BUILDING prompt
        for line in reversed(lines):
            parts = line.strip().split("|")
            if len(parts) >= 4 and parts[1] in ("CRAFTED", "SENT", "BUILDING"):
                prompt_id = parts[0]
                subprocess.run(
                    [str(tracker_script), "status", prompt_id, "DONE"],
                    capture_output=True, timeout=5
                )
                print(f"\n   🏷️  Prompt {prompt_id} → DONE")
                break
    except Exception:
        pass  # Don't fail audit if tracker update fails

if __name__ == "__main__":
    main()
