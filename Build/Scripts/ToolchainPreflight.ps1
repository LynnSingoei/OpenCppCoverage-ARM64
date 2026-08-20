# Verifies that MSBuild and vcpkg resolve one coherent MSVC toolchain before any
# compilation starts.
#
# Background: OpenCppCoverage used to pin PlatformToolset to v142. On a native
# ARM64 runner that selected the legacy 14.29 ARM64 toolset while vcpkg built the
# dependencies with the current toolset. The legacy compiler cannot parse the
# current Windows SDK headers, which failed as:
#   winnt.h(6343,12): error C3861: '_CountOneBits64': identifier not found
# This script fails closed on that class of mismatch instead of letting the
# compiler discover it thousands of lines into a build.

[CmdletBinding()]
param(
    [ValidateSet("Win32", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$ProjectPath,

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\logs"),

    # Treat a toolchain that cannot be positively identified as a failure.
    [switch]$RequireVcpkgComparison,

    # Permit a PlatformToolset that differs from the Visual Studio instance
    # default. Without this the preflight fails, because a pinned legacy toolset
    # is exactly what broke the ARM64 build.
    [switch]$AllowToolsetOverride
)

$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $ProjectPath) {
    $ProjectPath = Join-Path $repositoryRoot "Tools\Tools.vcxproj"
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

# MSVC target folder name for the requested MSBuild platform.
$targetArchitecture = switch ($Platform) {
    "Win32" { "x86" }
    "x64" { "x64" }
    "ARM64" { "arm64" }
}

$hostArchitecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    "Arm64" { "arm64" }
    "X64" { "x64" }
    "X86" { "x86" }
    default { "x64" }
}

$problems = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Resolve-MSBuild {
    $command = Get-Command "msbuild.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.Component.MSBuild `
            -find "MSBuild\**\Bin\MSBuild.exe" 2>$null | Select-Object -First 1
        if ($found -and (Test-Path -LiteralPath $found)) { return $found }
    }

    throw "MSBuild could not be located. Add it to PATH or install Visual Studio."
}

