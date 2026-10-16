# Runs the VM test scenarios against the Hyper-V VM "agentamph-test" (build it once with
# New-VmTemplate.ps1). Each scenario installs agentamph the way a user would, as the
# standard user "tester", and checks what the development machine cannot: a first
# install with nothing preinstalled, signing in, no console windows, uninstalling.
#
#   powershell -ExecutionPolicy Bypass -File tests\vm\Invoke-VmTests.ps1 [-Scenario 1,3]
#
# Run elevated, under Windows PowerShell 5.1. Writes tests\vm\results\<timestamp>\ and
# exits non-zero when any check fails. The owner's own profile is never touched.
# -Fault builds the release zip with a deliberate fault, to prove the checks catch it:
# NoHeadless (launch without --headless) or UninstallKeepsRun (uninstall keeps the
# login entry).

param(
    # Strings, split on commas: under -File, "-Scenario 1,3" arrives as one string.
    [string[]]$Scenario = @('1', '2', '3', '4', '5', '6', '7'),
    [ValidateSet('None', 'NoHeadless', 'UninstallKeepsRun')][string]$Fault = 'None'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmLib.ps1')
Assert-VmPrerequisites -NeedCheckpoint
$requested = @($Scenario -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [int]$_.Trim() })
$unknown = @($requested | Where-Object { $_ -notin 1..7 })
if ($unknown) { throw "No scenario $($unknown -join ', '). Scenarios are 1 to 7." }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ResultsDir = Join-Path $PSScriptRoot ("results\" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null
$script:LastScenario = 0

$Guest = @{
    Programs  = 'C:\Users\tester\AppData\Local\Programs\agentamph'
    Data      = 'C:\Users\tester\AppData\Local\agentamph'
    Shortcut  = 'C:\Users\tester\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\agentamph.lnk'
    Sessions  = 'C:\Users\tester\.claude\sessions'
    Downloads = 'C:\Users\tester\Downloads'
}

# ---- helpers -------------------------------------------------------------------

# Reads the desktop user's agentamph registry values through the loaded user hive.
function Get-TesterRegistry {
    Invoke-Guest -ArgumentList $script:DesktopUser -ScriptBlock {
        param($user)
        $sid = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value
        $base = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion"
        $run = (Get-ItemProperty -LiteralPath "$base\Run" -Name agentamph -ErrorAction SilentlyContinue).agentamph
        $arp = Get-ItemProperty -LiteralPath "$base\Uninstall\agentamph" -ErrorAction SilentlyContinue
        # Explicit nulls: an empty $(...) comes back over PowerShell Direct as a non-null object.
        $version = $null; $uninstall = $null
        if ($arp) { $version = $arp.DisplayVersion; $uninstall = $arp.UninstallString }
        [pscustomobject]@{ Run = $run; DisplayVersion = $version; UninstallString = $uninstall }
    }
}

# The tray app's processes: powershell.exe running tray.ps1, with owner and session.
function Get-GuestTray {
    @(Invoke-Guest {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match 'tray\.ps1' } | ForEach-Object {
            [pscustomobject]@{ ProcessId = $_.ProcessId; SessionId = $_.SessionId; Owner = (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User; CommandLine = $_.CommandLine }
        }
    })
}

function Wait-GuestTray([bool]$Running, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $tray = @(Get-GuestTray)
        if (($tray.Count -gt 0) -eq $Running) { return $tray }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $tray
}

function Save-Screens([string]$Name) {
    Save-HostScreenshot (Join-Path $script:ResultsDir "$Name-host.png")
    $guestPath = "$($script:Exchange)\$Name-desktop.png"
    Invoke-OnDesktop (Get-DesktopScreenshotScript $guestPath) 60 | Out-Null
    Copy-FromGuest $guestPath $script:ResultsDir
}

# Starts a window watch on the desktop, runs $Action, then checks that no console
# window appeared. Returns the action's result.
function Invoke-Watched([string]$Scenario, [string]$Name, [scriptblock]$Action, [int]$WatchSeconds = 40) {
    $log = "$($script:Exchange)\windows-$Name.log"
    $watch = Invoke-OnDesktop (Get-WindowWatchScript $log $WatchSeconds) -NoWait
    Start-Sleep -Seconds 3
    $result = & $Action
    Wait-DesktopTask $watch ($WatchSeconds + 60) | Out-Null
    Test-WindowLog $Scenario $Name $log
    $result
}

function Test-WindowLog([string]$Scenario, [string]$Name, [string]$GuestLog) {
    Copy-FromGuest $GuestLog $script:ResultsDir
    $local = Join-Path $script:ResultsDir (Split-Path -Leaf $GuestLog)
    $lines = if (Test-Path -LiteralPath $local) { @(Get-Content -LiteralPath $local) } else { @() }
    $consoles = @($lines | Where-Object { ($_ -split "`t")[2] -in 'conhost', 'powershell', 'cmd', 'WindowsTerminal', 'OpenConsole' })
    Add-Check $Scenario 'no console window appeared' ($consoles.Count -eq 0) $(if ($consoles) { $consoles -join '; ' } else { "$($lines.Count) windows seen, none a console; log $(Split-Path -Leaf $GuestLog)" })
}

function Test-Installed([string]$Scenario) {
    $files = Invoke-Guest -ArgumentList $Guest.Programs, $Guest.Shortcut -ScriptBlock {
        param($programs, $shortcut)
        [pscustomobject]@{ Tray = Test-Path "$programs\tray.ps1"; Uninstall = Test-Path "$programs\uninstall.ps1"; Icon = Test-Path "$programs\agentamph.ico"; Shortcut = Test-Path $shortcut }
    }
    Add-Check $Scenario 'program folder installed' ($files.Tray -and $files.Uninstall -and $files.Icon) "$($Guest.Programs): tray.ps1 $($files.Tray), uninstall.ps1 $($files.Uninstall), agentamph.ico $($files.Icon)"
    Add-Check $Scenario 'Start Menu shortcut' $files.Shortcut $Guest.Shortcut
    $reg = Get-TesterRegistry
    Add-Check $Scenario 'Apps & Features entry' ([bool]$reg.DisplayVersion) "DisplayVersion $($reg.DisplayVersion)"
    Add-Check $Scenario 'login entry' ([bool]$reg.Run -and $reg.Run -match '--headless') "$($reg.Run)"
    $tray = @(Wait-GuestTray $true)
    $ok = $tray.Count -eq 1 -and $tray[0].Owner -eq $script:DesktopUser -and $tray[0].SessionId -ne 0
    Add-Check $Scenario 'tray app running as tester on the desktop' $ok (($tray | ForEach-Object { "pid $($_.ProcessId), owner $($_.Owner), session $($_.SessionId)" }) -join '; ')
}

$script:ZipOnGuest = $null
function Publish-ReleaseZip {
    if ($script:ZipOnGuest) { return }
    $source = $repo
    if ($Fault -ne 'None') {
        # Build from a patched copy, never touching the clone.
        $source = Join-Path $script:ResultsDir 'fault-source'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        foreach ($item in 'src', 'scripts', 'install.ps1', 'uninstall.ps1') { Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $source -Recurse -Force }
        $patch = switch ($Fault) {
            'NoHeadless' { @{ File = 'src\lib\Startup.ps1'; Old = '"--headless `"'; New = '"`"' } }
            'UninstallKeepsRun' { @{ File = 'uninstall.ps1'; Old = "Set-StartAtLogin `$false ''"; New = '# fault: login entry kept' } }
        }
        $path = Join-Path $source $patch.File
        $text = [IO.File]::ReadAllText($path)
        if (-not $text.Contains($patch.Old)) { throw "Fault $Fault could not be applied to $($patch.File)." }
        [IO.File]::WriteAllText($path, $text.Replace($patch.Old, $patch.New))
        Write-VmLog "fault applied: $Fault ($($patch.File))"
    }
    $zip = & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'scripts\build-release.ps1') -OutDir $script:ResultsDir
    $script:ZipOnGuest = "$($script:Exchange)\$(Split-Path -Leaf $zip)"
    $script:ZipLocal = $zip
    Write-VmLog "built $(Split-Path -Leaf $zip)"
}

