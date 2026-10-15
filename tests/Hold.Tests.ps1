BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-HoldingIds($Sessions, [hashtable]$Marks, $Selector, $Mode, $Grace = 2, [hashtable]$LastBusy = @{}, $Now = [datetime]'2026-10-15T12:00:00') {
        @(Get-HoldingSessions -Sessions $Sessions -Marks $Marks -Selector $Selector -Mode $Mode -GraceMinutes $Grace -LastBusy $LastBusy -Now $Now | ForEach-Object { $_.SessionId })
    }
}

Describe 'Get-HoldingSessions' {
    BeforeAll {
        $busy = New-TestSession 'busy' 'busy'
        $idle = New-TestSession 'idle' 'idle'
        $sessions = @($busy, $idle)
        $now = [datetime]'2026-10-15T12:00:00'
    }

    It 'Critical + Until closed holds only marked live sessions' {
        Get-HoldingIds $sessions @{ idle = 1 } 'Critical' 'UntilClosed' | Should -Be @('idle')
        Get-HoldingIds $sessions @{} 'Critical' 'UntilClosed' | Should -BeNullOrEmpty
    }

    It 'All + Until closed holds every live session' {
        Get-HoldingIds $sessions @{} 'All' 'UntilClosed' | Should -Be @('busy', 'idle')
        Get-HoldingIds @() @{} 'All' 'UntilClosed' | Should -BeNullOrEmpty
    }

    It 'All + While busy holds busy sessions' {
        Get-HoldingIds $sessions @{} 'All' 'WhileBusy' | Should -Be @('busy')
    }

    It 'While busy keeps holding through the grace period, then lets go' {
        $last = @{ idle = $now.AddMinutes(-1) }
        Get-HoldingIds $sessions @{} 'All' 'WhileBusy' 2 $last $now | Should -Be @('busy', 'idle')
        $last = @{ idle = $now.AddMinutes(-3) }
        Get-HoldingIds $sessions @{} 'All' 'WhileBusy' 2 $last $now | Should -Be @('busy')
    }

    It 'a grace period of zero lets go at once' {
        $last = @{ idle = $now.AddSeconds(-10) }
        Get-HoldingIds $sessions @{} 'All' 'WhileBusy' 0 $last $now | Should -Be @('busy')
    }

    It 'Critical + While busy ignores busy unmarked sessions' {
        Get-HoldingIds $sessions @{} 'Critical' 'WhileBusy' | Should -BeNullOrEmpty
        Get-HoldingIds $sessions @{ busy = 1 } 'Critical' 'WhileBusy' | Should -Be @('busy')
    }

    It 'an unknown status counts as busy' {
        Get-HoldingIds @(New-TestSession 'odd' 'compacting') @{} 'All' 'WhileBusy' | Should -Be @('odd')
    }
}

Describe 'Get-SessionCount' {
    It 'counts a conversation open in two processes once' {
        $sessions = @((New-TestSession 'shared' -ProcessId 1), (New-TestSession 'shared' -ProcessId 2), (New-TestSession 'other' -ProcessId 3))
        Get-SessionCount $sessions | Should -Be 2
    }
    It 'counts nothing as zero' {
        Get-SessionCount @() | Should -Be 0
    }
}

Describe 'Update-LastBusy' {
    It 'records busy sessions and forgets gone ones' {
        $last = @{ gone = [datetime]'2026-01-01' }
        $now = [datetime]'2026-10-15T12:00:00'
        Update-LastBusy -Sessions @((New-TestSession 'b' 'busy'), (New-TestSession 'i' 'idle')) -LastBusy $last -Now $now
        $last['b'] | Should -Be $now
        $last.ContainsKey('i') | Should -BeFalse
        $last.ContainsKey('gone') | Should -BeFalse
    }
}

Describe 'Get-ExecutionStateFlags' {
    It 'requests system sleep prevention while holding' {
        Get-ExecutionStateFlags $true $false | Should -Be ([uint32]2147483649)
    }
    It 'adds the display only when asked' {
        Get-ExecutionStateFlags $true $true | Should -Be ([uint32]2147483651)
    }
    It 'clears everything when not holding' {
        Get-ExecutionStateFlags $false $true | Should -Be ([uint32]2147483648)
    }
}
