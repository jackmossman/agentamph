# Shared functions for the VM tests: the Hyper-V VM "agentamph-test", PowerShell
# Direct as the guest administrator, scheduled tasks that run on the standard user's
# desktop, host-side screenshots, and the report. Windows PowerShell 5.1, elevated.

$script:VmName = 'agentamph-test'
$script:CleanCheckpoint = 'clean'
$script:PendingRestartCheckpoint = 'pending-restart'
$script:AdminUser = 'amphadmin'
$script:DesktopUser = 'tester'
$script:Exchange = 'C:\exchange'
$script:VmHome = Join-Path $env:LOCALAPPDATA 'agentamph-vm'
$script:Checks = New-Object System.Collections.ArrayList
$script:ResultsDir = $null
$script:Session = $null

function Write-VmLog([string]$Message) {
    $line = "$((Get-Date).ToString('HH:mm:ss')) $Message"
    Write-Host $line
    if ($script:ResultsDir) { Add-Content -LiteralPath (Join-Path $script:ResultsDir 'run.log') -Value $line }
}

function Get-VmPassword {
    $path = Join-Path $script:VmHome 'password.txt'
    if (-not (Test-Path -LiteralPath $path)) { throw "No VM password at $path. Build the VM with tests\vm\New-VmTemplate.ps1." }
    (Get-Content -LiteralPath $path -Raw).Trim()
}

function Get-AdminCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The generated password of a throwaway test VM, kept outside the repository.')]
    param()
    New-Object PSCredential($script:AdminUser, (ConvertTo-SecureString (Get-VmPassword) -AsPlainText -Force))
}

# Stops with a message that says what to do when something the run needs is missing.
function Assert-VmPrerequisites([switch]$NeedCheckpoint) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated Windows PowerShell (Run as administrator).' }
    if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run this under Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.' }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { throw 'The Hyper-V PowerShell module is missing. Turn on Hyper-V in Windows Features.' }
    if ($NeedCheckpoint) {
        if (-not (Get-VM -Name $script:VmName -ErrorAction SilentlyContinue)) { throw "No VM named $($script:VmName). Build it with tests\vm\New-VmTemplate.ps1 -Iso <path to a Windows 11 ISO>." }
        if (-not (Get-VMSnapshot -VMName $script:VmName -Name $script:CleanCheckpoint -ErrorAction SilentlyContinue)) { throw "The VM has no '$($script:CleanCheckpoint)' checkpoint. Rebuild it with tests\vm\New-VmTemplate.ps1 -Replace." }
        Get-VmPassword | Out-Null
    }
}

# Opens a PowerShell Direct session as the guest administrator, waiting while the guest boots.
function Connect-Guest([int]$Minutes = 10) {
    if ($script:Session -and $script:Session.State -eq 'Opened') { return $script:Session }
    $credential = Get-AdminCredential
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try { $script:Session = New-PSSession -VMName $script:VmName -Credential $credential -ErrorAction Stop; return $script:Session } catch { Start-Sleep -Seconds 3 }
    }
    throw "PowerShell Direct to $($script:VmName) did not connect within $Minutes minutes."
}

function Disconnect-Guest {
    if ($script:Session) { Remove-PSSession $script:Session -ErrorAction SilentlyContinue; $script:Session = $null }
}

# Runs a script block as the guest administrator. Keep calls short: the runner polls
# rather than waiting in one long call.
function Invoke-Guest([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @()) {
    Invoke-Command -Session (Connect-Guest) -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

# Waits until the desktop user's Explorer is running, so the desktop is up.
function Wait-GuestDesktop([int]$Minutes = 10) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $up = Invoke-Guest -ArgumentList $script:DesktopUser -ScriptBlock {
                param($user)
                [bool](Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User -eq $user })
            }
            if ($up) { return }
        } catch { Disconnect-Guest }
        Start-Sleep -Seconds 3
    }
    throw "The desktop of $($script:DesktopUser) did not come up within $Minutes minutes."
}

function Initialize-GuestExchange {
    Invoke-Guest -ArgumentList $script:Exchange, $script:DesktopUser -ScriptBlock {
        param($dir, $user)
        New-Item -ItemType Directory -Path (Join-Path $dir 'tasks') -Force | Out-Null
        icacls $dir /grant "${user}:(OI)(CI)M" | Out-Null
    }
}

# Restores a checkpoint (by default the clean one), resumes the VM, and sets its clock
# from the host, because a checkpoint brings back the clock as it was when taken.
function Restore-CleanVm([string]$Checkpoint = $script:CleanCheckpoint) {
    Write-VmLog "restoring checkpoint '$Checkpoint'"
    Disconnect-Guest
    Restore-VMSnapshot -VMName $script:VmName -Name $Checkpoint -Confirm:$false
    if ((Get-VM -Name $script:VmName).State -ne 'Running') { Start-VM -Name $script:VmName }
    Connect-Guest | Out-Null
    $now = Get-Date
    Invoke-Guest -ArgumentList $now -ScriptBlock { param($t) Set-Date -Date $t | Out-Null }
    Wait-GuestDesktop
    Initialize-GuestExchange
}

