param(
    [Parameter(Mandatory = $true)][string]$Runner,
    [Parameter(Mandatory = $true)][string]$MountReport
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$runnerPath = Assert-EpaPathWithin (Resolve-Path -LiteralPath $Runner).Path (Join-Path $project 'build')
$MountReport = Assert-EpaPathWithin $MountReport (Get-EpaLocalPath acceptance)
$mount = Get-Content -LiteralPath $MountReport -Raw | ConvertFrom-Json
if ($mount.state -ne 'mounted' -or $mount.bytes -ne 256MB -or $mount.drive_letter -in @('C','D')) { throw 'Not a bounded fixture mount' }
$volume = Get-Volume -DriveLetter $mount.drive_letter
if ($volume.UniqueId -ne $mount.unique_id -or $volume.FileSystemLabel -ne $mount.fixture_label -or $volume.Size -gt 256MB) { throw 'Mounted fixture identity differs' }
$runId = [guid]::NewGuid().ToString('N').Substring(0,8)
$output = Get-EpaLocalPath reports "disk-full/run-$runId"
New-Item -ItemType Directory -Path $output | Out-Null
$results = [Collections.Generic.List[object]]::new()

function Invoke-Runner([string]$Mode, [string]$Root, [string]$Report, [string]$Stage) {
    $arguments = @($Mode, $Root, $Report, $Stage) | ForEach-Object { '"' + $_ + '"' }
    $child = Start-Process -FilePath $runnerPath -ArgumentList $arguments -WorkingDirectory $project -WindowStyle Hidden -PassThru
    try {
        if (-not $child.WaitForExit(45000)) { throw "Runner timed out: $Mode/$Stage" }
        $record = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
        if ($child.ExitCode -ne 0 -or $record.state -ne 'passed') { throw "Runner failed: $($record | ConvertTo-Json -Compress)" }
        return $record
    } finally {
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }
}

$scenarios = @(
    @('disk-full-initialize', 'catalog-created', 'disk-initialize'),
    @('disk-full-change', 'before-change', 'disk-before-change'),
    @('disk-full-change', 'password-committed', 'disk-after-change'),
    @('disk-full-transaction', 'before-transaction', 'disk-transaction')
)
foreach ($scenario in $scenarios) {
    $mode, $stage, $verification = $scenario
    $caseRoot = Join-Path ($mount.drive_letter + ':\') "$verification-$runId"
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $vault = Join-Path $caseRoot 'vault'
    if ($mode -ne 'disk-full-initialize') {
        Invoke-Runner seed $vault (Join-Path $output "$verification-seed.json") $stage | Out-Null
    }
    $failure = Invoke-Runner $mode $vault (Join-Path $output "$verification-failure.json") $stage
    if ($failure.actual_windows_disk_error -notin @(112,39)) { throw 'No actual Windows disk-full error recorded' }
    $recoveryStage = if ($mode -eq 'disk-full-change' -and $failure.committed_generation -eq 2) { 'disk-after-change' } else { $verification }
    $recovery = Invoke-Runner verify $vault (Join-Path $output "$verification-recovery.json") $recoveryStage
    $results.Add(@{scenario=$verification; failure=$failure; recovery=$recovery; passed=$true})
    @{
        recorded_at_utc=(Get-Date).ToUniversalTime().ToString('o'); passed=$results.Count
        scenarios=$results.ToArray(); mounted_volume=$mount
        runner_sha256=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
        app_so_sha256=(Get-FileHash -LiteralPath (Join-Path (Split-Path $runnerPath) 'data\app.so') -Algorithm SHA256).Hash
        scope='Actual bounded NTFS volume exhaustion, real Windows IO errors, production controller/SQLCipher/DPAPI, fresh process recovery. Mounting alone was elevated; app runner uses the original ordinary Windows user process.'
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'disk-full-report.json') -Encoding utf8
    Write-Output "$verification passed"
}
Write-Output "Report: $output\disk-full-report.json"
