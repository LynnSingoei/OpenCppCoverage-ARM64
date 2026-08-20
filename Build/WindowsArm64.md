# Native Windows ARM64 support

OpenCppCoverage builds and runs natively on Windows ARM64 in addition to the
existing Win32 (x86) and x64 configurations.

## Prerequisites

* Visual Studio 2022 17.x or later with:
  * `Microsoft.VisualStudio.Component.VC.Tools.ARM64` (MSVC ARM64 compiler,
    linker and CRT)
  * `Microsoft.VisualStudio.Component.VC.ATL.ARM64` (ATL for ARM64, required to
    link `CppCoverage.dll`)
  * The Windows SDK matching the Visual Studio installation
* The Visual Studio DIA SDK, which ships `lib\arm64\diaguids.lib` and
  `bin\arm64\msdia140.dll`

The projects no longer pin a specific `PlatformToolset`. Each project derives it
from `$(DefaultPlatformToolset)` so that MSBuild, vcpkg and the Windows SDK all
resolve to the same Visual Studio instance:

```xml
<PlatformToolset>$([MSBuild]::ValueOrDefault('$(OpenCppCoveragePlatformToolset)', '$(DefaultPlatformToolset)'))</PlatformToolset>
```

Set the `OpenCppCoveragePlatformToolset` environment variable (or MSBuild
property) to deliberately override the toolset. Doing so requires
`ToolchainPreflight.ps1 -AllowToolsetOverride`, which keeps accidental
overrides fail-closed.

> Pinning `v142` previously caused the ARM64 build to select MSVC 14.29 while
> vcpkg used a current compiler. The mismatch made `winnt.h` fail with
> `C3861: '_CountOneBits64': identifier not found`. The preflight below exists
> to make that class of mismatch impossible to reintroduce silently.

## Reproducible commands

```powershell
# 1. Restore the pinned dependency graph for the target triplet.
.\InstallThirdPartyLibraries.ps1 -Triplet arm64-windows

# 2. Prove the projects do not pin a toolset.
.\Build\Scripts\Test-ProjectToolsets.ps1

# 3. Prove the test pipeline cannot report a false pass.
.\Build\Scripts\Test-FailClosed.ps1

# 4. Prove MSBuild and vcpkg agree on one compiler, and that a real ARM64
#    cl.exe, link.exe and libcpmt.lib are present.
.\Build\Scripts\ToolchainPreflight.ps1 -Platform ARM64 -Configuration Debug

# 5. Build, test, and assert end-to-end coverage.
msbuild /m CppCoverage.sln /p:Configuration=Debug /p:Platform=ARM64
.\Build\Scripts\RunTests.ps1 -Platform ARM64 -Configuration Debug
msbuild /m CppCoverage.sln /p:Configuration=Release /p:Platform=ARM64
.\Build\Scripts\RunTests.ps1 -Platform ARM64 -Configuration Release
.\Build\Scripts\RunEndToEnd.ps1 -Platform ARM64 -Configuration Release

# 6. Package, then re-read all recorded evidence as an independent gate.
.\CreateRelease.ps1 -Platform ARM64 -Configuration Release
.\Build\Scripts\Assert-Results.ps1 -Platform ARM64
```

## Detecting a real ARM64 toolchain

An ARM64 Visual Studio installation can contain `VC\Tools\MSVC\<version>\lib\arm64`
and `bin\HostArm64\arm64` while the ARM64 compiler is **not** installed: those
directories are also created by the ASAN/clang runtime component. Probing for
the directory therefore produces false positives.

`ToolchainPreflight.ps1` requires `cl.exe`, `link.exe` **and** `libcpmt.lib` for
the target architecture before it reports success.

## Architecture-specific behaviour

### Closing braces have no line record on ARM64

The MSVC ARM64 compiler does not emit a line-table entry for the closing brace
of a function or lambda, whereas the x86 and x64 compilers do. This was
confirmed by reading the PDBs directly with DIA for the same source file:

| Source                                 | x64 line records      | ARM64 line records |
| -------------------------------------- | --------------------- | ------------------ |
| `TestCoverageConsole/TestDebugInformationEnumerator.cpp` | 25, 26, 28, **30** | 25, 26, 28 |
| `TestCoverageConsole/TestThread.cpp`   | 27, 28, 29, 30, **31**, 32, 33 | 27, 28, 29, 30, 32, 33 |

