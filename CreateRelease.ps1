param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Release")]
    [string]$Configuration = "Release",

    [string]$OutputRoot = (Join-Path $PSScriptRoot "artifacts")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Build\Scripts\PeArchitecture.ps1")
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

$platformInfo = @{
    x86 = @{
        BuildPlatform = "Win32"
        BuildDirectory = $Configuration
        Triplet = "x86-windows"
        Slug = "x86"
        DiaDirectory = ""
    }
    x64 = @{
        BuildPlatform = "x64"
        BuildDirectory = "x64\$Configuration"
        Triplet = "x64-windows"
        Slug = "x64"
        DiaDirectory = "amd64"
    }
    ARM64 = @{
        BuildPlatform = "ARM64"
        BuildDirectory = "ARM64\$Configuration"
        Triplet = "arm64-windows"
        Slug = "arm64"
        DiaDirectory = "arm64"
    }
}[$Platform]

$version = "0.9.9.0"
$buildDirectory = Join-Path $PSScriptRoot $platformInfo.BuildDirectory
$installedDirectory = Join-Path $PSScriptRoot "vcpkg_installed\$($platformInfo.Triplet)"
$packageName = "OpenCppCoverage-$version-windows-$($platformInfo.Slug)"
$stageRoot = Join-Path $OutputRoot "staging\$packageName"
$binariesDirectory = Join-Path $stageRoot "Binaries"
$pdbDirectory = Join-Path $stageRoot "Pdb"
$licensesDirectory = Join-Path $stageRoot "licenses"
$zipPath = Join-Path $OutputRoot "$packageName.zip"
$expandedRoot = Join-Path $OutputRoot "expanded\$packageName"
$dependencyManifestPath = Join-Path $stageRoot "dependency-manifest.json"

if (-not (Test-Path $buildDirectory)) {
    throw "Build output does not exist: $buildDirectory"
}
if (-not (Test-Path $installedDirectory)) {
    throw "Vcpkg install tree does not exist: $installedDirectory"
}

foreach ($path in @($stageRoot, $expandedRoot)) {
    if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $binariesDirectory, $pdbDirectory, $licensesDirectory | Out-Null

$runtimeFiles = @(
    "OpenCppCoverage.exe",
    "CppCoverage.dll",
    "Exporter.dll",
    "FileFilter.dll",
    "Plugin.dll",
    "Tools.dll"
)
foreach ($file in $runtimeFiles) {
    $source = Join-Path $buildDirectory $file
    if (-not (Test-Path $source)) {
        throw "Required runtime file is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination $binariesDirectory
}

$dependencyBin = Join-Path $installedDirectory "bin"
if (Test-Path $dependencyBin) {
    Get-ChildItem -Path $dependencyBin -Filter *.dll -File | ForEach-Object {
        $outputCopy = Join-Path $buildDirectory $_.Name
        if (Test-Path $outputCopy) {
            Copy-Item -LiteralPath $outputCopy -Destination $binariesDirectory
        }
    }
}

$templateDirectory = Join-Path $buildDirectory "Template"
if (-not (Test-Path $templateDirectory)) {
    throw "HTML templates are missing: $templateDirectory"
}
Copy-Item -LiteralPath $templateDirectory -Destination $binariesDirectory -Recurse

$pluginsExportDirectory = Join-Path $binariesDirectory "Plugins\Exporter"
New-Item -ItemType Directory -Force -Path $pluginsExportDirectory | Out-Null
@(
    "Custom coverage exporter plugins are loaded from this folder."
    "Place exporter DLLs built for $Platform here; OpenCppCoverage requires this folder to exist."
) | Set-Content -Path (Join-Path $pluginsExportDirectory "README.txt") -Encoding utf8

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found."
}
$vsInstallRoot = & $vswhere -latest -products * -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsInstallRoot) {
    throw "Visual Studio installation could not be located."
}
$diaRoot = Join-Path $vsInstallRoot "DIA SDK\bin"
if ($platformInfo.DiaDirectory) {
    $diaRoot = Join-Path $diaRoot $platformInfo.DiaDirectory
}
$diaDll = Join-Path $diaRoot "msdia140.dll"
if (-not (Test-Path $diaDll)) {
    throw "DIA runtime is missing: $diaDll"
}
Copy-Item -LiteralPath $diaDll -Destination $binariesDirectory

