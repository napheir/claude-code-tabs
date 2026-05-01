# claude-code-tabs install.ps1
#
# Copies the 5 hook scripts to ~/.claude/hooks/ and merges the four hook
# entries (Stop, Notification, SessionStart, UserPromptSubmit, PreToolUse)
# into ~/.claude/settings.json without overwriting the user's other entries.
# Idempotent -- re-running is safe.
#
# Usage:
#   ./install.ps1                # copy + register
#   ./install.ps1 -DryRun        # show what would change, don't write
#   ./install.ps1 -SkipStartup   # don't create watcher startup shortcut
#   ./install.ps1 -Update        # force-overwrite scripts (preserve settings.json entries)
#   ./install.ps1 -Uninstall     # remove our hook entries + scripts
#
# Requires: PowerShell 5.1+ on Windows.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipStartup,
    [switch]$Update,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# ----- Paths -----
$RepoRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir       = Join-Path $RepoRoot 'src'
$HooksDest    = Join-Path $env:USERPROFILE '.claude\hooks'
# NB: name is $SettingsPath (not $Settings) to avoid a PS case-insensitive
# collision with the local $settings hashtable inside Register-Hooks /
# Unregister-Hooks. PS uses dynamic scoping, so Save-Settings would otherwise
# read the caller's hashtable instead of this script-scope path.
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'agent-tabs-watcher.lnk'

# Each entry: hook event name -> ([script filename], [-Title arg], [-Message arg]).
# -Title / -Message only used for notify-done variants.
$HookSpec = @(
    @{ Event='Stop';             Script='notify-done.ps1';   Args=@("-Title 'Claude Code'", "-Message 'Task complete'") }
    @{ Event='Notification';     Script='notify-done.ps1';   Args=@("-Title 'Claude Code'", "-Message 'Waiting for input'") }
    @{ Event='SessionStart';     Script='notify-clear.ps1';  Args=@() }
    @{ Event='UserPromptSubmit'; Script='notify-busy.ps1';   Args=@() }
    @{ Event='PreToolUse';       Script='notify-resume.ps1'; Args=@() }
)

$Scripts = @(
    'notify-busy.ps1',
    'notify-done.ps1',
    'notify-clear.ps1',
    'notify-resume.ps1',
    'agent-tabs-watcher.ps1'
)

# ----- Helpers -----

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "  [skip] $msg" -ForegroundColor DarkGray }
function Write-WarnMsg($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

function Build-HookCommand([string]$ScriptName, [string[]]$ExtraArgs) {
    $scriptPath = Join-Path $HooksDest $ScriptName
    # Forward-slash for JSON readability; PowerShell accepts both.
    $scriptPath = $scriptPath -replace '\\', '/'
    $argString  = if ($ExtraArgs.Count) { ' ' + ($ExtraArgs -join ' ') } else { '' }
    return "powershell -NoProfile -ExecutionPolicy Bypass -File '$scriptPath'$argString 2>/dev/null"
}

function Copy-Scripts() {
    Write-Step 'Copying hook scripts'
    if ($DryRun) {
        $Scripts | ForEach-Object { Write-Host "  [dry-run] would copy $_ -> $HooksDest" }
        return
    }
    if (-not (Test-Path $HooksDest)) { New-Item -ItemType Directory -Path $HooksDest -Force | Out-Null }
    foreach ($s in $Scripts) {
        $src = Join-Path $SrcDir $s
        $dst = Join-Path $HooksDest $s
        if ((Test-Path $dst) -and -not $Update) {
            $srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) { Write-Skip "$s (unchanged)"; continue }
        }
        Copy-Item -Path $src -Destination $dst -Force
        Write-Ok "$s -> $dst"
    }
}

function Remove-Scripts() {
    Write-Step 'Removing hook scripts'
    foreach ($s in $Scripts) {
        $dst = Join-Path $HooksDest $s
        if (Test-Path $dst) {
            if ($DryRun) { Write-Host "  [dry-run] would remove $dst" } else { Remove-Item $dst -Force; Write-Ok "removed $s" }
        }
    }
}

function ConvertTo-HashtableRecursive($obj) {
    # PS5.1's ConvertFrom-Json returns PSCustomObject (no -AsHashtable until
    # PS7). The rest of this script wants hashtables for ContainsKey + index
    # assignment, so convert recursively at the boundary.
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $obj.Keys) { $h[$k] = ConvertTo-HashtableRecursive $obj[$k] }
        return $h
    }
    if ($obj -is [System.Collections.IList] -or $obj -is [array]) {
        return @($obj | ForEach-Object { ConvertTo-HashtableRecursive $_ })
    }
    if ($obj -is [PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableRecursive $p.Value }
        return $h
    }
    return $obj
}

function Load-Settings() {
    if (-not (Test-Path $SettingsPath)) { return @{ } }
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8
    if (-not $raw.Trim()) { return @{ } }
    return ConvertTo-HashtableRecursive ($raw | ConvertFrom-Json)
}

function Save-Settings($obj) {
    if ($DryRun) {
        Write-Host '  [dry-run] would write settings.json:'
        ($obj | ConvertTo-Json -Depth 32) -split "`n" | Select-Object -First 30 | ForEach-Object { Write-Host "    $_" }
        return
    }
    $parent = Split-Path -Parent $SettingsPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $SettingsPath) { Copy-Item -Path $SettingsPath -Destination ($SettingsPath + '.bak') -Force }
    $json = $obj | ConvertTo-Json -Depth 32
    Set-Content -LiteralPath $SettingsPath -Value $json -Encoding utf8
    Write-Ok "settings.json updated (backup at $SettingsPath.bak)"
}

