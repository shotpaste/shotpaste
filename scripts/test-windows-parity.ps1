param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [ValidateSet("Headless", "Interactive", "All")]
    [string]$Tier = "Headless",
    [switch]$SkipBuild,
    [string]$ProductExecutable,
    [string]$OutputRoot,
    [ValidateRange(0.0, 4.0)]
    [double]$RequireDpiScale = 0
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $repositoryRoot "platforms/windows/ShotPaste.Windows.sln"
$unitTests = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.Tests/ShotPaste.Windows.Tests.csproj"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repositoryRoot "build/e2e/windows-parity"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source

$projects = [ordered]@{
    History = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.HistoryE2E/ShotPaste.Windows.HistoryE2E.csproj"
    Inline = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.InlineE2E/ShotPaste.Windows.InlineE2E.csproj"
    Localization = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.LocalizationE2E/ShotPaste.Windows.LocalizationE2E.csproj"
    Ocr = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.OcrE2E/ShotPaste.Windows.OcrE2E.csproj"
    Recording = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.RecordingE2E/ShotPaste.Windows.RecordingE2E.csproj"
    Scrolling = Join-Path $repositoryRoot "platforms/windows/tests/ShotPaste.Windows.ScrollingE2E/ShotPaste.Windows.ScrollingE2E.csproj"
}

$results = [ordered]@{}
$summaryPath = Join-Path $OutputRoot "summary.json"
$gateFailure = $null
try {
    if (-not $SkipBuild) {
        & $dotnet build $solution -c $Configuration -p:Platform=x64
        if ($LASTEXITCODE -ne 0) { throw "Windows solution build failed with exit code $LASTEXITCODE." }
    }

    if ($Tier -in @("Headless", "All")) {
        $contractFilter = "FullyQualifiedName~AppControllerFlowTests|FullyQualifiedName~CaptureHistoryDeletionSafetyTests|FullyQualifiedName~ImageFileServiceTests|FullyQualifiedName~ShotPasteMcpTests|FullyQualifiedName~RecordingAnnotationStateTests|FullyQualifiedName~InlineAreaGeometryTests|FullyQualifiedName~ScrollingProgressWindowTests|FullyQualifiedName~UiDesignSystemTests|FullyQualifiedName~LocalizationServiceTests"
        $started = [DateTimeOffset]::Now
        & $dotnet test $unitTests -c $Configuration -p:Platform=x64 --no-restore --no-build --filter $contractFilter
        $exitCode = $LASTEXITCODE
        $results.Headless = [ordered]@{
            Status = if ($exitCode -eq 0) { "Passed" } else { "Failed" }
            ExitCode = $exitCode
            StartedAt = $started
            CompletedAt = [DateTimeOffset]::Now
            ContractFilter = $contractFilter
            E2EProjectsCompiled = @($projects.Keys)
        }
        if ($exitCode -ne 0) { throw "Headless parity contracts failed with exit code $exitCode." }
    }

    if ($Tier -in @("Interactive", "All")) {
        if (-not [Environment]::UserInteractive) {
            throw "Interactive Windows parity E2E requires a signed-in desktop session."
        }
        if ([string]::IsNullOrWhiteSpace($ProductExecutable)) {
            $ProductExecutable = Join-Path $repositoryRoot "platforms/windows/src/ShotPaste.Windows/bin/x64/$Configuration/net8.0-windows10.0.19041.0/win-x64/ShotPaste.exe"
        }
        $ProductExecutable = [System.IO.Path]::GetFullPath($ProductExecutable)
        if (-not (Test-Path -LiteralPath $ProductExecutable -PathType Leaf)) {
            throw "ShotPaste.exe was not found at $ProductExecutable"
        }

        function Invoke-ParityProject {
            param(
                [Parameter(Mandatory)] [string]$Name,
                [string]$ResultName = $Name,
                [Parameter(Mandatory)] [string[]]$Arguments
            )
            $project = $projects[$Name]
            $started = [DateTimeOffset]::Now
            & $dotnet run --project $project -c $Configuration -p:Platform=x64 --no-build -- @Arguments
            $exitCode = $LASTEXITCODE
            $results[$ResultName] = [ordered]@{
                Status = if ($exitCode -eq 0) { "Passed" } else { "Failed" }
                ExitCode = $exitCode
                StartedAt = $started
                CompletedAt = [DateTimeOffset]::Now
                Arguments = $Arguments
            }
            if ($exitCode -ne 0) { throw "$Name parity E2E failed with exit code $exitCode." }
        }

        Invoke-ParityProject -Name History -Arguments @(
            $ProductExecutable,
            (Join-Path $OutputRoot "history"))
        Invoke-ParityProject -Name Inline -Arguments @(
            $ProductExecutable,
            (Join-Path $OutputRoot "inline"))
        $localizationArguments = @($ProductExecutable, (Join-Path $OutputRoot "localization"))
        if ($RequireDpiScale -gt 0) { $localizationArguments += "--require-dpi-scale=$RequireDpiScale" }
        Invoke-ParityProject -Name Localization -Arguments $localizationArguments
        Invoke-ParityProject -Name Ocr -Arguments @((Join-Path $OutputRoot "ocr"))
        Invoke-ParityProject -Name Recording -Arguments @(
            (Join-Path $OutputRoot "recording"),
            $ProductExecutable)
        Invoke-ParityProject -Name Scrolling -ResultName ScrollingLive -Arguments @(
            "--live",
            (Join-Path $OutputRoot "scrolling/live.png"))
        Invoke-ParityProject -Name Scrolling -ResultName ScrollingEdge -Arguments @(
            "--edge",
            (Join-Path $OutputRoot "scrolling/edge.png"))
    }
}
catch {
    $gateFailure = $_
}
finally {
    $summary = [ordered]@{
        GeneratedAt = [DateTimeOffset]::Now
        Status = if ($null -eq $gateFailure) { "Passed" } else { "Failed" }
        Failure = if ($null -eq $gateFailure) { $null } else { $gateFailure.Exception.Message }
        Configuration = $Configuration
        Tier = $Tier
        ProductExecutable = $ProductExecutable
        RequireDpiScale = $RequireDpiScale
        Results = $results
        InteractiveSkipReason = if ($Tier -eq "Headless") { "Interactive UI, capture, clipboard, OCR, localization, and recording checks require a signed-in Windows desktop." } else { $null }
    }
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}

if ($null -ne $gateFailure) {
    Write-Error "Windows parity gate failed; summary: $summaryPath`n$($gateFailure.Exception.Message)"
    exit 1
}
Write-Host "Windows parity gate passed: $summaryPath"
