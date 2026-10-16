# The update guard, against temporary keys under HKCU standing in for Windows Update's
# Active Hours, its policy key and the pending-restart flag. The real keys are never
# touched.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $names = 'AGENTAMPH_ACTIVE_HOURS_KEY', 'AGENTAMPH_GUARD_BACKUP_KEY', 'AGENTAMPH_UPDATE_POLICY_KEY', 'AGENTAMPH_REBOOT_REQUIRED_KEY'
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Set-Values([string]$Key, [hashtable]$Values) {
        foreach ($name in $Values.Keys) { Set-ItemProperty -LiteralPath $Key -Name $name -Value $Values[$name] -Type DWord }
    }
    function Get-Values([string]$Key) { Get-ActiveHoursValues $Key }
    function Step([bool]$Hold, [bool]$Enabled = $true, [datetime]$Now = [datetime]'2026-10-16T12:30:00') {
        Update-UpdateGuard $state $Hold $Enabled $Now
    }
    function Set-DenyWrite([string]$Key, [bool]$Deny) {
        $path = $Key -replace '^HKCU:\\', ''
        $item = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::ReadKey)
        $acl = $item.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'SetValue', 'Deny')
        if ($Deny) { $acl.AddAccessRule($rule) } else { [void]$acl.RemoveAccessRule($rule) }
        $item.SetAccessControl($acl)
        $item.Close()
    }
}

AfterAll {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}

Describe 'Get-GuardWindow' {
    It 'starts an hour before now and spans 18 hours' {
        $w = Get-GuardWindow ([datetime]'2026-10-16T12:30:00')
        $w.ActiveHoursStart | Should -Be 11
        $w.ActiveHoursEnd | Should -Be 5
        $w.SmartActiveHoursState | Should -Be 0
    }
    It 'wraps around midnight' {
        $w = Get-GuardWindow ([datetime]'2026-10-16T00:10:00')
        $w.ActiveHoursStart | Should -Be 23
        $w.ActiveHoursEnd | Should -Be 17
    }
}

