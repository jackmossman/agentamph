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
