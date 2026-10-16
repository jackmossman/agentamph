# Builds the "pending-restart" checkpoint that scenario 8 (the update guard) needs: from
# "clean", installs the available Windows updates until one needs a restart, lets
# Windows' Update Orchestrator take charge of that restart, and checkpoints the VM.
#
#   powershell -ExecutionPolicy Bypass -File tests\vm\New-PendingRestartCheckpoint.ps1
#
# Run elevated, under Windows PowerShell 5.1, after New-VmTemplate.ps1. Takes 30 to 90
# minutes, mostly downloading. Re-run it to replace the checkpoint, for example when the
# updates it holds are out of date.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmLib.ps1')
Assert-VmPrerequisites -NeedCheckpoint

$script:ResultsDir = Join-Path $PSScriptRoot ("results\" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-pending-restart')
New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null
Restore-CleanVm

# The Windows Update API refuses to download in a remote session, so the install runs
# as SYSTEM from a scheduled task and reports through a log file.
$installer = @'
$log = 'C:\exchange\wu.log'
function L($m) { Add-Content $log "$((Get-Date).ToString('HH:mm:ss')) $m" }
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$updates.Add($u); L "found: $($u.Title)" }
    if ($updates.Count -gt 0) {
        $download = $session.CreateUpdateDownloader(); $download.Updates = $updates
        L "download result $($download.Download().ResultCode)"
        $install = $session.CreateUpdateInstaller(); $install.Updates = $updates
        $r = $install.Install()
        L "install result $($r.ResultCode), restart required $($r.RebootRequired)"
    }
} catch { L "ERROR $($_.Exception.Message)" }
L 'DONE'
'@

Write-VmLog 'installing Windows updates in the guest (as SYSTEM)'
Invoke-Guest -ArgumentList $installer -ScriptBlock {
    param($body)
    Remove-Item C:\exchange\wu.log -ErrorAction SilentlyContinue
    Set-Content C:\exchange\wu-install.ps1 $body -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\exchange\wu-install.ps1'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName 'agentamph-wu-install' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'agentamph-wu-install'
}
$seen = 0
$deadline = (Get-Date).AddHours(3)
do {
    Start-Sleep -Seconds 30
    $lines = @(Invoke-Guest { if (Test-Path C:\exchange\wu.log) { Get-Content C:\exchange\wu.log } })
    for ($k = $seen; $k -lt $lines.Count; $k++) { Write-VmLog "  guest: $($lines[$k])" }
    $seen = $lines.Count
} while (-not ($lines -match 'DONE') -and (Get-Date) -lt $deadline)
Invoke-Guest { Unregister-ScheduledTask -TaskName 'agentamph-wu-install' -Confirm:$false }
if (-not (Invoke-Guest { Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' })) {
    throw 'No update needed a restart, so there is nothing for the update guard to hold off. Try again after the next monthly update.'
}

# Windows' own scan hands the pending restart to the Update Orchestrator, which records
# when it noticed it. Without this, nothing restarts the guest by itself.
Write-VmLog 'running Windows'' scheduled update scan'
Invoke-Guest { Start-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Schedule Scan Static Task' }
$deadline = (Get-Date).AddMinutes(30)
do {
    Start-Sleep -Seconds 20
    $noticed = Invoke-Guest { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\StateVariables' -ErrorAction SilentlyContinue).CurrentRebootRecognitionTime }
} while (-not $noticed -and (Get-Date) -lt $deadline)
if (-not $noticed) { throw 'The Update Orchestrator did not take charge of the pending restart within 30 minutes.' }
Write-VmLog "Update Orchestrator noticed the pending restart at $([DateTimeOffset]::FromUnixTimeMilliseconds([long]$noticed).LocalDateTime)"

Disconnect-Guest
if (Get-VMSnapshot -VMName $script:VmName -Name $script:PendingRestartCheckpoint -ErrorAction SilentlyContinue) {
    Remove-VMSnapshot -VMName $script:VmName -Name $script:PendingRestartCheckpoint -Confirm:$false
}
Checkpoint-VM -Name $script:VmName -SnapshotName $script:PendingRestartCheckpoint
Write-VmLog "checkpoint '$($script:PendingRestartCheckpoint)' taken"
