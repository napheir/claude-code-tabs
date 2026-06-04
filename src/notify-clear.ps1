param()

# Clears the current session's status file + stops taskbar flash + resets
# window title prefix. Wired to the user-level SessionStart hook so a tab that
# starts a fresh session (or runs /clear) drops its stale prior entry from the
# panel and stops blinking.
#
# IMPORTANT: SessionStart does NOT only fire on a fresh start. It also fires
# with source "compact" (auto/manual context compaction) and "resume". In those
# cases the SAME session keeps working and will NOT emit a new UserPromptSubmit,
# so notify-busy never re-fires to rebuild the status file. Deleting on those
# events makes an actively-working tab silently vanish from the panel until its
# next Stop. This script therefore only clears on a genuine fresh start.

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

function Get-TerminalHwnd {
    $cur = $PID
    for ($i = 0; $i -lt 12; $i++) {
        $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
        if ($null -eq $proc) { break }
        if ($proc.MainWindowHandle -ne [System.IntPtr]::Zero) {
            return $proc.MainWindowHandle
        }
        $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
        if ($null -eq $parent -or $parent -eq 0 -or $parent -eq $cur) { break }
        $cur = [int]$parent
    }
    return [System.IntPtr]::Zero
}

# Force UTF-8 stdin (PS 5.1 default code page corrupts non-ASCII payloads).
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

# Read session_id + source from stdin (best-effort). SessionStart payload
# carries source in {startup, resume, clear, compact}.
$session_id = ""
$source = ""
try {
    $stdin_json = [Console]::In.ReadToEnd()
    if ($stdin_json -and $stdin_json[0] -eq [char]0xFEFF) {
        $stdin_json = $stdin_json.Substring(1)
    }
    if ($stdin_json) {
        $data = $stdin_json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.session_id) { $session_id = $data.session_id }
        if ($data -and $data.source) { $source = [string]$data.source }
    }
} catch {}
if (-not $session_id) { $session_id = [string]$PID }

$safeId = $session_id -replace '[^A-Za-z0-9_-]', '_'
$cacheDir = Join-Path $env:USERPROFILE ".claude\cache"
$statusFile = Join-Path $cacheDir "tab_status_$safeId.json"

# Delete status file (watcher drops the entry on next refresh) -- but ONLY on a
# genuine fresh start. On "compact" / "resume" the same session keeps working
# without a new UserPromptSubmit, so clearing here would leave the tab invisible
# until its next Stop. "startup" / "clear" (and an unknown/empty source, which
# preserves legacy behavior) still clear the entry.
$isContinuation = ($source -eq 'compact') -or ($source -eq 'resume')
if ((Test-Path $statusFile) -and (-not $isContinuation)) {
    Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
}

# Stop taskbar flash + strip title prefix
$hwnd = Get-TerminalHwnd
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
    if ($current -match '^\[(OK|WAIT|!)\]\s*') {
        $stripped = $current -replace '^\[(OK|WAIT|!)\]\s*', ''
        [CCNotify.W32]::SetWindowText($hwnd, $stripped) | Out-Null
    }
}
