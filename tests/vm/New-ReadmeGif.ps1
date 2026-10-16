# Makes docs\tray.gif for the README from screenshots taken in the VM: two simulated
# Claude Code sessions listed in the tray menu, one marked critical, and the icon
# changing to holding and back. agentamph is installed in the VM and driven with real
# mouse clicks on tester's desktop; the GIF is assembled here with GDI+.
#
#   powershell -ExecutionPolicy Bypass -File tests\vm\New-ReadmeGif.ps1
#
# Run elevated, under Windows PowerShell 5.1. Restores the VM's clean checkpoint first.

param([string]$OutFile = (Join-Path $PSScriptRoot '..\..\docs\tray.gif'))

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmLib.ps1')
Assert-VmPrerequisites -NeedCheckpoint

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ResultsDir = Join-Path $PSScriptRoot ("results\gif-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null

Restore-CleanVm
Invoke-Guest -ArgumentList "$($script:Exchange)\app" -ScriptBlock { param($dir) New-Item -ItemType Directory -Path $dir -Force | Out-Null }
foreach ($item in 'src', 'install.ps1', 'uninstall.ps1') { Copy-ToGuest (Join-Path $repo $item) "$($script:Exchange)\app" }

# Runs as tester. Each frame is a full-screen PNG; bounds.txt records where the icon
# and the menu were, so the host can crop every frame to the same rectangle.
$capture = (Get-TrayUiScript) + @'
$ErrorActionPreference = 'Stop'
$frames = 'C:\exchange\frames'
New-Item -ItemType Directory -Path $frames -Force | Out-Null

$script:frameNumber = 0
function Save-Frame($Menu) {
    $script:frameNumber++
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $frames ('frame{0}.png' -f $script:frameNumber)), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    foreach ($e in @(Get-TrayIcon) + @($Menu | Where-Object { $_ })) {
        $r = $e.Current.BoundingRectangle
        Add-Content -LiteralPath (Join-Path $frames 'bounds.txt') -Value ("{0},{1},{2},{3}" -f [int]$r.Left, [int]$r.Top, [int]$r.Right, [int]$r.Bottom)
    }
}

