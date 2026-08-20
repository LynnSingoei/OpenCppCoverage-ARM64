# Shared helpers for evaluating Google Test suite results.
#
# These are kept separate from RunTests.ps1 so the fail-closed decision logic
# can be exercised by a deterministic regression test that does not require
# building or running the product.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Extracts the "ran" and "passed" counters from Google Test console output.

.DESCRIPTION
Returns a hashtable with Ran and Passed. A value stays $null when the
corresponding line is absent, which happens when a suite crashes before
printing its summary. Callers must treat $null as a failure.
#>
function Get-GTestCounters {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$OutputLines
    )

    $ran = $null
    $passed = $null

    foreach ($line in @($OutputLines)) {
        if ($null -eq $line) { continue }

        # "[==========] 116 tests from 20 test suites ran. (1234 ms total)"
        if ($line -match '^\[=+\]\s+(\d+)\s+tests?\s+from\s+.*\bran\b') {
            $ran = [int]$Matches[1]
        }
        # "[  PASSED  ] 114 tests."
        elseif ($line -match '^\[\s*PASSED\s*\]\s+(\d+)\s+tests?\b') {
            $passed = [int]$Matches[1]
        }
    }

    return @{ Ran = $ran; Passed = $passed }
}

<#
.SYNOPSIS
Decides whether a set of suite results is acceptable.

.DESCRIPTION
A suite is only acceptable when it exited zero, reported both counters, ran at
least one test, and passed every test it ran. Any other shape - including a
missing summary or a zero exit code with failing tests - is a failure. This is
deliberately fail-closed: an unparsable or absent result never counts as a
pass.

Returns a hashtable with Success and Failures (array of human readable
strings).
#>
function Test-SuiteResults {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $failures = @()
    $results = @($Results)

    if ($results.Count -eq 0) {
        $failures += "No test suites were executed."
    }

    foreach ($result in $results) {
        $name = $result.Name

        if ($result.ExitCode -ne 0) {
            $failures += "$name exited with code $($result.ExitCode)."
        }

        if ($null -eq $result.Ran -or $null -eq $result.Passed) {
            $failures += "$name did not report a Google Test summary (Ran=$($result.Ran), Passed=$($result.Passed))."
            continue
        }

        if ($result.Ran -le 0) {
            $failures += "$name ran no tests."
        }

        if ($result.Passed -ne $result.Ran) {
            $failures += "$name passed $($result.Passed) of $($result.Ran) tests."
        }
    }

    return @{ Success = ($failures.Count -eq 0); Failures = $failures }
}
