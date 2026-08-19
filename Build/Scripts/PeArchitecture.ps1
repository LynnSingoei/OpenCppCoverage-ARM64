function Get-PeMachine {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = [IO.File]::OpenRead((Resolve-Path $Path))
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "$Path is not a PE image (missing MZ signature)."
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt $stream.Length - 6) {
            throw "$Path has an invalid PE header offset."
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "$Path is not a PE image (missing PE signature)."
        }

        $machine = $reader.ReadUInt16()
        $architecture = switch ($machine) {
            0x014C { "x86" }
            0x8664 { "x64" }
            0xAA64 { "ARM64" }
            0xA641 { "ARM64EC" }
            0xA64E { "ARM64X" }
            default { "Unknown" }
        }

        [pscustomobject]@{
            Path = (Resolve-Path $Path).Path
            Machine = ('0x{0:X4}' -f $machine)
            Architecture = $architecture
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-PeArchitecture {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("x86", "x64", "ARM64")]
        [string]$ExpectedArchitecture
    )

    $images = Get-ChildItem -Path $Path -Recurse -File |
        Where-Object { $_.Extension -in @(".exe", ".dll") } |
        ForEach-Object { Get-PeMachine -Path $_.FullName }

    if (-not $images) {
        throw "No PE images were found under $Path."
    }

    $unexpected = @($images | Where-Object {
        $_.Architecture -ne $ExpectedArchitecture
    })
    if ($unexpected) {
        $details = $unexpected |
            ForEach-Object { "$($_.Architecture) $($_.Path)" } |
            Out-String
        throw "Expected only $ExpectedArchitecture PE images under $Path.`n$details"
    }

    return $images
}