# Copies the release zip into the guest as a download and follows INSTALL.txt as tester.
function Install-FromZip([string]$Scenario) {
    Publish-ReleaseZip
    Copy-ToGuest $script:ZipLocal $script:Exchange
    $name = [IO.Path]::GetFileNameWithoutExtension($script:ZipLocal)
    $steps = @"
`$zip = '$($script:ZipOnGuest)'
`$downloads = '$($Guest.Downloads)'
Copy-Item `$zip `$downloads
`$copy = Join-Path `$downloads '$name.zip'
Set-Content -LiteralPath `$copy -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
Expand-Archive -LiteralPath `$copy -DestinationPath `$downloads -Force
`$folder = Join-Path `$downloads '$name'
# Extracting a downloaded zip in Explorer marks every file; do the same.
Get-ChildItem `$folder -Recurse -File | ForEach-Object { Set-Content -LiteralPath `$_.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" }
Set-Location `$folder
# INSTALL.txt step 3 and step 4, as written:
Get-ChildItem -Recurse | Unblock-File
powershell -ExecutionPolicy Bypass -File .\install.ps1
exit `$LASTEXITCODE
"@
    $result = Invoke-Watched $Scenario "$Scenario-install" { Invoke-OnDesktop $steps 300 }
    Add-Check $Scenario 'installer finished' ($result.ExitCode -eq 0) (($result.Output -split "`r?`n" | Where-Object { $_ }) -join ' / ')
}

function Start-Scenario([int]$Number, [string]$Title, [switch]$ContinueFrom) {
    Write-VmLog "scenario ${Number}: $Title"
    $script:LastScenario = $Number
}

# ---- scenarios -----------------------------------------------------------------

function Invoke-Scenario1 {
    Start-Scenario 1 'release zip install, following INSTALL.txt'
    Restore-CleanVm
    # The harness itself runs with -ExecutionPolicy Bypass (Process scope), so check
    # every other scope: all Undefined means Windows' default, Restricted.
    $policy = Invoke-OnDesktop "Get-ExecutionPolicy -List | Where-Object { `$_.Scope -ne 'Process' } | ForEach-Object { '{0}={1}' -f `$_.Scope, `$_.ExecutionPolicy }" 60
    $scopes = @($policy.Output -split "`r?`n" | Where-Object { $_ })
    Add-Check 1 'guest starts with the default execution policy' ($scopes.Count -eq 4 -and -not ($scopes | Where-Object { $_ -notmatch '=Undefined$' })) ($scopes -join ', ')
    Install-FromZip 1
    Test-Installed 1
    Save-Screens '1-installed'
}

