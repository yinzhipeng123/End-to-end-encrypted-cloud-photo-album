param([string]$FlutterRoot = 'D:\tools\flutter')
$ErrorActionPreference = 'Stop'
$dart = Join-Path $FlutterRoot 'bin/dart.bat'
. (Join-Path $PSScriptRoot '../../../scripts/support/repo-root.ps1')
$projectRoot = Get-EpaWindowsRoot
$buildRoot = Join-Path $projectRoot 'build/probes/sqlcipher'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$dataRoot = Get-EpaLocalPath acceptance 'sqlcipher-probe/results'
$reportRoot = Get-EpaLocalPath reports 'sqlcipher'
Push-Location $PSScriptRoot
try {
    & $dart pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw '探针依赖解析失败。' }
    & $dart analyze
    if ($LASTEXITCODE -ne 0) { throw '探针静态分析失败。' }
    & $dart build cli --target bin/verify.dart --output $buildRoot
    if ($LASTEXITCODE -ne 0) { throw '探针构建失败。' }
    $bundle = Join-Path $buildRoot 'bundle'
    $native = Join-Path $bundle 'lib/sqlcipher.dll'
    $expected = 'f13740c540bc2fd35c52372bf6effcaaf488b09e81c11d1896ac61b6cab06dce'
    if ((Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw '原生库与已审核的 sqlite3 3.9.1 Windows x64 哈希不同，拒绝执行。'
    }
    & (Join-Path $bundle 'bin/verify.exe') $dataRoot $reportRoot
    if ($LASTEXITCODE -ne 0) { throw 'SQLCipher 验证未全部通过。' }
} finally {
    Pop-Location
}
