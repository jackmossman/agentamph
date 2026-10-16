# How the tray app is launched: the hidden launch command, the "Start at login" value
# under the per-user Run key, and the named handles that let an installer or
# uninstaller ask a running app to exit. Environment overrides exist for tests.

$script:AgentampVersion = '0.0.4'
$script:TrayMutexName = if ($env:AGENTAMPH_TRAY_MUTEX) { $env:AGENTAMPH_TRAY_MUTEX } else { 'Local\agentamph-tray' }
$script:TrayExitEventName = "$($script:TrayMutexName)-exit"

function Get-RunKeyPath {
    if ($env:AGENTAMPH_RUN_KEY) { return $env:AGENTAMPH_RUN_KEY }
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

function Get-PowerShellPath { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
function Get-ConhostPath { Join-Path $env:WINDIR 'System32\conhost.exe' }

# Arguments for conhost.exe. "--headless" gives powershell.exe a console that is
# never shown, so no window appears at launch or at sign-in.
function Get-LaunchArguments([string]$TrayPath) {
    "--headless `"$(Get-PowerShellPath)`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$TrayPath`""
}

function Get-LaunchCommand([string]$TrayPath) { "`"$(Get-ConhostPath)`" $(Get-LaunchArguments $TrayPath)" }

function Start-TrayApp([string]$TrayPath) {
    Start-Process -FilePath (Get-ConhostPath) -WindowStyle Hidden -ArgumentList (Get-LaunchArguments $TrayPath)
}

function Test-StartAtLogin {
    $value = Get-ItemProperty -LiteralPath (Get-RunKeyPath) -Name 'agentamph' -ErrorAction SilentlyContinue
    [bool]$value
}

function Set-StartAtLogin([bool]$Enabled, [string]$TrayPath) {
    $key = Get-RunKeyPath
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name 'agentamph' -Value (Get-LaunchCommand $TrayPath) -Type String
    } elseif (Test-StartAtLogin) {
        Remove-ItemProperty -LiteralPath $key -Name 'agentamph'
    }
}

function Test-TrayRunning {
    $mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting($script:TrayMutexName, [ref]$mutex)) { $mutex.Dispose(); return $true }
    $false
}

# Asks a running tray app to exit, and waits until it has. Returns $true when no app
# is running afterwards.
function Stop-TrayApp([int]$TimeoutSeconds = 10) {
    if (-not (Test-TrayRunning)) { return $true }
    $exitEvent = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($script:TrayExitEventName, [ref]$exitEvent)) {
        [void]$exitEvent.Set()
        $exitEvent.Dispose()
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-TrayRunning)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    -not (Test-TrayRunning)
}
