param(
    [string]$Title = "Claude Code",
    [string]$Message = "Task complete"
)

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
        [DllImport("user32.dll")]
        public static extern System.IntPtr GetForegroundWindow();
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

# Walk parent process chain to find owning terminal window. Returns both the
# GUI hwnd (shared across all tabs in modern hosts like WT/Tabby) AND the
# pid of the last non-GUI ancestor (= per-tab shell process). Watcher uses
# terminal_pid for liveness — when the tab closes that pid dies and the
# entry can be dropped.
#
# Important: walk starts at the PARENT (not $PID). The current process is
# always the short-lived powershell running this hook.
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

# Force UTF-8 stdin (PowerShell 5.1 defaults to console code page; Claude
# writes UTF-8 hook payload — Chinese / Unicode prompts otherwise corrupt
# the JSON and ConvertFrom-Json fails).
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

# Derive event from message string.
$state = if ($Message -match 'complete|done') { "DONE" }
         elseif ($Message -match 'wait|input') { "WAITING" }
         else { "EVENT" }
$marker = if ($state -eq "DONE") { "[OK]" } elseif ($state -eq "WAITING") { "[WAIT]" } else { "[!]" }

# Per-tab identity from cwd basename (e.g. "agent-core"). cwd is stable
# per CC tab; the GUI hwnd is shared across all tabs in WT/Tabby so it
# can't distinguish them on its own.
$cwdLeaf = ""
if ($cwd) {
    try { $cwdLeaf = Split-Path -Leaf $cwd } catch {}
}
$toastTitle = if ($cwdLeaf) { "$Title - $cwdLeaf" } else { $Title }

$info = Get-TerminalInfo
$hwnd = $info.Hwnd
$terminalPid = $info.TerminalPid

# (A) Taskbar flash — until window comes to foreground.
# Skip when the host window is already foreground: WT/Tabby share one
# hwnd across all tabs, so flashing on the active host is a no-op.
if ($hwnd -ne [System.IntPtr]::Zero) {
    $fg = [CCNotify.W32]::GetForegroundWindow()
    if ($fg -ne $hwnd) {
        $flash = New-Object CCNotify.W32+FLASHWINFO
        $flash.cbSize = [uint32]20
        $flash.hwnd = $hwnd
        $flash.dwFlags = [uint32]15  # FLASHW_ALL (3) | FLASHW_TIMERNOFG (12)
        $flash.uCount = [uint32]0
        $flash.dwTimeout = [uint32]0
        [CCNotify.W32]::FlashWindowEx([ref]$flash) | Out-Null
    }
}

# (B) Window title prefix
$titleHint = ""
if ($hwnd -ne [System.IntPtr]::Zero) {
    $sb = New-Object System.Text.StringBuilder 256
    [CCNotify.W32]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    $current = $sb.ToString()
    $stripped = $current -replace '^\[(OK|WAIT|!)\]\s*', ''
    [CCNotify.W32]::SetWindowText($hwnd, "$marker $stripped") | Out-Null
    $titleHint = $stripped
}
if (-not $titleHint) { $titleHint = Split-Path -Leaf $cwd }

# (D) Status file — consumed by cc-tabs-watcher.ps1
$cacheDir = Join-Path $env:USERPROFILE ".claude\cache"
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}
$safeId = $session_id -replace '[^A-Za-z0-9_-]', '_'
$statusFile = Join-Path $cacheDir "tab_status_$safeId.json"

$status = @{
    session_id   = $session_id
    state        = $state
    cwd          = $cwd
    title        = $titleHint
    hwnd         = [int64]$hwnd
    pid          = $PID
    terminal_pid = $terminalPid
    ts           = (Get-Date).ToString("o")
} | ConvertTo-Json -Compress

$status | Set-Content -Path $statusFile -Encoding utf8

# Toast
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null

$APP_ID = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"

$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$xml = [xml]$template.GetXml()
$xml.SelectSingleNode('//text[@id="1"]').InnerText = $toastTitle
$xml.SelectSingleNode('//text[@id="2"]').InnerText = "$marker $Message"

$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml.OuterXml)

$toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($APP_ID).Show($toast)
