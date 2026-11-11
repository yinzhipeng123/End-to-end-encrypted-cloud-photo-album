$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/repo-root.ps1')
$project = Get-EpaWindowsRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $installation) { throw 'Visual Studio C++ tools unavailable' }
$cmake = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
& $cmake -S (Join-Path $project 'windows\source_reader') -B (Join-Path $project 'build\source-reader') -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Source reader configuration failed' }
& $cmake --build (Join-Path $project 'build\source-reader') --config Release
if ($LASTEXITCODE -ne 0) { throw 'Source reader build failed' }