function Hook-Entry-Exists($eventArray, $scriptName) {
    if (-not $eventArray) { return $false }
    foreach ($entry in $eventArray) {
        $hooks = $entry['hooks']
        if (-not $hooks) { continue }
        foreach ($h in $hooks) {
            $cmd = $h['command']
            if ($cmd -and $cmd -match [regex]::Escape($scriptName)) { return $true }
        }
    }
    return $false
}

function Register-Hooks() {
    Write-Step 'Registering hooks in settings.json'
    $settings = Load-Settings
    if (-not $settings.ContainsKey('hooks')) { $settings['hooks'] = @{ } }
    $hooksRoot = $settings['hooks']

    $changed = $false
    foreach ($spec in $HookSpec) {
        $event  = $spec.Event
        $script = $spec.Script
        $args   = $spec.Args

        if (-not $hooksRoot.ContainsKey($event)) { $hooksRoot[$event] = @() }
        $eventArray = @($hooksRoot[$event])

        if (Hook-Entry-Exists $eventArray $script) {
            Write-Skip "$event/$script already registered"
            continue
        }

        $newEntry = @{
            hooks = @(
                @{
                    type    = 'command'
                    command = (Build-HookCommand $script $args)
                    async   = $true
                    timeout = 5
                }
            )
        }
        $eventArray += $newEntry
        $hooksRoot[$event] = $eventArray
        Write-Ok "$event/$script registered"
        $changed = $true
    }

    if (-not $changed) {
        Write-Skip 'no settings.json changes'
        return
    }

    # PS5.1 ConvertFrom-Json unwraps single-element arrays. When we did need
    # to add an entry to one event but other events were untouched, those
    # untouched events would serialize as scalar objects (degraded form).
    # Normalize all event values + nested hooks arrays before save so we
    # never write a degraded settings.json.
    foreach ($k in @($hooksRoot.Keys)) {
        $arr = @($hooksRoot[$k])
        foreach ($entry in $arr) {
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('hooks')) {
                $entry['hooks'] = @($entry['hooks'])
            }
        }
        $hooksRoot[$k] = $arr
    }

    $settings['hooks'] = $hooksRoot
    Save-Settings $settings
}

function Unregister-Hooks() {
    Write-Step 'Removing our hook entries from settings.json'
    if (-not (Test-Path $SettingsPath)) { Write-Skip 'no settings.json'; return }
    $settings = Load-Settings
    if (-not $settings['hooks']) { Write-Skip 'no hooks in settings.json'; return }

    foreach ($spec in $HookSpec) {
        $event = $spec.Event
        $script = $spec.Script
        if (-not $settings['hooks'].ContainsKey($event)) { continue }
        $kept = @()
        foreach ($entry in $settings['hooks'][$event]) {
            $hooks = @($entry['hooks'])
            $hooksKept = $hooks | Where-Object { -not ($_['command'] -match [regex]::Escape($script)) }
            if ($hooksKept.Count -gt 0) {
                $entry['hooks'] = @($hooksKept)
                $kept += $entry
            }
        }
        $settings['hooks'][$event] = $kept
        Write-Ok "$event/$script unregistered"
    }
    Save-Settings $settings
}

function Install-Startup() {
    if ($SkipStartup) { Write-Skip 'startup shortcut (--SkipStartup)'; return }
    Write-Step "Creating watcher startup shortcut at $StartupLnk"
    if ($DryRun) { Write-Host "  [dry-run] would create $StartupLnk"; return }
    if (Test-Path $StartupLnk) { Write-Skip 'startup shortcut already exists'; return }

    $watcher = (Join-Path $HooksDest 'agent-tabs-watcher.ps1') -replace '\\', '/'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($StartupLnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments  = "-NoProfile -WindowStyle Hidden -File `"$watcher`""
    $sc.WindowStyle = 7  # minimized
    $sc.Description = 'Agent Tabs watcher (claude-code-tabs)'
    $sc.Save()
    Write-Ok "shortcut created"

    # Launch immediately so user sees the panel without rebooting.
    Start-Process powershell -ArgumentList "-NoProfile","-WindowStyle","Hidden","-File",$watcher -WindowStyle Hidden
    Write-Ok 'watcher launched'
}

function Remove-Startup() {
    Write-Step 'Removing watcher startup shortcut'
    if (Test-Path $StartupLnk) {
        if ($DryRun) { Write-Host "  [dry-run] would remove $StartupLnk" } else { Remove-Item $StartupLnk -Force; Write-Ok 'removed' }
    } else {
        Write-Skip 'no shortcut to remove'
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'agent-tabs-watcher' } |
        ForEach-Object {
            if ($DryRun) { Write-Host "  [dry-run] would stop watcher pid $($_.ProcessId)" }
            else { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Ok "stopped watcher pid $($_.ProcessId)" }
        }
}

# ----- Run -----
#
# Guard so tests can dot-source this file to expose Register-Hooks /
# Save-Settings / etc. without triggering a real install. When dot-sourced,
# $MyInvocation.InvocationName is '.'; otherwise it's '&' or the script path.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Uninstall) {
        Unregister-Hooks
        Remove-Scripts
        Remove-Startup
        Write-Host ''
        Write-Host 'Uninstalled.' -ForegroundColor Green
        exit 0
    }

    Copy-Scripts
    Register-Hooks
    Install-Startup

    Write-Host ''
    Write-Host 'Done. Open a new Claude Code tab for hook entries to take effect.' -ForegroundColor Green
    Write-Host 'The "Agent Tabs" panel should be visible (top-right of primary screen).' -ForegroundColor Green
    exit 0
}
