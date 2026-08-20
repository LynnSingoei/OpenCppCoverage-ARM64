# Deterministic regression proving the test pipeline is fail-closed.
#
# Run 32303203988 concluded "success" while CppCoverageTest exited 1 with
# 114 of 116 tests passing. These cases lock that behaviour out: they run on
# every platform, need no build output, and require no ARM64 hardware.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestSummary.ps1")

$failures = @()

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -ne $Actual) {
        $script:failures += "$Because : expected '$Expected' but got '$Actual'."
    }
}

function Assert-Rejected {
    param([object[]]$Results, [string]$Because)
    $evaluation = Test-SuiteResults -Results $Results
    if ($evaluation.Success) {
        $script:failures += "$Because : expected rejection but the results were accepted."
    }
}

function New-Suite {
    param([string]$Name, [int]$ExitCode, $Ran, $Passed)
    return [pscustomobject]@{ Name = $Name; ExitCode = $ExitCode; Ran = $Ran; Passed = $Passed }
}

# --- Counter parsing -------------------------------------------------------
$gtestOutput = @(
    "[==========] Running 116 tests from 20 test suites.",
    "[  FAILED  ] CodeCoverageRunnerTest.RunThread",
    "[==========] 116 tests from 20 test suites ran. (61234 ms total)",
    "[  PASSED  ] 114 tests.",
    "[  FAILED  ] 2 tests, listed below:"
)
$counters = Get-GTestCounters -OutputLines $gtestOutput
Assert-Equal 116 $counters.Ran "Parsed ran count"
Assert-Equal 114 $counters.Passed "Parsed passed count"

$crashOutput = @("[==========] Running 116 tests from 20 test suites.", "Fatal error")
$crashCounters = Get-GTestCounters -OutputLines $crashOutput
Assert-Equal $null $crashCounters.Ran "Crashed suite reports no ran count"
Assert-Equal $null $crashCounters.Passed "Crashed suite reports no passed count"

# --- Acceptance ------------------------------------------------------------
$healthy = @((New-Suite "CppCoverageTest" 0 116 116), (New-Suite "ToolsTest" 0 12 12))
$healthyEvaluation = Test-SuiteResults -Results $healthy
if (-not $healthyEvaluation.Success) {
    $failures += "A fully passing run must be accepted, but it reported: $($healthyEvaluation.Failures -join '; ')"
}

# --- Rejection -------------------------------------------------------------
# The exact shape of the falsely green run 32303203988.
Assert-Rejected @((New-Suite "CppCoverageTest" 1 116 114)) "Regression 32303203988 (nonzero exit, 114/116)"

# Nonzero exit code alone must fail even if the counters look healthy.
Assert-Rejected @((New-Suite "CppCoverageTest" 1 116 116)) "Nonzero exit code with healthy counters"

# Passed != Ran must fail even when the process exits zero.
Assert-Rejected @((New-Suite "CppCoverageTest" 0 116 114)) "Passed less than ran with zero exit code"

# A crashed or unparsable suite must never be treated as a pass.
Assert-Rejected @((New-Suite "CppCoverageTest" 0 $null $null)) "Missing Google Test summary"

# A suite that silently ran nothing must fail rather than look green.
Assert-Rejected @((New-Suite "CppCoverageTest" 0 0 0)) "Suite that ran no tests"

# A missing executable is recorded as ExitCode -1 and must fail.
Assert-Rejected @((New-Suite "CppCoverageTest" -1 $null $null)) "Missing test executable"

# One healthy suite must not mask a failing sibling suite.
Assert-Rejected @((New-Suite "ToolsTest" 0 12 12), (New-Suite "CppCoverageTest" 1 116 114)) "Failing suite alongside a passing suite"

# No suites at all must fail rather than vacuously pass.
Assert-Rejected @() "Empty result set"

# --- Report ----------------------------------------------------------------
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Error $failure -ErrorAction Continue }
    Write-Error "Fail-closed regression FAILED ($($failures.Count) problem(s))." -ErrorAction Continue
    exit 1
}

Write-Host "Fail-closed regression passed: failing, crashed, empty and partially passing suites are all rejected."
exit 0
