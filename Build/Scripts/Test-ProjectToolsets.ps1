# Deterministic regression guard for the defect that broke the native ARM64
# build: projects pinned PlatformToolset to v142, so a native ARM64 runner
# selected the legacy 14.29 ARM64 toolset while vcpkg built the dependencies
# with the current one. The legacy compiler cannot parse the current Windows SDK
# headers and failed with:
#   winnt.h(6343,12): error C3861: '_CountOneBits64': identifier not found
#
# This check is intentionally static: it needs no compiler and therefore catches
# the regression on any host, including hosts where the legacy toolset is not
# installed and MSBuild would silently fall back to a working one.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    # Projects that deliberately pin an old toolset because they are prebuilt
    # fixtures reproducing historical compiler output.
    [string[]]$ExcludedProjectPatterns = @("OptimizedBuildVS2013")
)

$ErrorActionPreference = "Stop"

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0

$projects = Get-ChildItem -Path $RepositoryRoot -Recurse -Filter *.vcxproj |
    Where-Object {
        $path = $_.FullName
        -not ($ExcludedProjectPatterns | Where-Object { $path -match [regex]::Escape($_) })
    }

foreach ($project in $projects) {
    $checked++
    $content = Get-Content -LiteralPath $project.FullName -Raw

    foreach ($match in [regex]::Matches($content, '<PlatformToolset>(?<value>[^<]*)</PlatformToolset>')) {
        $value = $match.Groups['value'].Value.Trim()

        # A literal toolset such as v142 pins every platform, including ARM64.
        if ($value -match '^v\d+$') {
            $failures.Add("$($project.Name): PlatformToolset is hardcoded to '$value'. Derive it from `$(DefaultPlatformToolset) so the toolset matches the Visual Studio instance and the toolset vcpkg used.")
        }
        elseif ([string]::IsNullOrWhiteSpace($value)) {
            $failures.Add("$($project.Name): PlatformToolset is empty.")
        }
        elseif ($value -notmatch 'DefaultPlatformToolset') {
            $failures.Add("$($project.Name): PlatformToolset '$value' does not derive from `$(DefaultPlatformToolset).")
        }
    }
}

if ($checked -eq 0) {
    throw "No .vcxproj files were found under '$RepositoryRoot'; the toolset guard would pass vacuously."
}

Write-Host "Checked $checked project file(s) for hardcoded platform toolsets."

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "TOOLSET REGRESSION: $failure" }
    Write-Error "$($failures.Count) project configuration(s) pin a platform toolset."
    exit 1
}

Write-Host "No project pins a legacy platform toolset."
exit 0
