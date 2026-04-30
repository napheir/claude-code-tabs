# tests/smoke.ps1 — Synthetic stdin → notify-busy + notify-done → assert
# tab_status_*.json appears with the expected fields.
#
# Uses an isolated cache dir under $env:TEMP so we don't pollute the user's
# real ~/.claude/cache. Cleans up on success and on failure.

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$srcDir     = Join-Path $repoRoot 'src'
$tmpHome    = Join-Path $env:TEMP "cct-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$tmpClaude  = Join-Path $tmpHome '.claude'
$tmpCache   = Join-Path $tmpClaude 'cache'

$failed = 0

function Cleanup {
    if (Test-Path $tmpHome) {
        Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
    }
}

trap { Cleanup; throw }

try {
    Write-Host "Smoke test: $tmpHome" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $tmpCache -Force | Out-Null

    # Override USERPROFILE for the child powershell so the hook scripts write
    # under our temp dir instead of the real ~/.claude/cache.
    $sessionId = "smoke-$(Get-Random)"
    $cwd       = (Get-Location).Path
    $payload   = @{ session_id = $sessionId; cwd = $cwd } | ConvertTo-Json -Compress

    function Invoke-Hook {
        param(
            [string]$ScriptName,
            [string[]]$ExtraArgs = @(),
            [string]$Stdin
        )
        $script = Join-Path $srcDir $ScriptName
        if (-not (Test-Path $script)) { throw "Missing: $script" }

        $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $ExtraArgs
        $tmpIn  = New-TemporaryFile
        $tmpOut = New-TemporaryFile
        $tmpErr = New-TemporaryFile
        try {
            Set-Content -LiteralPath $tmpIn.FullName -Value $Stdin -Encoding utf8 -NoNewline
            $oldProfile = $env:USERPROFILE
            try {
                $env:USERPROFILE = $tmpHome
                $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList `
                    -RedirectStandardInput $tmpIn.FullName `
                    -RedirectStandardOutput $tmpOut.FullName `
                    -RedirectStandardError $tmpErr.FullName `
                    -WindowStyle Hidden -PassThru -Wait
                return @{
                    ExitCode = $p.ExitCode
                    Stdout   = (Get-Content $tmpOut.FullName -Raw -ErrorAction SilentlyContinue)
                    Stderr   = (Get-Content $tmpErr.FullName -Raw -ErrorAction SilentlyContinue)
                }
            } finally {
                $env:USERPROFILE = $oldProfile
            }
        } finally {
            Remove-Item $tmpIn.FullName, $tmpOut.FullName, $tmpErr.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # ---- Test 1: notify-busy writes BUSY status ----
    Write-Host "  [1/2] notify-busy.ps1" -ForegroundColor Cyan
    $r = Invoke-Hook -ScriptName 'notify-busy.ps1' -Stdin $payload
    if ($r.ExitCode -ne 0) {
        Write-Host "    [FAIL] exit $($r.ExitCode)" -ForegroundColor Red
        Write-Host "    stderr: $($r.Stderr)" -ForegroundColor Red
        $failed++
    } else {
        $statusFiles = Get-ChildItem -Path $tmpCache -Filter "tab_status_*.json" -ErrorAction SilentlyContinue
        if (-not $statusFiles -or $statusFiles.Count -eq 0) {
            Write-Host "    [FAIL] no tab_status_*.json written" -ForegroundColor Red
            $failed++
        } else {
            $j = Get-Content $statusFiles[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if ($j.state -ne 'BUSY') {
                Write-Host "    [FAIL] state=$($j.state), expected BUSY" -ForegroundColor Red
                $failed++
            } elseif ($j.session_id -ne $sessionId) {
                Write-Host "    [FAIL] session_id=$($j.session_id), expected $sessionId" -ForegroundColor Red
                $failed++
            } else {
                Write-Host "    [OK]   state=BUSY, session_id matches, terminal_pid=$($j.terminal_pid)" -ForegroundColor Green
            }
        }
    }

    # ---- Test 2: notify-done overwrites with DONE ----
    Write-Host "  [2/2] notify-done.ps1" -ForegroundColor Cyan
    $r = Invoke-Hook -ScriptName 'notify-done.ps1' -ExtraArgs @('-Title', 'Smoke', '-Message', 'Task complete') -Stdin $payload
    if ($r.ExitCode -ne 0) {
        Write-Host "    [FAIL] exit $($r.ExitCode)" -ForegroundColor Red
        Write-Host "    stderr: $($r.Stderr)" -ForegroundColor Red
        $failed++
    } else {
        $statusFiles = Get-ChildItem -Path $tmpCache -Filter "tab_status_*.json" -ErrorAction SilentlyContinue
        if (-not $statusFiles -or $statusFiles.Count -eq 0) {
            Write-Host "    [FAIL] no tab_status_*.json after notify-done" -ForegroundColor Red
            $failed++
        } else {
            $j = Get-Content $statusFiles[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if ($j.state -ne 'DONE') {
                Write-Host "    [FAIL] state=$($j.state), expected DONE" -ForegroundColor Red
                $failed++
            } else {
                Write-Host "    [OK]   state=DONE" -ForegroundColor Green
            }
        }
    }

    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "$failed assertion(s) failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Smoke test passed." -ForegroundColor Green
    exit 0
}
finally {
    Cleanup
}
