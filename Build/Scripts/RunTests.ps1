param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PSNativeCommandUseErrorActionPreference = $false
$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot "PeArchitecture.ps1")
. (Join-Path $PSScriptRoot "TestResults.ps1")
$outputDirectory = switch ($Platform) {
    "x86" { Join-Path $repositoryRoot $Configuration }
    "x64" { Join-Path $repositoryRoot "x64\$Configuration" }
    "ARM64" { Join-Path $repositoryRoot "ARM64\$Configuration" }
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$cppCoverageExclusions = @("CodeCoverageRunnerTest.OptimizedBuild")
if ($Platform -eq "x86") {
    $cppCoverageExclusions += "CppCliTest.ManagedUnManagedModule"
}
$requiredFixtures = @()
if ($Platform -in @("x64", "ARM64")) {
    $requiredFixtures += "DefaultTest.dll"
}
@(
    "OS=$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    "OSArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    "ProcessArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
    "TestArchitecture=$Platform"
    "ExcludedTests=$($cppCoverageExclusions -join ',')"
    "RequiredFixtures=$($requiredFixtures -join ',')"
) | Set-Content -Path (Join-Path $LogDirectory "environment-$Platform-$Configuration.txt")

$outputScan = Assert-PeArchitecture -Path $outputDirectory -ExpectedArchitecture $Platform
$outputScan |
    Select-Object @{Name="Path"; Expression={
        $_.Path.Substring($outputDirectory.Length + 1)
    }}, Machine, Architecture |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $LogDirectory "pe-$Platform-$Configuration.json") -Encoding utf8

$requiredSuites = @(
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

$results = [System.Collections.Generic.List[object]]::new()
foreach ($test in $requiredSuites) {
    $executable = Join-Path $outputDirectory "$($test.Name).exe"
    if (-not (Test-Path $executable)) {
        $results.Add((ConvertFrom-GTestOutput `
            -Suite $test.Name -Output "" -ExitCode -1 -Present $false))
        continue
    }

    $logPath = Join-Path $LogDirectory "$($test.Name)-$Platform-$Configuration.log"
    & $executable @($test.Arguments) 2>&1 | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE
    $output = Get-Content -LiteralPath $logPath -Raw
    $results.Add((ConvertFrom-GTestOutput `
        -Suite $test.Name -Output $output -ExitCode $exitCode))
}

$summaryPath = Join-Path $LogDirectory "test-summary-$Platform-$Configuration.json"
$results | ConvertTo-Json -Depth 4 | Set-Content -Path $summaryPath -Encoding utf8
$results | Format-Table Suite, Present, ExitCode, Ran, Passed, Failed -AutoSize

$failures = @(Get-TestResultFailures `
    -Results @($results) `
    -RequiredSuites @($requiredSuites | ForEach-Object Name))
$failures += @(Get-RequiredArtifactFailures `
    -Root $outputDirectory `
    -RequiredArtifacts $requiredFixtures)
if ($failures.Count -gt 0) {
    throw "Native test gate failed:`n - $($failures -join "`n - ")"
}
