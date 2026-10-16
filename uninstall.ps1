# Removes agentamph for the current user: stops the app, then removes the program
# folder, the Start Menu shortcut, the login entry, the Apps & Features entry, and
# the settings and critical marks, and puts back any Active Hours the update guard
# changed. The optional Claude Code plugin is left to
# "/plugin uninstall". Apps & Features runs this script. The parameters exist for tests.

param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\agentamph'),
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\agentamph',
    [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'agentamph')
)

$ErrorActionPreference = 'Stop'

# Installed, the libraries sit next to this script; in a clone, under src.
$lib = Join-Path $PSScriptRoot 'lib'
if (-not (Test-Path -LiteralPath $lib)) { $lib = Join-Path $PSScriptRoot 'src\lib' }
. (Join-Path $lib 'Startup.ps1')
. (Join-Path $lib 'UpdateGuard.ps1')

if (-not (Stop-TrayApp)) { throw 'agentamph is still running. Choose Exit from its tray menu, then run the uninstall again.' }

Set-StartAtLogin $false ''
# The app restores Active Hours when it exits; this covers an app that crashed while holding.
try { Restore-UpdateGuardBackup } catch { Write-Warning "Could not put back your Active Hours: $($_.Exception.Message)" }
$shortcut = Join-Path $StartMenuDir 'agentamph.lnk'
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse -Force }
if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }

if (Test-Path -LiteralPath $InstallDir) {
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())
    try { Remove-Item -LiteralPath $InstallDir -Recurse -Force } catch { }
    if (Test-Path -LiteralPath $InstallDir) {
        # A file in use (such as this script) keeps the folder; remove it once this exits.
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -WindowStyle Hidden `
            -ArgumentList "/d /c ping -n 3 127.0.0.1 >nul & rmdir /s /q `"$InstallDir`""
    }
}

Write-Host 'agentamph has been removed.'