function Invoke-Scenario2 {
    Start-Scenario 2 'one-line install from GitHub'
    Restore-CleanVm
    $line = 'irm https://raw.githubusercontent.com/jackmossman/agentamph/main/install.ps1 | iex'
    $result = Invoke-Watched 2 '2-install' { Invoke-OnDesktop $line 300 }
    Add-Check 2 'one-line installer finished' ($result.Output -match 'is installed in') (($result.Output -split "`r?`n" | Where-Object { $_ }) -join ' / ')
    Test-Installed 2
    Save-Screens '2-installed'
}

function Invoke-Scenario3 {
    if ($script:LastScenario -ne 1) { Start-Scenario 3 'sign-in (installing first)'; Restore-CleanVm; Install-FromZip 3 }
    else { Start-Scenario 3 'sign-in, continuing from scenario 1' }
    # A logon task starts the window watch as tester signs in, before the Run entries.
    $log = "$($script:Exchange)\windows-3-signin.log"
    $watchScript = Get-WindowWatchScript $log 90
    Invoke-Guest -ArgumentList $script:Exchange, $script:DesktopUser, $watchScript -ScriptBlock {
        param($dir, $user, $body)
        $file = Join-Path $dir 'tasks\logon-watch.ps1'
        Set-Content -LiteralPath $file -Value $body -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        Register-ScheduledTask -TaskName 'agentamph-vm-logon-watch' -Action $action -Principal $principal -Trigger $trigger -Force | Out-Null
    }
    Restart-Guest
    $tray = @(Wait-GuestTray $true 90)
    $ok = $tray.Count -eq 1 -and $tray[0].Owner -eq $script:DesktopUser -and $tray[0].SessionId -ne 0
    Add-Check 3 'tray app started at sign-in' $ok (($tray | ForEach-Object { "pid $($_.ProcessId), owner $($_.Owner), session $($_.SessionId)" }) -join '; ')
    Start-Sleep -Seconds 60
    Invoke-Guest { Unregister-ScheduledTask -TaskName 'agentamph-vm-logon-watch' -Confirm:$false -ErrorAction SilentlyContinue }
    Test-WindowLog 3 '3-signin' $log
    Save-Screens '3-after-signin'
}

