<#
.SYNOPSIS
Resolves the MSBuild executable for a requested host architecture and, when
possible, proves which C++ tool architecture MSBuild will actually evaluate.

.DESCRIPTION
`microsoft/setup-msbuild` puts the 32-bit MSBuild on PATH. On the ARM64 runner
that matters: Microsoft.Cpp.Common.props only selects the native ARM64 compiler
when `PreferredToolArchitecture` is `arm64` AND the ARM64 tools are detected,
and a 32-bit MSBuild host quietly lands on `bin\HostX86\arm64` instead. The
build still succeeds, so nothing surfaces the discrepancy.

Passing `/p:PreferredToolArchitecture` alone was not sufficient. This script
selects the MSBuild binary that matches the requested host architecture and
fails closed when it is missing, rather than silently falling back.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$HostArchitecture,

    [string]$Project,

    [string]$Configuration,

    [string]$Platform,

    [string]$SummaryPath,

    [string]$EnvironmentVariable = 'MSBUILD_EXE'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedToolArchitecture = @{
    'x86'   = 'Native32Bit'
    'x64'   = 'Native64Bit'
    'arm64' = 'NativeARM64'
}[$HostArchitecture]

# The MSBuild binary lives in a differently named directory per host.
$binSubdirectory = @{
    'x86'   = '.'
    'x64'   = 'amd64'
    'arm64' = 'arm64'
}[$HostArchitecture]

function Get-VisualStudioInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        $vswhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe was not found; cannot resolve a Visual Studio installation."
    }

    $paths = & $vswhere -latest -prerelease -products * `
        -requires Microsoft.Component.MSBuild -property installationPath
    if ($LASTEXITCODE -ne 0) {
        throw "vswhere.exe failed with exit code $LASTEXITCODE."
    }

    $installPath = @($paths | Where-Object { $_ }) | Select-Object -First 1
    if (-not $installPath) {
        throw "No Visual Studio installation with MSBuild was found."
    }
    return $installPath
}

$installPath = Get-VisualStudioInstallPath
$binRoot = Join-Path $installPath 'MSBuild\Current\Bin'
$candidate = if ($binSubdirectory -eq '.') {
    Join-Path $binRoot 'MSBuild.exe'
} else {
    Join-Path $binRoot (Join-Path $binSubdirectory 'MSBuild.exe')
}

if (-not (Test-Path -LiteralPath $candidate)) {
    $present = @()
    if (Test-Path -LiteralPath $binRoot) {
        $present = @(
            Get-ChildItem -LiteralPath $binRoot -Recurse -Depth 1 -Filter 'MSBuild.exe' `
                -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        )
    }
    throw ("A $HostArchitecture MSBuild was required but '$candidate' does not exist. " +
        "Refusing to fall back to a different host architecture, because that is " +
        "exactly the substitution this check exists to catch. MSBuild hosts present " +
        "under '$binRoot': " + $(if ($present) { $present -join '; ' } else { '<none>' }))
}

$msbuild = (Resolve-Path -LiteralPath $candidate).Path
$versionOutput = & $msbuild -nologo -version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to run '$msbuild'."
}
$version = @($versionOutput | Where-Object { $_ -match '^\d+\.\d+' }) | Select-Object -First 1

$summary = [ordered]@{
    HostArchitecture         = $HostArchitecture
    MSBuild                  = $msbuild
    MSBuildVersion           = "$version".Trim()
    VisualStudio             = $installPath
    ExpectedToolArchitecture = $expectedToolArchitecture
    EvaluatedProperties      = $null
    PropertyQuery            = 'not-requested'
}

Write-Output "MSBuild ($HostArchitecture): $msbuild"
Write-Output "MSBuild version: $($summary.MSBuildVersion)"

# -getProperty arrived in MSBuild 17.8. When it is available it reports what
# MSBuild actually evaluates, which is far stronger evidence than inspecting
# the props files by hand.
if ($Project) {
    $supportsGetProperty = $false
    $parsedVersion = $null
    if ([Version]::TryParse(("$version".Trim() -split '-')[0], [ref]$parsedVersion)) {
        $supportsGetProperty = $parsedVersion -ge [Version]'17.8'
    }

    if (-not $supportsGetProperty) {
        $summary.PropertyQuery = "unsupported (MSBuild $($summary.MSBuildVersion) predates -getProperty)"
        Write-Warning ("MSBuild $($summary.MSBuildVersion) cannot report evaluated properties. " +
            "The post-build toolchain assertion remains the authoritative gate.")
    } else {
        $names = @(
            'PreferredToolArchitecture'
            'VCToolArchitecture'
            'VCToolsInstallDir'
            'VCToolsVersion'
            'WindowsTargetPlatformVersion'
            'ExecutablePath'
        )
        $arguments = @(
            $Project
            "-p:PreferredToolArchitecture=$HostArchitecture"
            "-getProperty:$($names -join ',')"
            '-nologo'
        )
        if ($Configuration) { $arguments += "-p:Configuration=$Configuration" }
        if ($Platform) { $arguments += "-p:Platform=$Platform" }

        $raw = & $msbuild @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to evaluate properties for '$Project':`n$($raw -join "`n")"
        }

        $properties = ($raw -join "`n" | ConvertFrom-Json).Properties
        $summary.EvaluatedProperties = $properties
        $summary.PropertyQuery = 'ok'

        foreach ($name in $names) {
            Write-Output ("  {0,-28} {1}" -f $name, $properties.$name)
        }

        if ($properties.VCToolArchitecture -ne $expectedToolArchitecture) {
            throw ("MSBuild evaluates VCToolArchitecture as " +
                "'$($properties.VCToolArchitecture)' but '$expectedToolArchitecture' was " +
                "required for host '$HostArchitecture'. PreferredToolArchitecture evaluated " +
                "to '$($properties.PreferredToolArchitecture)'. The compiler that would run " +
                "is not the one that was verified.")
        }
    }
}

if ($SummaryPath) {
    $directory = Split-Path -Parent $SummaryPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}

if ($env:GITHUB_ENV -and $EnvironmentVariable) {
    "$EnvironmentVariable=$msbuild" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding UTF8
}

Write-Output "Resolved $expectedToolArchitecture MSBuild host."
