param(
    [Parameter(Mandatory = $true)]
    [string]$BuildLog,

    # Host toolchain directory the compiler and linker must come from, e.g.
    # "Hostarm64" or "HostX64". Matching is case-insensitive because MSBuild
    # and the toolset spell these inconsistently ("Hostarm64" vs "HostARM64").
    [Parameter(Mandatory = $true)]
    [string]$ExpectedHost,

    [string]$SummaryPath
)

# Guards against a silent change of build host toolchain.
#
# The toolchain preflight probes which cl.exe *resolves*, but MSBuild picks the
# host toolchain independently: on the ARM64 runner it selected the emulated
# bin\HostX86\arm64 compiler even though bin\Hostarm64\arm64 was present and was
# what vcpkg had used. A build can therefore be produced by a different compiler
# than the one that was verified, and nothing would say so.
#
# This reads the actual command lines out of the build log and fails when any
# compiler or linker invocation comes from an unexpected host directory, or when
# no invocation is found at all.

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BuildLog)) {
    Write-Error "Build log does not exist: $BuildLog" -ErrorAction Continue
    exit 1
}

$pattern = '(?<Root>[A-Za-z]:\\[^"''<>|]*?\\VC\\Tools\\MSVC\\(?<Version>[0-9.]+)\\bin\\(?<Host>Host[A-Za-z0-9_]+)\\(?<Target>[A-Za-z0-9_]+)\\)(?<Tool>cl|link)\.exe'

$invocations = @{}
foreach ($match in [regex]::Matches((Get-Content -LiteralPath $BuildLog -Raw), $pattern, 'IgnoreCase')) {
    $key = "{0}|{1}|{2}|{3}" -f $match.Groups['Tool'].Value.ToLowerInvariant(),
                                $match.Groups['Host'].Value,
                                $match.Groups['Target'].Value,
                                $match.Groups['Version'].Value
    if ($invocations.ContainsKey($key)) {
        $invocations[$key].Count++
    }
    else {
        $invocations[$key] = [pscustomobject]@{
            Tool          = $match.Groups['Tool'].Value.ToLowerInvariant()
            Host          = $match.Groups['Host'].Value
            Target        = $match.Groups['Target'].Value
            ToolsVersion  = $match.Groups['Version'].Value
            Count         = 1
        }
    }
}

$observed = @($invocations.Values | Sort-Object Tool, Host)
$problems = @()

if ($observed.Count -eq 0) {
    $problems += "No cl.exe or link.exe invocation was found in $BuildLog, so the build host toolchain cannot be verified."
}

foreach ($invocation in $observed) {
    if ($invocation.Host -ine $ExpectedHost) {
        $problems += "$($invocation.Tool).exe was invoked $($invocation.Count) time(s) from '$($invocation.Host)' but '$ExpectedHost' was required."
    }
}

$distinctVersions = @($observed | ForEach-Object { $_.ToolsVersion } | Sort-Object -Unique)
if ($distinctVersions.Count -gt 1) {
    $problems += "The build mixed MSVC toolset versions: $($distinctVersions -join ', ')."
}

$summary = [pscustomobject]@{
    BuildLog     = (Resolve-Path -LiteralPath $BuildLog).Path
    ExpectedHost = $ExpectedHost
    Invocations  = $observed
    Problems     = $problems
    Succeeded    = ($problems.Count -eq 0)
}

if ($SummaryPath) {
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $SummaryPath -Encoding utf8
}

foreach ($invocation in $observed) {
    Write-Host ("{0,-6} {1}\{2} toolset {3} x{4}" -f $invocation.Tool, $invocation.Host, $invocation.Target, $invocation.ToolsVersion, $invocation.Count)
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Error $problem -ErrorAction Continue }
    Write-Error "Build host toolchain verification FAILED ($($problems.Count) problem(s))." -ErrorAction Continue
    exit 1
}

Write-Host "Build host toolchain verified: every compiler and linker invocation came from $ExpectedHost."
exit 0
