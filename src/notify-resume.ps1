param()

# Lightweight resume hook for PreToolUse. Transitions a WAITING status entry
# to BUSY when CC fires the first tool call after the user resolves a
# Notification (e.g. permission prompt). Permission grants do not fire
# UserPromptSubmit, so without this the panel is stuck at [WAIT] until the
# next Stop event makes it [DONE] -- user can't tell whether CC is still
# waiting or back to work.
#
# Designed for hot path: PreToolUse can fire 50-100x per task. Early-exit
# when state is not WAITING keeps the per-call cost to a JSON parse +
# string compare. No window walk, no toast, no flash.

$ErrorActionPreference = "SilentlyContinue"

# Force UTF-8 stdin (PS 5.1 default code page corrupts non-ASCII payloads).
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

# Read CC stdin payload for session_id (only field we need).
$session_id = ""
try {
    $stdin_json = [Console]::In.ReadToEnd()
    if ($stdin_json -and $stdin_json[0] -eq [char]0xFEFF) {
        $stdin_json = $stdin_json.Substring(1)
    }
    if ($stdin_json) {
        $data = $stdin_json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.session_id) { $session_id = $data.session_id }
    }
} catch {}
if (-not $session_id) { exit 0 }

$safeId = $session_id -replace '[^A-Za-z0-9_-]', '_'
$statusFile = Join-Path $env:USERPROFILE ".claude\cache\tab_status_$safeId.json"
if (-not (Test-Path $statusFile)) { exit 0 }

# Fast path: load + early-return when state isn't WAITING.
try {
    $cur = Get-Content $statusFile -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    exit 0
}
if (-not $cur -or $cur.state -ne "WAITING") { exit 0 }

# Slow path: flip state to BUSY, refresh ts.
$cur.state = "BUSY"
$cur.ts = (Get-Date).ToString("o")
$cur | ConvertTo-Json -Compress | Set-Content -Path $statusFile -Encoding utf8

exit 0
