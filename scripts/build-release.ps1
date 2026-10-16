# Builds the release zip: agentamph-<version>.zip holding one folder with
# install.ps1, uninstall.ps1, the app under src\, and INSTALL.txt.

param([string]$OutDir = (Join-Path $PSScriptRoot '..\dist'))

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repo 'src\lib\Startup.ps1')
$name = "agentamph-$($script:AgentampVersion)"

$stage = Join-Path ([IO.Path]::GetTempPath()) ("agentamph-build-" + [guid]::NewGuid().ToString('N'))
$folder = Join-Path $stage $name
New-Item -ItemType Directory -Path $folder -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repo 'src') -Destination $folder -Recurse
    foreach ($file in 'install.ps1', 'uninstall.ps1') { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $folder }
    $instructions = @"
agentamph $($script:AgentampVersion)
Keeps Windows awake for the Claude Code sessions you choose.

To install, for the current user and with no administrator rights:

1. Extract this zip to any folder.
2. Open PowerShell in the extracted folder (the one holding install.ps1).
3. Windows marks downloaded files as unsafe. Unblock them:

     Get-ChildItem -Recurse | Unblock-File

   (Or, before extracting, right-click the zip, choose Properties, tick Unblock
   and press OK.)
4. Run the installer:

     powershell -ExecutionPolicy Bypass -File .\install.ps1

agentamph then appears in the notification area, in the Start Menu, and in
Settings > Apps > Installed apps, where you can uninstall it. You can delete the
extracted folder afterwards.
"@
    [IO.File]::WriteAllText((Join-Path $folder 'INSTALL.txt'), $instructions.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object Text.ASCIIEncoding))

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $zip = Join-Path (Resolve-Path $OutDir).Path "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    # Compress-Archive in Windows PowerShell 5.1 writes backslashes into entry names,
    # which the zip format does not allow, so the entries are written here.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File) {
            $entry = $name + '/' + $file.FullName.Substring($folder.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry)
        }
    } finally { $archive.Dispose() }
    $zip
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
