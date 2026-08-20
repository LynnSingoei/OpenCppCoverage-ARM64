param(
    [Parameter(Mandatory)]
    [ValidateSet("Win32", "x64", "ARM64")]
    [string]$Platform,

    [ValidateSet("v143")]
    [string]$PlatformToolset = "v143",

    [string]$RequiredVCToolsVersion = "14.44.35207",

    [string]$RequiredWindowsSdkVersion = "10.0.26100.0",

    [Parameter(Mandatory)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ToolchainValidation.ps1")

$requestedVcpkgRoot = if ($env:VCPKG_ROOT -and
    (Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT ".git"))) {
    $env:VCPKG_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "OpenCppCoverage\vcpkg"
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere.exe was not found: $vswhere"
}

$component = if ($Platform -eq "ARM64") {
    "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
} else {
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
}
$vsRoot = & $vswhere -latest -products * -requires $component -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsRoot) {
    throw "Visual Studio with $component could not be located."
}
$env:PATH = "$(Split-Path -Parent $vswhere);$env:PATH"

$targetArchitecture = @{
    Win32 = "x86"
    x64 = "x64"
    ARM64 = "arm64"
}[$Platform]
$hostArchitecture =
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") {
        "arm64"
    } else {
        "x64"
    }
$vsDevCmd = Join-Path $vsRoot "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) {
    throw "VsDevCmd.bat was not found: $vsDevCmd"
}

Remove-Item Env:LIB, Env:LIBPATH, Env:INCLUDE -ErrorAction SilentlyContinue
$environmentCommand = "set LIB=& set LIBPATH=& set INCLUDE=& " +
    "call `"$vsDevCmd`" -no_logo -arch=$targetArchitecture -host_arch=$hostArchitecture " +
    "-vcvars_ver=$RequiredVCToolsVersion -winsdk=$RequiredWindowsSdkVersion >nul && set"
$environmentOutput = & $env:ComSpec /d /c $environmentCommand
if ($LASTEXITCODE -ne 0) {
    throw "VsDevCmd failed for MSVC $RequiredVCToolsVersion, SDK $RequiredWindowsSdkVersion, host $hostArchitecture, target $targetArchitecture."
}
foreach ($line in $environmentOutput) {
    $separator = $line.IndexOf("=")
    if ($separator -gt 0) {
        Set-Item -Path "Env:$($line.Substring(0, $separator))" `
            -Value $line.Substring($separator + 1)
    }
}
$env:VCPKG_ROOT = $requestedVcpkgRoot

foreach ($name in @(
    "VCToolsVersion", "VCToolsInstallDir", "WindowsSDKVersion",
    "WindowsSdkDir", "INCLUDE", "LIB"
)) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "$name was not initialized by VsDevCmd."
    }
}

