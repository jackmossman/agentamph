BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'critical marks' {
    BeforeEach { $dir = New-TestDirectory }
    AfterEach { Remove-Item $dir -Recurse -Force }

    It 'creates and removes a mark' {
        Set-CriticalMark 'abc-1' $dir
        (Get-CriticalMarks $dir).ContainsKey('abc-1') | Should -BeTrue
        Remove-CriticalMark 'abc-1' $dir
        (Get-CriticalMarks $dir).ContainsKey('abc-1') | Should -BeFalse
    }

    It 'accepts a mark file written by someone else' {
        Set-Content (Join-Path $dir '11111111-aaaa-4bbb-8ccc-000000000001') 'x'
        (Get-CriticalMarks $dir).ContainsKey('11111111-aaaa-4bbb-8ccc-000000000001') | Should -BeTrue
    }

    It 'ignores files whose names are not session ids' {
        Set-Content (Join-Path $dir '.hidden') 'x'
        Set-Content (Join-Path $dir 'has space') 'x'
        (Get-CriticalMarks $dir).Count | Should -Be 0
    }

    It 'refuses to write a mark outside the folder' {
        { Set-CriticalMark '..\evil' $dir } | Should -Throw
    }

    It 'moves a mark when a process gets a new session id' {
        $known = @{}
        Set-CriticalMark 'old-id' $dir
        Update-MarksForSessionChanges -Sessions @(New-TestSession 'old-id' -ProcessId 7 -ProcStart '9') -KnownByProcess $known -Directory $dir | Out-Null
        $changed = Update-MarksForSessionChanges -Sessions @(New-TestSession 'new-id' -ProcessId 7 -ProcStart '9') -KnownByProcess $known -Directory $dir
        $changed | Should -BeTrue
        $marks = Get-CriticalMarks $dir
        $marks.ContainsKey('new-id') | Should -BeTrue
        $marks.ContainsKey('old-id') | Should -BeFalse
    }

    It 'does not mark the new id when the old one was not marked' {
        $known = @{ '7:9' = 'old-id' }
        Update-MarksForSessionChanges -Sessions @(New-TestSession 'new-id' -ProcessId 7 -ProcStart '9') -KnownByProcess $known -Directory $dir | Out-Null
        (Get-CriticalMarks $dir).Count | Should -Be 0
    }

    It 'forgets processes that are gone' {
        $known = @{ '7:9' = 'old-id' }
        Update-MarksForSessionChanges -Sessions @() -KnownByProcess $known -Directory $dir | Should -BeTrue
        $known.Count | Should -Be 0
    }

    It 'keeps a mark for a session that is not running, so a resume finds it' {
        Set-CriticalMark 'resumable' $dir
        Remove-StaleMarks -LiveSessionIds @() -Directory $dir
        (Get-CriticalMarks $dir).ContainsKey('resumable') | Should -BeTrue
    }

    It 'prunes marks older than 30 days whose session is not live' {
        Set-CriticalMark 'ancient' $dir
        Set-CriticalMark 'ancient-live' $dir
        foreach ($id in 'ancient', 'ancient-live') { (Get-Item (Join-Path $dir $id)).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-31) }
        Remove-StaleMarks -LiveSessionIds @('ancient-live') -Directory $dir
        $marks = Get-CriticalMarks $dir
        $marks.ContainsKey('ancient') | Should -BeFalse
        $marks.ContainsKey('ancient-live') | Should -BeTrue
    }
}