function Invoke-Scenario4 {
    Start-Scenario 4 'start at login turned off'
    Restore-CleanVm
    Install-FromZip 4
    $off = Invoke-OnDesktop @"
. '$($Guest.Programs)\lib\Startup.ps1'
Set-StartAtLogin `$false ''
if (Test-StartAtLogin) { 'still on'; exit 1 } else { 'off' }
"@ 60
    Add-Check 4 'login entry removed through the app''s own code' ($off.ExitCode -eq 0 -and -not (Get-TesterRegistry).Run) $off.Output.Trim()
    Restart-Guest
    Start-Sleep -Seconds 45
    $tray = @(Get-GuestTray)
    Add-Check 4 'tray app not started at sign-in' ($tray.Count -eq 0) "$($tray.Count) tray processes 45 s after sign-in"
}

function Get-PowerRequests {
    $text = Invoke-Guest { (powercfg /requests) -join "`n" }
    $system = if ($text -match '(?s)SYSTEM:\s*\n(.*?)\n[A-Z]+:') { $Matches[1] } else { '' }
    $display = if ($text -match '(?s)DISPLAY:\s*\n(.*?)\n[A-Z]+:') { $Matches[1] } else { '' }
    [pscustomobject]@{ Text = $text; System = $system; Display = $display }
}

function Wait-PowerRequest([bool]$Present, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $requests = Get-PowerRequests
        if (($requests.System -match 'powershell\.exe') -eq $Present) { return $requests }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $requests
}

