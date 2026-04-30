# cc-tabs-watcher.ps1 -- Always-on-top status panel for Claude Code tabs.
#
# Reads ~/.claude/cache/tab_status_*.json (written by notify-done.ps1)
# and shows a compact list of which tabs need attention (DONE / WAITING).
# Double-click row to bring the corresponding terminal window to front.
#
# Run hidden:
#   powershell -NoProfile -WindowStyle Hidden -File ~/.claude/hooks/cc-tabs-watcher.ps1
#
# Auto-start at login:
#   See README at end of this file. Recommended: place a .lnk in
#   shell:startup pointing to the command above.

$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("CCWatcher.W32" -as [type])) {
    Add-Type -Namespace CCWatcher -Name W32 -MemberDefinition @"
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(System.IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        public static extern bool IsWindow(System.IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(System.IntPtr hWnd);
"@
}

$cacheDir = Join-Path $env:USERPROFILE ".claude\cache"
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}

# Time-based stale filter is disabled. Per-tab dedup (terminal_pid Group-Object
# newest-wins) plus liveness check (drop entries whose owning shell pid died)
# already prevent the panel from accumulating noise. Showing all live tabs
# regardless of age is what the user requested 2026-04-30 -- long-running
# tabs that haven't logged activity recently still belong on the panel.
# Set to a large value to act as a safety bound only (24h = 86400s).
$STALE_SECONDS = 86400

# ------------------------------------------------------------------
# Form
# ------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Agent Tabs"
$form.Size = New-Object System.Drawing.Size(420, 260)
$form.MinimumSize = New-Object System.Drawing.Size(300, 140)
$form.TopMost = $true
$form.StartPosition = "Manual"
$form.FormBorderStyle = "Sizable"
$form.ShowInTaskbar = $true

# Top-right corner of primary screen
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - 440), ($wa.Top + 20))

$lv = New-Object System.Windows.Forms.ListView
$lv.View = [System.Windows.Forms.View]::Details
$lv.Dock = [System.Windows.Forms.DockStyle]::Fill
$lv.FullRowSelect = $true
$lv.GridLines = $false
$lv.HideSelection = $false
$lv.Font = New-Object System.Drawing.Font("Consolas", 9)
[void]$lv.Columns.Add("State", 70)
[void]$lv.Columns.Add("Tab", 220)
[void]$lv.Columns.Add("Age", 80)
$form.Controls.Add($lv)

# Bottom info strip
$status = New-Object System.Windows.Forms.StatusStrip
$lblCount = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblCount.Text = "0 tabs"
[void]$status.Items.Add($lblCount)
$form.Controls.Add($status)

