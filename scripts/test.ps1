# Runs the Pester suite under Windows PowerShell 5.1, whatever shell calls this.
# Exits non-zero when any test fails.

$tests = (Resolve-Path (Join-Path $PSScriptRoot '..\tests')).Path
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = "Import-Module Pester -MinimumVersion 5.0; `$c = New-PesterConfiguration; `$c.Run.Path = '$tests'; `$c.Run.Exit = `$true; `$c.Output.Verbosity = 'Detailed'; Invoke-Pester -Configuration `$c"
& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
exit $LASTEXITCODE
