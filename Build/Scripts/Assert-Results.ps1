param(
    [ValidateSet("x86", "x64", "ARM64")]
    [string]$Platform = "x64",

    [string]$LogDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\test-logs"),

    [string[]]$Configurations = @("Debug", "Release")
)

# Independent final gate.
#
# Run 32303203988 reported success while a suite had exited 1, because the
# aggregate step never propagated a nonzero status. This step re-reads the
# recorded evidence and fails the job if anything is missing or not fully
# green, so a fail-open change to an earlier step cannot produce a green job.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestSummary.ps1")

$problems = @()

if (-not (Test-Path $LogDirectory)) {
    Write-Error "Log directory '$LogDirectory' does not exist; there is no evidence to verify." -ErrorAction Continue
    exit 1
}

foreach ($configuration in $Configurations) {
    $summaryPath = Join-Path $LogDirectory "test-summary-$Platform-$configuration.json"
    if (-not (Test-Path $summaryPath)) {
        $problems += "Missing test summary: $summaryPath"
        continue
    }

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

    # Re-evaluate from the raw per-suite numbers rather than trusting the
    # recorded Success flag.
    $evaluation = Test-SuiteResults -Results @($summary.Suites)
    foreach ($failure in $evaluation.Failures) {
        $problems += "[$Platform|$configuration] $failure"
    }

    if ($summary.Success -ne $true) {
        $problems += "[$Platform|$configuration] Recorded Success flag is '$($summary.Success)'."
    }

    if ($summary.Platform -ne $Platform) {
        $problems += "[$Platform|$configuration] Summary reports platform '$($summary.Platform)'."
    }

    if ($Platform -eq "ARM64" -and $summary.OSArchitecture -ne "Arm64") {
        $problems += "[$Platform|$configuration] ARM64 results were recorded on a '$($summary.OSArchitecture)' operating system, which is not native ARM64 execution."
    }
}

foreach ($label in @("build", "packaged")) {
    $suffix = if ($label -eq "build") { "$Platform-Release" } else { "$Platform-Release-$label" }
    $e2ePath = Join-Path $LogDirectory "e2e-summary-$suffix.json"
    if (-not (Test-Path $e2ePath)) {
        $problems += "Missing end-to-end summary ($label): $e2ePath"
        continue
    }

    $e2e = Get-Content -LiteralPath $e2ePath -Raw | ConvertFrom-Json
    if ($e2e.Success -ne $true) {
        $problems += "End-to-end coverage assertion ($label) did not succeed."
    }
    if ($e2e.CoverageExitCode -ne 0) {
        $problems += "End-to-end coverage run ($label) exited with $($e2e.CoverageExitCode)."
    }
    if ([int]$e2e.CoveredLines -le 0) {
        $problems += "End-to-end run ($label) reported no covered lines."
    }
    if ([int]$e2e.UnreachableHits -ne 0) {
        $problems += "End-to-end run ($label) reported the unreachable line as executed."
    }
    if ($Platform -eq "ARM64" -and $e2e.OSArchitecture -ne "Arm64") {
        $problems += "End-to-end ARM64 evidence ($label) was produced on '$($e2e.OSArchitecture)', which is not native ARM64 execution."
    }
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Error $problem -ErrorAction Continue }
    Write-Error "Result verification FAILED for $Platform ($($problems.Count) problem(s))." -ErrorAction Continue
    exit 1
}

Write-Host "All recorded results for $Platform are complete and fully passing ($($Configurations -join ', ') plus end-to-end)."
exit 0
