param([string]$FlutterRoot = 'D:\tools\flutter')

# Restricts ONLY the artificial credential probe child, never the desktop App.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$output = Join-Path $project 'build\security-probe'
$testDir = Get-EpaLocalPath acceptance ('security/low-memory-' + [Guid]::NewGuid().ToString('N'))
$reportRoot = Get-EpaLocalPath reports 'security'
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
New-Item -ItemType Directory -Path $testDir | Out-Null
$testFile = Join-Path $testDir 'vault.bootstrap'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EpaProbeJob {
    [StructLayout(LayoutKind.Sequential)] public struct Basic {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Io {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Extended {
        public Basic BasicLimitInformation;
        public Io IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref Extended info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job, int infoClass, ref Extended info, uint size, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.WorkingDirectory = $project
foreach ($argument in @('--disable-dart-dev', (Join-Path $output 'security-probe.dill'), 'child', 'limited-memory', $testFile)) {
    $start.ArgumentList.Add($argument)
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$job = [IntPtr]::Zero
$workerProcess = $null
try {
    if (-not $process.Start()) { throw 'Probe child could not start.' }
    $ready = $process.StandardOutput.ReadLineAsync()
    if (-not $ready.Wait(20000) -or $ready.Result -notmatch '^ready:(\d+)$') { throw 'Probe did not reach initialized backend.' }
    $workerId = [int]$Matches[1]
    # Recent Dart SDKs launch dartvm.exe beneath dart.exe. Constrain the actual
    # reporting VM, after verifying that it belongs to the child we started.
    $ancestor = $workerId
    for ($depth = 0; $ancestor -ne $process.Id -and $depth -lt 5; $depth++) {
        $entry = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor"
        if (-not $entry) { throw 'Cannot verify probe process ancestry.' }
        $ancestor = [int]$entry.ParentProcessId
    }
    if ($ancestor -ne $process.Id) { throw 'Reported VM does not belong to this isolated probe.' }
    $workerProcess = [Diagnostics.Process]::GetProcessById($workerId)
    $workerProcess.Refresh()
    $commitBefore = $workerProcess.PrivateMemorySize64
    $limit = $commitBefore + 32MB
    $job = [EpaProbeJob]::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw 'Cannot create isolated process memory limit.' }
    $info = [EpaProbeJob+Extended]::new()
    $basic = [EpaProbeJob+Basic]::new()
    $basic.LimitFlags = 0x2100 # PROCESS_MEMORY | KILL_ON_JOB_CLOSE
    $info.BasicLimitInformation = $basic
    $info.ProcessMemoryLimit = [UIntPtr]::new([ulong]$limit)
    if (-not [EpaProbeJob]::SetInformationJobObject($job, 9, [ref]$info, [Runtime.InteropServices.Marshal]::SizeOf($info))) {
        throw 'Cannot configure the isolated child limit.'
    }
    $actual = [EpaProbeJob+Extended]::new()
    if (-not [EpaProbeJob]::QueryInformationJobObject($job, 9, [ref]$actual, [Runtime.InteropServices.Marshal]::SizeOf($actual), [IntPtr]::Zero) -or `
        $actual.BasicLimitInformation.LimitFlags -ne 0x2100 -or $actual.ProcessMemoryLimit.ToUInt64() -ne $limit) {
        throw 'Windows did not confirm the requested memory limit.'
    }
    if (-not [EpaProbeJob]::AssignProcessToJobObject($job, $workerProcess.Handle)) { throw 'Cannot constrain the isolated VM.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine('derive')
    $process.StandardInput.Flush()
    if (-not $process.WaitForExit(30000)) { throw 'Limited-memory probe timed out.' }
    $childOutput = $stdoutTask.GetAwaiter().GetResult().Trim()
    $result = if ($childOutput.StartsWith('{')) { $childOutput | ConvertFrom-Json } else { @{code = 'no-structured-result'; file_exists = (Test-Path -LiteralPath $testFile)} }
    $null = $stderrTask.GetAwaiter().GetResult()
    $passed = $process.ExitCode -eq 0 -and $result.code -eq 'backendFailure' -and `
        $result.file_exists -eq $false -and -not (Test-Path -LiteralPath $testFile)
    @{
        status = $(if ($passed) { 'passed' } else { 'failed' })
        private_commit_before_bytes = $commitBefore
        process_commit_limit_bytes = $limit
        additional_budget_bytes = 32MB
        child_exit_code = $process.ExitCode
        code = $result.code
        file_exists = (Test-Path -LiteralPath $testFile)
        scope = 'Windows job object on synthetic child only'
    } | ConvertTo-Json | Tee-Object -FilePath (Join-Path $reportRoot 'low-memory-result.json')
    if (-not $passed) { throw 'Low-memory behavior did not satisfy the acceptance check.' }
} finally {
    if ($process.Id -and -not $process.HasExited) { $process.Kill($true) }
    if ($job -ne [IntPtr]::Zero) { [EpaProbeJob]::CloseHandle($job) | Out-Null }
    $process.Dispose()
    if ($workerProcess) { $workerProcess.Dispose() }
}
