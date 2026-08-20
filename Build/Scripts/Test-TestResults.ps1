$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "TestResults.ps1")

function New-Output {
    param(
        [int]$Ran,
        [int]$Passed,
        [int]$Failed = 0
    )

    $output = @"
[==========] Running $Ran tests from 1 test suite.
[==========] $Ran tests from 1 test suite ran. (1 ms total)
[  PASSED  ] $Passed tests.
"@
    if ($Failed -gt 0) {
        $output += "`n[  FAILED  ] $Failed tests, listed below:`n"
    }
    return $output
}

function Assert-Fails {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$Expected
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
            throw "Expected failure containing '$Expected', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected failure containing '$Expected', but the action succeeded."
}

$valid = ConvertFrom-GTestOutput -Suite Alpha -Output (New-Output 2 2) -ExitCode 0
Assert-TestResults -Results @($valid) -RequiredSuites @("Alpha")

$nonzero = ConvertFrom-GTestOutput -Suite Alpha -Output (New-Output 2 2) -ExitCode 7
Assert-Fails { Assert-TestResults @($nonzero) @("Alpha") } "exited with 7"

$failed = ConvertFrom-GTestOutput -Suite Alpha -Output (New-Output 2 1 1) -ExitCode 0
Assert-Fails { Assert-TestResults @($failed) @("Alpha") } "reported 1 failed tests"

$mismatch = ConvertFrom-GTestOutput -Suite Alpha -Output (New-Output 2 1) -ExitCode 0
Assert-Fails { Assert-TestResults @($mismatch) @("Alpha") } "passed 1 of 2 tests"

$zero = ConvertFrom-GTestOutput -Suite Alpha -Output (New-Output 0 0) -ExitCode 0
Assert-Fails { Assert-TestResults @($zero) @("Alpha") } "ran zero tests"

Assert-Fails { Assert-TestResults @($valid) @("Alpha", "Beta") } "Beta was omitted"

$missing = ConvertFrom-GTestOutput -Suite Alpha -Output "" -ExitCode -1 -Present $false
Assert-Fails { Assert-TestResults @($missing) @("Alpha") } "executable was omitted"

$missingFixtureRoot = Join-Path $PSScriptRoot "definitely-missing-fixture-root"
$fixtureFailures = @(Get-RequiredArtifactFailures `
    -Root $missingFixtureRoot `
    -RequiredArtifacts @("DefaultTest.dll"))
if ($fixtureFailures.Count -ne 1 -or
    $fixtureFailures[0] -notmatch "required fixture was omitted") {
    throw "An omitted required fixture was accepted."
}

Write-Output "All test-result gate regression cases passed."
