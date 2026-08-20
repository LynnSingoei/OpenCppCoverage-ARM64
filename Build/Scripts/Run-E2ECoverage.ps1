param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$outputDirectory = @{
    x86 = (Join-Path $repositoryRoot $Configuration)
    x64 = (Join-Path $repositoryRoot "x64\$Configuration")
    ARM64 = (Join-Path $repositoryRoot "ARM64\$Configuration")
}[$Platform]
$openCppCoverage = Join-Path $outputDirectory "OpenCppCoverage.exe"
$testProgram = Join-Path $outputDirectory "TestCoverageConsole.exe"
$source = Join-Path $repositoryRoot "TestCoverageConsole\TestThread.cpp"
foreach ($requiredFile in @($openCppCoverage, $testProgram, $source)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "E2E coverage input is missing: $requiredFile"
    }
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$coverageXml = Join-Path $LogDirectory "e2e-cobertura-$Platform-$Configuration.xml"
$logPath = Join-Path $LogDirectory "e2e-coverage-$Platform-$Configuration.log"
Remove-Item -LiteralPath $coverageXml -Force -ErrorAction SilentlyContinue

& $openCppCoverage `
    --quiet `
    --export_type "cobertura:$coverageXml" `
    --modules $testProgram `
    --sources $source `
    -- $testProgram TestThread 2>&1 |
    Tee-Object -FilePath $logPath
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "OpenCppCoverage E2E scenario exited with $exitCode. See $logPath."
}
if (-not (Test-Path -LiteralPath $coverageXml -PathType Leaf) -or
    (Get-Item -LiteralPath $coverageXml).Length -eq 0) {
    throw "OpenCppCoverage E2E scenario did not produce a Cobertura report."
}

function Get-TaggedLines {
    param([Parameter(Mandatory)][string]$Tag)

    $lineNumber = 0
    return @(Get-Content -LiteralPath $source | ForEach-Object {
        ++$lineNumber
        if ($_ -like "*$Tag*") {
            $lineNumber
        }
    })
}

[xml]$coverage = Get-Content -LiteralPath $coverageXml -Raw
$classes = @($coverage.coverage.packages.package.classes.class |
    Where-Object { [IO.Path]::GetFileName([string]$_.filename) -eq "TestThread.cpp" })
if ($classes.Count -ne 1) {
    throw "Expected one TestThread.cpp class in Cobertura output, found $($classes.Count)."
}

$reportedLines = @{}
foreach ($line in @($classes[0].lines.line)) {
    $reportedLines[[int]$line.number] = [int]$line.hits
}
$requiredLines = @(Get-TaggedLines "@ThreadCoverageRequired")
$unexecutedLines = @(Get-TaggedLines "@ThreadCoverageNotExpected")
if ($requiredLines.Count -ne 1 -or $unexecutedLines.Count -ne 1) {
    throw "The E2E source oracle requires exactly one executed and one unexecuted tagged line."
}
foreach ($line in $requiredLines) {
    if (-not $reportedLines.ContainsKey($line) -or $reportedLines[$line] -le 0) {
        throw "Cobertura output did not report required line $line as covered."
    }
}
foreach ($line in $unexecutedLines) {
    if (-not $reportedLines.ContainsKey($line) -or $reportedLines[$line] -ne 0) {
        throw "Cobertura output did not report uncalled line $line as uncovered."
    }
}

Write-Output "E2E Cobertura oracle passed: covered=$($requiredLines -join ',') uncovered=$($unexecutedLines -join ',')."
