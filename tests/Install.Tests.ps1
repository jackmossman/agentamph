# Installs, reinstalls and uninstalls into temporary folders and a temporary registry
# key, with the tray app's mutex, data folder and sessions folder overridden, so the
# real install and any running tray app are never touched.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $id = [guid]::NewGuid().ToString('N')
    $root = New-TestDirectory
    $installDir = Join-Path $root 'Programs\agentamph'
    $startMenu = Join-Path $root 'Start Menu'
    $dataDir = Join-Path $root 'data'
    $sessionsDir = Join-Path $root 'sessions'
    New-Item -ItemType Directory -Path $sessionsDir | Out-Null
    $testKey = "HKCU:\Software\agentamph-test-$id"
    $uninstallKey = "$testKey\Uninstall\agentamph"

    $saved = @{}
    foreach ($name in 'AGENTAMPH_RUN_KEY', 'AGENTAMPH_TRAY_MUTEX', 'AGENTAMPH_HOME', 'AGENTAMPH_SESSIONS_DIR') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $env:AGENTAMPH_RUN_KEY = "$testKey\Run"
    $env:AGENTAMPH_TRAY_MUTEX = "Local\agentamph-test-$id"
    $env:AGENTAMPH_HOME = $dataDir
    $env:AGENTAMPH_SESSIONS_DIR = $sessionsDir
    # Startup.ps1 reads the overrides when loaded.
    . (Join-Path $RepoRoot 'src\lib\Startup.ps1')

    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Invoke-Install([switch]$NoStart) {
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'install.ps1'),
            '-Source', $RepoRoot, '-InstallDir', $installDir, '-StartMenuDir', $startMenu, '-UninstallKey', $uninstallKey)
        if ($NoStart) { $arguments += '-NoStart' }
        & $powershell @arguments | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    function Invoke-Uninstall {
        & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $installDir 'uninstall.ps1') `
            -InstallDir $installDir -StartMenuDir $startMenu -UninstallKey $uninstallKey -DataDir $dataDir | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    function Get-TestTrayProcesses {
        $tray = Join-Path $installDir 'tray.ps1'
        # The comma keeps a single process an array, so [0] and Count work.
        , @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tray) })
    }
    function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
        [bool](& $Condition)
    }
}

AfterAll {
    foreach ($process in (Get-TestTrayProcesses)) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $testKey) { Remove-Item $testKey -Recurse -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}

Describe 'start at login' {
    It 'writes, reads and removes the Run value' {
        $tray = 'C:\Program Files Test\agentamph\tray.ps1'
        Set-StartAtLogin $true $tray
        Test-StartAtLogin | Should -BeTrue
        (Get-ItemProperty $env:AGENTAMPH_RUN_KEY).agentamph | Should -Be (Get-LaunchCommand $tray)
        Set-StartAtLogin $false ''
        Test-StartAtLogin | Should -BeFalse
    }

    It 'launches through a headless console so no window appears' {
        $command = Get-LaunchCommand 'C:\x\tray.ps1'
        $command | Should -Match '^"[^"]+\\conhost\.exe" --headless "[^"]+\\powershell\.exe" '
        $command | Should -Match '-WindowStyle Hidden -File "C:\\x\\tray\.ps1"$'
    }
}

Describe 'install, reinstall and uninstall' {
    It 'installs the app, shortcut, Apps & Features entry and login value' {
        Invoke-Install -NoStart
        $tray = Join-Path $installDir 'tray.ps1'
        foreach ($file in 'tray.ps1', 'lib\Startup.ps1', 'lib\Sessions.ps1', 'uninstall.ps1', 'agentamph.ico') {
            Test-Path (Join-Path $installDir $file) | Should -BeTrue -Because "$file is installed"
        }

        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startMenu 'agentamph.lnk'))
        $shortcut.TargetPath | Should -BeLike '*\conhost.exe'
        $shortcut.Arguments | Should -Be (Get-LaunchArguments $tray)

        $entry = Get-ItemProperty $uninstallKey
        $entry.DisplayName | Should -Be 'agentamph'
        $entry.DisplayVersion | Should -Be $AgentampVersion
        $entry.UninstallString | Should -BeLike "*-File `"$installDir\uninstall.ps1`""
        $entry.NoModify | Should -Be 1

        (Get-ItemProperty $env:AGENTAMPH_RUN_KEY).agentamph | Should -Be (Get-LaunchCommand $tray)
    }

    It 'writes an icon file Windows can read' {
        $icon = New-Object System.Drawing.Icon((Join-Path $installDir 'agentamph.ico'), 32, 32)
        $icon.Width | Should -Be 32
        $icon.Dispose()
    }

    It 'replaces a running app on reinstall and keeps settings and marks' {
        Start-TrayApp (Join-Path $installDir 'tray.ps1')
        Wait-Until { Test-TrayRunning } | Should -BeTrue
        $first = (Get-TestTrayProcesses)[0].ProcessId
        Set-CriticalMark 'kept-mark' (Join-Path $dataDir 'critical')
        Test-Path (Join-Path $dataDir 'settings.json') | Should -BeFalse -Because 'the app writes settings only when changed'
        Save-AgentampSettings ([pscustomobject]@{ Selector = 'All'; Mode = 'WhileBusy'; GraceMinutes = 5; KeepDisplayOn = $true }) (Join-Path $dataDir 'settings.json')

        Invoke-Install
        Wait-Until { (Get-TestTrayProcesses).Count -eq 1 -and (Get-TestTrayProcesses)[0].ProcessId -ne $first } | Should -BeTrue
        (Get-TestTrayProcesses).Count | Should -Be 1
        (Get-CriticalMarks (Join-Path $dataDir 'critical')).ContainsKey('kept-mark') | Should -BeTrue
        (Read-AgentampSettings (Join-Path $dataDir 'settings.json')).Selector | Should -Be 'All'
    }

    It 'keeps start at login off when the user turned it off' {
        Set-StartAtLogin $false ''
        Invoke-Install -NoStart
        Test-StartAtLogin | Should -BeFalse
        Set-StartAtLogin $true (Join-Path $installDir 'tray.ps1')
    }

    It 'stops the app and removes everything on uninstall' {
        Start-TrayApp (Join-Path $installDir 'tray.ps1')
        Wait-Until { Test-TrayRunning } | Should -BeTrue
        Invoke-Uninstall
        Test-TrayRunning | Should -BeFalse
        (Get-TestTrayProcesses).Count | Should -Be 0
        Test-Path (Join-Path $startMenu 'agentamph.lnk') | Should -BeFalse
        Test-Path $uninstallKey | Should -BeFalse
        Test-StartAtLogin | Should -BeFalse
        Test-Path $dataDir | Should -BeFalse
        Wait-Until { -not (Test-Path $installDir) } 10 | Should -BeTrue
    }

    It 'installs from the release zip by following INSTALL.txt' {
        $zip = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\build-release.ps1') -OutDir (Join-Path $root 'dist')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        $entries = @($archive.Entries | ForEach-Object { $_.FullName })
        $archive.Dispose()
        $entries | Should -Contain "agentamph-$AgentampVersion/install.ps1"
        $entries | Should -Contain "agentamph-$AgentampVersion/src/lib/Startup.ps1"
        @($entries | Where-Object { $_.Contains('\') }).Count | Should -Be 0

        # Extract, mark the files as downloaded from the internet, then follow the steps.
        $extracted = Join-Path $root 'extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extracted)
        $folder = Join-Path $extracted "agentamph-$AgentampVersion"
        Get-ChildItem $folder -Recurse -File | ForEach-Object { Set-Content -LiteralPath $_.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" }
        Get-Content (Join-Path $folder 'INSTALL.txt') -Raw | Should -Match 'Unblock-File'
        Get-ChildItem $folder -Recurse | Unblock-File
        & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $folder 'install.ps1') `
            -InstallDir $installDir -StartMenuDir $startMenu -UninstallKey $uninstallKey -NoStart | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-ItemProperty $uninstallKey).DisplayVersion | Should -Be $AgentampVersion
        Test-Path (Join-Path $installDir 'tray.ps1') | Should -BeTrue
        Invoke-Uninstall
        Wait-Until { -not (Test-Path $installDir) } 10 | Should -BeTrue
    }
}
