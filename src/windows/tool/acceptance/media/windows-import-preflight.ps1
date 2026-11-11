param(
    [string]$OutputRoot
)

# Isolated capability experiment only. Does not import user media or change
# production identity, hashing, scheduling or source-handling policy.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
if (-not $OutputRoot) { $OutputRoot = Get-EpaLocalPath acceptance 'import-preflight' }
$OutputRoot = Assert-EpaPathWithin $OutputRoot (Get-EpaLocalPath acceptance)
$runPath = Join-Path $OutputRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runPath)

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ImportIdentityPreflight {
    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo {
        public UInt64 Volume;
        public UInt64 Low;
        public UInt64 High;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle handle, int infoClass, out FileIdInfo info, uint size);

    public static string ReadIdentity(string path) {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read,
                                        FileShare.Read)) {
            FileIdInfo id;
            if (!GetFileInformationByHandleEx(file.SafeFileHandle, 18, out id,
                                              (uint)Marshal.SizeOf<FileIdInfo>()))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return id.Volume.ToString("x16") + ":" + id.High.ToString("x16")
                   + id.Low.ToString("x16");
        }
    }
}
'@

$results = [Collections.Generic.List[object]]::new()
function Record-Check([string]$Name, [bool]$Passed) {
    $results.Add([ordered]@{name=$Name;passed=$Passed})
    if (-not $Passed) { throw "Preflight failed: $Name" }
}

$originalPath = Join-Path $runPath 'artificial-original.bin'
$renamedPath = Join-Path $runPath 'artificial-renamed.bin'
$copiedPath = Join-Path $runPath 'artificial-copy.bin'
$bytes = [byte[]]::new(4 * 1024 * 1024)
[Random]::new(12345).NextBytes($bytes)
[IO.File]::WriteAllBytes($originalPath,$bytes)
$before = [ImportIdentityPreflight]::ReadIdentity($originalPath)
[IO.File]::Move($originalPath,$renamedPath)
$renamed = [ImportIdentityPreflight]::ReadIdentity($renamedPath)
Record-Check 'native identity survives same-volume rename' ($before -eq $renamed)

[IO.File]::Copy($renamedPath,$copiedPath)
$copied = [ImportIdentityPreflight]::ReadIdentity($copiedPath)
Record-Check 'independent byte-identical copy has a different native identity' ($copied -ne $renamed)

$writer = [IO.FileStream]::new($renamedPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {
    $readRefused = $false
    try {
        $unexpectedReader = [IO.FileStream]::new($renamedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $unexpectedReader.Dispose()
    } catch [IO.IOException] { $readRefused = $true }
    Record-Check 'read-only shared snapshot refuses an existing writer' $readRefused
} finally { $writer.Dispose() }

$reader = [IO.FileStream]::new($renamedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $writeRefused = $false
    try {
        $unexpectedWriter = [IO.FileStream]::new($renamedPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        $unexpectedWriter.Dispose()
    } catch [IO.IOException] { $writeRefused = $true }
    Record-Check 'snapshot handle refuses a new writer' $writeRefused
    $moveRefused = $false
    try { [IO.File]::Move($renamedPath,(Join-Path $runPath 'blocked-move.bin')) }
    catch [IO.IOException] { $moveRefused = $true }
    Record-Check 'snapshot handle refuses a concurrent move' $moveRefused
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reader))
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    Record-Check 'full read matches the artificial source bytes' ($actualHash -eq $expectedHash)
} finally { $reader.Dispose() }

$finalPath = Join-Path $runPath 'artificial-final.bin'
[IO.File]::Move($renamedPath,$finalPath)
Record-Check 'closing the snapshot releases move protection' ([IO.File]::Exists($finalPath))
Record-Check 'source bytes are unchanged after all checks' ((Get-FileHash -Algorithm SHA256 -LiteralPath $finalPath).Hash -eq $expectedHash)

$report = [ordered]@{
    date='2026-11-10'
    kind='isolated Windows capability experiment; not approved production implementation'
    directory=$runPath
    fileSystem=(Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($runPath).Substring(0,1))).FileSystem
    artificialDataOnly=$true
    passed=$results.Count
    checks=$results
    limits=@('Only this volume was tested','Does not prove FAT/exFAT/ReFS behavior','Does not prove file IDs unique across deletion or different devices','Does not prove a media container is complete or decodable','No Flutter importer, watcher or encrypted catalog integration')
}
$reportRoot = Get-EpaLocalPath reports 'import-preflight'
[void][IO.Directory]::CreateDirectory($reportRoot)
$reportPath = Join-Path $reportRoot ((Split-Path -Leaf $runPath) + '.json')
[IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
Write-Output ($report | ConvertTo-Json -Depth 6)