# ------------------------------------------------------------------
# Refresh
# ------------------------------------------------------------------
function Refresh-Tabs {
    $now = Get-Date
    $entries = @()
    Get-ChildItem -Path $cacheDir -Filter "tab_status_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $raw = Get-Content $_.FullName -Raw -Encoding utf8
            if (-not $raw) { return }
            $d = $raw | ConvertFrom-Json
            if ($null -eq $d.ts) { return }
            $tsParsed = [datetime]::Parse($d.ts)
            $age = ($now - $tsParsed).TotalSeconds
            if ($age -gt $STALE_SECONDS) { return }

            # Liveness: drop entries whose owning shell process has died
            # (= the CC tab was closed without notify-clear firing). Falls
            # back to time-based purge when the field is missing (legacy
            # status files written before the schema change).
            if ($d.terminal_pid) {
                $alive = Get-Process -Id ([int]$d.terminal_pid) -ErrorAction SilentlyContinue
                if (-not $alive) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    return
                }
            }

            $entries += [PSCustomObject]@{
                State       = $d.state
                Title       = $d.title
                Cwd         = $d.cwd
                TerminalPid = if ($d.terminal_pid) { [int]$d.terminal_pid } else { 0 }
                SessionId   = $d.session_id
                Hwnd        = [int64]$d.hwnd
                Age         = [int]$age
                Ts          = $tsParsed
                Path        = $_.FullName
            }
        } catch {}
    }

    # Per-tab dedup: keep newest entry per tab, delete superseded files.
    # A tab is identified by terminal_pid (shell pid, stable for tab lifetime).
    # When CC restarts inside the same tab the new session writes a fresh
    # status file with a new session_id but the same terminal_pid -- older
    # ones are orphans and can go. Fallback keys for legacy/missing fields
    # below preserve correctness for entries written before this schema.
    $deduped = @()
    $entries | Group-Object {
        if ($_.TerminalPid -gt 0) { "tp:$($_.TerminalPid)" }
        elseif ($_.Cwd) { "cwd:$($_.Cwd)" }
        else { "sid:$($_.SessionId)" }
    } | ForEach-Object {
        $sorted = $_.Group | Sort-Object Ts -Descending
        $deduped += $sorted[0]
        foreach ($drop in ($sorted | Select-Object -Skip 1)) {
            Remove-Item $drop.Path -Force -ErrorAction SilentlyContinue
        }
    }

    # Preserve selection by hwnd
    $selectedHwnd = $null
    if ($lv.SelectedItems.Count -gt 0) { $selectedHwnd = $lv.SelectedItems[0].Tag }

    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($e in ($deduped | Sort-Object Ts -Descending)) {
        # ASCII labels -- non-ASCII renders as mojibake when the .ps1 source
        # is interpreted as GBK on Windows (PowerShell 5.1 default code page).
        $stateLabel = switch ($e.State) {
            "DONE"    { "[DONE]" }
            "WAITING" { "[WAIT]" }
            "BUSY"    { "[BUSY]" }
            default   { "[" + $e.State + "]" }
        }
        # Tab name from cwd basename (e.g. "agent-core"). Falls back to title
        # then <tab> when cwd missing.
        $tabName = ""
        if ($e.Cwd) {
            try { $tabName = Split-Path -Leaf $e.Cwd } catch {}
        }
        if (-not $tabName) { $tabName = if ($e.Title) { $e.Title } else { "<tab>" } }
        $ageLabel = if ($e.Age -lt 60) { "{0}s" -f $e.Age }
                    elseif ($e.Age -lt 3600) { "{0:N0}m" -f ($e.Age / 60) }
                    else { "{0:N1}h" -f ($e.Age / 3600) }
        $item = New-Object System.Windows.Forms.ListViewItem($stateLabel)
        [void]$item.SubItems.Add($tabName)
        [void]$item.SubItems.Add($ageLabel)
        $item.Tag = $e.Hwnd
        $item.UseItemStyleForSubItems = $false
        if ($e.State -eq "DONE") {
            $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        } elseif ($e.State -eq "WAITING") {
            $item.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
        } elseif ($e.State -eq "BUSY") {
            $item.ForeColor = [System.Drawing.Color]::FromArgb(50, 100, 200)
        }
        if ($selectedHwnd -and $item.Tag -eq $selectedHwnd) {
            $item.Selected = $true
        }
        [void]$lv.Items.Add($item)
    }
    $lv.EndUpdate()
    $lblCount.Text = "$($lv.Items.Count) tabs"
}

# Double-click -> bring terminal to front
$lv.Add_DoubleClick({
    if ($lv.SelectedItems.Count -eq 0) { return }
    $hwnd = [System.IntPtr][int64]$lv.SelectedItems[0].Tag
    if ($hwnd -ne [System.IntPtr]::Zero -and [CCWatcher.W32]::IsWindow($hwnd)) {
        if ([CCWatcher.W32]::IsIconic($hwnd)) {
            [CCWatcher.W32]::ShowWindowAsync($hwnd, 9) | Out-Null  # SW_RESTORE
        }
        [CCWatcher.W32]::SetForegroundWindow($hwnd) | Out-Null
    }
})

# Timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Refresh-Tabs })
$timer.Start()

Refresh-Tabs
[System.Windows.Forms.Application]::Run($form)

<#
README -- Auto-start at login

Option 1 (recommended): Startup folder shortcut

    Win+R  ->  shell:startup  ->  paste a .lnk with:
      Target:  powershell.exe
      Args:    -NoProfile -WindowStyle Hidden -File "%USERPROFILE%\.claude\hooks\cc-tabs-watcher.ps1"

Option 2: Task Scheduler (logs survive better, hidden by default)

    schtasks /Create /TN "CCTabsWatcher" /SC ONLOGON /TR "powershell.exe -NoProfile -WindowStyle Hidden -File %USERPROFILE%\.claude\hooks\cc-tabs-watcher.ps1" /RL LIMITED

To run once now (for testing):

    powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\cc-tabs-watcher.ps1"
#>