# Two simulated sessions: a session file for a long-running ping.exe each.
$sessions = Join-Path $env:USERPROFILE '.claude\sessions'
New-Item -ItemType Directory -Path $sessions -Force | Out-Null
$demo = @(
    @{ Id = '5f0c2a8e-1d4b-4c9a-9b7e-2f6d3a1c8e01'; Name = 'Refactor the billing API'; Cwd = 'C:\work\billing-api'; Status = 'busy'; Entrypoint = 'cli' },
    @{ Id = '8a3e7b14-6c2d-4f0e-a5b9-0d1e2c3f4a02'; Name = 'Update the docs site'; Cwd = 'C:\work\website'; Status = 'idle'; Entrypoint = 'claude-vscode' }
)
foreach ($s in $demo) {
    $dummy = Start-Process -FilePath ping.exe -ArgumentList '-n 3600 127.0.0.1' -WindowStyle Hidden -PassThru
    $json = [ordered]@{ pid = $dummy.Id; sessionId = $s.Id; cwd = $s.Cwd; procStart = $dummy.StartTime.ToFileTimeUtc().ToString(); name = $s.Name; status = $s.Status; entrypoint = $s.Entrypoint; updatedAt = 0 }
    [IO.File]::WriteAllText((Join-Path $sessions "$($dummy.Id).json"), ($json | ConvertTo-Json -Compress))
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\exchange\app\install.ps1'
if ($LASTEXITCODE) { throw "install failed: $LASTEXITCODE" }
Initialize-TrayUi

$menu = Open-Menu; Save-Frame $menu              # 1: sessions listed, none critical, icon idle
Switch-FirstSession                              #    mark the first session critical
$menu = Open-Menu; Save-Frame $menu              # 2: marked critical and holding, icon amber
Close-Menu; Save-Frame $null                     # 3: menu closed, icon holding
$null = Open-Menu; Switch-FirstSession           #    unmark it
$null = Open-Menu; Close-Menu                    #    (settle the menu's size again)
$menu = Open-Menu; Save-Frame $menu              # 4: unmarked, icon idle again
Close-Menu; Save-Frame $null                     # 5: menu closed, icon idle
'@

$result = Invoke-OnDesktop $capture 300
if ($result.ExitCode -ne 0) { throw "Capturing the frames failed: $($result.Output)" }
Copy-FromGuest "$($script:Exchange)\frames" $script:ResultsDir
Disconnect-Guest
$framesDir = Join-Path $script:ResultsDir 'frames'
Write-VmLog "frames saved to $framesDir"

# ---- assemble the GIF ------------------------------------------------------------

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

public static class AgentamphGif {
    // One palette for every frame: the 256 most common colours at 5 bits per channel.
    public static Color[] BuildPalette(Bitmap[] frames) {
        var counts = new Dictionary<int, int>();
        foreach (var f in frames) foreach (var px in Pixels(f)) {
            int key = ((px >> 19) & 0x1F) << 10 | ((px >> 11) & 0x1F) << 5 | ((px >> 3) & 0x1F);
            int n; counts.TryGetValue(key, out n); counts[key] = n + 1;
        }
        return counts.OrderByDescending(kv => kv.Value).Take(256).Select(kv => Color.FromArgb(
            ((kv.Key >> 10) & 0x1F) * 255 / 31, ((kv.Key >> 5) & 0x1F) * 255 / 31, (kv.Key & 0x1F) * 255 / 31)).ToArray();
    }

    static int[] Pixels(Bitmap b) {
        var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new int[b.Width * b.Height];
        for (int y = 0; y < b.Height; y++) Marshal.Copy(IntPtr.Add(d.Scan0, y * d.Stride), px, y * b.Width, b.Width);
        b.UnlockBits(d);
        return px;
    }

    // A single-frame GIF of the frame, mapped to the palette, encoded by GDI+.
    static byte[] EncodeFrame(Bitmap frame, Color[] palette, Dictionary<int, byte> cache) {
        int w = frame.Width, h = frame.Height;
        var src = Pixels(frame);
        var indexed = new Bitmap(w, h, PixelFormat.Format8bppIndexed);
        var pal = indexed.Palette;
        for (int i = 0; i < 256; i++) pal.Entries[i] = i < palette.Length ? palette[i] : Color.Black;
        indexed.Palette = pal;
        var d = indexed.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format8bppIndexed);
        var row = new byte[w];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int c = src[y * w + x] & 0xFFFFFF;
                byte best;
                if (!cache.TryGetValue(c, out best)) {
                    int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, bl = c & 0xFF, bestDist = int.MaxValue;
                    for (int i = 0; i < palette.Length; i++) {
                        int dr = palette[i].R - r, dg = palette[i].G - g, db = palette[i].B - bl;
                        int dist = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
                        if (dist < bestDist) { bestDist = dist; best = (byte)i; }
                    }
                    cache[c] = best;
                }
                row[x] = best;
            }
            Marshal.Copy(row, 0, IntPtr.Add(d.Scan0, y * d.Stride), w);
        }
        indexed.UnlockBits(d);
        using (var ms = new MemoryStream()) { indexed.Save(ms, ImageFormat.Gif); indexed.Dispose(); return ms.ToArray(); }
    }

    // Splices the single-frame GIFs into one looping GIF89a: each frame's colour table
    // becomes a local table, preceded by a control block with the frame's delay.
    public static void Write(string path, Bitmap[] frames, int[] delaysCs) {
        var palette = BuildPalette(frames);
        var cache = new Dictionary<int, byte>();
        using (var o = new FileStream(path, FileMode.Create)) {
            for (int f = 0; f < frames.Length; f++) {
                var g = EncodeFrame(frames[f], palette, cache);
                int packed = g[10];
                int tableSize = (packed & 0x80) != 0 ? 3 << ((packed & 7) + 1) : 0;
                byte[] table = new byte[tableSize];
                Array.Copy(g, 13, table, 0, tableSize);
                if (f == 0) {
                    o.Write(g, 0, 10);
                    o.WriteByte((byte)(packed & 0x70)); o.WriteByte(0); o.WriteByte(0);
                    var loop = new byte[] { 0x21, 0xFF, 0x0B, (byte)'N', (byte)'E', (byte)'T', (byte)'S', (byte)'C', (byte)'A', (byte)'P', (byte)'E', (byte)'2', (byte)'.', (byte)'0', 0x03, 0x01, 0x00, 0x00, 0x00 };
                    o.Write(loop, 0, loop.Length);
                }
                int p = 13 + tableSize;
                while (p < g.Length && g[p] != 0x3B) {
                    if (g[p] == 0x21) {
                        p += 2;
                        while (g[p] != 0) p += g[p] + 1;
                        p++;
                    } else if (g[p] == 0x2C) {
                        var gce = new byte[] { 0x21, 0xF9, 0x04, 0x00, (byte)(delaysCs[f] & 0xFF), (byte)(delaysCs[f] >> 8), 0x00, 0x00 };
                        o.Write(gce, 0, gce.Length);
                        int localPacked = g[p + 9];
                        int localSize = (localPacked & 0x80) != 0 ? 3 << ((localPacked & 7) + 1) : 0;
                        o.Write(g, p, 9);
                        if (localSize > 0) { o.WriteByte((byte)localPacked); o.Write(g, p + 10, localSize); }
                        else { o.WriteByte((byte)(0x80 | (packed & 7))); o.Write(table, 0, tableSize); }
                        p += 10 + localSize;
                        int start = p;
                        p++;
                        while (g[p] != 0) p += g[p] + 1;
                        p++;
                        o.Write(g, start, p - start);
                    } else {
                        throw new InvalidDataException("Unexpected GIF block 0x" + g[p].ToString("X2"));
                    }
                }
            }
            o.WriteByte(0x3B);
        }
    }
}
'@

