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
