param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [switch]$Publish
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $repositoryRoot "platforms/windows/ShotPaste.Windows.sln"
$project = Join-Path $repositoryRoot "platforms/windows/src/ShotPaste.Windows/ShotPaste.Windows.csproj"

function Get-ShotPasteBuildProperty {
    param([Parameter(Mandatory = $true)][string]$Name)

    $result = & dotnet msbuild $project -nologo -p:Configuration=$Configuration -p:Platform=x64 "-getProperty:$Name"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $value = ($result | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "MSBuild property '$Name' is empty." }
    return $value
}

function Test-ShotPasteBuildIdentity {
    param([Parameter(Mandatory = $true)][string]$Executable)

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "ShotPaste app artifact was not found: $Executable"
    }
    $process = Start-Process -FilePath $Executable -ArgumentList "--verify-build-identity" -PassThru
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch [System.InvalidOperationException] { }
        throw "ShotPaste build identity verification timed out: $Executable"
    }
    if ($process.ExitCode -ne 0) {
        throw "ShotPaste build identity verification failed with exit code $($process.ExitCode): $Executable"
    }
    Write-Host "Verified $Configuration app identity: $Executable"
}

dotnet restore $solution -p:Platform=x64
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
dotnet test $solution -c $Configuration -p:Platform=x64 --no-restore `
    --filter "FullyQualifiedName!~ScrollingStitcherTests&FullyQualifiedName!~ClipboardMonitorServiceTests.CaptureFileDropAsync_CreatesOneTypedRecordPerPathAndDeduplicatesReplay&FullyQualifiedName!~CaptureHistoryStoreTests"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Run native-memory-heavy stitch/database regressions in a fresh test host. Keeping
# them isolated avoids carrying WPF/OCR/native bitmap state from the broad suite.
dotnet test $solution -c $Configuration -p:Platform=x64 --no-restore --no-build `
    --filter "FullyQualifiedName~ScrollingStitcherTests|FullyQualifiedName~ClipboardMonitorServiceTests.CaptureFileDropAsync_CreatesOneTypedRecordPerPathAndDeduplicatesReplay|FullyQualifiedName~CaptureHistoryStoreTests"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$targetDirectory = Get-ShotPasteBuildProperty -Name "TargetDir"
$assemblyName = Get-ShotPasteBuildProperty -Name "AssemblyName"
$application = Join-Path $targetDirectory "$assemblyName.exe"
Test-ShotPasteBuildIdentity -Executable $application

# Compile every E2E project in the solution and execute the stable parity contract
# subset on ordinary/non-interactive build agents. Real desktop E2E is orchestrated
# by test-windows-parity.ps1 -Tier Interactive on the dedicated Windows node.
& (Join-Path $PSScriptRoot "test-windows-parity.ps1") `
    -Configuration $Configuration `
    -Tier Headless `
    -SkipBuild
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Publish) {
    dotnet publish $project -c $Configuration -r win-x64 --self-contained true -p:Platform=x64 -p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Test-ShotPasteBuildIdentity -Executable (Join-Path $targetDirectory "publish\$assemblyName.exe")
}
