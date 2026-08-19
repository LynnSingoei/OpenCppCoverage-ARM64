param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs")
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot "PeArchitecture.ps1")
$outputDirectory = switch ($Platform) {
    "x86" { Join-Path $repositoryRoot $Configuration }
    "x64" { Join-Path $repositoryRoot "x64\$Configuration" }
    "ARM64" { Join-Path $repositoryRoot "ARM64\$Configuration" }
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$cppCoverageExclusions = @("CodeCoverageRunnerTest.OptimizedBuild")
if ($Platform -in @("x86", "ARM64")) {
    $cppCoverageExclusions += "CppCliTest.ManagedUnManagedModule"
}
@(
    "OS=$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    "OSArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    "ProcessArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
    "TestArchitecture=$Platform"
    "ExcludedTests=$($cppCoverageExclusions -join ',')"
) | Set-Content -Path (Join-Path $LogDirectory "environment-$Platform-$Configuration.txt")

$outputScan = Assert-PeArchitecture -Path $outputDirectory -ExpectedArchitecture $Platform
$outputScan |
    Select-Object @{Name="Path"; Expression={
        $_.Path.Substring($outputDirectory.Length + 1)
    }}, Machine, Architecture |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $LogDirectory "pe-$Platform-$Configuration.json") -Encoding utf8

$tests = @(
    @{
        Name = "CppCoverageTest"
        Arguments = @("--gtest_filter=-$($cppCoverageExclusions -join ':')")
    },
    @{ Name = "ExporterTest"; Arguments = @() },
    @{ Name = "FileFilterTest"; Arguments = @() },
    @{ Name = "OpenCppCoverageTest"; Arguments = @() },
    @{ Name = "PluginTest"; Arguments = @() },
    @{ Name = "ToolsTest"; Arguments = @() }
)

foreach ($test in $tests) {
    $executable = Join-Path $outputDirectory "$($test.Name).exe"
    if (-not (Test-Path $executable)) {
        throw "Test executable is missing: $executable"
    }

    $logPath = Join-Path $LogDirectory "$($test.Name)-$Platform-$Configuration.log"
    & $executable @($test.Arguments) 2>&1 | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$($test.Name) failed with exit code $exitCode. See $logPath."
    }
}
