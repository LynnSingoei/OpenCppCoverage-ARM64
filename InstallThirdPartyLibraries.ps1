param(
    [ValidateSet("x86-windows", "x64-windows", "arm64-windows")]
    [string]$Triplet = "x64-windows"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Build\Scripts\ToolchainValidation.ps1")
$requiredVCToolsVersion = "14.44.35207"
$requiredWindowsSdkVersion = "10.0.26100.0"
$requiredToolchainVariables = @(
    "VCToolsInstallDir",
    "VCToolsVersion",
    "WindowsSdkDir",
    "WindowsSDKVersion",
    "INCLUDE",
    "LIB"
)
foreach ($name in $requiredToolchainVariables) {
    if (-not [Environment]::GetEnvironmentVariable($name, "Process")) {
        throw "The coherent MSVC environment is not initialized: $name is missing."
    }
}
$vcToolsVersion = $env:VCToolsVersion.TrimEnd("\")
if ($vcToolsVersion -ne $requiredVCToolsVersion) {
    throw "Dependency restore requires VCToolsVersion $requiredVCToolsVersion; got $vcToolsVersion."
}
$windowsSdkVersion = $env:WindowsSDKVersion.TrimEnd("\")
if ($windowsSdkVersion -ne $requiredWindowsSdkVersion) {
    throw "Dependency restore requires Windows SDK $requiredWindowsSdkVersion; got $windowsSdkVersion."
}
$resolvedCl = @(Get-Command cl.exe -CommandType Application)[0].Source
$resolvedLink = @(Get-Command link.exe -CommandType Application)[0].Source
$vcToolsRoot = [IO.Path]::GetFullPath($env:VCToolsInstallDir).TrimEnd("\")
foreach ($tool in @($resolvedCl, $resolvedLink)) {
    if (-not [IO.Path]::GetFullPath($tool).StartsWith(
            $vcToolsRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "'$tool' is outside VCToolsInstallDir '$vcToolsRoot'."
    }
}
$targetArchitecture = @{
    "x86-windows" = "x86"
    "x64-windows" = "x64"
    "arm64-windows" = "arm64"
}[$Triplet]
Assert-CoherentEnvironmentPaths `
    -Paths (@($env:INCLUDE, $env:LIB) -split ";") `
    -VCToolsVersion $vcToolsVersion `
    -WindowsSdkVersion $windowsSdkVersion `
    -TargetArchitecture $targetArchitecture
$vcpkgCommit = "06d00ffa491e4668627728f14b891d22c6fea146"
$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$vcpkgRoot = if ($env:VCPKG_ROOT) {
    $env:VCPKG_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "OpenCppCoverage\vcpkg"
}

# Vcpkg uses Git work trees internally; force long-path support for those
# child processes without modifying the user's global Git configuration.
$env:GIT_CONFIG_COUNT = "1"
$env:GIT_CONFIG_KEY_0 = "core.longpaths"
$env:GIT_CONFIG_VALUE_0 = "true"

if (-not (Test-Path (Join-Path $vcpkgRoot ".git"))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vcpkgRoot) | Out-Null
    git -c core.longpaths=true clone --filter=blob:none https://github.com/microsoft/vcpkg.git $vcpkgRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone vcpkg."
    }
}

git -C $vcpkgRoot config core.longpaths true
if ($LASTEXITCODE -ne 0) {
    throw "Failed to enable long path support for vcpkg."
}

git -C $vcpkgRoot fetch --depth 1 origin $vcpkgCommit
if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch pinned vcpkg commit $vcpkgCommit."
}

git -C $vcpkgRoot checkout --detach $vcpkgCommit
if ($LASTEXITCODE -ne 0) {
    throw "Failed to check out pinned vcpkg commit $vcpkgCommit."
}

& (Join-Path $vcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
if ($LASTEXITCODE -ne 0) {
    throw "Failed to bootstrap vcpkg."
}

$hostTriplet = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") {
    "arm64-windows"
} else {
    "x64-windows"
}

& (Join-Path $vcpkgRoot "vcpkg.exe") install `
    "--triplet=$Triplet" `
    "--host-triplet=$hostTriplet" `
    "--x-manifest-root=$repositoryRoot"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to restore vcpkg dependencies for $Triplet."
}

$env:VCPKG_ROOT = $vcpkgRoot
if ($env:GITHUB_ENV) {
    "VCPKG_ROOT=$vcpkgRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Output "VCPKG_ROOT=$vcpkgRoot"
Write-Output "DependencyToolchain=$vcToolsVersion"
Write-Output "DependencyCompiler=$resolvedCl"
Write-Output "DependencyLinker=$resolvedLink"
Write-Output "DependencyWindowsSDK=$windowsSdkVersion"