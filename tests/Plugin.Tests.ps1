BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $pluginRoot = Join-Path $RepoRoot 'plugin'
}

Describe 'plugin manifests' {
    It 'names the marketplace and plugin agentamph and points at ./plugin' {
        $marketplace = Get-Content (Join-Path $RepoRoot '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
        $marketplace.name | Should -Be 'agentamph'
        $marketplace.plugins.Count | Should -Be 1
        $marketplace.plugins[0].name | Should -Be 'agentamph'
        $marketplace.plugins[0].source | Should -Be './plugin'
    }

    It 'declares the trigger phrase option with the same default the scripts use' {
        $plugin = Get-Content (Join-Path $pluginRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        $plugin.name | Should -Be 'agentamph'
        $plugin.version | Should -Be $AgentampVersion
        $default = $plugin.userConfig.trigger_phrase.default
        $default | Should -Be 'this session is critical'
        Get-Content (Join-Path $pluginRoot 'hooks\mark-critical.cmd') -Raw | Should -Match ([regex]::Escape("set `"PHRASE=$default`""))
        Get-Content (Join-Path $pluginRoot 'hooks\mark-critical.ps1') -Raw | Should -Match ([regex]::Escape("`$phrase = '$default'"))
    }

    It 'runs the hook in exec form through cmd.exe' {
        $hooks = Get-Content (Join-Path $pluginRoot 'hooks\hooks.json') -Raw | ConvertFrom-Json
        $hook = $hooks.hooks.UserPromptSubmit[0].hooks[0]
        $hook.command | Should -Be 'cmd.exe'
        $hook.args[-1] | Should -Be '${CLAUDE_PLUGIN_ROOT}/hooks/mark-critical.cmd'
    }

    It 'stores the batch file with CRLF line endings' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $pluginRoot 'hooks\mark-critical.cmd'))
        $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
        $crlf = ([Text.Encoding]::ASCII.GetString($bytes) -split "`r`n").Count - 1
        $lf | Should -Be $crlf
    }
}

Describe 'trigger phrase hook' {
    BeforeEach {
        $testHome = New-TestDirectory
        $marks = Join-Path $testHome 'critical'
        $notRunning = @{ AGENTAMPH_HOME = $testHome; AGENTAMPH_TRAY_MUTEX = "Local\agentamph-test-$([guid]::NewGuid().ToString('N'))" }
    }
    AfterEach { Remove-Item $testHome -Recurse -Force }

    It 'marks the session when the first line holds the phrase in any case' {
        $result = Invoke-Hook (New-HookInput 'sess-1' "Please note: This Session Is Critical.`nThen do the work.") $notRunning
        $result.ExitCode | Should -Be 0
        Test-Path (Join-Path $marks 'sess-1') | Should -BeTrue
        (Get-CriticalMarks $marks).ContainsKey('sess-1') | Should -BeTrue
    }

    It 'ignores the phrase after the first line' {
        $result = Invoke-Hook (New-HookInput 'sess-2' "Do the work.`nthis session is critical") $notRunning
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Test-Path (Join-Path $marks 'sess-2') | Should -BeFalse
    }

    It 'does nothing without the phrase' {
        $result = Invoke-Hook (New-HookInput 'sess-3' 'Do the work.') $notRunning
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Test-Path $marks | Should -BeFalse
    }

    It 'uses a configured phrase instead of the default' {
        $configured = $notRunning + @{ CLAUDE_PLUGIN_OPTION_TRIGGER_PHRASE = 'keep me awake' }
        Invoke-Hook (New-HookInput 'sess-4' 'this session is critical') $configured | Out-Null
        Test-Path (Join-Path $marks 'sess-4') | Should -BeFalse
        Invoke-Hook (New-HookInput 'sess-5' 'Keep Me Awake while this runs') $configured | Out-Null
        Test-Path (Join-Path $marks 'sess-5') | Should -BeTrue
    }

    It 'handles a prompt far longer than one console line' {
        $prompt = 'this session is critical ' + ('x' * 200000) + " cafe" + [char]0xe9
        Invoke-Hook (New-HookInput 'sess-6' $prompt) $notRunning | Out-Null
        Test-Path (Join-Path $marks 'sess-6') | Should -BeTrue
    }

    It 'says when the tray app is not running' {
        $result = Invoke-Hook (New-HookInput 'sess-7' 'this session is critical') $notRunning
        $result.Output | Should -Match 'marked critical, but the agentamph tray app is not running'
        Test-Path (Join-Path $marks 'sess-7') | Should -BeTrue
    }

    It 'says the session is now critical when the tray app is running' {
        $name = "Local\agentamph-test-$([guid]::NewGuid().ToString('N'))"
        $mutex = New-Object System.Threading.Mutex($true, $name)
        try {
            $result = Invoke-Hook (New-HookInput 'sess-8' 'this session is critical') @{ AGENTAMPH_HOME = $testHome; AGENTAMPH_TRAY_MUTEX = $name }
            $result.Output | Should -Match 'now marked critical'
        } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    }

    It 'refuses a session id that could leave the marks folder' {
        $result = Invoke-Hook (New-HookInput '..\evil' 'this session is critical') $notRunning
        $result.ExitCode | Should -Be 1
        @(Get-ChildItem $testHome -Recurse -File).Count | Should -Be 0
    }

    It 'works the same without Git Bash on PATH' {
        $bare = $notRunning + @{ PATH = "$env:WINDIR\System32;$env:WINDIR" }
        Invoke-Hook (New-HookInput 'sess-9' 'this session is critical') $bare | Out-Null
        Test-Path (Join-Path $marks 'sess-9') | Should -BeTrue
        (Invoke-Hook (New-HookInput 'sess-10' 'no phrase') $bare).ExitCode | Should -Be 0
    }

    It 'leaves no temporary files behind' {
        $before = @(Get-ChildItem $env:TEMP -Filter 'agentamph-hook-*').Count
        Invoke-Hook (New-HookInput 'sess-11' 'this session is critical') $notRunning | Out-Null
        Invoke-Hook (New-HookInput 'sess-12' 'nothing') $notRunning | Out-Null
        @(Get-ChildItem $env:TEMP -Filter 'agentamph-hook-*').Count | Should -Be $before
    }

    It 'adds at most 100 ms to a prompt without the phrase (median of 20)' {
        $json = New-HookInput 'sess-13' ('An ordinary prompt. ' * 50)
        Invoke-Hook $json $notRunning | Out-Null
        $times = foreach ($i in 1..20) { (Measure-Command { Invoke-Hook $json $notRunning | Out-Null }).TotalMilliseconds }
        $median = ($times | Sort-Object)[10]
        $median | Should -BeLessOrEqual 100
    }
}
