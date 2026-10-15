# Decides which sessions hold the machine awake. Pure: no clocks, files or processes.

# Records the last time each session was seen busy. Entries for gone sessions drop out.
function Update-LastBusy {
    param($Sessions, [hashtable]$LastBusy, [datetime]$Now)
    $live = @{}
    foreach ($session in $Sessions) {
        $live[$session.SessionId] = $true
        if (Test-SessionBusy $session) { $LastBusy[$session.SessionId] = $Now }
    }
    foreach ($id in @($LastBusy.Keys)) { if (-not $live.ContainsKey($id)) { $LastBusy.Remove($id) } }
}

# Selector: 'All' or 'Critical'. Mode: 'UntilClosed' or 'WhileBusy'.
function Get-HoldingSessions {
    param($Sessions, [hashtable]$Marks, [string]$Selector, [string]$Mode, [int]$GraceMinutes, [hashtable]$LastBusy, [datetime]$Now)
    $holding = @()
    foreach ($session in $Sessions) {
        if ($Selector -eq 'Critical' -and -not $Marks.ContainsKey($session.SessionId)) { continue }
        if ($Mode -eq 'WhileBusy' -and -not (Test-SessionBusy $session)) {
            $last = $LastBusy[$session.SessionId]
            if ($null -eq $last -or ($Now - $last).TotalMinutes -gt $GraceMinutes) { continue }
        }
        $holding += $session
    }
    , $holding
}
