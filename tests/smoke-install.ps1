# tests/smoke-install.ps1 -- Exercise install.ps1's Register-Hooks /
# Save-Settings write path against a temp settings.json.
#
# Why this test exists: tests/smoke.ps1 covers the runtime hook scripts but
# never invokes install.ps1's write path. install.ps1 -DryRun (the other CI
# surface) skips the path-touching code in Save-Settings. Result: a regression
# in Register-Hooks/Save-Settings can ship green. The case-collision fix in
# ac45c75 surfaced exactly this gap.
#
# Strategy: dot-source install.ps1 (its top-level Run block is guarded so it
# does nothing on dot-source), then override script-scope $SettingsPath and
# $HooksDest to point inside an isolated temp dir before calling Register-Hooks
# / Unregister-Hooks. We verify the file is actually written, that pre-existing
# unrelated entries survive, that re-running is idempotent, and that uninstall
# leaves the unrelated entries intact.

$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tmpRoot     = Join-Path $env:TEMP "cct-installsmoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$tmpHooks    = Join-Path $tmpRoot 'hooks'
$tmpSettings = Join-Path $tmpRoot 'settings.json'

$failed = 0

function Cleanup {
    if (Test-Path $tmpRoot) {
        Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
    }
}

trap { Cleanup; throw }

function Assert-That($cond, $msg) {
    if ($cond) {
        Write-Host "    [OK]   $msg" -ForegroundColor Green
    } else {
        Write-Host "    [FAIL] $msg" -ForegroundColor Red
        $script:failed++
    }
}

function Get-StopCommands($obj) {
    $out = @()
    foreach ($entry in @($obj.hooks.Stop)) {
        foreach ($h in @($entry.hooks)) {
            if ($h.command) { $out += $h.command }
        }
    }
    return ,$out
}

try {
    Write-Host "Install smoke: $tmpRoot" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    # Pre-populate settings.json with an unrelated entry that must survive
    # both Register-Hooks and Unregister-Hooks. Literal JSON (not round-tripped
    # through ConvertTo-Json) so the input shape is unambiguous.
    $preexistingJson = @'
{
    "theme": "dark",
    "hooks": {
        "Stop": [
            { "hooks": [ { "type": "command", "command": "echo other" } ] }
        ]
    }
}
'@
    Set-Content -LiteralPath $tmpSettings -Value $preexistingJson -Encoding utf8

    # Dot-source install.ps1. The script's Run-block guard
    # ($MyInvocation.InvocationName -ne '.') makes this a no-op apart from
    # populating script-scope vars and defining functions in our scope.
    . (Join-Path $repoRoot 'install.ps1')

    # Redirect script-scope paths into our temp dir. $SrcDir stays pointed at
    # the real repo so Copy-Scripts has source files to read.
    $SettingsPath = $tmpSettings
    $HooksDest    = $tmpHooks
    $DryRun       = $false
    $Update       = $false
    $Uninstall    = $false

    Write-Host "  [1/4] Copy-Scripts to temp hooks dir" -ForegroundColor Cyan
    Copy-Scripts | Out-Null
    Assert-That (Test-Path (Join-Path $tmpHooks 'notify-busy.ps1'))   "notify-busy.ps1 copied"
    Assert-That (Test-Path (Join-Path $tmpHooks 'notify-done.ps1'))   "notify-done.ps1 copied"
    Assert-That (Test-Path (Join-Path $tmpHooks 'notify-clear.ps1'))  "notify-clear.ps1 copied"
    Assert-That (Test-Path (Join-Path $tmpHooks 'notify-resume.ps1')) "notify-resume.ps1 copied"

    Write-Host "  [2/4] Register-Hooks writes settings.json" -ForegroundColor Cyan
    Register-Hooks | Out-Null
    Assert-That (Test-Path $tmpSettings) "settings.json present after register"
    Assert-That (Test-Path ($tmpSettings + '.bak')) "settings.json.bak created"
    $written = Get-Content -LiteralPath $tmpSettings -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-That ($written.theme -eq 'dark') "preexisting 'theme' key preserved"
    $stopCmds = Get-StopCommands $written
    Assert-That (@($stopCmds | Where-Object { $_ -match 'echo other' }).Count -gt 0) "preexisting Stop entry preserved"
    Assert-That (@($stopCmds | Where-Object { $_ -match 'notify-done\.ps1' }).Count -gt 0) "notify-done.ps1 Stop entry registered"
    Assert-That ($null -ne $written.hooks.Notification)     "Notification event registered"
    Assert-That ($null -ne $written.hooks.SessionStart)     "SessionStart event registered"
    Assert-That ($null -ne $written.hooks.UserPromptSubmit) "UserPromptSubmit event registered"
    Assert-That ($null -ne $written.hooks.PreToolUse)       "PreToolUse event registered"

    Write-Host "  [3/4] Re-Register-Hooks is idempotent" -ForegroundColor Cyan
    $afterFirstHash = (Get-FileHash $tmpSettings -Algorithm SHA256).Hash
    Register-Hooks | Out-Null
    $afterSecondHash = (Get-FileHash $tmpSettings -Algorithm SHA256).Hash
    Assert-That ($afterFirstHash -eq $afterSecondHash) "settings.json hash unchanged on second Register-Hooks"

    Write-Host "  [4/4] Unregister-Hooks removes our entries, preserves others" -ForegroundColor Cyan
    Unregister-Hooks | Out-Null
    $afterUnreg = Get-Content -LiteralPath $tmpSettings -Raw -Encoding utf8 | ConvertFrom-Json
    $stopCmdsAfter = Get-StopCommands $afterUnreg
    Assert-That (@($stopCmdsAfter | Where-Object { $_ -match 'notify-done\.ps1' }).Count -eq 0) "our Stop entry removed"
    Assert-That (@($stopCmdsAfter | Where-Object { $_ -match 'echo other' }).Count -gt 0) "preexisting Stop entry still present"
    Assert-That ($afterUnreg.theme -eq 'dark') "preexisting 'theme' key still present"

    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "$failed assertion(s) failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Install smoke passed." -ForegroundColor Green
    exit 0
}
finally {
    Cleanup
}
