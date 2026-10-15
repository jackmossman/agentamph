# Locations agentamph reads and writes. Environment overrides exist so tests can
# point everything at temporary folders.

function Get-AgentampHome {
    if ($env:AGENTAMPH_HOME) { return $env:AGENTAMPH_HOME }
    Join-Path $env:LOCALAPPDATA 'agentamph'
}

# The only location under the Claude Code configuration folder that agentamph reads.
function Get-ClaudeSessionsDirectory {
    if ($env:AGENTAMPH_SESSIONS_DIR) { return $env:AGENTAMPH_SESSIONS_DIR }
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    Join-Path $root 'sessions'
}

function Get-MarksDirectory { Join-Path (Get-AgentampHome) 'critical' }
function Get-SettingsPath { Join-Path (Get-AgentampHome) 'settings.json' }
function Get-StatePath { Join-Path (Get-AgentampHome) 'state.json' }
function Get-LogPath { Join-Path (Get-AgentampHome) 'tray.log' }

function Initialize-AgentampHome {
    foreach ($dir in @((Get-AgentampHome), (Get-MarksDirectory))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

# Writes UTF-8 without a byte-order mark, with LF line endings (ConvertTo-Json in
# Windows PowerShell 5.1 emits CRLF), replacing the file in one step.
function Write-Utf8File([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
