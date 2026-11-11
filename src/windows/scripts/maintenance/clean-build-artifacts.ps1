[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/repo-root.ps1')
$projectRoot = Get-EpaWindowsRoot
# Only generated outputs of the NEW Windows host. Historical bundles, accounts,
# artificial sources and reports are preserved in src/.local and never targets.
$relativeTargets = @(
    'build/windows', 'build/source-reader', 'build/dependencies',
    'build/probes/sqlcipher', 'build/background-lock-platform/runner',
    'build/catalog-recovery/bundle', 'build/import-ui-runner',
    'build/organization-ui-runner', 'build/sync-platform/runner',
    'build/github-auth-acceptance/runner', 'build/windows-runner-probe',
    'build/security-probe/native', 'build/security-probe/security-probe.dill',
    'build/flutter_assets', 'build/native_assets', 'build/test_cache',
    'build/unit_test_assets', 'build/.last_build_id',
    'tool/probes/sqlcipher/.dart_tool', '.dart_tool',
    'windows/flutter/ephemeral', '.flutter-plugins-dependencies'
)
$targets = @($relativeTargets | ForEach-Object {
    Assert-EpaPathWithin (Join-Path $projectRoot $_) $projectRoot
})
$running = @(Get-Process encrypted_photo_app -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count) { throw 'Close the Windows host application before cleanup; no process is stopped automatically.' }

# Windows PowerShell 5.1 must never recursively traverse Flutter plugin
# junctions: their targets are outside this project in the user's Pub cache.
function Get-CleanupItem([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if (-not $full.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup item is outside the Windows host.'
    }
    $null = Assert-EpaPathWithin (Split-Path -Parent $full) $projectRoot -AllowBoundary
    return Get-Item -LiteralPath $full -Force
}

function Assert-CleanupDirectoryLink($Item) {
    $linkTargets = @($Item.Target)
    if (-not $Item.PSIsContainer -or
        $Item.LinkType -notin @('Junction', 'SymbolicLink') -or
        $linkTargets.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$linkTargets[0])) {
        throw 'Unsupported reparse point in cleanup tree; nothing will traverse it.'
    }
    $destination = [string]$linkTargets[0]
    # Volume mount points share the junction reparse tag. Reject their volume
    # GUID targets, and reject drive-root destinations conservatively as well.
    if ($destination -match '(?i)(?:^|[\\/])Volume\{' -or
        $destination -match '^(?:\\\?\?\\|\\\\\?\\)?[A-Za-z]:[\\/]$') {
        throw 'Volume mount points are not accepted in cleanup trees.'
    }
}

function Assert-CleanupTree([string]$Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        $item = Get-CleanupItem $pending.Pop()
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Assert-CleanupDirectoryLink $item
            continue
        }
        if (-not $item.PSIsContainer) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Assert-CleanupDirectoryLink $child
            } elseif ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function Remove-CleanupTree([string]$Path) {
    $item = Get-CleanupItem $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Assert-CleanupDirectoryLink $item
        # Non-recursive .NET deletion removes the link itself only.
        [IO.Directory]::Delete($item.FullName, $false)
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) {
            Remove-CleanupTree $child.FullName
        }
        $current = Get-CleanupItem $Path
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Cleanup directory changed into a reparse point; refusing to continue.'
        }
        [IO.Directory]::Delete($current.FullName, $false)
    } else {
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

# Inspect every existing target before the first mutation. Enumerate one level
# at a time and never enter reparse points, even when only previewing (-WhatIf).
foreach ($target in $targets) {
    if (Test-Path -LiteralPath $target) { Assert-CleanupTree $target }
}

$removed = @()
foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target)) { continue }
    if (-not $PSCmdlet.ShouldProcess($target, 'Remove explicitly listed generated output')) { continue }
    # Validate the absolute target again immediately before the recursive action.
    $null = Assert-EpaPathWithin $target $projectRoot
    Remove-CleanupTree $target
    if (Test-Path -LiteralPath $target) { throw 'Removal did not complete.' }
    $removed += $target
}
if (-not $WhatIfPreference) {
    $reportRoot = Get-EpaLocalPath reports 'maintenance'
    [IO.Directory]::CreateDirectory($reportRoot) | Out-Null
    [ordered]@{
        atUtc = (Get-Date).ToUniversalTime().ToString('o')
        removed = $removed
        preserved = @('source', 'OpenSpec', 'src/.local/pre-structure', 'acceptance accounts and sources', 'user vaults')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $reportRoot 'cleanup-result.json')
    Write-Output "Removed $($removed.Count) generated paths. Source and all vault/test data were preserved."
}
