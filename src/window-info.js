// src/window-info.js — Capture active window metadata (title + process) via PowerShell
// Zero dependencies — uses Win32 API through PowerShell's Add-Type

const { execSync, execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// Write PowerShell script to a file to avoid all quoting/escaping issues
const PS_SCRIPT_PATH = path.join(__dirname, '..', 'scripts', 'get-window.ps1');

function ensureScript() {
  const dir = path.dirname(PS_SCRIPT_PATH);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  if (!fs.existsSync(PS_SCRIPT_PATH)) {
    fs.writeFileSync(PS_SCRIPT_PATH, `
Add-Type -Name U -Namespace W -MemberDefinition @"
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int c);
"@ -ErrorAction SilentlyContinue

$h = [W.U]::GetForegroundWindow()
$sb = New-Object System.Text.StringBuilder 512
[void][W.U]::GetWindowText($h, $sb, 512)
$wpid = [uint32]0
[void][W.U]::GetWindowThreadProcessId($h, [ref]$wpid)
$p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
"$($sb.ToString())|$($p.ProcessName)|$($p.Path)"
`, 'utf8');
  }
}

/**
 * Get the currently focused window's title and process name.
 * Must be called synchronously BEFORE opening the capture popup,
 * otherwise the foreground window will be the capture window itself.
 *
 * @returns {{ title: string|null, processName: string|null, processPath: string|null }}
 */
function getActiveWindow() {
  try {
    ensureScript();
    const out = execFileSync('powershell', [
      '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
      '-File', PS_SCRIPT_PATH,
    ], {
      encoding: 'utf8',
      timeout: 3000,
      windowsHide: true,
    }).trim();

    const [title, processName, processPath] = out.split('|');
    return {
      title: title || null,
      processName: processName || null,
      processPath: processPath || null,
    };
  } catch (e) {
    console.error('[WindowInfo] Failed to get active window:', e.message);
    return { title: null, processName: null, processPath: null };
  }
}

module.exports = { getActiveWindow };