# One crop for every frame: the widest menu, out to the screen's right edge and
# down through the taskbar, with a margin.
$bounds = @(Get-Content (Join-Path $framesDir 'bounds.txt') | ForEach-Object { $v = $_ -split ','; [pscustomobject]@{ L = [int]$v[0]; T = [int]$v[1]; R = [int]$v[2]; B = [int]$v[3] } })
$first = [System.Drawing.Image]::FromFile((Join-Path $framesDir 'frame1.png'))
$screenW = $first.Width; $screenH = $first.Height; $first.Dispose()
$left = [Math]::Max(0, ((($bounds | Measure-Object L -Minimum).Minimum) - 24))
$top = [Math]::Max(0, ((($bounds | Measure-Object T -Minimum).Minimum) - 24))
$crop = New-Object System.Drawing.Rectangle($left, $top, ($screenW - $left), ($screenH - $top))
Write-VmLog "screen ${screenW}x${screenH}, crop $crop"

$frames = foreach ($i in 1..5) {
    $full = [System.Drawing.Bitmap]::FromFile((Join-Path $framesDir "frame$i.png"))
    $part = $full.Clone($crop, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $full.Dispose()
    $part
}
$OutFile = [IO.Path]::GetFullPath($OutFile)
New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
# Delays in hundredths of a second, frame by frame.
[AgentamphGif]::Write($OutFile, [System.Drawing.Bitmap[]]$frames, [int[]](220, 300, 180, 220, 180))
foreach ($f in $frames) { $f.Dispose() }
Write-VmLog "wrote $OutFile ($([int]((Get-Item $OutFile).Length / 1KB)) KB)"
