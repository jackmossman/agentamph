# agentamph tray app: lists Claude Code sessions, lets the user mark them critical,
# and keeps Windows awake according to the chosen selector and mode.
# Runs under Windows PowerShell 5.1. Launch hidden; see scripts\start-tray.ps1.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

foreach ($lib in 'Paths', 'Sessions', 'Marks', 'Hold', 'Settings', 'Power', 'Icons') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}
Add-Type -AssemblyName System.Windows.Forms

# AGENTAMPH_HARNESS loads the app without the single-instance lock or the message
# loop, so a test script can drive the real menu and icon.
$script:harness = [bool]$env:AGENTAMPH_HARNESS
if (-not $script:harness) {
    $createdNew = $false
    $script:mutex = New-Object System.Threading.Mutex($true, 'Local\agentamph-tray', [ref]$createdNew)
    if (-not $createdNew) { exit 0 }
}

Initialize-AgentampHome

function Write-Log([string]$Message) {
    try {
        $path = Get-LogPath
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) { Remove-Item -LiteralPath $path -Force }
        Add-Content -LiteralPath $path -Value ("{0:o} {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch { }
}

function Read-State {
    $known = @{}
    try {
        $path = Get-StatePath
        if (Test-Path -LiteralPath $path) {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $map = Get-JsonValue $json 'KnownByProcess'
            if ($map) { foreach ($p in $map.PSObject.Properties) { $known[$p.Name] = [string]$p.Value } }
        }
    } catch { Write-Log "state unreadable: $($_.Exception.Message)" }
    $known
}

function Save-State {
    Write-Utf8File (Get-StatePath) ((@{ KnownByProcess = $script:knownByProcess } | ConvertTo-Json) + "`n")
}

$script:settings = Read-AgentampSettings
$script:knownByProcess = Read-State
$script:scanState = @{}
$script:lastBusy = @{}
$script:sessions = @()
$script:marks = @{}
$script:holding = @()
$script:unrecognised = $false
$script:lastSignature = ''
$script:lastFullScan = [datetime]::MinValue
$script:lastHoldKey = ''
$script:iconHandle = [IntPtr]::Zero

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$script:menu.Items.Add('agentamph')
$script:notifyIcon.ContextMenuStrip = $script:menu

function Get-FolderSignature([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) { return '-' }
    $items = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue)
    $latest = 0
    foreach ($item in $items) { if ($item.LastWriteTimeUtc.Ticks -gt $latest) { $latest = $item.LastWriteTimeUtc.Ticks } }
    "$($items.Count):$latest"
}

function Get-ModeLabel {
    $selector = if ($script:settings.Selector -eq 'All') { 'All' } else { 'Critical' }
    $mode = if ($script:settings.Mode -eq 'WhileBusy') { 'While busy' } else { 'Until closed' }
    "$selector, $mode"
}

function Update-TrayIcon {
    $count = @($script:holding).Count
    $handle = New-AgentampIconHandle ($count -gt 0) $count ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $script:notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($handle)
    Remove-IconHandle $script:iconHandle
    $script:iconHandle = $handle

    $text = if ($script:unrecognised) { "agentamph: session format not recognised" }
            elseif ($count -gt 0) { "agentamph: $count holding ($(Get-ModeLabel))" }
            else { "agentamph: none holding ($(Get-ModeLabel))" }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:notifyIcon.Text = $text
}

