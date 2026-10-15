BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'ConvertFrom-SessionText' {
    It 'reads a CLI session file' {
        $s = ConvertFrom-SessionText (Get-Content (Join-Path $FixtureSessions 'cli-busy.json') -Raw)
        $s.Pid | Should -Be 1111
        $s.SessionId | Should -Be '11111111-aaaa-4bbb-8ccc-000000000001'
        $s.Name | Should -Be 'alpha-a0'
        $s.Folder | Should -Be 'alpha'
        $s.Status | Should -Be 'busy'
        $s.Entrypoint | Should -Be 'CLI'
        $s.ProcStart | Should -Be '134365700000000001'
    }

    It 'labels a VS Code session' {
        $s = ConvertFrom-SessionText (Get-Content (Join-Path $FixtureSessions 'vscode-idle.json') -Raw)
        $s.Entrypoint | Should -Be 'VS Code'
        $s.Status | Should -Be 'idle'
    }

    It 'rejects text that is not a session' {
        ConvertFrom-SessionText '{"pid":12' | Should -BeNullOrEmpty
        ConvertFrom-SessionText '{"sessionId":"x"}' | Should -BeNullOrEmpty
        ConvertFrom-SessionText '{"pid":"abc","sessionId":"x"}' | Should -BeNullOrEmpty
        ConvertFrom-SessionText '[1,2]' | Should -BeNullOrEmpty
    }

    It 'falls back to the folder when there is no name' {
        $s = ConvertFrom-SessionText '{"pid":5,"sessionId":"s5","cwd":"C:\\x\\gamma"}'
        $s.Name | Should -Be 'gamma'
        $s.Entrypoint | Should -Be 'unknown'
    }
}

Describe 'Test-SessionBusy' {
    It 'treats anything but idle as busy' {
        Test-SessionBusy (New-TestSession 'a' 'busy') | Should -BeTrue
        Test-SessionBusy (New-TestSession 'a' 'thinking') | Should -BeTrue
        Test-SessionBusy (New-TestSession 'a' '') | Should -BeTrue
        Test-SessionBusy (New-TestSession 'a' 'idle') | Should -BeFalse
    }
}

Describe 'Get-ClaudeSessions' {
    BeforeEach {
        $dir = New-TestDirectory
        Copy-Item (Join-Path $FixtureSessions '*.json') $dir
        $noClaude = { @() }
    }
    AfterEach { Remove-Item $dir -Recurse -Force }

    It 'lists live sessions from the folder' {
        $r = Get-ClaudeSessions -Directory $dir -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude
        @($r.Sessions).Count | Should -Be 2
        $r.Unrecognised | Should -BeFalse
    }

    It 'ignores a file whose process is gone' {
        $starts = @{ 2222 = '134365700000000002' }
        $r = Get-ClaudeSessions -Directory $dir -GetProcessStart { param($id) $starts[[int]$id] } -ListClaudeProcesses $noClaude
        @($r.Sessions).SessionId | Should -Be @('22222222-aaaa-4bbb-8ccc-000000000002')
    }

    It 'ignores a file whose pid now belongs to another process' {
        $starts = @{ 1111 = '999'; 2222 = '134365700000000002' }
        $r = Get-ClaudeSessions -Directory $dir -GetProcessStart { param($id) $starts[[int]$id] } -ListClaudeProcesses $noClaude
        @($r.Sessions).Count | Should -Be 1
    }

    It 'never deletes stale files' {
        Get-ClaudeSessions -Directory $dir -GetProcessStart { param($id) $null } -ListClaudeProcesses $noClaude | Out-Null
        @(Get-ChildItem $dir -Filter '*.json').Count | Should -Be 2
    }

    It 'does not report a file caught mid-write once' {
        Set-Content (Join-Path $dir '3333.json') '{"pid":33' -NoNewline
        $state = @{}
        $r = Get-ClaudeSessions -Directory $dir -State $state -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude
        $r.Unrecognised | Should -BeFalse
    }

    It 'reports an unrecognised format and falls back to claude.exe processes' {
        Set-Content (Join-Path $dir '3333.json') '{"process":33,"id":"x"}' -NoNewline
        $state = @{}
        $list = { @([pscustomobject]@{ Pid = 1111; ProcStart = '134365700000000001' }, [pscustomobject]@{ Pid = 4444; ProcStart = '7' }) }
        Get-ClaudeSessions -Directory $dir -State $state -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $list | Out-Null
        $r = Get-ClaudeSessions -Directory $dir -State $state -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $list
        $r.Unrecognised | Should -BeTrue
        $fallback = @($r.Sessions | Where-Object Fallback)
        $fallback.Count | Should -Be 1
        $fallback[0].Pid | Should -Be 4444
        Test-SessionBusy $fallback[0] | Should -BeTrue
    }

    It 'clears the warning once the bad file is gone' {
        Set-Content (Join-Path $dir '3333.json') 'nonsense' -NoNewline
        $state = @{}
        1..2 | ForEach-Object { Get-ClaudeSessions -Directory $dir -State $state -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude | Out-Null }
        Remove-Item (Join-Path $dir '3333.json')
        (Get-ClaudeSessions -Directory $dir -State $state -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude).Unrecognised | Should -BeFalse
    }

    It 'returns nothing when the folder does not exist' {
        $r = Get-ClaudeSessions -Directory (Join-Path $dir 'missing') -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude
        @($r.Sessions).Count | Should -Be 0
        $r.Unrecognised | Should -BeFalse
    }

    It 'reads only the json files directly in the sessions folder' {
        New-Item -ItemType Directory (Join-Path $dir 'nested') | Out-Null
        Set-Content (Join-Path $dir 'nested\5555.json') '{}'
        Set-Content (Join-Path $dir '1111.abc.key') 'secret'
        $read = New-Object System.Collections.ArrayList
        $reader = { param($path) [void]$read.Add($path); Read-SharedText $path }.GetNewClosure()
        Get-ClaudeSessions -Directory $dir -ReadText $reader -GetProcessStart $FixtureGetProcessStart -ListClaudeProcesses $noClaude | Out-Null
        @($read).Count | Should -Be 2
        foreach ($path in $read) {
            Split-Path -Parent $path | Should -Be $dir
            $path | Should -Match '\.json$'
        }
    }
}
