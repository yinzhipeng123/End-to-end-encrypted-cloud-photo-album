param(
    [string]$FlutterRoot = 'D:\tools\flutter',
    [switch]$UseInstalledToolchain
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/repo-root.ps1')
$projectPath = Get-EpaWindowsRoot
$flutterCommand = Join-Path $FlutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterCommand)) {
    throw 'Flutter SDK not found. Pass -FlutterRoot with the SDK directory.'
}
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
if (-not $env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.dev' }
Push-Location -LiteralPath $projectPath
try {
    $pubErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell represents redirected native stderr as error
        # records. Capture it without losing Flutter's actual exit status.
        $ErrorActionPreference = 'Continue'
        $dependencyOutput = @(& $flutterCommand pub get 2>&1)
        $dependencyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $pubErrorPreference
    }
    $dependencyOutput | ForEach-Object { Write-Output $_ }
    if ($dependencyExit -ne 0 -and ($dependencyOutput -join "`n") -match 'requires symlink support') {
        Initialize-EpaPluginJunctions $projectPath
        & $flutterCommand pub get
        $dependencyExit = $LASTEXITCODE
    }
    if ($dependencyExit -ne 0) { throw 'Dependency resolution failed.' }
    & $flutterCommand build windows --release --no-pub --target lib/main.dart
    if ($LASTEXITCODE -eq 0) { return }
    if (-not $UseInstalledToolchain) {
        throw 'Standard build failed. Run flutter doctor. If only installer completion after reboot is pending, see README.'
    }

    # A local CMake build using the installed compiler; does not modify Flutter,
    # installer state, Windows settings, or registry reboot markers.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installations = & $vswhere -all -products '*' -format json -utf8 | ConvertFrom-Json
    $installation = $installations | Where-Object {
        $_.installationVersion -like '17.*' -and
        (Test-Path -LiteralPath (Join-Path $_.installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))
    } | Sort-Object installationVersion -Descending | Select-Object -First 1
    if (-not $installation) { throw 'No installed Visual Studio 2022 CMake toolchain found.' }
    $cmake = Join-Path $installation.installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    $instance = $installation.installationPath.Replace('\', '/') + ',version=' + $installation.installationVersion
    & $cmake -S windows -B build/windows/x64 -G 'Visual Studio 17 2022' -A x64 "-DCMAKE_GENERATOR_INSTANCE=$instance" '-DFLUTTER_TARGET_PLATFORM=windows-x64'
    if ($LASTEXITCODE -ne 0) { throw 'CMake toolchain verification/configuration failed.' }
    & $cmake --build build/windows/x64 --config Release --target INSTALL
    if ($LASTEXITCODE -ne 0) { throw 'Native release build failed.' }
} finally {
    Pop-Location
}
