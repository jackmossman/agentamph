# Starts the tray app from this clone with no visible console window.
# Starting it again while it runs does nothing; the app keeps a single instance.

$tray = (Resolve-Path (Join-Path $PSScriptRoot '..\src\tray.ps1')).Path
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'

Start-Process -FilePath $conhost -WindowStyle Hidden -ArgumentList @(
    '--headless', "`"$powershell`"", '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-STA', '-WindowStyle', 'Hidden', '-File', "`"$tray`""
)
