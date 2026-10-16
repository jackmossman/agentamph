# Builds the Hyper-V VM "agentamph-test" for the VM tests, once: applies the ISO's
# Windows 11 Pro image straight to a VHDX (no setup UI, no boot prompt), with an answer
# file that creates an administrator "amphadmin" and a standard user "tester" who signs
# in automatically, then takes the "clean" checkpoint the tests restore.
#
#   powershell -ExecutionPolicy Bypass -File tests\vm\New-VmTemplate.ps1 -Iso <Windows 11 ISO>
#
# Run elevated, under Windows PowerShell 5.1. -Replace deletes an existing VM first.

param(
    [Parameter(Mandatory)][string]$Iso,
    [string]$Root = 'D:\vm\agentamph-test',
    [string]$Edition = 'Windows 11 Pro',
    [switch]$Replace
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmLib.ps1')
Assert-VmPrerequisites
if (-not (Test-Path -LiteralPath $Iso)) { throw "No ISO at $Iso" }

$existing = Get-VM -Name $script:VmName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Replace) { throw "The VM $($script:VmName) already exists. Pass -Replace to rebuild it." }
    Write-VmLog "removing the existing VM"
    Stop-VM -Name $script:VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Get-VMSnapshot -VMName $script:VmName | Remove-VMSnapshot
    Remove-VM -Name $script:VmName -Force
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}

# The accounts' password lives on the host, outside the repository.
New-Item -ItemType Directory -Path $script:VmHome -Force | Out-Null
$password = 'Amph-' + [guid]::NewGuid().ToString('N').Substring(0, 16) + '!'
[IO.File]::WriteAllText((Join-Path $script:VmHome 'password.txt'), $password)

$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>AMPH-TEST</ComputerName>
      <TimeZone>Pacific Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$($script:AdminUser)</Name>
            <Group>Administrators</Group>
            <Password><Value>$password</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
          <LocalAccount wcm:action="add">
            <Name>$($script:DesktopUser)</Name>
            <Group>Users</Group>
            <Password><Value>$password</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$($script:DesktopUser)</Username>
        <Password><Value>$password</Value><PlainText>true</PlainText></Password>
        <LogonCount>9999999</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@

New-Item -ItemType Directory -Path $Root -Force | Out-Null
$vhd = Join-Path $Root 'disk.vhdx'
Write-VmLog 'creating the disk'
New-VHD -Path $vhd -SizeBytes 80GB -Dynamic | Out-Null
$disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
try {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $efi -FileSystem FAT32 -Force | Out-Null
    $efi | Add-PartitionAccessPath -AssignDriveLetter
    $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $os -FileSystem NTFS -Force | Out-Null
    $efiLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter
    $osLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber).DriveLetter

    $mounted = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $isoLetter = ($mounted | Get-Volume).DriveLetter
        $wim = Get-ChildItem "${isoLetter}:\sources\install.wim", "${isoLetter}:\sources\install.esd" -ErrorAction SilentlyContinue | Select-Object -First 1
        $image = Get-WindowsImage -ImagePath $wim.FullName | Where-Object { $_.ImageName -eq $Edition }
        if (-not $image) { throw "The ISO has no '$Edition' image." }
        Write-VmLog "applying $Edition (index $($image.ImageIndex))"
        Expand-WindowsImage -ImagePath $wim.FullName -Index $image.ImageIndex -ApplyPath "${osLetter}:\" | Out-Null
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }

    # The host's bcdboot: the image's own copy fails when run from the host.
    & "$env:WINDIR\System32\bcdboot.exe" "${osLetter}:\Windows" /s "${efiLetter}:" /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE" }
    New-Item -ItemType Directory -Path "${osLetter}:\Windows\Panther" -Force | Out-Null
    [IO.File]::WriteAllText("${osLetter}:\Windows\Panther\unattend.xml", $unattend)
} finally {
    Dismount-VHD -Path $vhd
}

Write-VmLog 'creating the VM'
New-VM -Name $script:VmName -Generation 2 -MemoryStartupBytes 6GB -VHDPath $vhd -SwitchName 'Default Switch' -Path $Root | Out-Null
Set-VMMemory -VMName $script:VmName -DynamicMemoryEnabled $false
Set-VMProcessor -VMName $script:VmName -Count 4
Set-VMKeyProtector -VMName $script:VmName -NewLocalKeyProtector
Enable-VMTPM -VMName $script:VmName
Enable-VMIntegrationService -VMName $script:VmName -Name 'Guest Service Interface'
Set-VM -Name $script:VmName -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Start-VM -Name $script:VmName

Write-VmLog 'waiting for setup to finish and the desktop to come up (about 10 minutes)'
Connect-Guest -Minutes 40 | Out-Null
Wait-GuestDesktop -Minutes 20
# The first sign-in shows "Almost there" for a while after Explorer starts. Restart
# once, so the checkpoint holds an ordinary sign-in, and let it settle.
Start-Sleep -Seconds 120
Restart-Guest
Initialize-GuestExchange
Start-Sleep -Seconds 60
Save-HostScreenshot (Join-Path $script:VmHome 'clean.png')
$caption = Invoke-Guest { "$((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)" }
Write-VmLog "guest: $caption"
Disconnect-Guest

Checkpoint-VM -Name $script:VmName -SnapshotName $script:CleanCheckpoint
Write-VmLog "checkpoint '$($script:CleanCheckpoint)' taken; the VM is ready for tests\vm\Invoke-VmTests.ps1"
