# Tray icons drawn at runtime: a grey capsule outline when idle, and a filled amber
# capsule with the holding count when holding. No binary assets.

Add-Type -AssemblyName System.Drawing

if (-not ('Agentamph.IconNative' -as [type])) {
    Add-Type -Namespace Agentamph -Name IconNative -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
}

function New-CapsulePath([System.Drawing.RectangleF]$Rect) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Rect.Height
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 90, 180)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 180)
    $path.CloseFigure()
    $path
}

function Get-CountText([int]$Count) { if ($Count -gt 9) { '9+' } else { [string]$Count } }

# Returns a handle to a new icon. The caller owns it and frees it with Remove-IconHandle.
function New-AgentampIconHandle([bool]$Holding, [int]$Count, [int]$Size = 16) {
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        if ($Holding) {
            $rect = New-Object System.Drawing.RectangleF(0.5, ($Size * 0.12), ($Size - 1), ($Size * 0.76))
            $path = New-CapsulePath $rect
            $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 176, 0))
            $g.FillPath($fill, $path)
            $text = Get-CountText $Count
            $fontSize = if ($text.Length -gt 1) { $Size * 0.5 } else { $Size * 0.62 }
            $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $format = New-Object System.Drawing.StringFormat
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString($text, $font, [System.Drawing.Brushes]::Black, $rect, $format)
            $font.Dispose(); $fill.Dispose(); $path.Dispose(); $format.Dispose()
        } else {
            $rect = New-Object System.Drawing.RectangleF(1, ($Size * 0.25), ($Size - 2), ($Size * 0.5))
            $path = New-CapsulePath $rect
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 150, 150, 150), [Math]::Max(1.0, $Size / 12.0))
            $g.DrawPath($pen, $path)
            $mid = $rect.X + $rect.Width / 2
            $g.DrawLine($pen, $mid, $rect.Y, $mid, $rect.Bottom)
            $pen.Dispose(); $path.Dispose()
        }
        $bitmap.GetHicon()
    } finally {
        $g.Dispose(); $bitmap.Dispose()
    }
}

function Remove-IconHandle([IntPtr]$Handle) {
    if ($Handle -ne [IntPtr]::Zero) { [void][Agentamph.IconNative]::DestroyIcon($Handle) }
}