function Invoke-Refresh([bool]$Force) {
    $now = Get-Date
    $signature = (Get-FolderSignature (Get-ClaudeSessionsDirectory)) + '|' + (Get-FolderSignature (Get-MarksDirectory))
    if ($Force -or $signature -ne $script:lastSignature -or ($now - $script:lastFullScan).TotalSeconds -ge 5) {
        $script:lastSignature = $signature
        $script:lastFullScan = $now
        $scan = Get-ClaudeSessions -State $script:scanState
        $script:sessions = @($scan.Sessions)
        $script:unrecognised = $scan.Unrecognised
        if (Update-MarksForSessionChanges -Sessions $script:sessions -KnownByProcess $script:knownByProcess) { Save-State }
        Remove-StaleMarks -LiveSessionIds @($script:sessions | ForEach-Object { $_.SessionId })
        $script:marks = Get-CriticalMarks
    }

    Update-LastBusy -Sessions $script:sessions -LastBusy $script:lastBusy -Now $now
    $script:holding = Get-HoldingSessions -Sessions $script:sessions -Marks $script:marks -Selector $script:settings.Selector `
        -Mode $script:settings.Mode -GraceMinutes $script:settings.GraceMinutes -LastBusy $script:lastBusy -Now $now
    $holdNow = @($script:holding).Count -gt 0
    Set-KeepAwake $holdNow $script:settings.KeepDisplayOn

    $holdKey = "$(@($script:holding).Count)|$($script:unrecognised)|$(Get-ModeLabel)"
    if ($Force -or $holdKey -ne $script:lastHoldKey) {
        $script:lastHoldKey = $holdKey
        Update-TrayIcon
    }
}

function Save-Settings { Save-AgentampSettings $script:settings; Invoke-Refresh $true }

function New-MenuItem([string]$Text, $Tag, [bool]$Checked, [scriptblock]$OnClick) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $item.Tag = $Tag
    $item.Checked = $Checked
    if ($OnClick) { $item.add_Click($OnClick) }
    $item
}

$script:onToggleCritical = {
    param($sender, $e)
    try {
        $id = [string]$sender.Tag
        if ($script:marks.ContainsKey($id)) { Remove-CriticalMark $id } else { Set-CriticalMark $id }
        Invoke-Refresh $true
    } catch { Write-Log "toggle failed: $($_.Exception.Message)" }
}
$script:onSelector = { param($sender, $e) $script:settings.Selector = [string]$sender.Tag; Save-Settings }
$script:onMode = { param($sender, $e) $script:settings.Mode = [string]$sender.Tag; Save-Settings }
$script:onGrace = { param($sender, $e) $script:settings.GraceMinutes = [int]$sender.Tag; Save-Settings }
$script:onDisplay = { param($sender, $e) $script:settings.KeepDisplayOn = -not $script:settings.KeepDisplayOn; Save-Settings }
$script:onExit = { param($sender, $e) Stop-Tray }

function Get-SessionLabel($Session) {
    $parts = @($Session.Status)
    if (-not $Session.Status) { $parts = @('busy') }
    $parts += $Session.Entrypoint
    $label = $Session.Name
    if ($Session.Folder -and $Session.Folder -ne $Session.Name) { $label += " - $($Session.Folder)" }
    $label += " ($($parts -join ', '))"
    $holdingIds = @($script:holding | ForEach-Object { $_.SessionId })
    if ($holdingIds -contains $Session.SessionId) { $label += '  [holding]' }
    $label
}

function Update-Menu {
    $script:menu.Items.Clear()
    $count = @($script:holding).Count
    $header = New-MenuItem "agentamph: $count holding" $null $false $null
    $header.Enabled = $false
    [void]$script:menu.Items.Add($header)
    if ($script:unrecognised) {
        $warn = New-MenuItem 'Claude session format not recognised' $null $false $null
        $warn.Enabled = $false
        [void]$script:menu.Items.Add($warn)
    }
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    if (@($script:sessions).Count -eq 0) {
        $none = New-MenuItem 'No Claude Code sessions running' $null $false $null
        $none.Enabled = $false
        [void]$script:menu.Items.Add($none)
    }
    foreach ($session in ($script:sessions | Sort-Object Name)) {
        $item = New-MenuItem (Get-SessionLabel $session) $session.SessionId ($script:marks.ContainsKey($session.SessionId)) $script:onToggleCritical
        $item.ToolTipText = 'Click to mark or unmark this session critical'
        [void]$script:menu.Items.Add($item)
    }
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $sessionsMenu = New-MenuItem 'Sessions' $null $false $null
    foreach ($choice in @(@('All', 'All'), @('Critical', 'Critical'))) {
        [void]$sessionsMenu.DropDownItems.Add((New-MenuItem $choice[1] $choice[0] ($script:settings.Selector -eq $choice[0]) $script:onSelector))
    }
    $modeMenu = New-MenuItem 'Keep awake' $null $false $null
    foreach ($choice in @(@('UntilClosed', 'Until closed'), @('WhileBusy', 'While busy'))) {
        [void]$modeMenu.DropDownItems.Add((New-MenuItem $choice[1] $choice[0] ($script:settings.Mode -eq $choice[0]) $script:onMode))
    }
    $graceMenu = New-MenuItem 'Grace period (While busy)' $null $false $null
    foreach ($minutes in $script:GraceChoices) {
        $label = if ($minutes -eq 0) { 'None' } else { "$minutes minutes" }
        [void]$graceMenu.DropDownItems.Add((New-MenuItem $label $minutes ($script:settings.GraceMinutes -eq $minutes) $script:onGrace))
    }
    [void]$script:menu.Items.Add($sessionsMenu)
    [void]$script:menu.Items.Add($modeMenu)
    [void]$script:menu.Items.Add($graceMenu)
    [void]$script:menu.Items.Add((New-MenuItem 'Keep display on' $null $script:settings.KeepDisplayOn $script:onDisplay))
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$script:menu.Items.Add((New-MenuItem 'Exit' $null $false $script:onExit))
}

function Stop-Tray {
    try { $script:timer.Stop() } catch { }
    Set-KeepAwake $false $false
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    Remove-IconHandle $script:iconHandle
    [System.Windows.Forms.Application]::Exit()
}

$script:menu.add_Opening({
    param($sender, $e)
    try { Invoke-Refresh $true; Update-Menu } catch { Write-Log "menu failed: $($_.Exception.Message)" }
    $e.Cancel = $false
})

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000
$script:timer.add_Tick({
    try { Invoke-Refresh $false } catch { Write-Log "refresh failed: $($_.Exception.Message)" }
})

if ($script:harness) { return }

try {
    Invoke-Refresh $true
    $script:notifyIcon.Visible = $true
    $script:timer.Start()
    Write-Log 'started'
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-Log "fatal: $($_.Exception.Message)"
    Set-KeepAwake $false $false
} finally {
    Write-Log 'stopped'
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
}
