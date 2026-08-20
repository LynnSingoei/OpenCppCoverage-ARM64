param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs"),

    # Test-only switch used by the fail-closed regression to prove that a
    # failing suite really does fail this script and therefore the CI job.
    [string]$InjectFailureIn = ""
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot "PeArchitecture.ps1")
. (Join-Path $PSScriptRoot "TestSummary.ps1")

$outputDirectory = switch ($Platform) {
    "x86" { Join-Path $repositoryRoot $Configuration }
    "x64" { Join-Path $repositoryRoot "x64\$Configuration" }
    "ARM64" { Join-Path $repositoryRoot "ARM64\$Configuration" }
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

# Every exclusion must carry an explicit justification. Silent skipping is what
# allowed a previous run to look green while tests were not executed.
$testExclusions = @(
    [pscustomobject]@{
        Test      = "CodeCoverageRunnerTest.OptimizedBuild"
        Platforms = @("x86", "x64", "ARM64")
        Reason    = "Depends on the checked-in OptimizedBuildVS2013 x86 fixture, which is not rebuilt for other toolsets or architectures."
    },
    [pscustomobject]@{
        Test      = "CppCliTest.ManagedUnManagedModule"
        Platforms = @("x86", "ARM64")
        Reason    = "Requires the C++/CLI TestCppCli assembly. MSVC does not support /clr for ARM64 targets, so no ARM64 managed module can exist."
    }
)

$projectExclusions = @(
    [pscustomobject]@{
        Project   = "TestCppCli"
        Platforms = @("ARM64")
        Reason    = "MSVC has no /clr code generation for ARM64. The project is intentionally not built for ARM64 rather than silently mapped to another architecture."
    }
)

$activeTestExclusions = @(
    $testExclusions | Where-Object { $Platform -in $_.Platforms } | ForEach-Object { $_.Test }
)
$activeProjectExclusions = @(
    $projectExclusions | Where-Object { $Platform -in $_.Platforms }
)

@(
    "OS=$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    "OSArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    "ProcessArchitecture=$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
    "TestArchitecture=$Platform"
    "Configuration=$Configuration"
    "ExcludedTests=$($activeTestExclusions -join ',')"
    "ExcludedProjects=$(($activeProjectExclusions | ForEach-Object { $_.Project }) -join ',')"
) | Set-Content -Path (Join-Path $LogDirectory "environment-$Platform-$Configuration.txt")

$outputScan = Assert-PeArchitecture -Path $outputDirectory -ExpectedArchitecture $Platform
$outputScan |
    Select-Object @{Name="Path"; Expression={
        $_.Path.Substring($outputDirectory.Length + 1)
    }}, Machine, Architecture |
    ConvertTo-Json |
    Set-Content -Path (Join-Path $LogDirectory "pe-$Platform-$Configuration.json") -Encoding utf8

$gtestFilter = if ($activeTestExclusions.Count -gt 0) {
    @("--gtest_filter=-$($activeTestExclusions -join ':')")
} else {
    @()
}

$tests = @(
    @{ Name = "CppCoverageTest"; Arguments = $gtestFilter },
    @{ Name = "ExporterTest"; Arguments = @() },
    @{ Name = "FileFilterTest"; Arguments = @() },
    @{ Name = "OpenCppCoverageTest"; Arguments = @() },
    @{ Name = "PluginTest"; Arguments = @() },
    @{ Name = "ToolsTest"; Arguments = @() }
)

# Every suite runs so the report is complete, but the results are evaluated
# afterwards and any problem fails this script.
$results = @()
foreach ($test in $tests) {
    $executable = Join-Path $outputDirectory "$($test.Name).exe"
    $logPath = Join-Path $LogDirectory "$($test.Name)-$Platform-$Configuration.log"

    if (-not (Test-Path $executable)) {
        "Test executable is missing: $executable" | Set-Content -Path $logPath
        $results += [pscustomobject]@{
            Name = $test.Name; ExitCode = -1; Ran = $null; Passed = $null
            LogPath = $logPath; Error = "Missing executable: $executable"
        }
        continue
    }

    $arguments = @($test.Arguments)
    if ($InjectFailureIn -and $InjectFailureIn -eq $test.Name) {
        # Selects no test at all, which is rejected by the "ran no tests" rule.
        $arguments = @("--gtest_filter=OpenCppCoverageInjectedFailureThatDoesNotExist")
    }

    Write-Host "Running $($test.Name) $($arguments -join ' ')"
    # Native tools legitimately write to stderr. With ErrorActionPreference
    # 'Stop' that would abort the run before the exit code is inspected, so it
    # is relaxed for the invocation only and the exit code remains the source
    # of truth.
    $output = & {
        $ErrorActionPreference = 'Continue'
        & $executable @arguments 2>&1
    } | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE

    $counters = Get-GTestCounters -OutputLines ($output | ForEach-Object { "$_" })
    $results += [pscustomobject]@{
        Name = $test.Name; ExitCode = $exitCode
        Ran = $counters.Ran; Passed = $counters.Passed
        LogPath = $logPath; Error = $null
    }
}

$evaluation = Test-SuiteResults -Results $results

$summaryPath = Join-Path $LogDirectory "test-summary-$Platform-$Configuration.json"
[pscustomobject]@{
    Platform         = $Platform
    Configuration    = $Configuration
    OSArchitecture   = "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    Success          = $evaluation.Success
    Failures         = $evaluation.Failures
    Suites           = $results
    ExcludedTests    = ($testExclusions | Where-Object { $Platform -in $_.Platforms })
    ExcludedProjects = $activeProjectExclusions
} | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host "Test summary written to $summaryPath"
$results | Format-Table Name, ExitCode, Ran, Passed | Out-String | Write-Host

if (-not $evaluation.Success) {
    foreach ($failure in $evaluation.Failures) {
        Write-Error $failure -ErrorAction Continue
    }
    Write-Error "Test run FAILED for $Platform|$Configuration." -ErrorAction Continue
    exit 1
}

Write-Host "All test suites passed for $Platform|$Configuration."
exit 0
