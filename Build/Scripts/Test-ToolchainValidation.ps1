$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ToolchainValidation.ps1")

function Assert-Fails {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$Expected
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
            throw "Expected '$Expected', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected failure containing '$Expected', but the action succeeded."
}

$testRoot = Join-Path $PSScriptRoot "..\..\artifacts\script-tests\toolchain-layout"
try {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    $compilerDirectory = Join-Path $testRoot "bin\Hostarm64\arm64"
    $libraryDirectory = Join-Path $testRoot "lib\arm64"
    New-Item -ItemType Directory -Force $compilerDirectory, $libraryDirectory | Out-Null

    $cl = Join-Path $compilerDirectory "cl.exe"
    $link = Join-Path $compilerDirectory "link.exe"
    $crt = Join-Path $libraryDirectory "libcpmt.lib"
    Set-Content -LiteralPath (Join-Path $libraryDirectory "clang_rt.asan_dynamic-aarch64.lib") `
        -Value "sanitizer-only"

    Assert-Fails {
        Assert-RequiredToolchainFiles $cl $link $crt "arm64"
    } "Required arm64 toolchain file is missing"

    Set-Content -LiteralPath $cl -Value "compiler"
    Set-Content -LiteralPath $link -Value "linker"
    Set-Content -LiteralPath $crt -Value "crt"
    Assert-RequiredToolchainFiles $cl $link $crt "arm64"

    Assert-Fails {
        Assert-CoherentEnvironmentPaths `
            -Paths @("C:\VS\VC\Tools\MSVC\14.29.30133\include") `
            -VCToolsVersion "14.44.35207" `
            -WindowsSdkVersion "10.0.26100.0" `
            -TargetArchitecture "arm64"
    } "Mixed MSVC root"

    Assert-Fails {
        Assert-CoherentEnvironmentPaths `
            -Paths @("C:\Windows Kits\10\Lib\10.0.22621.0\um\arm64") `
            -VCToolsVersion "14.44.35207" `
            -WindowsSdkVersion "10.0.26100.0" `
            -TargetArchitecture "arm64"
    } "Mixed Windows SDK root"

    Assert-Fails {
        Assert-CoherentEnvironmentPaths `
            -Paths @("C:\VS\VC\Tools\MSVC\14.44.35207\lib\x64") `
            -VCToolsVersion "14.44.35207" `
            -WindowsSdkVersion "10.0.26100.0" `
            -TargetArchitecture "arm64"
    } "non-ARM64 target path"
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$assertScript = Join-Path $PSScriptRoot "Assert-BuildToolchain.ps1"
$logRoot = Join-Path $PSScriptRoot "..\..\artifacts\script-tests\build-toolchain"
New-Item -ItemType Directory -Force $logRoot | Out-Null
try {
    function Assert-BuildLogResult {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string[]]$Lines,

            [Parameter(Mandatory)]
            [int]$ExpectedExitCode
        )

        $logPath = Join-Path $logRoot "$Name.log"
        Set-Content -LiteralPath $logPath -Value $Lines
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & pwsh -NoProfile -File $assertScript `
            -BuildLog $logPath -ExpectedHost Hostarm64 *> $null
        $actualExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction
        if ($actualExitCode -ne $ExpectedExitCode) {
            throw "Build-toolchain case '$Name' exited $actualExitCode; expected $ExpectedExitCode."
        }
    }

    $nativeCl =
        "C:\VS\VC\Tools\MSVC\14.44.35207\bin\Hostarm64\arm64\cl.exe /c fixture.cpp"
    $nativeLink =
        "C:\VS\VC\Tools\MSVC\14.44.35207\bin\Hostarm64\arm64\link.exe fixture.obj"
    Assert-BuildLogResult native @($nativeCl, $nativeLink) 0
    Assert-BuildLogResult wrong-host @(
        "C:\VS\VC\Tools\MSVC\14.44.35207\bin\HostX86\arm64\cl.exe /c fixture.cpp",
        $nativeLink
    ) 1
    Assert-BuildLogResult empty @("Build succeeded without command lines.") 1
    Assert-BuildLogResult mixed-version @(
        $nativeCl,
        "C:\VS\VC\Tools\MSVC\14.45.00000\bin\Hostarm64\arm64\link.exe fixture.obj"
    ) 1
} finally {
    Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "All toolchain validation regression cases passed."