$redistArchitecture = $platformInfo.Slug
$redistRoot = Join-Path $vsInstallRoot "VC\Redist\MSVC"
$crtDirectory = Get-ChildItem -Path $redistRoot -Directory |
    Sort-Object Name -Descending |
    ForEach-Object {
        Get-ChildItem -Path (Join-Path $_.FullName $redistArchitecture) `
            -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    } |
    Select-Object -First 1
if (-not $crtDirectory) {
    throw "The Microsoft VC $redistArchitecture runtime was not found under $redistRoot."
}
$crtStaged = @()
$crtRejected = @()
foreach ($crtDll in Get-ChildItem -Path $crtDirectory -Filter *.dll -File) {
    $crtMachine = Get-PeMachine -Path $crtDll.FullName
    if ($crtMachine.Architecture -eq $Platform) {
        Copy-Item -LiteralPath $crtDll.FullName -Destination $binariesDirectory
        $crtStaged += $crtDll.Name
    } else {
        $crtRejected += [pscustomobject]@{
            Name         = $crtDll.Name
            Architecture = $crtMachine.Architecture
            Machine      = $crtMachine.Machine
            Source       = $crtDll.FullName
        }
    }
}
if ($crtStaged.Count -eq 0) {
    throw "No $Platform CRT runtime DLL was found in $crtDirectory."
}
foreach ($required in @("vcruntime140.dll", "msvcp140.dll")) {
    if ($crtStaged -notcontains $required) {
        throw "The $Platform CRT runtime is incomplete: $required was not staged from $crtDirectory."
    }
}
if ($crtRejected.Count -gt 0) {
    Write-Warning "Rejected $($crtRejected.Count) non-$Platform CRT image(s) from $crtDirectory."
}

foreach ($project in @("OpenCppCoverage", "CppCoverage", "Exporter", "FileFilter", "Plugin", "Tools")) {
    $pdb = Join-Path $buildDirectory "$project.pdb"
    if (-not (Test-Path $pdb)) {
        throw "Required PDB is missing: $pdb"
    }
    Copy-Item -LiteralPath $pdb -Destination $pdbDirectory
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "LICENSE.txt") -Destination $licensesDirectory
Get-ChildItem -Path (Join-Path $installedDirectory "share") -Directory | ForEach-Object {
    $copyright = Join-Path $_.FullName "copyright"
    if (Test-Path $copyright) {
        Copy-Item -LiteralPath $copyright -Destination (Join-Path $licensesDirectory "$($_.Name).txt")
    }
}

$vcpkgRoot = if ($env:VCPKG_ROOT) {
    $env:VCPKG_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "OpenCppCoverage\vcpkg"
}
$vcpkg = Join-Path $vcpkgRoot "vcpkg.exe"
if (-not (Test-Path $vcpkg)) {
    throw "vcpkg.exe was not found: $vcpkg"
}
$dependencyOutput = & $vcpkg list "--x-install-root=$(Join-Path $PSScriptRoot 'vcpkg_installed')"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read the vcpkg dependency inventory."
}
$dependencies = @($dependencyOutput | ForEach-Object {
    if ($_ -match '^(?<Name>\S+):(?<Triplet>\S+)\s+(?<Version>\S+)\s*(?<Description>.*)$' -and
        $Matches.Triplet -eq $platformInfo.Triplet) {
        [pscustomobject]@{
            Name = $Matches.Name
            Version = $Matches.Version
            Triplet = $Matches.Triplet
            Description = $Matches.Description
        }
    }
})
if (-not $dependencies) {
    throw "No installed dependencies were found for $($platformInfo.Triplet)."
}
$dependencies |
    Sort-Object Name |
    ConvertTo-Json |
    Set-Content -Path $dependencyManifestPath -Encoding utf8

$crtManifestPath = Join-Path $stageRoot "crt-manifest.json"
[pscustomobject]@{
    Source       = $crtDirectory
    Architecture = $Platform
    Staged       = @($crtStaged | Sort-Object)
    NotStaged    = @($crtRejected | Sort-Object Name)
} | ConvertTo-Json -Depth 4 | Set-Content -Path $crtManifestPath -Encoding utf8

$stageScan = Assert-PeArchitecture -Path $stageRoot -ExpectedArchitecture $Platform
$stageScan |
    Select-Object @{Name="Path"; Expression={ $_.Path.Substring($stageRoot.Length + 1) }}, Machine, Architecture |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $stageRoot "pe-manifest.json") -Encoding utf8

$manifest = Get-ChildItem -Path $stageRoot -Recurse -File |
    Where-Object { $_.Name -ne "file-manifest.json" } |
    Sort-Object FullName |
    ForEach-Object {
        [pscustomobject]@{
            Path = $_.FullName.Substring($stageRoot.Length + 1)
            Size = $_.Length
            Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
$manifest |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $stageRoot "file-manifest.json") -Encoding utf8

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal

New-Item -ItemType Directory -Force -Path $expandedRoot | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $expandedRoot
$expandedManifestPath = Join-Path $expandedRoot "file-manifest.json"
if (-not (Test-Path $expandedManifestPath)) {
    throw "The expanded package is missing file-manifest.json."
}
$expandedManifest = @(Get-Content -Raw $expandedManifestPath | ConvertFrom-Json)
$expandedFiles = @(Get-ChildItem -Path $expandedRoot -Recurse -File |
    Where-Object { $_.FullName -ne $expandedManifestPath })
if ($expandedFiles.Count -ne $expandedManifest.Count) {
    throw "Expanded package file count does not match file-manifest.json."
}
foreach ($entry in $expandedManifest) {
    $expandedFile = Join-Path $expandedRoot $entry.Path
    if (-not (Test-Path -LiteralPath $expandedFile -PathType Leaf)) {
        throw "Expanded package file is missing: $($entry.Path)"
    }
    $file = Get-Item -LiteralPath $expandedFile
    $hash = (Get-FileHash -LiteralPath $expandedFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($file.Length -ne $entry.Size -or $hash -ne $entry.Sha256) {
        throw "Expanded package file does not match its manifest: $($entry.Path)"
    }
}
$expandedScan = Assert-PeArchitecture -Path $expandedRoot -ExpectedArchitecture $Platform
$expandedScan |
    Select-Object @{Name="Path"; Expression={ $_.Path.Substring($expandedRoot.Length + 1) }}, Machine, Architecture |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $OutputRoot "$packageName-expanded-pe-manifest.json") -Encoding utf8

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = "$zipPath.sha256"
"$zipHash  $([IO.Path]::GetFileName($zipPath))" |
    Set-Content -Path $checksumPath -Encoding ascii

[pscustomobject]@{
    Package = $zipPath
    Size = (Get-Item $zipPath).Length
    Sha256 = $zipHash
    Checksum = $checksumPath
    Staging = $stageRoot
    Expanded = $expandedRoot
    PeImageCount = $stageScan.Count
    FileCount = $manifest.Count
    DependencyCount = $dependencies.Count
    CrtSource = $crtDirectory
    CrtStaged = @($crtStaged | Sort-Object)
    CrtNotStaged = @($crtRejected | Sort-Object Name)
} | ConvertTo-Json -Depth 4
