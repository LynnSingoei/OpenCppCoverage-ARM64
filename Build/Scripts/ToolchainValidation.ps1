Set-StrictMode -Version Latest

function Assert-RequiredToolchainFiles {
    param(
        [Parameter(Mandatory)]
        [string]$ClPath,

        [Parameter(Mandatory)]
        [string]$LinkPath,

        [Parameter(Mandatory)]
        [string]$CrtLibraryPath,

        [Parameter(Mandatory)]
        [ValidateSet("x86", "x64", "arm64")]
        [string]$TargetArchitecture
    )

    foreach ($requiredFile in @($ClPath, $LinkPath, $CrtLibraryPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required $TargetArchitecture toolchain file is missing: $requiredFile"
        }
    }

    if ($TargetArchitecture -eq "arm64") {
        foreach ($path in @($ClPath, $LinkPath, $CrtLibraryPath)) {
            if ($path -notmatch '(?i)\\arm64\\') {
                throw "ARM64 toolchain path does not target ARM64: $path"
            }
            if ($path -match '(?i)\\x64\\') {
                throw "ARM64 toolchain path contains an x64 target segment: $path"
            }
        }
    }
}

function Assert-CoherentEnvironmentPaths {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string]$VCToolsVersion,

        [Parameter(Mandatory)]
        [string]$WindowsSdkVersion,

        [Parameter(Mandatory)]
        [ValidateSet("x86", "x64", "arm64")]
        [string]$TargetArchitecture
    )

    foreach ($path in $Paths | Where-Object { $_ }) {
        if ($path -match '(?i)\\VC\\Tools\\MSVC\\(?<Version>[^\\]+)\\' -and
            $Matches.Version -ne $VCToolsVersion) {
            throw "Mixed MSVC root in INCLUDE/LIB: $path"
        }
        if ($path -match '(?i)\\Windows Kits\\10\\(?:Include|Lib)\\(?<Version>[^\\]+)\\' -and
            $Matches.Version -ne $WindowsSdkVersion) {
            throw "Mixed Windows SDK root in INCLUDE/LIB: $path"
        }
        if ($TargetArchitecture -eq "arm64" -and
            $path -match '(?i)\\(?:lib|bin)\\(?:x64|x86)(?:\\|$)') {
            throw "ARM64 environment contains a non-ARM64 target path: $path"
        }
    }
}
