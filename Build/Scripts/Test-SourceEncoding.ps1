$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "SourceEncoding.ps1")

$ansi = Get-AnsiEncoding
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("source-encoding-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

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

function New-Fixture {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $path = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    return $Name
}

try {
    $accented = [char]0xE9, [char]0xE0, [char]0xE8 -join ""
    $headerName = "Special$accented.hpp"
    [void](New-Fixture -Name $headerName -Bytes $ansi.GetBytes("#pragma once`n"))

    $includeLine = "#include `"$headerName`"`nint main() { return 0; }`n"
    $utf8 = [System.Text.Encoding]::UTF8

    # Encoding classification is byte-exact, not heuristic.
    if ((Get-SourceEncodingKind -Bytes $ansi.GetBytes($includeLine)) -ne "ansi") {
        throw "An ANSI source was not classified as ansi."
    }
    if ((Get-SourceEncodingKind -Bytes $utf8.GetBytes($includeLine)) -ne "utf8-no-bom") {
        throw "A BOM-less UTF-8 source was not classified as utf8-no-bom."
    }
    $bomBytes = $utf8.GetPreamble() + $utf8.GetBytes($includeLine)
    if ((Get-SourceEncodingKind -Bytes $bomBytes) -ne "utf8-bom") {
        throw "A UTF-8 source with BOM was not classified as utf8-bom."
    }
    if ((Get-SourceEncodingKind -Bytes $utf8.GetBytes("int main() { return 0; }")) -ne "ascii") {
        throw "An ASCII source was not classified as ascii."
    }

    # Positive controls: both encodings MSVC decodes correctly are accepted.
    $ansiFile = New-Fixture -Name "ansi-include.cpp" -Bytes $ansi.GetBytes($includeLine)
    $bomFile = New-Fixture -Name "bom-include.cpp" -Bytes $bomBytes
    $asciiFile = New-Fixture -Name "ascii.cpp" `
        -Bytes $utf8.GetBytes("#include `"Special.hpp`"`n")
    Assert-SourceEncoding -Root $fixtureRoot -Files @($ansiFile, $bomFile, $asciiFile)

    # Negative control: the exact regression that broke the ARM64 build.
    $brokenFile = New-Fixture -Name "utf8-no-bom.cpp" -Bytes $utf8.GetBytes($includeLine)
    Assert-Fails `
        { Assert-SourceEncoding -Root $fixtureRoot -Files @($brokenFile) } `
        "without a UTF-8 BOM"

    # Negative control: a BOM'd file whose include names a file that is absent.
    $missingInclude = "#include `"Missing$accented.hpp`"`n"
    $missingFile = New-Fixture -Name "bom-missing-include.cpp" `
        -Bytes ($utf8.GetPreamble() + $utf8.GetBytes($missingInclude))
    Assert-Fails `
        { Assert-SourceEncoding -Root $fixtureRoot -Files @($missingFile) } `
        "does not resolve to a file on disk"

    # Negative control: an ANSI file whose include names a file that is absent.
    $ansiMissingFile = New-Fixture -Name "ansi-missing-include.cpp" `
        -Bytes $ansi.GetBytes($missingInclude)
    Assert-Fails `
        { Assert-SourceEncoding -Root $fixtureRoot -Files @($ansiMissingFile) } `
        "does not resolve to a file on disk"

    Assert-Fails `
        { Assert-SourceEncoding -Root $fixtureRoot -Files @("definitely-missing.cpp") } `
        "missing from the worktree"

    # The repository itself must satisfy the gate.
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $trackedFiles = Get-TrackedSourceFiles -Root $repositoryRoot
    Assert-SourceEncoding -Root $repositoryRoot -Files $trackedFiles

    $expectedNonAscii = [ordered]@{
        "CppCoverageTest/CodeCoverageRunnerTest.cpp"  = "utf8-bom"
        "ExporterTest/CoberturaExporterTest.cpp"      = "ansi"
        "ExporterTest/CoverageDataSerializerTest.cpp" = "ansi"
        "TestCoverageConsole/TestCoverageConsole.cpp" = "ansi"
        "TestCppCli/UnitTest.cpp"                     = "utf8-bom"
        "ToolsTest/ToolTest.cpp"                      = "ansi"
    }

    $actualNonAscii = [ordered]@{}
    foreach ($file in $trackedFiles) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repositoryRoot $file))
        $kind = Get-SourceEncodingKind -Bytes $bytes
        if ($kind -ne "ascii") {
            $actualNonAscii[$file] = $kind
        }
    }

    $inventoryFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $expectedNonAscii.Keys) {
        if (-not $actualNonAscii.Contains($file)) {
            $inventoryFailures.Add("$file : expected a non-ASCII source, but it is now pure ASCII.")
        } elseif ($actualNonAscii[$file] -ne $expectedNonAscii[$file]) {
            $inventoryFailures.Add(
                "$file : encoding changed from $($expectedNonAscii[$file]) to $($actualNonAscii[$file]).")
        }
    }
    foreach ($file in $actualNonAscii.Keys) {
        if (-not $expectedNonAscii.Contains($file)) {
            $inventoryFailures.Add(
                "$file : new non-ASCII source ($($actualNonAscii[$file])) is not in the reviewed inventory.")
        }
    }
    if ($inventoryFailures.Count -gt 0) {
        throw "Non-ASCII source inventory changed:`n - $($inventoryFailures -join "`n - ")"
    }

    Write-Output "Non-ASCII source inventory matches $($expectedNonAscii.Count) reviewed files."
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "All source encoding gate regression cases passed."
