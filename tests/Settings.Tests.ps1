BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'settings' {
    BeforeEach { $dir = New-TestDirectory; $path = Join-Path $dir 'settings.json' }
    AfterEach { Remove-Item $dir -Recurse -Force }

    It 'defaults to Critical, Until closed, 2 minutes, display off' {
        $s = Read-AgentampSettings $path
        $s.Selector | Should -Be 'Critical'
        $s.Mode | Should -Be 'UntilClosed'
        $s.GraceMinutes | Should -Be 2
        $s.KeepDisplayOn | Should -BeFalse
    }

    It 'round-trips every setting' {
        Save-AgentampSettings ([pscustomobject]@{ Selector = 'All'; Mode = 'WhileBusy'; GraceMinutes = 10; KeepDisplayOn = $true }) $path
        $s = Read-AgentampSettings $path
        $s.Selector | Should -Be 'All'
        $s.Mode | Should -Be 'WhileBusy'
        $s.GraceMinutes | Should -Be 10
        $s.KeepDisplayOn | Should -BeTrue
    }

    It 'replaces invalid values with defaults' {
        Set-Content $path '{"Selector":"Some","Mode":"Forever","GraceMinutes":7,"KeepDisplayOn":"yes"}'
        $s = Read-AgentampSettings $path
        $s.Selector | Should -Be 'Critical'
        $s.Mode | Should -Be 'UntilClosed'
        $s.GraceMinutes | Should -Be 2
        $s.KeepDisplayOn | Should -BeFalse
    }

    It 'survives a corrupt file' {
        Set-Content $path 'not json'
        (Read-AgentampSettings $path).Selector | Should -Be 'Critical'
    }

    It 'writes LF-only UTF-8 without a byte-order mark' {
        Save-AgentampSettings (Get-DefaultSettings) $path
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes -contains 13 | Should -BeFalse
        $bytes[0] | Should -Not -Be 0xEF
    }
}
