Set-StrictMode -Version Latest

# MSVC decodes a source file as UTF-8 only when it starts with a UTF-8 BOM
# (or when /utf-8 is passed). Otherwise it decodes using the active code page.
# A file that was silently re-encoded to UTF-8 without a BOM therefore compiles
# with mojibake identifiers, literals, and #include paths.

function Get-AnsiEncoding {
    try {
        [System.Text.Encoding]::RegisterProvider(
            [System.Text.CodePagesEncodingProvider]::Instance)
    } catch {
    }

    try {
        return [System.Text.Encoding]::GetEncoding(1252)
    } catch {
        return [System.Text.Encoding]::Latin1
    }
}

function Test-Utf8Bom {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    return ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Test-ValidUtf8 {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        [void]$strict.GetString($Bytes)
        return $true
    } catch {
        return $false
    }
}

function Get-SourceEncodingKind {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if (Test-Utf8Bom -Bytes $Bytes) {
        return "utf8-bom"
    }
    if (-not ($Bytes | Where-Object { $_ -gt 0x7F })) {
        return "ascii"
    }
    if (Test-ValidUtf8 -Bytes $Bytes) {
        return "utf8-no-bom"
    }
    return "ansi"
}

function ConvertFrom-SourceBytes {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if (Test-Utf8Bom -Bytes $Bytes) {
        return [System.Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    return (Get-AnsiEncoding).GetString($Bytes)
}

function Get-QuotedIncludes {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $includeMatches = [regex]::Matches($Text, '(?m)^\s*#\s*include\s*"([^"]+)"')
    return @($includeMatches | ForEach-Object { $_.Groups[1].Value })
}

function Get-SourceEncodingFailures {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Files
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        $fullPath = Join-Path $Root $file
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $failures.Add("$file : tracked source file is missing from the worktree.")
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $kind = Get-SourceEncodingKind -Bytes $bytes
        if ($kind -eq "utf8-no-bom") {
            $failures.Add(
                "$file : contains non-ASCII UTF-8 bytes without a UTF-8 BOM, " +
                "so MSVC decodes it with the active code page. " +
                "Save it as UTF-8 with BOM.")
            continue
        }

        $text = ConvertFrom-SourceBytes -Bytes $bytes
        $directory = Split-Path -Parent $fullPath
        foreach ($include in (Get-QuotedIncludes -Text $text)) {
            if (-not ($include.ToCharArray() | Where-Object { [int]$_ -gt 0x7F })) {
                continue
            }

            $normalized = $include -replace '/', '\'
            $candidates = @(
                (Join-Path $Root $normalized)
                (Join-Path $directory $normalized)
            )
            if (-not ($candidates | Where-Object { Test-Path -LiteralPath $_ })) {
                $failures.Add(
                    "$file : non-ASCII include '$include' does not resolve to a " +
                    "file on disk when decoded as $kind.")
            }
        }
    }

    return $failures.ToArray()
}

function Assert-SourceEncoding {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Files
    )

    $failures = @(Get-SourceEncodingFailures -Root $Root -Files $Files)
    if ($failures.Count -gt 0) {
        throw "Source encoding gate failed:`n - $($failures -join "`n - ")"
    }

    Write-Output "Source encoding gate passed for $($Files.Count) files."
}

function Get-TrackedSourceFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $files = & git -C $Root -c core.quotepath=off ls-files `
            "*.cpp" "*.hpp" "*.h" "*.c" "*.cc" "*.cxx"
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to enumerate tracked source files in $Root."
        }
    } finally {
        [Console]::OutputEncoding = $previousEncoding
    }

    return @($files | Where-Object { $_ })
}
