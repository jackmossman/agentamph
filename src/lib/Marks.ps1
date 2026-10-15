# Critical marks: one file per session id in the marks folder. The folder is a
# contract with outside writers, so creating a file there marks a session critical.

$script:SessionIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'

function Test-SessionIdText([string]$SessionId) { $SessionId -match $script:SessionIdPattern }

function Get-CriticalMarks([string]$Directory = (Get-MarksDirectory)) {
    $marks = @{}
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue) {
            if (Test-SessionIdText $file.Name) { $marks[$file.Name] = $file.LastWriteTimeUtc }
        }
    }
    $marks
}

function Set-CriticalMark([string]$SessionId, [string]$Directory = (Get-MarksDirectory)) {
    if (-not (Test-SessionIdText $SessionId)) { throw "Not a session id: $SessionId" }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    Write-Utf8File (Join-Path $Directory $SessionId) ((Get-Date).ToUniversalTime().ToString('o') + "`n")
}

function Remove-CriticalMark([string]$SessionId, [string]$Directory = (Get-MarksDirectory)) {
    if (-not (Test-SessionIdText $SessionId)) { return }
    $path = Join-Path $Directory $SessionId
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# A process keeps its pid and start time when /clear or compaction gives it a new
# session id. $KnownByProcess maps "pid:procStart" to the last session id seen, and
# a mark on the old id moves to the new one. Returns $true when the map changed.
function Update-MarksForSessionChanges {
    param($Sessions, [hashtable]$KnownByProcess, [string]$Directory = (Get-MarksDirectory))
    $changed = $false
    $marks = Get-CriticalMarks $Directory
    foreach ($session in $Sessions) {
        if ($session.Fallback) { continue }
        $key = "$($session.Pid):$($session.ProcStart)"
        $previous = $KnownByProcess[$key]
        if ($previous -and $previous -ne $session.SessionId -and $marks.ContainsKey($previous)) {
            Set-CriticalMark $session.SessionId $Directory
            Remove-CriticalMark $previous $Directory
        }
        if ($previous -ne $session.SessionId) { $KnownByProcess[$key] = $session.SessionId; $changed = $true }
    }
    $live = @{}
    foreach ($session in $Sessions) { $live["$($session.Pid):$($session.ProcStart)"] = $true }
    foreach ($key in @($KnownByProcess.Keys)) {
        if (-not $live.ContainsKey($key)) { $KnownByProcess.Remove($key); $changed = $true }
    }
    $changed
}

function Remove-StaleMarks {
    param($LiveSessionIds, [datetime]$NowUtc = (Get-Date).ToUniversalTime(), [int]$MaxAgeDays = 30, [string]$Directory = (Get-MarksDirectory))
    $live = @{}
    foreach ($id in $LiveSessionIds) { $live[$id] = $true }
    $marks = Get-CriticalMarks $Directory
    foreach ($id in @($marks.Keys)) {
        if (-not $live.ContainsKey($id) -and ($NowUtc - $marks[$id]).TotalDays -gt $MaxAgeDays) {
            Remove-CriticalMark $id $Directory
        }
    }
}