# Lets a test move the guest's clock: turns off Hyper-V time sync and stops Windows Time
# in the guest, which otherwise put the clock back within minutes. Undo-GuestClockControl
# turns time sync back on; the guest itself is reset by the next checkpoint restore.
function Enable-GuestClockControl {
    Disable-VMIntegrationService -VMName $script:VmName -Name 'Time Synchronization'
    Invoke-Guest { Stop-Service w32time -Force; Set-Service w32time -StartupType Disabled }
}

function Undo-GuestClockControl {
    Enable-VMIntegrationService -VMName $script:VmName -Name 'Time Synchronization'
}

function Set-GuestClock([datetime]$Time) {
    for ($k = 0; $k -lt 5; $k++) {
        Invoke-Guest -ArgumentList $Time -ScriptBlock { param($t) Set-Date -Date $t | Out-Null }
        Start-Sleep -Seconds 2
        $now = Invoke-Guest { Get-Date }
        if ([math]::Abs(($now - $Time).TotalSeconds) -lt 60) { return }
    }
    throw "The guest clock could not be set to $Time."
}

function Get-GuestBootTime { Invoke-Guest { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } }

# Watches for the guest restarting by itself. Returns $true when its boot time changes.
function Wait-GuestRestart($BootTime, [int]$Minutes) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        try { if ((Get-GuestBootTime) -ne $BootTime) { return $true } } catch { Disconnect-Guest }
    }
    # A guest in the middle of restarting cannot answer; wait for its desktop, then compare.
    Wait-GuestDesktop
    (Get-GuestBootTime) -ne $BootTime
}

# Restarts the guest from inside, then waits for the desktop user to be signed in again.
function Restart-Guest {
    Write-VmLog 'restarting the guest'
    # The session can drop while the guest goes down.
    try { Invoke-Guest { Restart-Computer -Force } } catch { }
    Disconnect-Guest
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline -and (Get-VMIntegrationService -VMName $script:VmName -Name Heartbeat).PrimaryStatusDescription -eq 'OK') { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 5
    Wait-GuestDesktop -Minutes 10
}

# Runs a script on the desktop user's desktop, through a scheduled task with an
# interactive logon (no stored password), started through a headless console so it
# never shows a window. Returns @{ ExitCode; Output }. With -NoWait, returns the task
# id at once; collect it later with Wait-DesktopTask.
function Invoke-OnDesktop([string]$Script, [int]$TimeoutSeconds = 300, [switch]$NoWait) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-Guest -ArgumentList $script:Exchange, $script:DesktopUser, $id, $Script -ScriptBlock {
        param($dir, $user, $id, $body)
        $tasks = Join-Path $dir 'tasks'
        $file = Join-Path $tasks "$id.ps1"
        Set-Content -LiteralPath $file -Value $body -Encoding UTF8
        # The done file is written last, with the script's exit code (99 when it threw).
        $command = "`$code = 0; try { & '$file' *> '$tasks\$id.out'; if (`$LASTEXITCODE) { `$code = `$LASTEXITCODE } } catch { Add-Content -LiteralPath '$tasks\$id.out' -Value ('ERROR: ' + `$_); `$code = 99 }; Set-Content -LiteralPath '$tasks\$id.done' -Value `$code"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName "agentamph-vm-$id" -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName "agentamph-vm-$id"
    }
    if ($NoWait) { return $id }
    Wait-DesktopTask $id $TimeoutSeconds
}

function Wait-DesktopTask([string]$Id, [int]$TimeoutSeconds = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Invoke-Guest -ArgumentList $script:Exchange, $Id -ScriptBlock {
            param($dir, $id)
            $done = Join-Path $dir "tasks\$id.done"
            if (-not (Test-Path -LiteralPath $done)) { return $null }
            $out = Join-Path $dir "tasks\$id.out"
            $result = @{ ExitCode = [int]((Get-Content -LiteralPath $done -Raw).Trim()); Output = $(if (Test-Path $out) { Get-Content -LiteralPath $out -Raw } else { '' }) }
            Unregister-ScheduledTask -TaskName "agentamph-vm-$id" -Confirm:$false -ErrorAction SilentlyContinue
            $result
        }
        if ($state) { return [pscustomobject]$state }
        Start-Sleep -Seconds 2
    }
    throw "The desktop task $Id did not finish within $TimeoutSeconds seconds."
}

