# User settings, stored as JSON. Unknown or invalid values fall back to defaults.

$script:GraceChoices = @(0, 2, 5, 10)

function Get-DefaultSettings {
    [pscustomobject]@{ Selector = 'Critical'; Mode = 'UntilClosed'; GraceMinutes = 2; KeepDisplayOn = $false }
}

function Read-AgentampSettings([string]$Path = (Get-SettingsPath)) {
    $settings = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }
    try { $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $settings }
    if ($null -eq $json) { return $settings }

    $selector = Get-JsonValue $json 'Selector'
    if ($selector -in @('All', 'Critical')) { $settings.Selector = $selector }
    $mode = Get-JsonValue $json 'Mode'
    if ($mode -in @('UntilClosed', 'WhileBusy')) { $settings.Mode = $mode }
    $grace = Get-JsonValue $json 'GraceMinutes'
    if ($null -ne $grace -and ($grace -as [int]) -in $script:GraceChoices) { $settings.GraceMinutes = [int]$grace }
    $display = Get-JsonValue $json 'KeepDisplayOn'
    if ($display -is [bool]) { $settings.KeepDisplayOn = $display }
    $settings
}

function Save-AgentampSettings($Settings, [string]$Path = (Get-SettingsPath)) {
    Write-Utf8File $Path (($Settings | ConvertTo-Json) + "`n")
}
