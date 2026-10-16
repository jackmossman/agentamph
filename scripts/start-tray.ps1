# Starts the tray app from this clone with no visible console window.
# Starting it again while it runs does nothing; the app keeps a single instance.

. (Join-Path $PSScriptRoot '..\src\lib\Startup.ps1')
Start-TrayApp (Resolve-Path (Join-Path $PSScriptRoot '..\src\tray.ps1')).Path
