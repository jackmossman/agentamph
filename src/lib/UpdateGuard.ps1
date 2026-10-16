# Update guard: while a session holds, keeps the current time inside Windows Update's
# Active Hours, so Windows does not restart the machine for updates. Standard users may
# write Active Hours (as Settings does); no elevation is used. The user's own values are
# saved under HKCU first and put back when nothing holds. Environment overrides exist so
# tests can point every key at a temporary one.

function Get-ActiveHoursKey {
    if ($env:AGENTAMPH_ACTIVE_HOURS_KEY) { return $env:AGENTAMPH_ACTIVE_HOURS_KEY }
    'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
}

function Get-UpdateGuardBackupKey {
    if ($env:AGENTAMPH_GUARD_BACKUP_KEY) { return $env:AGENTAMPH_GUARD_BACKUP_KEY }
    'HKCU:\Software\agentamph\UpdateGuard'
}

function Get-UpdatePolicyKey {
    if ($env:AGENTAMPH_UPDATE_POLICY_KEY) { return $env:AGENTAMPH_UPDATE_POLICY_KEY }
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
}

function Get-RebootRequiredKey {
    if ($env:AGENTAMPH_REBOOT_REQUIRED_KEY) { return $env:AGENTAMPH_REBOOT_REQUIRED_KEY }
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
}

$script:ActiveHoursNames = @('ActiveHoursStart', 'ActiveHoursEnd', 'SmartActiveHoursState')

# The window the guard sets: from the hour before now, for Windows' maximum of 18 hours.
function Get-GuardWindow([datetime]$Now) {
    $start = ($Now.Hour + 23) % 24
    @{ ActiveHoursStart = $start; ActiveHoursEnd = ($start + 18) % 24; SmartActiveHoursState = 0 }
}

function Get-ActiveHoursValues([string]$Key) {
    $values = @{}
    $item = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
    foreach ($name in $script:ActiveHoursNames) {
        if ($item -and $item.PSObject.Properties[$name]) { $values[$name] = [int]$item.$name }
    }
    $values
}

# Why the guard cannot work here, or $null when it can.
function Get-UpdateGuardBlocker {
    $policy = Get-ItemProperty -LiteralPath (Get-UpdatePolicyKey) -ErrorAction SilentlyContinue
    if ($policy -and $policy.PSObject.Properties['SetActiveHours'] -and [int]$policy.SetActiveHours -ne 0) {
        return 'Active Hours are set by Group Policy'
    }
    if (-not (Test-Path -LiteralPath (Get-ActiveHoursKey))) { return 'Windows Update settings not found' }
    $null
}

function Test-UpdateGuardBackup { Test-Path -LiteralPath (Get-UpdateGuardBackupKey) }

# Saves the user's values once per holding period. A value Windows did not have is
# recorded as absent, so restoring removes it again.
function Save-UpdateGuardBackup {
    if (Test-UpdateGuardBackup) { return }
    $original = Get-ActiveHoursValues (Get-ActiveHoursKey)
    $key = Get-UpdateGuardBackupKey
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    foreach ($name in $original.Keys) { Set-ItemProperty -LiteralPath $key -Name $name -Value $original[$name] -Type DWord -ErrorAction Stop }
    Set-ItemProperty -LiteralPath $key -Name 'Saved' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Type String -ErrorAction Stop
}

# Puts the saved values back and deletes the backup. Does nothing without a backup.
function Restore-UpdateGuardBackup {
    $backupKey = Get-UpdateGuardBackupKey
    if (-not (Test-Path -LiteralPath $backupKey)) { return }
    $saved = Get-ActiveHoursValues $backupKey
    $key = Get-ActiveHoursKey
    $have = Get-ActiveHoursValues $key
    # Only differences are written, so a key the guard never managed to change needs no access.
    foreach ($name in $script:ActiveHoursNames) {
        if ($saved.ContainsKey($name)) {
            if (-not $have.ContainsKey($name) -or $have[$name] -ne $saved[$name]) { Set-ItemProperty -LiteralPath $key -Name $name -Value $saved[$name] -Type DWord -ErrorAction Stop }
        } elseif ($have.ContainsKey($name)) {
            Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop
        }
    }
    Remove-Item -LiteralPath $backupKey -Recurse -Force -ErrorAction Stop
    $parent = Split-Path -Parent $backupKey
    if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent) -and -not (Get-Item -LiteralPath $parent).Property) {
        Remove-Item -LiteralPath $parent -Force
    }
}

# Writes the guard's window when the current values differ from it. Returns $true when
# it wrote anything.
function Set-GuardWindow([datetime]$Now) {
    $key = Get-ActiveHoursKey
    $want = Get-GuardWindow $Now
    $have = Get-ActiveHoursValues $key
    $changed = $false
    foreach ($name in $script:ActiveHoursNames) {
        if (-not $have.ContainsKey($name) -or $have[$name] -ne $want[$name]) {
            Set-ItemProperty -LiteralPath $key -Name $name -Value $want[$name] -Type DWord -ErrorAction Stop
            $changed = $true
        }
    }
    $changed
}

function Test-RebootPending { Test-Path -LiteralPath (Get-RebootRequiredKey) }

# One step of the guard, called on every refresh. $State is a hashtable kept by the
# caller: State ('off', 'holding' or 'unavailable'), Reason, and RetryAt. Returns a
# short description of what changed, or $null.
function Update-UpdateGuard([hashtable]$State, [bool]$Hold, [bool]$Enabled, [datetime]$Now) {
    if (-not ($Hold -and $Enabled)) {
        $was = $State.State
        $State.State = 'off'; $State.Reason = $null
        if ((Test-UpdateGuardBackup) -and $Now -ge $State.RetryAt) {
            try { Restore-UpdateGuardBackup; $State.RetryAt = [datetime]::MinValue; return 'restored Active Hours' }
            catch { $State.RetryAt = $Now.AddMinutes(1); return "restore failed: $($_.Exception.Message)" }
        }
        if ($was -ne 'off') { return 'off' }
        return $null
    }
    if ($State.State -eq 'unavailable' -and $Now -lt $State.RetryAt) { return $null }

    $blocker = Get-UpdateGuardBlocker
    if (-not $blocker) {
        try {
            Save-UpdateGuardBackup
            $wrote = Set-GuardWindow $Now
            $was = $State.State
            $State.State = 'holding'; $State.Reason = $null
            if ($was -ne 'holding') { return 'holding' }
            if ($wrote) { return 'moved Active Hours' }
            return $null
        } catch {
            $blocker = "cannot change Active Hours: $($_.Exception.Message)"
            try { Restore-UpdateGuardBackup } catch { }
        }
    } elseif (Test-UpdateGuardBackup) {
        try { Restore-UpdateGuardBackup } catch { }
    }
    $changed = $State.State -ne 'unavailable' -or $State.Reason -ne $blocker
    $State.State = 'unavailable'; $State.Reason = $blocker; $State.RetryAt = $Now.AddMinutes(1)
    if ($changed) { return "unavailable: $blocker" }
    $null
}

function New-UpdateGuardState { @{ State = 'off'; Reason = $null; RetryAt = [datetime]::MinValue } }
