BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $sourceFiles = @(Get-ChildItem (Join-Path $RepoRoot 'src') -Recurse -Filter '*.ps1')
}

Describe 'privacy and safety of the source' {
    It 'names the Claude configuration folder in exactly one place' {
        $hits = @($sourceFiles | Select-String -Pattern "'\.claude'" -SimpleMatch:$false)
        $hits.Count | Should -Be 1
        $hits[0].Path | Should -Match 'Paths\.ps1$'
    }

    It 'never reads Claude transcripts, credentials or settings' {
        foreach ($word in 'projects', 'transcript', 'credentials', 'history.jsonl', 'settings.local') {
            @($sourceFiles | Select-String -Pattern $word -SimpleMatch).Count | Should -Be 0 -Because "src must not mention $word"
        }
    }

    It 'uses no networking commands or APIs outside the installer and the tests' {
        # install.ps1 downloads on purpose, and so do the VM scenarios under tests.
        $files = @(Get-ChildItem (Join-Path $RepoRoot 'src'), (Join-Path $RepoRoot 'plugin'), (Join-Path $RepoRoot 'scripts') -Recurse -File) +
            @(Get-Item (Join-Path $RepoRoot 'uninstall.ps1'))
        $files.Count | Should -BeGreaterThan 10
        foreach ($pattern in 'Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net', 'Net.WebClient', 'WebClient', 'HttpClient', 'Net.Sockets', 'Start-BitsTransfer', 'bitsadmin', 'curl', 'wget') {
            $hits = @($files | Select-String -Pattern $pattern -SimpleMatch)
            $hits.Count | Should -Be 0 -Because "no script outside the installer may use $pattern ($(($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', '))"
        }
    }

    It 'keeps every script ASCII-only, as Windows PowerShell 5.1 requires' {
        $files = @(Get-ChildItem $RepoRoot -Recurse -Include '*.ps1' | Where-Object { $_.FullName -notmatch '\\\.git\\' })
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because "$($file.Name) must be ASCII"
        }
    }

    It 'stores every text file with LF line endings, and batch files with CRLF' {
        $binary = '.png', '.gif', '.ico', '.zip'
        $files = @(Get-ChildItem $RepoRoot -Recurse -File -Force | Where-Object {
            $_.FullName.Substring($RepoRoot.Length) -notmatch '^\\(\.git|\.vs|plans|dist|tests\\vm\\results)\\' -and $_.Extension -notin $binary })
        $files.Count | Should -BeGreaterThan 30
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
            $cr = @($bytes | Where-Object { $_ -eq 13 }).Count
            if ($file.Extension -eq '.cmd') {
                $crlf = ([Text.Encoding]::ASCII.GetString($bytes) -split "`r`n").Count - 1
                ($cr -eq $lf -and $crlf -eq $lf) | Should -BeTrue -Because "$($file.Name) must use CRLF"
            } else {
                $cr | Should -Be 0 -Because "$($file.FullName.Substring($RepoRoot.Length + 1)) must use LF"
            }
        }
    }
}

Describe 'privacy of prompts in the plugin hook' {
    BeforeAll {
        $testHome = New-TestDirectory
        $notRunning = @{ AGENTAMPH_HOME = $testHome; AGENTAMPH_TRAY_MUTEX = "Local\agentamph-test-$([guid]::NewGuid().ToString('N'))" }
        $marker = 'agentamph-privacy-' + [guid]::NewGuid().ToString('N')
        $tempBefore = @(Get-ChildItem $env:TEMP -Filter 'agentamph-hook-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

        # Every place the hook or the app could keep text: the test's data folder, the
        # real data folder, the real registry key, and the hook's temporary files.
        function Find-Marker {
            $found = @()
            $folders = @($testHome, (Join-Path $env:LOCALAPPDATA 'agentamph')) | Where-Object { Test-Path -LiteralPath $_ }
            foreach ($file in @(Get-ChildItem -LiteralPath $folders -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $text = [IO.File]::ReadAllText($file.FullName)
                if ($text.Contains($marker) -or $file.Name.Contains($marker)) { $found += $file.FullName }
            }
            foreach ($file in @(Get-ChildItem $env:TEMP -Filter 'agentamph-hook-*' -ErrorAction SilentlyContinue)) {
                if ($tempBefore -notcontains $file.FullName) { $found += $file.FullName }
            }
            $key = 'HKCU:\Software\agentamph'
            if (Test-Path -LiteralPath $key) {
                foreach ($item in @(Get-Item -LiteralPath $key) + @(Get-ChildItem -LiteralPath $key -Recurse)) {
                    if ($item.PSChildName.Contains($marker)) { $found += $item.Name }
                    foreach ($name in $item.Property) {
                        if ("$name $($item.GetValue($name))".Contains($marker)) { $found += "$($item.Name)\$name" }
                    }
                }
            }
            $found
        }
    }
    AfterAll { Remove-Item $testHome -Recurse -Force }

    It 'keeps no prompt text, whether or not the prompt has the trigger phrase' {
        $prompts = @(
            "this session is critical $marker",
            "This Session Is Critical`n$marker on the second line",
            "$marker without the phrase",
            "$marker first, then this session is critical",
            "Do the work.`nthis session is critical $marker"
        )
        $i = 0
        foreach ($prompt in $prompts) {
            $i++
            (Invoke-Hook (New-HookInput "privacy-$i" $prompt) $notRunning).ExitCode | Should -Be 0
        }
        # The three prompts with the phrase on their first line marked their sessions, so
        # the hook really ran its second stage on them.
        @(Get-ChildItem (Join-Path $testHome 'critical') -File | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('privacy-1', 'privacy-2', 'privacy-4')
        Find-Marker | Should -BeNullOrEmpty
    }
}