Describe 'Update-UpdateGuard' {
    BeforeEach {
        $root = "HKCU:\Software\agentamph-test-$([guid]::NewGuid().ToString('N'))"
        $env:AGENTAMPH_ACTIVE_HOURS_KEY = "$root\UX"
        $env:AGENTAMPH_GUARD_BACKUP_KEY = "$root\agentamph\UpdateGuard"
        $env:AGENTAMPH_UPDATE_POLICY_KEY = "$root\Policy"
        $env:AGENTAMPH_REBOOT_REQUIRED_KEY = "$root\RebootRequired"
        $ux = $env:AGENTAMPH_ACTIVE_HOURS_KEY
        New-Item -Path $ux -Force | Out-Null
        Set-Values $ux @{ ActiveHoursStart = 8; ActiveHoursEnd = 17; SmartActiveHoursState = 1 }
        $state = New-UpdateGuardState
    }
    AfterEach {
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    }

    It 'saves the user''s values, then puts the current time inside Active Hours' {
        Step $true | Should -Be 'holding'
        $state.State | Should -Be 'holding'
        $v = Get-Values $ux
        $v.ActiveHoursStart | Should -Be 11
        $v.ActiveHoursEnd | Should -Be 5
        $v.SmartActiveHoursState | Should -Be 0
        $b = Get-Values $env:AGENTAMPH_GUARD_BACKUP_KEY
        $b.ActiveHoursStart | Should -Be 8
        $b.ActiveHoursEnd | Should -Be 17
        $b.SmartActiveHoursState | Should -Be 1
    }

    It 'moves the window when the hour changes, and leaves it alone within the hour' {
        Step $true | Out-Null
        Step $true -Now ([datetime]'2026-10-16T12:59:00') | Should -BeNullOrEmpty
        Step $true -Now ([datetime]'2026-10-16T13:05:00') | Should -Be 'moved Active Hours'
        (Get-Values $ux).ActiveHoursStart | Should -Be 12
        (Get-Values $env:AGENTAMPH_GUARD_BACKUP_KEY).ActiveHoursStart | Should -Be 8 -Because 'the backup is taken once per holding period'
    }

    It 'puts the window back if something else changes it while holding' {
        Step $true | Out-Null
        Set-Values $ux @{ SmartActiveHoursState = 1 }
        Step $true | Should -Be 'moved Active Hours'
        (Get-Values $ux).SmartActiveHoursState | Should -Be 0
    }

    It 'restores the user''s values and removes the backup when nothing holds' {
        Step $true | Out-Null
        Step $false | Should -Be 'restored Active Hours'
        $state.State | Should -Be 'off'
        $v = Get-Values $ux
        $v.ActiveHoursStart | Should -Be 8
        $v.ActiveHoursEnd | Should -Be 17
        $v.SmartActiveHoursState | Should -Be 1
        Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
        Test-Path (Split-Path -Parent $env:AGENTAMPH_GUARD_BACKUP_KEY) | Should -BeFalse
    }

    It 'restores values that were absent as absent' {
        Remove-ItemProperty -LiteralPath $ux -Name ActiveHoursStart, ActiveHoursEnd, SmartActiveHoursState
        Step $true | Out-Null
        (Get-Values $ux).Count | Should -Be 3
        Step $false | Out-Null
        (Get-Values $ux).Count | Should -Be 0
    }

    It 'restores at once when turned off while holding' {
        Step $true | Out-Null
        Step $true -Enabled $false | Should -Be 'restored Active Hours'
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
        Step $true | Should -Be 'holding'
        (Get-Values $ux).ActiveHoursStart | Should -Be 11
    }

    It 'restores a backup left by a crash when nothing holds at start' {
        Step $true | Out-Null
        $state = New-UpdateGuardState
        Step $false | Should -Be 'restored Active Hours'
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
    }

    It 'does nothing when nothing holds and nothing was changed' {
        Step $false | Should -BeNullOrEmpty
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
        Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
    }

    It 'is unavailable under the SetActiveHours policy, and changes nothing' {
        New-Item -Path $env:AGENTAMPH_UPDATE_POLICY_KEY -Force | Out-Null
        Set-Values $env:AGENTAMPH_UPDATE_POLICY_KEY @{ SetActiveHours = 1 }
        Step $true | Should -Be 'unavailable: Active Hours are set by Group Policy'
        $state.State | Should -Be 'unavailable'
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
        Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
    }

    It 'restores and reports unavailable when the policy appears while holding' {
        Step $true | Out-Null
        New-Item -Path $env:AGENTAMPH_UPDATE_POLICY_KEY -Force | Out-Null
        Set-Values $env:AGENTAMPH_UPDATE_POLICY_KEY @{ SetActiveHours = 1 }
        Step $true | Should -Match '^unavailable'
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
        Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
    }

    It 'is unavailable when writing is denied, changes nothing, and leaves no backup' {
        Set-DenyWrite $ux $true
        try {
            Step $true | Should -Match '^unavailable: cannot change Active Hours'
            $state.State | Should -Be 'unavailable'
            $v = Get-Values $ux
            $v.ActiveHoursStart | Should -Be 8
            $v.SmartActiveHoursState | Should -Be 1
            Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
            Step $true | Should -BeNullOrEmpty -Because 'it retries after a minute, not on every refresh'
        } finally { Set-DenyWrite $ux $false }
    }

    It 'is unavailable when the Active Hours key does not exist' {
        Remove-Item $ux -Recurse -Force
        Step $true | Should -Be 'unavailable: Windows Update settings not found'
        Test-Path $ux | Should -BeFalse
    }

    It 'detects a pending update restart' {
        Test-RebootPending | Should -BeFalse
        New-Item -Path $env:AGENTAMPH_REBOOT_REQUIRED_KEY -Force | Out-Null
        Test-RebootPending | Should -BeTrue
    }

    It 'uninstall.ps1 restores the values a crashed app left behind' {
        Step $true | Out-Null
        $other = New-TestDirectory
        $before = @{}
        foreach ($name in 'AGENTAMPH_RUN_KEY', 'AGENTAMPH_TRAY_MUTEX') { $before[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:AGENTAMPH_RUN_KEY = "$root\Run"
            $env:AGENTAMPH_TRAY_MUTEX = "Local\agentamph-test-$([guid]::NewGuid().ToString('N'))"
            $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'uninstall.ps1') `
                -InstallDir (Join-Path $other 'Programs') -StartMenuDir (Join-Path $other 'Start') -UninstallKey "$root\Uninstall" -DataDir (Join-Path $other 'data') | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            foreach ($name in $before.Keys) { [Environment]::SetEnvironmentVariable($name, $before[$name]) }
            Remove-Item $other -Recurse -Force -ErrorAction SilentlyContinue
        }
        (Get-Values $ux).ActiveHoursStart | Should -Be 8
        Test-Path $env:AGENTAMPH_GUARD_BACKUP_KEY | Should -BeFalse
    }
}
