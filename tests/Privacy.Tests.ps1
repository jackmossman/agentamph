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

    It 'uses no networking commands or APIs' {
        foreach ($pattern in 'Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net', 'Start-BitsTransfer', 'curl', 'wget', 'WebClient') {
            @($sourceFiles | Select-String -Pattern $pattern -SimpleMatch).Count | Should -Be 0 -Because "src must not use $pattern"
        }
    }

    It 'keeps every script ASCII-only, as Windows PowerShell 5.1 requires' {
        $files = @(Get-ChildItem $RepoRoot -Recurse -Include '*.ps1' | Where-Object { $_.FullName -notmatch '\\\.git\\' })
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because "$($file.Name) must be ASCII"
        }
    }

    It 'stores every text file with LF line endings' {
        $files = @(Get-ChildItem $RepoRoot -Recurse -File -Include '*.ps1', '*.json', '*.md' | Where-Object { $_.FullName -notmatch '\\(\.git|plans)\\' })
        foreach ($file in $files) {
            [IO.File]::ReadAllBytes($file.FullName) -contains 13 | Should -BeFalse -Because "$($file.Name) must use LF"
        }
    }
}
