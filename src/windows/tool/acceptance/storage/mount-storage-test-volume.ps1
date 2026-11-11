param([Parameter(Mandatory = $true)][string]$FixtureRoot)

# Administrative fixture setup only. Never accepts a physical disk number.
# A fresh bounded VHDX is the only disk this script initializes or formats.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$dataRoot = Get-EpaLocalPath acceptance
$buildRoot = $dataRoot + '\'
$fixture = Assert-EpaPathWithin $FixtureRoot $dataRoot
if (-not $fixture.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $fixture -Leaf) -notmatch '^storage-volume-[a-f0-9]{8}$' -or
    -not (Test-Path -LiteralPath $fixture -PathType Container)) { throw 'Invalid isolated fixture directory' }
$image = Join-Path $fixture 'bounded-test-volume.vhdx'
$report = Join-Path $fixture 'mount.json'
if (Test-Path -LiteralPath $image) { throw 'Refusing an existing virtual disk' }
$hostDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fixture))
if ($hostDrive.AvailableFreeSpace -lt 1GB) { throw 'Insufficient host reserve for bounded test volume' }
$attached = $false
try {
    New-VHD -Path $image -Dynamic -SizeBytes 256MB | Out-Null
    $attachedVhd = Mount-VHD -Path $image -PassThru
    $attached = $true
    $disk = $attachedVhd | Get-Disk
    $verifiedVhd = Get-VHD -Path $image
    if ($disk.Number -ne $verifiedVhd.DiskNumber -or $disk.IsSystem -or $disk.IsBoot -or
        $disk.PartitionStyle -ne 'RAW' -or $disk.Size -ne 256MB -or
        [IO.Path]::GetFullPath($verifiedVhd.Path) -ne $image) {
        throw 'Virtual disk identity check failed; refusing initialization'
    }
    $disk | Initialize-Disk -PartitionStyle GPT -PassThru | Out-Null
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $label = 'EPA-' + (Split-Path $fixture -Leaf).Substring(15)
    $volume = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false
    if ($volume.FileSystemLabel -ne $label -or -not $volume.DriveLetter) { throw 'New fixture volume did not mount' }
    @{
        state='mounted'; virtual_disk=$image; bytes=256MB
        drive_letter=[string]$volume.DriveLetter; unique_id=$volume.UniqueId
        fixture_label=$label; disk_number=$disk.Number
        created_at_utc=(Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding utf8
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $fixture 'detach.request'))) {
        Start-Sleep -Seconds 1
    }
} catch {
    @{state='failed'; error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding utf8
    throw
} finally {
    if ($attached) {
        Dismount-VHD -Path $image
        @{state='detached'; virtual_disk=$image; at_utc=(Get-Date).ToUniversalTime().ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'detached.json') -Encoding utf8
    }
}
