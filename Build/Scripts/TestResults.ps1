Set-StrictMode -Version Latest

function ConvertFrom-GTestOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Suite,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Output,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [bool]$Present = $true
    )

    $ranMatches = [regex]::Matches(
        $Output,
        '(?m)^\[==========\]\s+(\d+)\s+tests?\s+from\s+\d+\s+test (?:suites?|cases?)\s+ran\.')
    $passedMatches = [regex]::Matches(
        $Output,
        '(?m)^\[\s+PASSED\s+\]\s+(\d+)\s+tests?\.')
    $failedMatches = [regex]::Matches(
        $Output,
        '(?m)^\[\s+FAILED\s+\]\s+(\d+)\s+tests?(?:,|\.)')

    $parseErrors = [System.Collections.Generic.List[string]]::new()
    if ($ranMatches.Count -ne 1) {
        $parseErrors.Add("expected exactly one GoogleTest ran summary")
    }
    if ($passedMatches.Count -ne 1) {
        $parseErrors.Add("expected exactly one GoogleTest passed summary")
    }
    if ($failedMatches.Count -gt 1) {
        $parseErrors.Add("expected at most one GoogleTest failed summary")
    }

    $ran = if ($ranMatches.Count -eq 1) {
        [int]$ranMatches[0].Groups[1].Value
    } else {
        $null
    }
    $passed = if ($passedMatches.Count -eq 1) {
        [int]$passedMatches[0].Groups[1].Value
    } else {
        $null
    }
    $failed = if ($failedMatches.Count -eq 1) {
        [int]$failedMatches[0].Groups[1].Value
    } else {
        0
    }

    [pscustomobject]@{
        Suite = $Suite
        Present = $Present
        ExitCode = $ExitCode
        Ran = $ran
        Passed = $passed
        Failed = $failed
        ParseErrors = @($parseErrors)
    }
}

function Get-TestResultFailures {
    param(
        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string[]]$RequiredSuites
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($requiredSuite in $RequiredSuites) {
        $matches = @($Results | Where-Object Suite -eq $requiredSuite)
        if ($matches.Count -ne 1) {
            $failures.Add(
                "$requiredSuite was $($matches.Count -eq 0 ? 'omitted' : 'reported more than once')")
        }
    }

    foreach ($result in $Results) {
        if ($result.Suite -notin $RequiredSuites) {
            $failures.Add("$($result.Suite) is not in the required suite manifest")
        }
        if (-not $result.Present) {
            $failures.Add("$($result.Suite) executable was omitted")
        }
        if ($result.ExitCode -ne 0) {
            $failures.Add("$($result.Suite) exited with $($result.ExitCode)")
        }
        foreach ($parseError in $result.ParseErrors) {
            $failures.Add("$($result.Suite): $parseError")
        }
        if ($null -ne $result.Ran -and $result.Ran -eq 0) {
            $failures.Add("$($result.Suite) ran zero tests")
        }
        if ($result.Failed -gt 0) {
            $failures.Add("$($result.Suite) reported $($result.Failed) failed tests")
        }
        if ($null -ne $result.Ran -and $null -ne $result.Passed -and
            $result.Passed -ne $result.Ran) {
            $failures.Add(
                "$($result.Suite) passed $($result.Passed) of $($result.Ran) tests")
        }
    }

    return @($failures)
}

function Assert-TestResults {
    param(
        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string[]]$RequiredSuites
    )

    $failures = @(Get-TestResultFailures -Results $Results -RequiredSuites $RequiredSuites)
    if ($failures.Count -gt 0) {
        throw "Native test gate failed:`n - $($failures -join "`n - ")"
    }
}

function Get-RequiredArtifactFailures {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$RequiredArtifacts
    )

    $failures = @()
    foreach ($artifact in $RequiredArtifacts) {
        $artifactPath = Join-Path $Root $artifact
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            $failures += "required fixture was omitted: $artifactPath"
        }
    }
    return $failures
}
