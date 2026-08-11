param(
    [string]$OutputRoot,
    [string]$ProductExecutable,
    [ValidateRange(10, 300)]
    [int]$RecordingSeconds = 20,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repositoryRoot "build/e2e/perf-p2"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$dotnetCommand = Get-Command dotnet -ErrorAction Stop
$productProject = Join-Path $repositoryRoot "platforms/windows/src/ShotPaste.Windows/ShotPaste.Windows.csproj"
if (-not $SkipBuild) {
    & $dotnetCommand.Source build $productProject -c Release -p:Platform=x64
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ([string]::IsNullOrWhiteSpace($ProductExecutable)) {
    $ProductExecutable = Join-Path $repositoryRoot "platforms/windows/src/ShotPaste.Windows/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/ShotPaste.exe"
}
$ProductExecutable = [System.IO.Path]::GetFullPath($ProductExecutable)
if (-not (Test-Path -LiteralPath $ProductExecutable -PathType Leaf)) {
    throw "ShotPaste.exe was not found at $ProductExecutable"
}

function Invoke-BaselineProject {
    param(
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string[]]$Arguments
    )
    & $dotnetCommand.Source run --project $Project -c Release -- @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-BaselineProject `
    (Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.HistoryE2E/ShotPaste.Windows.HistoryE2E.csproj") `
    @($ProductExecutable, (Join-Path $OutputRoot "history"))

Invoke-BaselineProject `
    (Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.InlineE2E/ShotPaste.Windows.InlineE2E.csproj") `
    @($ProductExecutable, (Join-Path $OutputRoot "inline"), "performance_baseline")

Invoke-BaselineProject `
    (Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.RecordingE2E/ShotPaste.Windows.RecordingE2E.csproj") `
    @((Join-Path $OutputRoot "recording"), "--performance-only", "--performance-seconds=$RecordingSeconds")

$summary = [ordered]@{
    GeneratedAt = [DateTimeOffset]::Now
    ProductExecutable = $ProductExecutable
    RecordingSeconds = $RecordingSeconds
    History = Get-Content -LiteralPath (Join-Path $OutputRoot "history/summary.json") -Raw | ConvertFrom-Json
    Inline = Get-Content -LiteralPath (Join-Path $OutputRoot "inline/summary.json") -Raw | ConvertFrom-Json
    Recording = Get-Content -LiteralPath (Join-Path $OutputRoot "recording/performance-baseline/summary.json") -Raw | ConvertFrom-Json
}
$summaryPath = Join-Path $OutputRoot "summary.json"
$summary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Host "Performance baseline completed: $summaryPath"