function Get-ClVersion {
    param([string]$ClPath)

    # cl.exe prints its banner on stderr and exits non-zero with no inputs, which
    # is expected here: the banner is the only thing we need. Stderr must not be
    # promoted to a terminating error while we read it.
    $ErrorActionPreference = "Continue"
    $output = & $ClPath 2>&1 | Out-String
    if ($output -match 'Version\s+([0-9]+(?:\.[0-9]+)+)\s+for\s+(\S+)') {
        return [pscustomobject]@{
            Version = $Matches[1]
            Target  = $Matches[2]
            Banner  = ($output -split "`r?`n" | Where-Object { $_ -match 'Version' } | Select-Object -First 1).Trim()
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 1. Ask MSBuild what it would actually use, rather than guessing.
# ---------------------------------------------------------------------------
$requested = @(
    "PlatformToolset"
    "DefaultPlatformToolset"
    "VCToolsVersion"
    "VCToolsInstallDir"
    "WindowsTargetPlatformVersion"
    "WindowsSDKVersion"
    "LibraryPath"
)

$msbuildPath = Resolve-MSBuild
$msbuildJson = & $msbuildPath $ProjectPath `
    "/p:Configuration=$Configuration" `
    "/p:Platform=$Platform" `
    "-getProperty:$($requested -join ',')" 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    throw "Unable to evaluate $ProjectPath for $Configuration|$Platform. MSBuild output:`n$msbuildJson"
}

try {
    $properties = ($msbuildJson | ConvertFrom-Json).Properties
}
catch {
    throw "MSBuild did not return evaluable JSON properties (requires MSBuild 17.8+). Output:`n$msbuildJson"
}

$platformToolset = $properties.PlatformToolset
$vcToolsVersion = $properties.VCToolsVersion
$vcToolsInstallDir = $properties.VCToolsInstallDir
$windowsSdk = $properties.WindowsSDKVersion
if (-not $windowsSdk) { $windowsSdk = $properties.WindowsTargetPlatformVersion }

if (-not $vcToolsInstallDir) {
    $problems.Add("MSBuild resolved an empty VCToolsInstallDir for $Configuration|$Platform.")
}

# A toolset pinned below the instance default is the defect that produced the
# ARM64 winnt.h C3861 failure. Detect it directly, because a host that lacks the
# pinned toolset silently falls back to the default and would otherwise hide it.
if ($platformToolset -and $properties.DefaultPlatformToolset -and
    $platformToolset -ne $properties.DefaultPlatformToolset -and -not $AllowToolsetOverride) {
    $problems.Add("PlatformToolset '$platformToolset' differs from this Visual Studio instance's default '$($properties.DefaultPlatformToolset)' for $Configuration|$Platform. A pinned legacy toolset cannot compile the current Windows SDK headers when targeting ARM64. Pass -AllowToolsetOverride only if the pin is deliberate.")
}

# ---------------------------------------------------------------------------
# 2. Fail-closed toolchain detection.
#    A present directory proves nothing: the ASAN runtime ships aarch64 files
#    into lib\arm64 and bin\HostArm64\arm64 even when the ARM64 compiler and CRT
#    are not installed. Require the compiler, the linker and a CRT import
#    library before declaring the toolchain usable.
# ---------------------------------------------------------------------------
$clPath = $null
$linkPath = $null
$crtLibPath = $null

if ($vcToolsInstallDir) {
    $hostCandidates = @("Host$hostArchitecture") + @("Hostx64", "Hostx86", "HostArm64") |
        Select-Object -Unique
    foreach ($hostCandidate in $hostCandidates) {
        $candidate = Join-Path $vcToolsInstallDir "bin\$hostCandidate\$targetArchitecture\cl.exe"
        if (Test-Path -LiteralPath $candidate) {
            $clPath = $candidate
            $linkPath = Join-Path $vcToolsInstallDir "bin\$hostCandidate\$targetArchitecture\link.exe"
            break
        }
    }

    $crtLibPath = Join-Path $vcToolsInstallDir "lib\$targetArchitecture\libcpmt.lib"
}

if (-not $clPath) {
    $problems.Add("No cl.exe targeting $targetArchitecture was found under '$vcToolsInstallDir'. Install the MSVC $targetArchitecture build tools component.")
}
if ($linkPath -and -not (Test-Path -LiteralPath $linkPath)) {
    $problems.Add("cl.exe targeting $targetArchitecture exists but link.exe does not: '$linkPath'.")
}
if (-not $crtLibPath -or -not (Test-Path -LiteralPath $crtLibPath)) {
    $problems.Add("The $targetArchitecture C++ runtime import library is missing: '$crtLibPath'. A present lib\$targetArchitecture directory is not sufficient, it also holds architecture-specific sanitizer runtimes.")
}

$clInfo = $null
if ($clPath) {
    $clInfo = Get-ClVersion -ClPath $clPath
    if (-not $clInfo) {
        $problems.Add("'$clPath' did not report a parsable compiler banner.")
    }
    elseif ($clInfo.Target -and $clInfo.Target -notmatch "^$targetArchitecture$") {
        $problems.Add("'$clPath' reports target '$($clInfo.Target)' but '$targetArchitecture' was requested.")
    }
}

# ---------------------------------------------------------------------------
# 3. Reject stale library paths from a different toolset.
# ---------------------------------------------------------------------------
$foreignLibraryPaths = @()
if ($properties.LibraryPath -and $vcToolsVersion) {
    foreach ($entry in ($properties.LibraryPath -split ';' | Where-Object { $_ })) {
        if ($entry -match '\\VC\\Tools\\MSVC\\([0-9][^\\]*)\\' -and $Matches[1] -ne $vcToolsVersion) {
            $foreignLibraryPaths += $entry
        }
    }
}
foreach ($entry in $foreignLibraryPaths) {
    $problems.Add("LibraryPath leaks a different MSVC toolset than the selected $vcToolsVersion : '$entry'.")
}

# ---------------------------------------------------------------------------
# 4. Compare the MSBuild compiler identity with the compiler vcpkg used.
#    vcpkg records the compiler it probed in its compiler-detection logs; a
#    mismatch means the dependencies and the product are built by different
#    toolsets, which is what produced the ARM64 winnt.h failure.
# ---------------------------------------------------------------------------
$vcpkgCompilerVersion = $null
$vcpkgCompilerPath = $null
$vcpkgCompilerBannerVersion = $null
$vcpkgCompilerSource = $null
$vcpkgRoot = $env:VCPKG_ROOT
if (-not $vcpkgRoot) {
    $vcpkgRoot = Join-Path $env:LOCALAPPDATA "OpenCppCoverage\vcpkg"
}
$detectRoot = Join-Path $vcpkgRoot "buildtrees\detect_compiler"
if (Test-Path -LiteralPath $detectRoot) {
    $detectLog = Get-ChildItem -Path $detectRoot -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($detectLog) {
        $vcpkgCompilerSource = $detectLog.FullName
        $detectContent = Get-Content -LiteralPath $detectLog.FullName -Raw -ErrorAction SilentlyContinue
        # vcpkg records the exact compiler it probed, using forward slashes.
        if ($detectContent -match '#COMPILER_CXX_PATH#(.+)') {
            $vcpkgCompilerPath = $Matches[1].Trim()
        }
        if ($detectContent -match '#COMPILER_CXX_VERSION#([0-9][0-9.]*)') {
            $vcpkgCompilerBannerVersion = $Matches[1].Trim()
        }
        elseif ($detectContent -match 'CXX compiler identification is MSVC ([0-9][0-9.]*)') {
            $vcpkgCompilerBannerVersion = $Matches[1].Trim()
        }
        if ($vcpkgCompilerPath -match 'MSVC[\\/]([0-9][^\\/]*)[\\/]bin') {
            $vcpkgCompilerVersion = $Matches[1]
        }
    }
}

if ($vcpkgCompilerVersion -and $vcToolsVersion) {
    if ($vcpkgCompilerVersion -ne $vcToolsVersion) {
        $problems.Add("vcpkg built the dependencies with MSVC $vcpkgCompilerVersion but MSBuild selected MSVC $vcToolsVersion for $Configuration|$Platform. Align the toolsets before building (source: $vcpkgCompilerSource).")
    }
    elseif ($clPath -and $vcpkgCompilerPath) {
        # Same toolset version, so the compiler binaries must also match once
        # path separators are normalised.
        $normalisedVcpkg = ($vcpkgCompilerPath -replace '/', '\').TrimEnd()
        if (-not [string]::Equals($normalisedVcpkg, $clPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add("vcpkg used compiler '$normalisedVcpkg' but MSBuild resolved '$clPath' for $Configuration|$Platform.")
        }
    }
}
elseif ($RequireVcpkgComparison) {
    $problems.Add("The vcpkg compiler identity could not be determined and -RequireVcpkgComparison was specified.")
}
else {
    $warnings.Add("The vcpkg compiler identity could not be determined; the MSBuild/vcpkg comparison was skipped.")
}

# ---------------------------------------------------------------------------
# 5. Report.
# ---------------------------------------------------------------------------
$report = [ordered]@{
    Platform                    = $Platform
    Configuration               = $Configuration
    Project                     = $ProjectPath
    HostArchitecture            = $hostArchitecture
    TargetArchitecture          = $targetArchitecture
    OSArchitecture              = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    ProcessArchitecture         = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    MSBuildPath                 = $msbuildPath
    PlatformToolset             = $platformToolset
    DefaultPlatformToolset      = $properties.DefaultPlatformToolset
    VCToolsVersion              = $vcToolsVersion
    VCToolsInstallDir           = $vcToolsInstallDir
    WindowsSdkVersion           = $windowsSdk
    ClPath                      = $clPath
    ClVersion                   = if ($clInfo) { $clInfo.Version } else { $null }
    ClTarget                    = if ($clInfo) { $clInfo.Target } else { $null }
    ClBanner                    = if ($clInfo) { $clInfo.Banner } else { $null }
    LinkPath                    = $linkPath
    CrtImportLibrary            = $crtLibPath
    VcpkgCompilerVersion        = $vcpkgCompilerVersion
    VcpkgCompilerPath           = $vcpkgCompilerPath
    VcpkgCompilerBannerVersion  = $vcpkgCompilerBannerVersion
    VcpkgCompilerSource         = $vcpkgCompilerSource
    ForeignLibraryPaths         = $foreignLibraryPaths
    Warnings                    = $warnings.ToArray()
    Problems                    = $problems.ToArray()
    Succeeded                   = ($problems.Count -eq 0)
}

$reportPath = Join-Path $LogDirectory "toolchain-preflight-$Platform-$Configuration.json"
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8

foreach ($key in $report.Keys) {
    if ($key -in @("Warnings", "Problems")) { continue }
    Write-Host ("{0,-24}: {1}" -f $key, $report[$key])
}
foreach ($warning in $warnings) { Write-Warning $warning }

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host "TOOLCHAIN PROBLEM: $problem" }
    Write-Error "Toolchain preflight failed for $Configuration|$Platform with $($problems.Count) problem(s). Report: $reportPath"
    exit 1
}

Write-Host "Toolchain preflight succeeded. Report: $reportPath"
exit 0
