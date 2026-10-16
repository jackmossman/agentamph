# Shared functions for the VM tests: the Hyper-V VM "agentamph-test", PowerShell
# Direct as the guest administrator, scheduled tasks that run on the standard user's
# desktop, host-side screenshots, and the report. Windows PowerShell 5.1, elevated.

$script:VmName = 'agentamph-test'
$script:CleanCheckpoint = 'clean'
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

# Restores the clean checkpoint, resumes the VM, and sets its clock from the host,
# because a checkpoint brings back the clock as it was when taken.
function Restore-CleanVm {
    Write-VmLog "restoring checkpoint '$($script:CleanCheckpoint)'"
    Disconnect-Guest
    Restore-VMSnapshot -VMName $script:VmName -Name $script:CleanCheckpoint -Confirm:$false
    if ((Get-VM -Name $script:VmName).State -ne 'Running') { Start-VM -Name $script:VmName }
    Connect-Guest | Out-Null
    $now = Get-Date
    Invoke-Guest -ArgumentList $now -ScriptBlock { param($t) Set-Date -Date $t | Out-Null }
    Wait-GuestDesktop
    Initialize-GuestExchange
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
