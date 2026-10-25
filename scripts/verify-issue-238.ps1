[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Repository,

    [Parameter(Mandatory)]
    [string]$VcpkgRoot,

    [string]$VisualStudioRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise',
    [ValidateRange(2, 20)]
    [int]$Iterations = 3,
    [string]$OutputRoot = (Join-Path $PWD 'issue-238-results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BaselineSha = 'd07608d5d39ae08af75430b33c2d1a03b90b4956'
$PrHeadSha = 'c41a5384fb26b3d4fe73ab867fb30787c3a8bd1b'
$Vstest = Join-Path $VisualStudioRoot 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe'
$Toolchain = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
$Vcpkg = Join-Path $VcpkgRoot 'vcpkg.exe'
$Filter = 'FullyQualifiedName~EventMonitorTests|FullyQualifiedName~JsonProcessorTests|FullyQualifiedName~UtilityTests'

foreach ($RequiredPath in @($Repository, $VcpkgRoot, $Vstest, $Toolchain, $Vcpkg)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required path not found: $RequiredPath"
    }
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$Repository = (Resolve-Path -LiteralPath $Repository).Path
$VcpkgRoot = (Resolve-Path -LiteralPath $VcpkgRoot).Path

function Invoke-Recorded {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList 2>&1 | Tee-Object -FilePath $LogPath
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

function Get-TrxSummary {
    param([Parameter(Mandatory)][string]$TrxPath)

    if (-not (Test-Path -LiteralPath $TrxPath)) {
        return [ordered]@{ Present = $false; XmlValid = $false; Outcome = $null; Counters = $null }
    }

    try {
        [xml]$Trx = Get-Content -LiteralPath $TrxPath -Raw
        $Summary = $Trx.TestRun.ResultSummary
        return [ordered]@{
            Present = $true
            XmlValid = $true
            Outcome = [string]$Summary.outcome
            Counters = if ($null -ne $Summary.Counters) { [ordered]@{
                Total = [int]$Summary.Counters.total
                Executed = [int]$Summary.Counters.executed
                Passed = [int]$Summary.Counters.passed
                Failed = [int]$Summary.Counters.failed
                Error = [int]$Summary.Counters.error
                Aborted = [int]$Summary.Counters.aborted
            }} else { $null }
        }
    }
    catch {
        return [ordered]@{ Present = $true; XmlValid = $false; Outcome = $null; Counters = $null; ParseError = $_.Exception.Message }
    }
}

$Environment = [ordered]@{
    CollectedAt = (Get-Date).ToString('o')
    ComputerInfo = Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture
    GitVersion = (& git --version 2>&1 | Out-String).Trim()
    CMakeVersion = (& cmake --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    VstestPath = $Vstest
    VstestVersion = (Get-Item -LiteralPath $Vstest).VersionInfo.FileVersion
    VisualStudioRoot = $VisualStudioRoot
    VcpkgRoot = $VcpkgRoot
    ApplicationLogRecordCount = (Get-WinEvent -ListLog Application).RecordCount
}
$Environment | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'environment.json') -Encoding utf8

$Results = @()
$Targets = @(
    [ordered]@{ Name = 'baseline'; Sha = $BaselineSha },
    [ordered]@{ Name = 'pr-head'; Sha = $PrHeadSha }
)

foreach ($Target in $Targets) {
    $TargetRoot = Join-Path $OutputRoot $Target.Name
    $Worktree = Join-Path $TargetRoot 'src'
    $Build = Join-Path $Worktree 'LogMonitor\build'
    New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null

    & git -C $Repository cat-file -e "$($Target.Sha)^{commit}"
    if ($LASTEXITCODE -ne 0) { throw "Commit is unavailable locally: $($Target.Sha)" }
    & git -C $Repository worktree add --detach $Worktree $Target.Sha
    if ($LASTEXITCODE -ne 0) { throw "Could not create worktree for $($Target.Sha)" }

    $ResolvedSha = (& git -C $Worktree rev-parse HEAD).Trim()
    $ConfigureLog = Join-Path $TargetRoot 'configure.log'
    $ConfigureArgs = @(
        '-S', (Join-Path $Worktree 'LogMonitor'),
        '-B', $Build,
        '-G', 'Visual Studio 17 2022',
        '-A', 'x64',
        "-DCMAKE_TOOLCHAIN_FILE=$Toolchain",
        '-DVCPKG_TARGET_TRIPLET=x64-windows-static'
    )
    $ConfigureExit = Invoke-Recorded -FilePath 'cmake' -ArgumentList $ConfigureArgs -LogPath $ConfigureLog -WorkingDirectory $Worktree

    $BuildLog = Join-Path $TargetRoot 'build.log'
    $BuildExit = if ($ConfigureExit -eq 0) {
        Invoke-Recorded -FilePath 'cmake' -ArgumentList @('--build', $Build, '--config', 'Release', '--target', 'LogMonitorTests', '--parallel', '4') -LogPath $BuildLog -WorkingDirectory $Worktree
    } else { $null }

    if ($ConfigureExit -ne 0 -or $BuildExit -ne 0) {
        $Results += [ordered]@{ Target = $Target.Name; Sha = $ResolvedSha; ConfigureExitCode = $ConfigureExit; BuildExitCode = $BuildExit; Run = 'NOT RUN' }
        continue
    }

    $TestDll = Join-Path $Build 'Release\LogMonitorTests.dll'
    if (-not (Test-Path -LiteralPath $TestDll)) { throw "Test DLL not found: $TestDll" }

    for ($Iteration = 1; $Iteration -le $Iterations; $Iteration++) {
        $RunRoot = Join-Path $TargetRoot ("run-{0:D2}" -f $Iteration)
        New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
        $TrxName = 'event-monitor-repro.trx'
        $TrxPath = Join-Path $RunRoot $TrxName
        $RunLog = Join-Path $RunRoot 'vstest.log'
        $Args = @(
            $TestDll,
            "/TestCaseFilter:$Filter",
            "/Logger:trx;LogFileName=$TrxName",
            "/ResultsDirectory:$RunRoot"
        )
        $StartedAt = Get-Date
        $ExitCode = Invoke-Recorded -FilePath $Vstest -ArgumentList $Args -LogPath $RunLog -WorkingDirectory $Worktree
        $EndedAt = Get-Date
        $Trx = Get-TrxSummary -TrxPath $TrxPath
        $CountersComplete = $null -ne $Trx.Counters -and
            $Trx.Counters.Executed -eq $Trx.Counters.Total -and
            $Trx.Counters.Failed -eq 0 -and
            $Trx.Counters.Error -eq 0 -and
            $Trx.Counters.Aborted -eq 0
        $ExitCodeHex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ExitCode), 0))

        $Result = [ordered]@{
            Target = $Target.Name
            Sha = $ResolvedSha
            Iteration = $Iteration
            StartedAt = $StartedAt.ToString('o')
            EndedAt = $EndedAt.ToString('o')
            DurationSeconds = [math]::Round(($EndedAt - $StartedAt).TotalSeconds, 3)
            ProcessExitCodeSigned = $ExitCode
            ProcessExitCodeHex = $ExitCodeHex
            Trx = $Trx
            FullRunPass = ($ExitCode -eq 0 -and $Trx.Present -and $Trx.XmlValid -and $Trx.Outcome -eq 'Completed' -and $CountersComplete)
        }
        $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunRoot 'result.json') -Encoding utf8
        $Results += $Result
    }
}

$Results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding utf8
$Results | Format-Table Target, Sha, Iteration, ProcessExitCodeSigned, ProcessExitCodeHex, FullRunPass -AutoSize

Write-Host "Results saved to: $OutputRoot"
Write-Host 'This script does not clear or delete Windows Application event logs.'
Write-Host 'If the baseline crashes, use an already-approved dump-capture setup for a repeat run; do not publish private dump contents.'
