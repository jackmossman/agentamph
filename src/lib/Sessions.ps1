# Discovers live Claude Code sessions from the per-session files Claude Code writes
# to <config>\sessions\<pid>.json. The format is undocumented, so every field is
# read defensively and an unreadable format falls back to listing claude.exe.

function Read-SharedText([string]$Path) {
    # Open without locking, so Claude Code can keep writing the file.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-JsonValue($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Get-ProcessStartKey([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try { $process.StartTime.ToFileTimeUtc().ToString() } catch { $null }
}

function Get-ClaudeProcessList {
    Get-Process -Name 'claude' -ErrorAction SilentlyContinue | ForEach-Object {
        $start = $null
        try { $start = $_.StartTime.ToFileTimeUtc().ToString() } catch { }
        [pscustomobject]@{ Pid = $_.Id; ProcStart = $start }
    }
}

function Get-EntrypointLabel([string]$Entrypoint) {
    switch ($Entrypoint) {
        'cli' { 'CLI' }
        'claude-vscode' { 'VS Code' }
        { [string]::IsNullOrEmpty($_) } { 'unknown' }
        default { $Entrypoint }
    }
}

# Returns a session object, or $null when the text is not a recognisable session file.
function ConvertFrom-SessionText([string]$Text) {
    try { $json = $Text | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $json -or $json -isnot [pscustomobject]) { return $null }

    $processId = Get-JsonValue $json 'pid'
    $sessionId = [string](Get-JsonValue $json 'sessionId')
    if ($null -eq $processId -or -not ($processId -as [int]) -or [string]::IsNullOrEmpty($sessionId)) { return $null }

    $cwd = [string](Get-JsonValue $json 'cwd')
    $name = [string](Get-JsonValue $json 'name')
    $folder = if ($cwd) { Split-Path -Leaf $cwd } else { '' }
    $procStart = Get-JsonValue $json 'procStart'

    [pscustomobject]@{
        Pid        = [int]$processId
        ProcStart  = if ($null -ne $procStart) { [string]$procStart } else { $null }
        SessionId  = $sessionId
        Cwd        = $cwd
        Folder     = $folder
        Name       = if ($name) { $name } else { $folder }
        Status     = [string](Get-JsonValue $json 'status')
        Entrypoint = Get-EntrypointLabel ([string](Get-JsonValue $json 'entrypoint'))
        Fallback   = $false
    }
}

function Test-SessionBusy($Session) { $Session.Status -ne 'idle' }

# Scans the sessions folder. $State carries parse-failure counts between scans, so a
# file caught mid-write is not reported as an unrecognised format.
function Get-ClaudeSessions {
    param(
        [string]$Directory = (Get-ClaudeSessionsDirectory),
        [hashtable]$State = @{},
        [scriptblock]$ReadText = { param($path) Read-SharedText $path },
        [scriptblock]$GetProcessStart = { param($id) Get-ProcessStartKey $id },
        [scriptblock]$ListClaudeProcesses = { Get-ClaudeProcessList }
    )
    if (-not $State.ContainsKey('Failures')) { $State.Failures = @{} }
    $sessions = New-Object System.Collections.ArrayList
    $unrecognised = $false
    $seen = @{}

    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $seen[$file.FullName] = $true
            $session = $null
            try { $session = ConvertFrom-SessionText (& $ReadText $file.FullName) } catch { $session = $null }
            if ($null -eq $session) {
                $State.Failures[$file.FullName] = 1 + [int]$State.Failures[$file.FullName]
                if ($State.Failures[$file.FullName] -ge 2) { $unrecognised = $true }
                continue
            }
            $State.Failures.Remove($file.FullName)
            $start = & $GetProcessStart $session.Pid
            if ($null -eq $start) { continue }
            if ($session.ProcStart -and $session.ProcStart -ne $start) { continue }
            [void]$sessions.Add($session)
        }
    }
    foreach ($path in @($State.Failures.Keys)) { if (-not $seen.ContainsKey($path)) { $State.Failures.Remove($path) } }

    if ($unrecognised) {
        $known = @{}
        foreach ($s in $sessions) { $known[$s.Pid] = $true }
        foreach ($p in @(& $ListClaudeProcesses)) {
            if ($known.ContainsKey($p.Pid)) { continue }
            [void]$sessions.Add([pscustomobject]@{
                Pid = $p.Pid; ProcStart = $p.ProcStart; SessionId = "process-$($p.Pid)-$($p.ProcStart)"
                Cwd = ''; Folder = ''; Name = "claude.exe ($($p.Pid))"; Status = 'busy'
                Entrypoint = 'unknown'; Fallback = $true
            })
        }
    }

    [pscustomobject]@{ Sessions = @($sessions); Unrecognised = $unrecognised }
}