OpenCppCoverage reports the lines that are present in the debug information, so
this is a faithful result rather than a coverage defect: a line the compiler
never recorded cannot be instrumented. `DebugInformationEnumeratorTest` and
`CodeCoverageRunnerTest.RunThread` express this with `#ifndef _M_ARM64` so the
x86 and x64 expectations remain exactly as strict as before.

### C++/CLI

MSVC has no `/clr` code generation for ARM64. `TestCppCli` is therefore not
built for ARM64 and `CppCliTest.ManagedUnManagedModule` is excluded there. The
exclusion is declared with a justification in `RunTests.ps1` and is written into
`test-summary-ARM64-*.json`, so it appears in the run report instead of being
skipped silently. Coverage of native C++ ARM64 code is unaffected.

### ARM64EC / ARM64X

Mixed-architecture ARM64EC and ARM64X images are out of scope. The supported
target is native `IMAGE_FILE_MACHINE_ARM64`. `PeArchitecture.ps1` recognises the
ARM64EC and ARM64X machine values so that such an image is reported explicitly
rather than being mistaken for a native ARM64 binary.

## Why the ARM64 suite count differs

`CppCoverageTest` executes 116 tests on both x64 and ARM64, but they are not the
same 116. Comparing the `[ RUN ]` lines of the two runs:

| Test | x64 | ARM64 |
| --- | --- | --- |
| `CppCliTest.ManagedUnManagedModule` | runs | excluded - MSVC has no `/clr` for ARM64 |
| `BreakPointTest.RejectsUnalignedArm64Address` | not compiled | runs - ARM64 `BRK` must be 4-byte aligned |

Win32 executes 115 because it excludes `CppCliTest.ManagedUnManagedModule` (the
C++/CLI fixture is built for x64 only) without gaining an ARM64-only test. Every
exclusion carries a written justification in `RunTests.ps1` and is copied into
`environment-<Platform>-<Configuration>.txt` and the test summary, so a skipped
test is always visible in the evidence.

## The build host toolchain must be pinned, not assumed

The toolchain preflight records which `cl.exe` *resolves*, but MSBuild selects
its host toolchain independently. On the ARM64 runner, MSBuild 2022 runs as a
32-bit process, so it defaulted to the emulated `bin\HostX86\arm64` compiler even
though `bin\Hostarm64\arm64` was present and was what vcpkg had used to configure
the dependencies. The build succeeded, but it was not produced by the toolchain
that had been verified, and nothing in the evidence said so.

Two things now prevent that:

- Each job passes `/p:PreferredToolArchitecture` (`arm64` on the ARM64 runner,
  `x64` on the x64 runners).
- `Assert-BuildToolchain.ps1` parses the actual `cl.exe` and `link.exe` command
  lines out of the build log after every build and fails when any of them comes
  from an unexpected host directory, when the toolset version is not consistent
  across invocations, or when no invocation is found at all.

This matters beyond tidiness. MSVC decodes a source file that has no BOM using
the ambient code page, so anything that changes which compiler process runs, or
the code page it runs under, can change how non-ASCII sources are interpreted.
Pinning the host removes that variable instead of relying on it.

Note that `/utf-8` is deliberately **not** used. Five source files
(`CodeCoverageRunnerTest.cpp`, `CoberturaExporterTest.cpp`,
`CoverageDataSerializerTest.cpp`, `TestCoverageConsole.cpp`, `ToolTest.cpp`) are
genuine upstream Windows-1252, carrying bytes `e9 e0 e8`. Forcing UTF-8
interpretation would corrupt exactly the special-character fixtures the tests
rely on.

## Source encoding is gated, because it broke the build once

An intermediate commit on this port (`bf5cdc1`) re-saved
`CppCoverageTest/CodeCoverageRunnerTest.cpp` as BOM-less UTF-8. The accented
bytes in its `#include "TestCoverageConsole/FileWithSpecialCharéàè.hpp"` line
went from `e9 e0 e8` (Windows-1252, 19184 bytes) to `c3 a9 c3 a0 c3 a8` (UTF-8,
19203 bytes). MSVC decodes a BOM-less file with the active code page, so on a
1252 host it looked for a mojibake'd path and failed with:

```
CodeCoverageRunnerTest.cpp(49,10): fatal error C1083: Cannot open include file
```

`Build/Scripts/SourceEncoding.ps1` and `Test-SourceEncoding.ps1` now run before
restore in every job. The gate reads raw bytes and classifies each tracked
source as `ascii`, `ansi`, `utf8-bom`, or `utf8-no-bom`. It rejects only two
things: a non-ASCII source with no BOM that is valid UTF-8, and a non-ASCII
quoted include that does not resolve on disk under the encoding MSVC would
actually use. Windows-1252 sources are explicitly accepted, so the upstream
files above are not asked to change.

It also locks an inventory of the six non-ASCII sources and their encodings, so
"normalizing" one of them fails the build instead of silently changing what the
compiler reads. The gate is verified against the real `bf5cdc1` bytes, not just
synthetic fixtures.

Two measurement traps are worth recording, because both produced a wrong
conclusion during this work:

- `GET /repos/.../contents/...` transcodes text to UTF-8. It reported the
  Windows-1252 and the UTF-8 revision of this file as identical, and its `size`
  field disagreed with the length of its own base64 payload. Use
  `GET /git/blobs/<sha>`, or compare git blob SHAs, for byte-level claims.
- In PowerShell, `git cat-file blob ... > file` decodes and re-encodes through
  the console encoding. Byte-level checks must use `[IO.File]::ReadAllBytes`.

## How a green run is guaranteed to be real

A previous CI run reported success while `CppCoverageTest` had exited 1 with
114 of 116 tests passing, because the step was marked `continue-on-error` and
the aggregate step never propagated a nonzero status.

The pipeline now enforces the following, and none of it depends on a step
author remembering to check an exit code:

1. `RunTests.ps1` runs every suite, then fails unless **every** suite exited 0,
   reported a Google Test summary, ran at least one test, and passed everything
   it ran.
2. `Test-FailClosed.ps1` is a deterministic regression that feeds synthetic
   results - including the exact shape of the false-green run - through the same
   decision function and requires each of them to be rejected. It needs no build
   output and runs on every platform.
3. `Assert-Results.ps1` runs last and re-derives the verdict from the recorded
   per-suite numbers instead of trusting the recorded `Success` flag. It also
   fails if a summary is missing, or if ARM64 results were not produced on a
   native ARM64 operating system.
4. The ARM64 job asserts `OSArchitecture -eq Arm64` before it does anything, so
   a cross-build can never be presented as native ARM64 execution.
5. `RunEndToEnd.ps1` runs twice: once against the build output and once, via
   `-PackageRoot`, against the re-expanded ZIP. `Assert-Results.ps1` requires
   both summaries, so a package that cannot start is never reported as good.

## Packaging pitfalls this port had to solve

Both of the following produced a payload that passed every static check while
being either impure or completely unrunnable, which is why the packaged
end-to-end run is a required gate rather than a nicety.

### The ARM64 CRT redistributable contains an x64 DLL

`VC\Redist\MSVC\<version>\arm64\Microsoft.VC*.CRT` ships an **x64**
`vcruntime140_1.dll` alongside the ARM64 binaries; that DLL implements x64
exception handling and has no ARM64 form. Copying the folder wholesale put a
foreign image into the ARM64 payload and the staging PE scan rejected it:

```
Expected only ARM64 PE images under ...\Binaries\vcruntime140_1.dll. x64
```

`CreateRelease.ps1` therefore checks the machine type of every redistributable
DLL, stages only matching ones, requires `vcruntime140.dll` and `msvcp140.dll`
to be present afterwards, and records the rejected files in `crt-manifest.json`
so the omission is explicit rather than silent.

### The package must contain `Plugins\Exporter`

`OpenCppCoverage.cpp` (`GetPluginsExportFolder`) enumerates
`<exe folder>\Plugins\Exporter` at startup and fails with
`directory_iterator: The system cannot find the path specified` when it is
missing. A ZIP cannot store an empty directory, so the packager creates the
folder and writes a `README.txt` placeholder into it. Test fixtures that the
build drops under `Plugins` are deliberately not shipped.
