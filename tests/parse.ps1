# tests/parse.ps1 — Parse-check every .ps1 in src/ and the installer.
#
# Catches syntax errors before they ship. Runs in seconds. Used by CI and
# recommended pre-commit.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$targets = @(
    Join-Path $repoRoot 'install.ps1'
)
$targets += Get-ChildItem -Path (Join-Path $repoRoot 'src') -Filter '*.ps1' -File | ForEach-Object { $_.FullName }

$failed = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t)) {
        Write-Host "  [skip] $t (not found)" -ForegroundColor DarkGray
        continue
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($t, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "  [FAIL] $t" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host "         $($e.Extent.StartLineNumber):$($e.Extent.StartColumnNumber) — $($e.Message)" -ForegroundColor Red
        }
        $failed++
    } else {
        Write-Host "  [OK]   $(Split-Path -Leaf $t)" -ForegroundColor Green
    }
}

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "$failed file(s) failed to parse." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "All scripts parsed cleanly." -ForegroundColor Green
exit 0
