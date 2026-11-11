param([Parameter(Mandatory = $true)][string]$Runner)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$runnerPath = Assert-EpaPathWithin (Resolve-Path -LiteralPath $Runner).Path (Join-Path $project 'build')
$expectedBuildRoot = [IO.Path]::GetFullPath((Join-Path $project 'build')) + '\'
if (-not $runnerPath.StartsWith($expectedBuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Only an isolated verification runner inside project build/ is accepted.'
}
$runRoot = Get-EpaLocalPath acceptance ('app-recovery-results/run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$reportRoot = Get-EpaLocalPath reports ('app-recovery/' + (Split-Path -Leaf $runRoot))
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runRoot | Out-Null
$results = [Collections.Generic.List[object]]::new()
$stages = @(
    @('initialize', 'bootstrap-created', 'bootstrap-created'),
    @('initialize', 'bootstrap-flushed', 'bootstrap-flushed'),
    @('initialize', 'catalog-created', 'catalog-created'),
    @('initialize', 'pin-committed', 'pin-committed'),
    @('initialize', 'auxiliary-committed', 'initialize-auxiliary'),
    @('initialize', 'initialization-completed', 'initialization-completed'),
    @('change', 'password-candidate-flushed', 'password-candidate-flushed'),
    @('change', 'password-committed', 'password-committed'),
    @('change', 'auxiliary-committed', 'change-auxiliary'),
    @('change', 'password-change-completed', 'password-change-completed'),
    @('transaction', 'transaction-uncommitted', 'transaction-uncommitted'),
    @('transaction', 'transaction-committed', 'transaction-committed')
)

function Invoke-FixtureProcess([string]$Mode, [string]$Root, [string]$Report, [string]$Stage, [switch]$TerminateAtCheckpoint) {
    $arguments = @($Mode, $Root, $Report, $Stage) | ForEach-Object { '"' + $_ + '"' }
    $child = Start-Process -FilePath $runnerPath -ArgumentList $arguments -WorkingDirectory $project -WindowStyle Hidden -PassThru
    try {
        $deadline = (Get-Date).AddSeconds(45)
        while (-not $child.HasExited -and (Get-Date) -lt $deadline) {
            if ($TerminateAtCheckpoint -and (Test-Path -LiteralPath $Report)) {
                try { $record = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json } catch { $record = $null }
                if ($record.state -eq 'ready' -and $record.pid -eq $child.Id -and $record.stage -eq $Stage) {
                    # Kill only this child, after its actual completed IO boundary.
                    $child.Kill()
                    $child.WaitForExit()
                    return
                }
            }
            Start-Sleep -Milliseconds 100
            $child.Refresh()
        }
        if (-not $child.HasExited) { throw "Fixture timed out: $Mode/$Stage" }
        $child.WaitForExit()
        if ($TerminateAtCheckpoint) {
            $record = if (Test-Path -LiteralPath $Report) { Get-Content -LiteralPath $Report -Raw } else { 'No report' }
            throw "Fixture exited before checkpoint: $Mode/$Stage $record"
        }
        $record = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
        if ($child.ExitCode -ne 0 -or $record.state -ne 'passed') { throw "Fixture failed: $Mode/$Stage $($record | ConvertTo-Json -Compress)" }
    } finally {
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }
}

foreach ($scenario in $stages) {
    $mode, $stage, $verification = $scenario
    $caseRoot = Join-Path $runRoot "$mode-$stage"
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $vault = Join-Path $caseRoot 'vault'
    if ($mode -ne 'initialize') {
        Invoke-FixtureProcess seed $vault (Join-Path $caseRoot 'seed.json') $stage
    }
    Invoke-FixtureProcess $mode $vault (Join-Path $caseRoot 'checkpoint.json') $stage -TerminateAtCheckpoint
    $bytesChecked = 0
    $residue = @()
    foreach ($file in Get-ChildItem -LiteralPath $vault -File) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $bytesChecked += $bytes.Length
        $raw = [Text.Encoding]::Latin1.GetString($bytes)
        foreach ($marker in @('ARTIFICIAL_APP_CRASH_METADATA_20261110', 'artificial application crash test password', 'new artificial application crash test password')) {
            $utf16 = [Text.Encoding]::Latin1.GetString([Text.Encoding]::Unicode.GetBytes($marker))
            if ($raw.Contains($marker) -or $raw.Contains($utf16)) { throw "Plaintext marker in controlled residue: $mode/$stage" }
        }
        $residue += @{name=$file.Name; bytes=$bytes.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    }
    Invoke-FixtureProcess verify $vault (Join-Path $caseRoot 'verify.json') $verification
    $results.Add(@{mode=$mode; stage=$stage; passed=$true; actual_process_terminated=$true; fresh_process_recovery=$true; residue_bytes_checked=$bytesChecked; residue=$residue})
    Write-Output "$mode/$stage passed"
    @{
        recorded_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        platform=[Environment]::OSVersion.VersionString
        runner=$runnerPath
        runner_sha256=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
        app_so_sha256=(Get-FileHash -LiteralPath (Join-Path (Split-Path $runnerPath) 'data\app.so') -Algorithm SHA256).Hash
        passed=$results.Count
        scenarios=$results.ToArray()
        scope='Real production PhotoVaultApp/controller, SQLCipher, DPAPI and filesystem; File delegates pause at IO boundaries; actual process termination and fresh runner recovery. Artificial fixtures only. No physical power-loss or volume-exhaustion claim.'
    } | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $reportRoot 'report.json') -Encoding utf8
}
Write-Output "Report: $reportRoot\report.json"