$toolsVersion = $env:VCToolsVersion.TrimEnd("\")
if ($toolsVersion -ne $RequiredVCToolsVersion) {
    throw "Expected VCToolsVersion $RequiredVCToolsVersion, resolved $toolsVersion."
}
$expectedToolsRoot = [IO.Path]::GetFullPath(
    (Join-Path $vsRoot "VC\Tools\MSVC\$RequiredVCToolsVersion")).TrimEnd("\")
$actualToolsRoot = [IO.Path]::GetFullPath($env:VCToolsInstallDir).TrimEnd("\")
if (-not $actualToolsRoot.Equals(
        $expectedToolsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "VCToolsInstallDir '$actualToolsRoot' does not match '$expectedToolsRoot'."
}

$compilerDirectory = Join-Path $expectedToolsRoot "bin\Host$hostArchitecture\$targetArchitecture"
$expectedCl = Join-Path $compilerDirectory "cl.exe"
$expectedLink = Join-Path $compilerDirectory "link.exe"
$crtLibrary = Join-Path $expectedToolsRoot "lib\$targetArchitecture\libcpmt.lib"
Assert-RequiredToolchainFiles $expectedCl $expectedLink $crtLibrary $targetArchitecture

$clPath = @(Get-Command cl.exe -CommandType Application -ErrorAction Stop)[0].Source
$linkPath = @(Get-Command link.exe -CommandType Application -ErrorAction Stop)[0].Source
foreach ($resolved in @(
    @{ Name = "cl.exe"; Actual = $clPath; Expected = $expectedCl },
    @{ Name = "link.exe"; Actual = $linkPath; Expected = $expectedLink }
)) {
    if (-not [IO.Path]::GetFullPath($resolved.Actual).Equals(
            [IO.Path]::GetFullPath($resolved.Expected),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$($resolved.Name) resolved to '$($resolved.Actual)', expected '$($resolved.Expected)'."
    }
}

$sdkVersion = $env:WindowsSDKVersion.TrimEnd("\")
if ($sdkVersion -ne $RequiredWindowsSdkVersion) {
    throw "Expected Windows SDK $RequiredWindowsSdkVersion, resolved $sdkVersion."
}
$sdkRoot = [IO.Path]::GetFullPath($env:WindowsSdkDir).TrimEnd("\")
$requiredSdkFiles = @(
    (Join-Path $sdkRoot "Include\$sdkVersion\um\Windows.h"),
    (Join-Path $sdkRoot "Lib\$sdkVersion\um\$targetArchitecture\kernel32.lib"),
    (Join-Path $sdkRoot "Lib\$sdkVersion\ucrt\$targetArchitecture\ucrt.lib")
)
foreach ($sdkFile in $requiredSdkFiles) {
    if (-not (Test-Path -LiteralPath $sdkFile -PathType Leaf)) {
        throw "Required Windows SDK file is missing: $sdkFile"
    }
}

$environmentPaths = @($env:INCLUDE, $env:LIB) -split ";"
Assert-CoherentEnvironmentPaths `
    -Paths $environmentPaths `
    -VCToolsVersion $toolsVersion `
    -WindowsSdkVersion $sdkVersion `
    -TargetArchitecture $targetArchitecture

$clVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($clPath)
$linkVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($linkPath)
$clProductVersion = $clVersion.ProductVersion
$linkProductVersion = $linkVersion.ProductVersion
if ($clProductVersion -ne $linkProductVersion) {
    throw "cl.exe version $clProductVersion does not match link.exe version $linkProductVersion."
}
$toolsetMajorMinor = ($RequiredVCToolsVersion -split "\.")[0..1] -join "."
if (-not $clProductVersion.StartsWith(
        "$toolsetMajorMinor.", [StringComparison]::Ordinal)) {
    throw "Compiler/linker version $clProductVersion does not belong to VCToolsVersion $RequiredVCToolsVersion."
}
$compilerBanner = (& $clPath /Bv 2>&1) -join [Environment]::NewLine
if ($compilerBanner -notmatch "Compiler Passes:|Compiler Version") {
    throw "cl.exe /Bv did not report a valid compiler identity."
}

$asanFiles = @(
    Get-ChildItem (Join-Path $expectedToolsRoot "lib\$targetArchitecture") `
        -Filter "clang_rt.asan*" -File -ErrorAction SilentlyContinue
)
$log = @(
    "Platform=$Platform"
    "PlatformToolset=$PlatformToolset"
    "HostArchitecture=$hostArchitecture"
    "TargetArchitecture=$targetArchitecture"
    "VisualStudioRoot=$vsRoot"
    "VCToolsVersion=$toolsVersion"
    "VCToolsInstallDir=$actualToolsRoot"
    "cl.exe basename=$([IO.Path]::GetFileName($clPath))"
    "cl.exe path=$clPath"
    "cl.exe FileVersion=$($clVersion.FileVersion)"
    "cl.exe ProductVersion=$($clVersion.ProductVersion)"
    "link.exe basename=$([IO.Path]::GetFileName($linkPath))"
    "link.exe path=$linkPath"
    "link.exe FileVersion=$($linkVersion.FileVersion)"
    "link.exe ProductVersion=$($linkVersion.ProductVersion)"
    "WindowsSdkDir=$sdkRoot"
    "WindowsSDKVersion=$sdkVersion"
    "ARM64 cl.exe=$(if ($Platform -eq 'ARM64') { $clPath } else { 'not requested' })"
    "ARM64 CRT=$(if ($Platform -eq 'ARM64') { $crtLibrary } else { 'not requested' })"
    "ASAN runtime file count=$($asanFiles.Count)"
    "VCPKG_ROOT=$env:VCPKG_ROOT"
    "LIB=$env:LIB"
    "LIBPATH=$env:LIBPATH"
    "INCLUDE=$env:INCLUDE"
    ""
    "cl.exe /Bv:"
    $compilerBanner
)

$logDirectory = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$log | Tee-Object -FilePath $LogPath
$global:LASTEXITCODE = 0