function Copy-ToGuest([string]$Path, [string]$Destination) {
    Copy-Item -ToSession (Connect-Guest) -Path $Path -Destination $Destination -Recurse -Force
}

function Copy-FromGuest([string]$Path, [string]$Destination) {
    Copy-Item -FromSession (Connect-Guest) -Path $Path -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
}

# Captures the whole VM screen from the host through Hyper-V's WMI API (RGB565 pixels).
function Save-HostScreenshot([string]$Path) {
    $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$($script:VmName)'"
    $settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
    $head = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VideoHead | Select-Object -First 1
    $width = [int]$head.CurrentHorizontalResolution; $height = [int]$head.CurrentVerticalResolution
    $service = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
    $result = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $settings; WidthPixels = [uint16]$width; HeightPixels = [uint16]$height }
    $bytes = [byte[]]$result.ImageData
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $data = $bitmap.LockBits((New-Object System.Drawing.Rectangle(0, 0, $width, $height)), 'WriteOnly', $bitmap.PixelFormat)
    for ($y = 0; $y -lt $height; $y++) {
        [Runtime.InteropServices.Marshal]::Copy($bytes, $y * $width * 2, [IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $width * 2)
    }
    $bitmap.UnlockBits($data)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

# A script for the desktop task that logs every visible top-level window, with its
# process, every 50 ms for $Seconds seconds, to $LogPath.
function Get-WindowWatchScript([string]$LogPath, [int]$Seconds) {
    @"
Add-Type -Namespace AgentamphVm -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint p);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
'@
`$seen = @{}
`$end = (Get-Date).AddSeconds($Seconds)
`$names = @{}
while ((Get-Date) -lt `$end) {
    `$cb = [AgentamphVm.Win+EnumProc]{
        param(`$h, `$l)
        if ([AgentamphVm.Win]::IsWindowVisible(`$h)) {
            `$procId = 0; [void][AgentamphVm.Win]::GetWindowThreadProcessId(`$h, [ref]`$procId)
            `$key = "`$h"
            if (-not `$seen.ContainsKey(`$key)) {
                `$sb = New-Object System.Text.StringBuilder 256; [void][AgentamphVm.Win]::GetWindowText(`$h, `$sb, 256)
                `$name = try { (Get-Process -Id `$procId -ErrorAction Stop).ProcessName } catch { '?' }
                `$seen[`$key] = `$true
                Add-Content -LiteralPath '$LogPath' -Value ("{0:HH:mm:ss.fff}`t{1}`t{2}`t{3}" -f (Get-Date), `$procId, `$name, `$sb.ToString())
            }
        }
        `$true
    }
    [void][AgentamphVm.Win]::EnumWindows(`$cb, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
}
"@
}

# A script for the desktop task that saves a screenshot of the desktop to $Path.
function Get-DesktopScreenshotScript([string]$Path) {
    @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
`$bmp = New-Object System.Drawing.Bitmap(`$b.Width, `$b.Height)
`$g = [System.Drawing.Graphics]::FromImage(`$bmp)
`$g.CopyFromScreen(`$b.Location, [System.Drawing.Point]::Empty, `$b.Size)
`$bmp.Save('$Path', [System.Drawing.Imaging.ImageFormat]::Png)
`$g.Dispose(); `$bmp.Dispose()
"@
}

# Functions for a desktop task that drives the installed tray app as a user would, with
# real clicks and keys: Initialize-TrayUi finds the app, shows its icon on the taskbar
# and clears OneDrive's prompt; Open-Menu, Close-Menu and Switch-FirstSession work the
# menu; Get-TrayIcon's Name is the icon's tooltip.
function Get-TrayUiScript {
    @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace AgentamphVm -Name Input -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.UIntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
"@
$uia = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]

function Find-Element($Root, [scriptblock]$Match, [int]$Seconds = 10) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        foreach ($e in $Root.FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if (& $Match $e) { return $e } }
        Start-Sleep -Milliseconds 250
    }
    throw 'UI element not found'
}
function Get-Center($Element) { $r = $Element.Current.BoundingRectangle; @([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2)) }
function Move-PointerAway { [void][AgentamphVm.Input]::SetCursorPos(40, 300) }
function Invoke-Click([int[]]$At, [switch]$Right) {
    [void][AgentamphVm.Input]::SetCursorPos($At[0], $At[1]); Start-Sleep -Milliseconds 150
    $down, $up = if ($Right) { 0x0008, 0x0010 } else { 0x0002, 0x0004 }
    [AgentamphVm.Input]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    [AgentamphVm.Input]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
}
function Send-Key([byte]$Key) {
    [AgentamphVm.Input]::keybd_event($Key, 0, 0, [UIntPtr]::Zero); [AgentamphVm.Input]::keybd_event($Key, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Get-TrayIcon {
    $taskbar = $uia::RootElement.FindFirst($scope::Children, (New-Object Windows.Automation.PropertyCondition($uia::ClassNameProperty, 'Shell_TrayWnd')))
    Find-Element $taskbar { param($e) $e.Current.Name -like 'agentamph*' }
}
# The icon's tooltip once it matches $Pattern (UI Automation can briefly hold a stale
# copy of the icon), or every tooltip seen when none does within 15 seconds.
function Wait-TrayTip([string]$Pattern) {
    $end = (Get-Date).AddSeconds(15)
    do {
        $taskbar = $uia::RootElement.FindFirst($scope::Children, (New-Object Windows.Automation.PropertyCondition($uia::ClassNameProperty, 'Shell_TrayWnd')))
        $tips = @($taskbar.FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ -like 'agentamph*' } | ForEach-Object { $_ -replace '\r?\n', ' / ' })
        $match = @($tips | Where-Object { $_ -match $Pattern })
        if ($match) { return $match[0] }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $end)
    $tips -join ' + '
}
# The open menu: the tray app's top-level Windows Forms window.
function Get-Menu {
    $end = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $end) {
        foreach ($e in $uia::RootElement.FindAll($scope::Children, [Windows.Automation.Condition]::TrueCondition)) {
            if ($e.Current.ProcessId -eq $script:trayPid -and $e.Current.ClassName -like 'WindowsForms10.Window*') { return $e }
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'the menu did not open'
}
function Open-Menu {
    Invoke-Click (Get-Center (Get-TrayIcon)) -Right
    $menu = Get-Menu
    # Move the pointer off the menu, so no item is highlighted.
    Move-PointerAway
    Start-Sleep -Milliseconds 800
    $menu
}
function Close-Menu { Send-Key 0x1B; Start-Sleep -Milliseconds 600 }
# Toggles the first session in the open menu. UI Automation does not see the menu's
# items, so this uses the keyboard: Down passes the header and the guard's line.
function Switch-FirstSession {
    foreach ($i in 1..3) { Send-Key 0x28 }
    Send-Key 0x0D
    Start-Sleep -Milliseconds 2500
}
function Initialize-TrayUi {
    $end = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $script:trayPid = (Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*agentamph\tray.ps1*' } | Select-Object -First 1).ProcessId
    } until ($script:trayPid -or (Get-Date) -gt $end)
    if (-not $script:trayPid) { throw 'the tray app is not running' }
    Start-Sleep -Seconds 3
    # Windows 11 puts a new icon in the overflow; show it on the taskbar, as a user would.
    Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' | ForEach-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath
        if ($p.ExecutablePath -like '*powershell.exe') { Set-ItemProperty -LiteralPath $_.PSPath -Name IsPromoted -Value 1 -Type DWord }
    }
    # The checkpoint's desktop shows OneDrive's "Turn On Windows Backup" prompt, which
    # would cover the menu. Stop OneDrive and close the prompt with its X, anchored to
    # the bottom-right of the work area; on a desktop without it, the click lands on nothing.
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Invoke-Click @(($area.Right - 41), ($area.Bottom - 279))
    Move-PointerAway
    Start-Sleep -Seconds 2
    # The first open places the menu before it is filled; open it once to settle its size.
    $null = Open-Menu; Close-Menu
}
'@
}

# Records one check's result and evidence for the report.
function Add-Check([string]$Scenario, [string]$Check, [bool]$Passed, [string]$Evidence = '') {
    [void]$script:Checks.Add([pscustomobject]@{ Scenario = $Scenario; Check = $Check; Passed = $Passed; Evidence = $Evidence })
    Write-VmLog ("  [{0}] {1}{2}" -f $(if ($Passed) { 'pass' } else { 'FAIL' }), $Check, $(if ($Evidence) { " -- $Evidence" } else { '' }))
}

function Save-Report {
    $lines = @('# agentamph VM test report', '', "Run: $(Split-Path -Leaf $script:ResultsDir)", '')
    $failed = @($script:Checks | Where-Object { -not $_.Passed }).Count
    $lines += "Result: $(if ($failed) { "$failed of $($script:Checks.Count) checks failed" } else { "all $($script:Checks.Count) checks passed" })", ''
    $lines += '| Scenario | Check | Result | Evidence |', '|---|---|---|---|'
    foreach ($c in $script:Checks) {
        $evidence = ($c.Evidence -replace '\|', '/' -replace "`r?`n", '<br>')
        $lines += "| $($c.Scenario) | $($c.Check) | $(if ($c.Passed) { 'pass' } else { '**FAIL**' }) | $evidence |"
    }
    [IO.File]::WriteAllText((Join-Path $script:ResultsDir 'report.md'), ($lines -join "`n") + "`n")
    $failed
}
