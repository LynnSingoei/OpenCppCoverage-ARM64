$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$solutionPath = Join-Path $repositoryRoot "CppCoverage.sln"
$solution = Get-Content -LiteralPath $solutionPath -Raw
$requiredProjects = @(
    "CppCoverage", "OpenCppCoverage", "CppCoverageTest", "TestCoverageConsole",
    "Exporter", "ExporterTest", "TestCoverageSharedLib", "OpenCppCoverageTest",
    "Tools", "TestHelper", "FileFilter", "FileFilterTest", "ToolsTest",
    "TestCoverageOptimizedBuild", "TestCppCli", "Plugin", "PluginTest"
)

foreach ($projectName in $requiredProjects) {
    $projectPattern =
        '(?m)^Project\("[^"]+"\) = "' + [regex]::Escape($projectName) +
        '", "(?<Path>[^"]+)", "(?<Guid>\{[^}]+\})"\r?$'
    $projectMatch = [regex]::Match($solution, $projectPattern)
    if (-not $projectMatch.Success) {
        throw "Required project is missing from CppCoverage.sln: $projectName"
    }

    $guid = [regex]::Escape($projectMatch.Groups["Guid"].Value)
    foreach ($configuration in @("Debug", "Release")) {
        foreach ($mapping in @("ActiveCfg", "Build\.0")) {
            $mappingPattern =
                "(?m)^\s*$guid\.$configuration\|ARM64\.$mapping\s*=\s*" +
                "$configuration\|ARM64\s*\r?$"
            if ($solution -notmatch $mappingPattern) {
                throw "$projectName is not explicitly selected for $configuration|ARM64 ($mapping)."
            }
        }
    }

    $projectPath = Join-Path $repositoryRoot $projectMatch.Groups["Path"].Value
    [xml]$project = Get-Content -LiteralPath $projectPath
    $namespace = [Xml.XmlNamespaceManager]::new($project.NameTable)
    $namespace.AddNamespace("m", "http://schemas.microsoft.com/developer/msbuild/2003")
    foreach ($configuration in @("Debug", "Release")) {
        $configurationNode = $project.SelectSingleNode(
            "//m:ProjectConfiguration[@Include='$configuration|ARM64']", $namespace)
        if (-not $configurationNode) {
            throw "$projectName lacks a $configuration|ARM64 project configuration."
        }

        $propertyGroup = @(
            @($project.SelectNodes(
                "//m:PropertyGroup[@Label='Configuration']", $namespace)) |
                Where-Object {
                    $_.Condition -eq "'`$(Configuration)|`$(Platform)'=='$configuration|ARM64'"
                }
        )
        if ($propertyGroup.Count -ne 1 -or
            [string]$propertyGroup[0].PlatformToolset -ne "v143") {
            throw "$projectName $configuration|ARM64 must use PlatformToolset v143."
        }
    }
}

$cppCoverageTest = Get-Content -LiteralPath (
    Join-Path $repositoryRoot "CppCoverageTest\CppCoverageTest.vcxproj") -Raw
if ($cppCoverageTest -match
    '(?s)<ClCompile Include="CppCliTest\.cpp">.*?ExcludedFromBuild.*?ARM64') {
    throw "CppCliTest.cpp is excluded from the ARM64 test binary."
}

$directoryTargets = Get-Content -LiteralPath (
    Join-Path $repositoryRoot "Directory.Build.targets") -Raw
if ($directoryTargets -notmatch
    [regex]::Escape("'`$(PreferredToolArchitecture)' != 'arm64'")) {
    throw "Directory.Build.targets does not enforce the native ARM64 compiler host."
}

$arm64Workflow = Get-Content -LiteralPath (
    Join-Path $repositoryRoot ".github\workflows\arm64-compat.yml") -Raw
if ($arm64Workflow -notmatch '(?m)/p:PreferredToolArchitecture=arm64\s*`' -or
    $arm64Workflow -notmatch '(?m)-PreferredToolArchitecture arm64\s*`' -or
    $arm64Workflow -notmatch '(?m)-HostArchitecture arm64\s*`' -or
    $arm64Workflow -notmatch '(?m)& "\$env:MSBUILD_EXE" /m CppCoverage\.sln' -or
    $arm64Workflow -notmatch '(?m)-ExpectedHost Hostarm64\s*`' -or
    $arm64Workflow -notmatch '(?m)-Configuration Release -LogDirectory artifacts\\logs' -or
    $arm64Workflow -notmatch '(?m)-PackageRoot \$packageRoot -Label packaged') {
    throw "The native ARM64 workflow does not select and verify the native ARM64 MSBuild host."
}

Write-Output "ARM64 graph includes all $($requiredProjects.Count) required projects in Debug and Release."
