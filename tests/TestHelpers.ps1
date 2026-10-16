# Loads the tray app's libraries (not the UI) for tests.

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:FixtureSessions = Join-Path $PSScriptRoot 'fixtures\sessions'
foreach ($lib in 'Paths', 'Sessions', 'Marks', 'Hold', 'Settings', 'Power', 'Icons', 'Startup', 'UpdateGuard') {
    . (Join-Path $script:RepoRoot "src\lib\$lib.ps1")
}

function New-TestDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("agentamph-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}

function New-TestSession([string]$Id, [string]$Status = 'busy', [int]$ProcessId = 100, [string]$ProcStart = '1') {
    [pscustomobject]@{
        Pid = $ProcessId; ProcStart = $ProcStart; SessionId = $Id; Cwd = "C:\work\$Id"; Folder = $Id
        Name = $Id; Status = $Status; Entrypoint = 'CLI'; Fallback = $false
    }
}

# Process lookups for the fixture sessions: pid 1111 and 2222 are "running" with the
# start times recorded in their files.
$script:FixtureProcessStarts = @{ 1111 = '134365700000000001'; 2222 = '134365700000000002' }
$script:FixtureGetProcessStart = { param($id) $script:FixtureProcessStarts[[int]$id] }

# Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} with forward slashes on Windows.
$script:HookScript = (Join-Path $script:RepoRoot 'plugin\hooks\mark-critical.cmd').Replace('\', '/')

# Runs the plugin hook the way its exec-form entry does: cmd.exe /d /c <script>, with
# the hook input on stdin. $Environment adds or replaces variables for the child.
function Invoke-Hook([string]$Json, [hashtable]$Environment = @{}) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
    $info.Arguments = "/d /c $script:HookScript"
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = $Environment[$name] }
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Write($Json)
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $out; Error = $err }
}

function New-HookInput([string]$SessionId, [string]$Prompt) {
    @{ session_id = $SessionId; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt } | ConvertTo-Json -Compress
}
