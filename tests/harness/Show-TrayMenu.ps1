# Review aid, not a test: loads the tray app in harness mode against the real
# session folder, opens its menu and saves screenshots of the menu and the icons.
# Run under Windows PowerShell 5.1: powershell.exe -STA -File Show-TrayMenu.ps1 -OutDir <dir>

param([Parameter(Mandatory)][string]$OutDir)

$env:AGENTAMPH_HARNESS = '1'
. (Join-Path $PSScriptRoot '..\..\src\tray.ps1')
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

foreach ($case in @(@{ Name = 'icon-idle'; Holding = $false; Count = 0 }, @{ Name = 'icon-1'; Holding = $true; Count = 1 }, @{ Name = 'icon-3'; Holding = $true; Count = 3 }, @{ Name = 'icon-12'; Holding = $true; Count = 12 })) {
    foreach ($size in 16, 32) {
        $handle = New-AgentampIconHandle $case.Holding $case.Count $size
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        $big = New-Object System.Drawing.Bitmap(128, 128)
        $g = [System.Drawing.Graphics]::FromImage($big)
        $g.Clear([System.Drawing.Color]::FromArgb(255, 32, 32, 32))
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.DrawImage($icon.ToBitmap(), 0, 0, 128, 128)
        $big.Save((Join-Path $OutDir "$($case.Name)-$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $big.Dispose(); $icon.Dispose(); Remove-IconHandle $handle
    }
}

Invoke-Refresh $true
Update-Menu
$point = New-Object System.Drawing.Point(200, 200)
$script:menu.Show($point)
foreach ($i in 1..10) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
$bounds = $script:menu.Bounds
$shot = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($shot)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$shot.Save((Join-Path $OutDir 'menu.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $shot.Dispose()

# Open each submenu in turn.
foreach ($name in 'Sessions', 'Keep awake', 'Grace period (While busy)') {
    $item = $script:menu.Items | Where-Object { $_.Text -eq $name }
    $item.ShowDropDown()
    foreach ($i in 1..6) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $b = [System.Drawing.Rectangle]::Union($script:menu.Bounds, $item.DropDown.Bounds)
    $shot = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $shot.Save((Join-Path $OutDir ("menu-" + ($name -replace '[^A-Za-z]', '') + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $shot.Dispose()
    $item.HideDropDown()
}
$script:menu.Close()
Set-KeepAwake $false $false
"holding: $(@($script:holding).Count); sessions: $(@($script:sessions).Count); unrecognised: $script:unrecognised"
