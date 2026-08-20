param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs"),

    # When set, the OpenCppCoverage.exe under test is taken from a staged or
    # re-expanded package instead of the build output, so the artifact that is
    # actually shipped is the one proven to work.
    [string]$PackageRoot = "",

    [string]$Label = "build"
)

# End-to-end proof that the built OpenCppCoverage really instruments a native
# process of the target architecture and produces truthful line coverage.
#
# This is deliberately stronger than "the exe starts": it requires that a line
# known to be unreachable is reported as NOT covered, so an exporter that
# marked everything as covered would fail here.

$ErrorActionPreference = "Stop"
$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot "PeArchitecture.ps1")

$outputDirectory = switch ($Platform) {
    "x86" { Join-Path $repositoryRoot $Configuration }
    "x64" { Join-Path $repositoryRoot "x64\$Configuration" }
    "ARM64" { Join-Path $repositoryRoot "ARM64\$Configuration" }
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$suffix = if ($Label -eq "build") { "$Platform-$Configuration" } else { "$Platform-$Configuration-$Label" }

$openCppCoverage = Join-Path $outputDirectory "OpenCppCoverage.exe"
if ($PackageRoot) {
    $openCppCoverage = Join-Path $PackageRoot "Binaries\OpenCppCoverage.exe"
}
$testConsole = Join-Path $outputDirectory "TestCoverageConsole.exe"
$sourceFile = Join-Path $repositoryRoot "TestCoverageConsole\TestBasic.cpp"

foreach ($required in @($openCppCoverage, $testConsole, $sourceFile)) {
    if (-not (Test-Path $required)) {
        Write-Error "End-to-end prerequisite is missing: $required" -ErrorAction Continue
        exit 1
    }
}

# The binaries under test must really be of the target architecture.
foreach ($binary in @($openCppCoverage, $testConsole)) {
    $machine = Get-PeMachine -Path $binary
    if ($machine.Architecture -ne $Platform) {
        Write-Error "$binary is $($machine.Architecture) but $Platform was expected." -ErrorAction Continue
        exit 1
    }
}

# Locate the fixture lines by content so ordinary edits to TestBasic.cpp cannot
# silently invalidate the assertion.
$sourceLines = Get-Content -LiteralPath $sourceFile
$unreachableLine = $null
for ($i = 0; $i -lt $sourceLines.Count; $i++) {
    if ($sourceLines[$i] -match '^\s*int answer = 42;') {
        $unreachableLine = $i + 1
        break
    }
}
if (-not $unreachableLine) {
    Write-Error "Could not locate the unreachable fixture statement in $sourceFile." -ErrorAction Continue
    exit 1
}

$reportPath = Join-Path $LogDirectory "e2e-cobertura-$suffix.xml"
Remove-Item $reportPath -Force -ErrorAction SilentlyContinue
$logPath = Join-Path $LogDirectory "e2e-$suffix.log"

$arguments = @(
    "--sources", "TestCoverageConsole"
    "--export_type=cobertura:$reportPath"
    "--"
    $testConsole
    "TestBasic"
)

Write-Host "Running: $openCppCoverage $($arguments -join ' ')"
# OpenCppCoverage writes progress to stderr, which would otherwise become a
# terminating error before the exit code can be inspected.
& {
    $ErrorActionPreference = 'Continue'
    & $openCppCoverage @arguments 2>&1
} | Tee-Object -FilePath $logPath
$coverageExitCode = $LASTEXITCODE

if ($coverageExitCode -ne 0) {
    Write-Error "OpenCppCoverage exited with $coverageExitCode. See $logPath." -ErrorAction Continue
    exit 1
}

if (-not (Test-Path $reportPath)) {
    Write-Error "No Cobertura report was produced at $reportPath." -ErrorAction Continue
    exit 1
}

[xml]$report = Get-Content -LiteralPath $reportPath
$class = $report.SelectNodes("//class") |
    Where-Object { $_.filename -and ([System.IO.Path]::GetFileName($_.filename) -ieq "TestBasic.cpp") } |
    Select-Object -First 1

if (-not $class) {
    Write-Error "The Cobertura report contains no entry for TestBasic.cpp." -ErrorAction Continue
    exit 1
}

$lines = @($class.SelectNodes("lines/line"))
if ($lines.Count -eq 0) {
    Write-Error "The Cobertura report contains no line records for TestBasic.cpp." -ErrorAction Continue
    exit 1
}

$covered = @($lines | Where-Object { [int]$_.hits -gt 0 })
if ($covered.Count -eq 0) {
    Write-Error "No line of TestBasic.cpp was reported as executed; instrumentation did not work." -ErrorAction Continue
    exit 1
}

$unreachable = $lines | Where-Object { [int]$_.number -eq $unreachableLine } | Select-Object -First 1
if (-not $unreachable) {
    Write-Error "Line $unreachableLine of TestBasic.cpp is absent from the report, so the unexecuted-line assertion cannot be made." -ErrorAction Continue
    exit 1
}
if ([int]$unreachable.hits -ne 0) {
    Write-Error "Line $unreachableLine of TestBasic.cpp is unreachable but was reported as executed $($unreachable.hits) time(s)." -ErrorAction Continue
    exit 1
}

$summary = [pscustomobject]@{
    Platform          = $Platform
    Configuration     = $Configuration
    Label             = $Label
    OpenCppCoverage   = $openCppCoverage
    OSArchitecture    = "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    ProcessArchitecture = "$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
    CoverageExitCode  = $coverageExitCode
    ReportPath        = $reportPath
    TotalLines        = $lines.Count
    CoveredLines      = $covered.Count
    UnreachableLine   = $unreachableLine
    UnreachableHits   = [int]$unreachable.hits
    Success           = $true
}
$summaryPath = Join-Path $LogDirectory "e2e-summary-$suffix.json"
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host "End-to-end coverage verified on ${Platform}|${Configuration}: $($covered.Count)/$($lines.Count) lines executed in TestBasic.cpp, unreachable line $unreachableLine correctly reported as not executed."
Write-Host "Summary written to $summaryPath"
exit 0
