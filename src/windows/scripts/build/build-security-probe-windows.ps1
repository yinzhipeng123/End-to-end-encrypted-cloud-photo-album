param(
    [string]$FlutterRoot = 'D:\tools\flutter',
    [string]$VisualStudioRoot = 'D:\tools\VSBuildTools'
)

# Isolated validation build for a machine whose VS installation is pending a
# reboot. Uses the package's unmodified hook with an explicit installed compiler.
# Does not change SDK/package sources, registry, installer state or App startup.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$dartSdk = Join-Path $FlutterRoot 'bin\cache\dart-sdk'
$dart = Join-Path $dartSdk 'bin\dart.exe'
$outDir = Join-Path $project 'build\security-probe'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$configPath = Join-Path $project '.dart_tool\package_config.json'
$packages = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$package = $packages.packages | Where-Object name -eq 'sodium'
if (-not $package) { throw 'Run flutter pub get first.' }
$configUri = [Uri]::new($configPath)
$packageRoot = [Uri]::new($configUri, $package.rootUri).LocalPath
$archive = Join-Path $packageRoot '3rdparty\libsodium-1.0.22-stable.tar.gz'
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($archiveHash -ne '5D829F95EA7BE72EEDF373B197F01DF765171DA80619B1291692D3F854E10E46') {
    throw 'The approved source archive hash does not match.'
}
$vcVersion = Get-ChildItem -LiteralPath (Join-Path $VisualStudioRoot 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$compilerDir = Join-Path $vcVersion.FullName 'bin\Hostx64\x64'
$devCmd = Join-Path $VisualStudioRoot 'Common7\Tools\VsDevCmd.bat'
foreach ($path in @($devCmd, (Join-Path $compilerDir 'cl.exe'), (Join-Path $compilerDir 'link.exe'), (Join-Path $compilerDir 'lib.exe'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Installed MSVC toolchain is incomplete.' }
}
$hookOutput = Join-Path $outDir 'hook-output.json'
$inputPath = Join-Path $outDir 'hook-input.json'
$inputData = @{
    assets = @{}
    config = @{
        build_asset_types = @('code_assets/code')
        linking_enabled = $false
        extensions = @{
            code_assets = @{
                link_mode_preference = 'dynamic'
                target_architecture = 'x64'
                target_os = 'windows'
                c_compiler = @{
                    cc = (Join-Path $compilerDir 'cl.exe')
                    ld = (Join-Path $compilerDir 'link.exe')
                    ar = (Join-Path $compilerDir 'lib.exe')
                    windows = @{
                        developer_command_prompt = @{
                            script = $devCmd
                            arguments = @('-arch=amd64', '-host_arch=amd64')
                        }
                    }
                }
            }
        }
    }
    out_dir_shared = (Join-Path $outDir 'native\')
    out_file = $hookOutput
    package_name = 'sodium'
    package_root = $packageRoot.TrimEnd('\') + '\'
    user_defines = @{}
}
$inputData | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $inputPath -Encoding utf8
Push-Location -LiteralPath $project
try {
    & $dart --disable-dart-dev "--packages=$configPath" (Join-Path $packageRoot 'hook\build.dart') "--config=$inputPath"
    if ($LASTEXITCODE -ne 0) { throw 'Actual libsodium source build failed.' }
    $hook = Get-Content -LiteralPath $hookOutput -Raw | ConvertFrom-Json
    $asset = $hook.assets | ForEach-Object { $_.encoding } | Where-Object id -eq 'package:sodium/libsodium'
    if (-not $asset -or -not (Test-Path -LiteralPath $asset.file -PathType Leaf)) {
        throw 'The hook did not emit the expected native library.'
    }
    $mappingPath = Join-Path $outDir 'native-assets.json'
    @{
        'format-version' = @(1, 0, 0)
        'native-assets' = @{
            windows_x64 = @{'package:sodium/libsodium' = @('absolute', $asset.file)}
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mappingPath -Encoding utf8
    @{
        sodium = '4.1.2+1'
        source_sha256 = $archiveHash
        dll = $asset.file
        dll_sha256 = (Get-FileHash -LiteralPath $asset.file -Algorithm SHA256).Hash
        compiler = $vcVersion.Name
        validation_build_only = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'build-identity.json') -Encoding utf8
    & (Join-Path $dartSdk 'bin\dartaotruntime.exe') (Join-Path $dartSdk 'bin\snapshots\gen_kernel_aot.dart.snapshot') `
        --platform (Join-Path $dartSdk 'lib\_internal\vm_platform.dill') `
        --packages $configPath --native-assets $mappingPath `
        --output (Join-Path $outDir 'security-probe.dill') (Join-Path $project 'tool\acceptance\security\security_probe.dart')
    if ($LASTEXITCODE -ne 0) { throw 'Security probe compilation failed.' }
    Write-Output 'Built real native library and security-probe.dill; tests have not yet run.'
} finally {
    Pop-Location
}
