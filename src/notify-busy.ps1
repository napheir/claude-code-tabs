param()

# Mark the current CC session as BUSY (user just submitted a prompt; CC is now
# working). Wired to the UserPromptSubmit hook. Replaces the previous
# notify-clear wiring on that event so the Claude Tabs panel can show an
# explicit "in progress" between two DONE states — without this, the panel
# stays on the previous [DONE] indefinitely and the user can't tell whether
# the next task has started or finished.

$ErrorActionPreference = "SilentlyContinue"

if (-not ("CCNotify.W32" -as [type])) {
    Add-Type -Namespace CCNotify -Name W32 -MemberDefinition @"
        [DllImport("user32.dll")]
        public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
        [DllImport("user32.dll", CharSet=CharSet.Auto)]
        public static extern int SetWindowText(System.IntPtr hWnd, string text);
        [DllImport("user32.dll", CharSet=CharSet.Auto)]
        public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder s, int n);
        [DllImport("user32.dll")]
        public static extern int GetWindowTextLength(System.IntPtr hWnd);
        [StructLayout(LayoutKind.Sequential)]
        public struct FLASHWINFO {
            public uint cbSize;
            public System.IntPtr hwnd;
            public uint dwFlags;
            public uint uCount;
            public uint dwTimeout;
        }
"@
}

# Walk parent chain to find host GUI window + per-tab shell pid. Starts at
# parent (not $PID) — current powershell is short-lived hook script and
# cannot serve as terminal_pid (would be killed by watcher liveness).
function Get-TerminalInfo {
    $startProc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if (-not $startProc) { return @{ Hwnd = [System.IntPtr]::Zero; TerminalPid = $PID } }
    $parent = [int]$startProc.ParentProcessId
    if ($parent -le 0) { return @{ Hwnd = [System.IntPtr]::Zero; TerminalPid = $PID } }

    $cur = $parent
    $lastShellPid = $cur
    for ($i = 0; $i -lt 12; $i++) {
        $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
        if ($null -eq $proc) { break }
        if ($proc.MainWindowHandle -ne [System.IntPtr]::Zero) {
            return @{ Hwnd = $proc.MainWindowHandle; TerminalPid = $lastShellPid }
        }
        $lastShellPid = $cur
        $next = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
        if ($null -eq $next -or $next -eq 0 -or $next -eq $cur) { break }
        $cur = [int]$next
    }
    return @{ Hwnd = [System.IntPtr]::Zero; TerminalPid = $lastShellPid }
}

# Force UTF-8 stdin decode. PowerShell 5.1 defaults to console code page
# (GBK on Chinese Windows / cp936); Claude Code writes UTF-8 hook payload.
# Without this, prompts containing Chinese / Unicode chars become mojibake
# and ConvertFrom-Json fails on invalid control chars.
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

$session_id = ""
$cwd = (Get-Location).Path
try {
    $stdin_json = [Console]::In.ReadToEnd()
    if ($stdin_json) {
        $data = $stdin_json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data) {
            if ($data.session_id) { $session_id = $data.session_id }
            if ($data.cwd) { $cwd = $data.cwd }
        }
    }
} catch {}
if (-not $session_id) { $session_id = [string]$PID }

$info = Get-TerminalInfo
$hwnd = $info.Hwnd
$terminalPid = $info.TerminalPid

# Stop flash + strip title prefix from prior DONE/WAIT
$titleHint = ""
if ($hwnd -ne [System.IntPtr]::Zero) {
    $flash = New-Object CCNotify.W32+FLASHWINFO
    $flash.cbSize = [uint32]20
    $flash.hwnd = $hwnd
    $flash.dwFlags = [uint32]0  # FLASHW_STOP
    $flash.uCount = [uint32]0
    $flash.dwTimeout = [uint32]0
    [CCNotify.W32]::FlashWindowEx([ref]$flash) | Out-Null

    $sb = New-Object System.Text.StringBuilder 256
    [CCNotify.W32]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    $current = $sb.ToString()
    $stripped = $current -replace '^\[(OK|WAIT|!)\]\s*', ''
    if ($stripped -ne $current) {
        [CCNotify.W32]::SetWindowText($hwnd, $stripped) | Out-Null
    }
    $titleHint = $stripped
}
if (-not $titleHint) { $titleHint = Split-Path -Leaf $cwd }

# Write BUSY status file
$cacheDir = Join-Path $env:USERPROFILE ".claude\cache"
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}
$safeId = $session_id -replace '[^A-Za-z0-9_-]', '_'
$statusFile = Join-Path $cacheDir "tab_status_$safeId.json"

$status = @{
    session_id   = $session_id
    state        = "BUSY"
    cwd          = $cwd
    title        = $titleHint
    hwnd         = [int64]$hwnd
    pid          = $PID
    terminal_pid = $terminalPid
    ts           = (Get-Date).ToString("o")
} | ConvertTo-Json -Compress

$status | Set-Content -Path $statusFile -Encoding utf8
