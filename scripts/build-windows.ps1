param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [switch]$Publish
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $repositoryRoot "platforms/windows/ShotPaste.Windows.sln"

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

if ($Publish) {
    $project = Join-Path $repositoryRoot "platforms/windows/src/ShotPaste.Windows/ShotPaste.Windows.csproj"
    dotnet publish $project -c $Configuration -r win-x64 --self-contained true -p:Platform=x64 -p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