function Invoke-Scenario5 {
    Start-Scenario 5 'keep-awake with a simulated critical session'
    Restore-CleanVm
    Install-FromZip 5
    $sessionId = [guid]::NewGuid().ToString()
    $start = Invoke-OnDesktop @"
`$dummy = Start-Process -FilePath ping.exe -ArgumentList '-n 900 127.0.0.1' -WindowStyle Hidden -PassThru
New-Item -ItemType Directory -Path '$($Guest.Sessions)' -Force | Out-Null
`$session = [ordered]@{ pid = `$dummy.Id; sessionId = '$sessionId'; cwd = 'C:\work\demo'; procStart = `$dummy.StartTime.ToFileTimeUtc().ToString(); name = 'demo'; status = 'idle'; entrypoint = 'cli'; updatedAt = 0 }
[IO.File]::WriteAllText('$($Guest.Sessions)\' + `$dummy.Id + '.json', (`$session | ConvertTo-Json -Compress))
New-Item -ItemType Directory -Path '$($Guest.Data)\critical' -Force | Out-Null
[IO.File]::WriteAllText('$($Guest.Data)\critical\$sessionId', (Get-Date).ToUniversalTime().ToString('o'))
`$dummy.Id
"@ 60
    $dummyId = [int]($start.Output.Trim() -split "`r?`n")[-1]
    $on = Wait-PowerRequest $true 20
    Add-Check 5 'critical session holds: app listed under SYSTEM' ($on.System -match 'powershell\.exe') (($on.System -split "`n" | Where-Object { $_ }) -join ' / ')
    Save-Screens '5-holding'
    Invoke-Guest -ArgumentList $dummyId -ScriptBlock { param($id) Stop-Process -Id $id -Force }
    $off = Wait-PowerRequest $false 20
    Add-Check 5 'session closed: SYSTEM entry gone' (-not ($off.System -match 'powershell\.exe')) $(if ($off.System.Trim()) { $off.System.Trim() } else { 'SYSTEM: None' })
}

function Invoke-Scenario6 {
    Start-Scenario 6 'uninstall through the Apps & Features entry'
    Restore-CleanVm
    Install-FromZip 6
    $result = Invoke-OnDesktop @'
$command = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\agentamph').UninstallString
"running: $command"
$p = Start-Process -FilePath cmd.exe -ArgumentList "/s /c `"$command`"" -WindowStyle Hidden -Wait -PassThru
exit $p.ExitCode
'@ 120
    Add-Check 6 'uninstaller finished' ($result.ExitCode -eq 0) $result.Output.Trim()
    Start-Sleep -Seconds 10
    $left = Invoke-Guest -ArgumentList $Guest.Programs, $Guest.Shortcut, $Guest.Data -ScriptBlock {
        param($programs, $shortcut, $data)
        @($programs, $shortcut, $data | Where-Object { Test-Path $_ })
    }
    $reg = Get-TesterRegistry
    $tray = @(Get-GuestTray)
    Add-Check 6 'program folder, shortcut and data removed' (@($left).Count -eq 0) $(if ($left) { "left: $($left -join ', ')" } else { 'none left' })
    Add-Check 6 'login entry and Apps & Features entry removed' (-not $reg.Run -and -not $reg.DisplayVersion) "Run: [$($reg.Run)], DisplayVersion: [$($reg.DisplayVersion)]"
    Add-Check 6 'tray app stopped' ($tray.Count -eq 0) "$($tray.Count) tray processes"
}

function Invoke-Scenario7 {
    Start-Scenario 7 'Pester suite in the guest, as tester'
    Restore-CleanVm
    $zip = Join-Path $script:ResultsDir 'repo.zip'
    $files = @(git -C $repo ls-files -co --exclude-standard)
    $stage = Join-Path $script:ResultsDir 'repo'
    foreach ($f in $files) {
        $target = Join-Path $stage $f
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $target
    }
    Compress-Archive -Path "$stage\*" -DestinationPath $zip
    Remove-Item -LiteralPath $stage -Recurse -Force
    Copy-ToGuest $zip $script:Exchange
    Invoke-Guest -ArgumentList $script:Exchange -ScriptBlock { param($dir) Expand-Archive -LiteralPath "$dir\repo.zip" -DestinationPath "$dir\repo" -Force }
    $setup = Invoke-OnDesktop @'
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
"Pester $((Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version)"
'@ 600
    Add-Check 7 'Pester installed for tester' ($setup.Output -match 'Pester (\d+)\.' -and [int]$Matches[1] -ge 5) $setup.Output.Trim()
    $run = Invoke-OnDesktop "powershell -NoProfile -ExecutionPolicy Bypass -File $($script:Exchange)\repo\scripts\test.ps1; exit `$LASTEXITCODE" 1500
    # Pester 6 colours its output with escape codes; strip them.
    $text = $run.Output -replace "$([char]27)\[[0-9;]*m", ''
    [IO.File]::WriteAllText((Join-Path $script:ResultsDir '7-pester.txt'), $text)
    $summary = ($text -split "`r?`n" | Where-Object { $_ -match '^Tests Passed:' }) -join ' '
    $failures = ($text -split "`r?`n" | Where-Object { $_ -match '^\s+\[-\]' }) -join '; '
    Add-Check 7 'Pester suite passes as a standard user' ($run.ExitCode -eq 0) $(if ($failures) { "$summary; failed: $failures" } else { $summary })
}

# ---- run -----------------------------------------------------------------------

$order = @(1, 3, 2, 4, 5, 6, 7) | Where-Object { $_ -in $requested }
try {
    foreach ($number in $order) {
        try { & "Invoke-Scenario$number" }
        catch { Add-Check $number 'scenario ran to the end' $false "$($_.Exception.Message)"; Disconnect-Guest }
    }
} finally {
    Disconnect-Guest
    $failed = Save-Report
    Write-VmLog "report: $(Join-Path $script:ResultsDir 'report.md')"
}
if ($failed -or $script:Checks.Count -eq 0) { exit 1 }
