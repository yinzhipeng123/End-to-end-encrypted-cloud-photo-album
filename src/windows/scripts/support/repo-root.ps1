# Path-only helpers: loading this file does not create data, build or run tests.
function Get-EpaWindowsRoot([string]$Start = $PSScriptRoot) {
    $cursor = [IO.Path]::GetFullPath($Start)
    while ($cursor) {
        $manifest = Join-Path $cursor 'pubspec.yaml'
        if ((Test-Path -LiteralPath $manifest -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $cursor 'windows') -PathType Container) -and
            ([IO.File]::ReadAllText($manifest) -match '(?m)^name:\s*encrypted_photo_app\s*$')) { return $cursor }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    throw 'Windows Flutter host root could not be found from the tool location.'
}

function Assert-EpaPathWithin([string]$Path, [string]$Boundary, [switch]$AllowBoundary) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $base = [IO.Path]::GetFullPath($Boundary).TrimEnd('\','/')
    if (-not ($full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        ($AllowBoundary -and $full.Equals($base, [StringComparison]::OrdinalIgnoreCase)))) {
        throw 'Path is outside its isolated tool boundary.'
    }
    # Check every existing ancestor, including the boundary itself.
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Redirected tool paths are not accepted.'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Get-EpaLocalPath([ValidateSet('acceptance','reports','probes')][string]$Kind, [string]$Relative = '', [string]$WindowsRoot = (Get-EpaWindowsRoot)) {
    $localRoot = Join-Path (Split-Path -Parent $WindowsRoot) '.local'
    $base = Join-Path $localRoot $Kind
    $path = if ($Relative) { Join-Path $base $Relative } else { $base }
    return Assert-EpaPathWithin $path $localRoot
}

function Initialize-EpaPluginJunctions([string]$WindowsRoot) {
    # Project-local fallback for Flutter's specific missing-symlink-support
    # error. Does not enable Developer Mode, elevate, or modify package caches.
    $hostRoot = Get-EpaWindowsRoot $WindowsRoot
    $pluginManifest = Join-Path $hostRoot '.flutter-plugins-dependencies'
    $packageManifest = Join-Path $hostRoot '.dart_tool/package_config.json'
    if (-not (Test-Path -LiteralPath $pluginManifest -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packageManifest -PathType Leaf)) {
        throw 'Flutter did not emit plugin/package metadata for the junction fallback.'
    }
    $plugins = (Get-Content -LiteralPath $pluginManifest -Raw | ConvertFrom-Json).plugins.windows
    $packages = (Get-Content -LiteralPath $packageManifest -Raw | ConvertFrom-Json).packages
    $linkRoot = Assert-EpaPathWithin (Join-Path $hostRoot 'windows/flutter/ephemeral/.plugin_symlinks') $hostRoot
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    foreach ($plugin in $plugins) {
        if ($plugin.name -notmatch '^[a-z][a-z0-9_]*$') { throw 'Invalid generated plugin name.' }
        $source = [IO.Path]::GetFullPath([string]$plugin.path).TrimEnd('\','/')
        $package = @($packages | Where-Object name -EQ $plugin.name)
        if ($package.Count -ne 1) { throw 'Plugin has no unique resolved package.' }
        $packageUri = [Uri]::new([Uri]::new($packageManifest), [string]$package[0].rootUri)
        if (-not $packageUri.IsFile -or
            -not $source.Equals([IO.Path]::GetFullPath($packageUri.LocalPath).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath (Join-Path $source 'pubspec.yaml') -PathType Leaf)) {
            throw 'Plugin source differs from the resolved package.'
        }
        $destination = Join-Path $linkRoot $plugin.name
        if (Test-Path -LiteralPath $destination) {
            $existing = Get-Item -LiteralPath $destination -Force
            if (-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                -not ([IO.Path]::GetFullPath([string]$existing.Target).TrimEnd('\','/')).Equals($source, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Existing plugin link differs; refusing to replace it.'
            }
        } else {
            New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
        }
    }
}
