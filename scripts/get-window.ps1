
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
