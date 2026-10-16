# Installs agentamph for the current user, with no administrator rights.
#
#   One line, from the public repository:
#     irm https://raw.githubusercontent.com/jackmossman/agentamph/main/install.ps1 | iex
#   From a release zip, after extracting it:
#     powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Run from a folder that holds the app (a clone or an extracted release zip), it
# installs that copy. Run any other way, it downloads the latest tagged release, or
# main while no release exists. Reinstalling replaces the running app and keeps
# settings and critical marks. The parameters exist for tests.

param(
    [string]$Source,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\agentamph'),
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\agentamph',
    [switch]$NoStart
)

function Get-AgentampDownload {
    $repo = 'jackmossman/agentamph'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $ref = 'refs/heads/main'
    try {
        $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repo/releases/latest"
        $ref = "refs/tags/$($release.tag_name)"
    } catch {
        # Only "no release yet" falls back to main. Any other failure stops the
        # install, so an outage never installs main's working state over a release.
        $response = $_.Exception.Response
        if (-not $response -or [int]$response.StatusCode -ne 404) { throw "Could not ask GitHub for the latest release: $($_.Exception.Message)" }
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('agentamph-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'agentamph.zip'
    Write-Host "Downloading agentamph ($ref)"
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/$ref.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $work
    $root = Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1
    if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName 'src\tray.ps1'))) { throw 'The download does not contain the agentamph app.' }
    $root.FullName
}

function Install-Agentamph {
    param([string]$Source, [string]$InstallDir, [string]$StartMenuDir, [string]$UninstallKey, [bool]$NoStart, [string]$ScriptRoot)
    $ErrorActionPreference = 'Stop'

    $download = $null
    if (-not $Source) {
        if ($ScriptRoot -and (Test-Path -LiteralPath (Join-Path $ScriptRoot 'src\tray.ps1'))) { $Source = $ScriptRoot }
        else { $Source = Get-AgentampDownload; $download = Split-Path -Parent $Source }
    }
    try {
        $sourceApp = Join-Path $Source 'src'
        . (Join-Path $sourceApp 'lib\Startup.ps1')
        . (Join-Path $sourceApp 'lib\Icons.ps1')

        $firstInstall = -not (Test-Path -LiteralPath $UninstallKey)
        if (-not (Stop-TrayApp)) { throw 'agentamph is still running. Choose Exit from its tray menu, then run the install again.' }

        # Replace the program files. Settings and marks live elsewhere and are untouched.
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Copy-Item -Path (Join-Path $sourceApp '*') -Destination $InstallDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $Source 'uninstall.ps1') -Destination $InstallDir -Force
        Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Unblock-File
        $icon = Join-Path $InstallDir 'agentamph.ico'
        Save-AgentampIconFile $icon
        $tray = Join-Path $InstallDir 'tray.ps1'

        if (-not (Test-Path -LiteralPath $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path $StartMenuDir 'agentamph.lnk'))
        $shortcut.TargetPath = Get-ConhostPath
        $shortcut.Arguments = Get-LaunchArguments $tray
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.IconLocation = "$icon,0"
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Keep Windows awake for the Claude Code sessions you choose'
        $shortcut.Save()

        $uninstall = Join-Path $InstallDir 'uninstall.ps1'
        $size = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
        New-Item -Path $UninstallKey -Force | Out-Null
        $values = [ordered]@{
            DisplayName     = 'agentamph'
            DisplayVersion  = $script:AgentampVersion
            Publisher       = 'Jack Mossman'
            DisplayIcon     = $icon
            InstallLocation = $InstallDir
            URLInfoAbout    = 'https://github.com/jackmossman/agentamph'
            UninstallString = "`"$(Get-PowerShellPath)`" -NoProfile -ExecutionPolicy Bypass -File `"$uninstall`""
        }
        foreach ($name in $values.Keys) { Set-ItemProperty -LiteralPath $UninstallKey -Name $name -Value $values[$name] -Type String }
        foreach ($name in 'NoModify', 'NoRepair') { Set-ItemProperty -LiteralPath $UninstallKey -Name $name -Value 1 -Type DWord }
        Set-ItemProperty -LiteralPath $UninstallKey -Name 'EstimatedSize' -Value $size -Type DWord

        # A first install turns on start at login. A reinstall keeps the user's choice,
        # pointing an existing value at the new copy.
        if ($firstInstall -or (Test-StartAtLogin)) { Set-StartAtLogin $true $tray }

        if (-not $NoStart) { Start-TrayApp $tray }
        Write-Host "agentamph $($script:AgentampVersion) is installed in $InstallDir and running in the notification area."
    } finally {
        # The one-line install's download is only needed until the copy is made.
        if ($download -and (Test-Path -LiteralPath $download)) { Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Install-Agentamph -Source $Source -InstallDir $InstallDir -StartMenuDir $StartMenuDir -UninstallKey $UninstallKey -NoStart $NoStart.IsPresent -ScriptRoot $PSScriptRoot
