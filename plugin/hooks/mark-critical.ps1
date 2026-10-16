# agentamph UserPromptSubmit hook, second stage. When the first line of the prompt
# contains the trigger phrase (any case), writes the session's critical mark to
# %LOCALAPPDATA%\agentamph\critical\<sessionId>, the folder the tray app watches.
# Prints a note that Claude receives as context. Self-contained: the plugin cache
# holds only the plugin folder.

param([Parameter(Mandatory)][string]$InputPath)

$ErrorActionPreference = 'Stop'

$phrase = $env:CLAUDE_PLUGIN_OPTION_TRIGGER_PHRASE
if ([string]::IsNullOrWhiteSpace($phrase)) { $phrase = 'this session is critical' }

# The first stage copied stdin with "more", which breaks lines every 65535 bytes.
# JSON never holds a raw line break inside a string, so removing them all gives
# back exactly the input Claude Code sent.
$text = [IO.File]::ReadAllText($InputPath, [Text.Encoding]::UTF8).Replace("`r", '').Replace("`n", '')
$hookInput = $text | ConvertFrom-Json

$firstLine = ([string]$hookInput.prompt -split "`r?`n", 2)[0]
if ($firstLine.IndexOf($phrase.Trim(), [StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 0 }

$sessionId = [string]$hookInput.session_id
if ($sessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    [Console]::Error.WriteLine("agentamph: the hook input has no usable session id.")
    exit 1
}

$agentampHome = if ($env:AGENTAMPH_HOME) { $env:AGENTAMPH_HOME } else { Join-Path $env:LOCALAPPDATA 'agentamph' }
$marks = Join-Path $agentampHome 'critical'
if (-not (Test-Path -LiteralPath $marks)) { New-Item -ItemType Directory -Path $marks -Force | Out-Null }
$mark = Join-Path $marks $sessionId
[IO.File]::WriteAllText("$mark.tmp", (Get-Date).ToUniversalTime().ToString('o') + "`n", (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath "$mark.tmp" -Destination $mark -Force

# The tray app holds this mutex while it runs. The override exists for tests.
$mutexName = if ($env:AGENTAMPH_TRAY_MUTEX) { $env:AGENTAMPH_TRAY_MUTEX } else { 'Local\agentamph-tray' }
$mutex = $null
if ([System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$mutex)) {
    $mutex.Dispose()
    'agentamph: this session is now marked critical. The agentamph tray app will keep Windows awake for it according to its settings. Tell the user so in one short line.'
} else {
    'agentamph: this session is marked critical, but the agentamph tray app is not running (or not installed), so nothing is keeping Windows awake yet. The mark takes effect when the app starts. Tell the user so in one short line.'
}
