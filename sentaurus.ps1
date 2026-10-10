[CmdletBinding()]
param(
    [ValidateSet('Run', 'Smoke', 'Preflight', 'Check', 'Version', 'License', 'Probe', 'SmokeStatus', 'SWB', 'SWBStatus', 'SWBReport', 'SWBStop', 'SWBClean', 'Help')]
    [string]$Action = 'Run',
    [string]$Project = '/home/TCAD2022/STDB/codex_test/test1',
    [string]$RunId,
    [ValidateRange(2, 3600)]
    [int]$PollSeconds = 10,
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 10,
    [ValidateRange(0, 10)]
    [int]$RetryCount = 1,
    [ValidateRange(0, 3650)]
    [int]$KeepDays = 14,
    [switch]$NoPreflight,
    [switch]$NoFetch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$resultsRoot = Join-Path $root 'results'
$nativeConfig = if (Test-Path -LiteralPath (Join-Path $root 'ssh_config.local')) {
    Join-Path $root 'ssh_config.local'
} else {
    Join-Path $root 'ssh_config'
}
$knownHosts = (Join-Path $root 'known_hosts').Replace('\', '/')

function Show-Help {
    $helpText = @(
        'Sentaurus project controller',
        '',
        'Default:',
        "  ./sentaurus.ps1 -Action Run",
        '    Run preflight, submit the diode smoke test, wait, and fetch results.',
        '',
        'SWB commands:',
        "  ./sentaurus.ps1 -Action Preflight",
        "  ./sentaurus.ps1 -Action SWB -Project /home/TCAD2022/STDB/codex_test/test1",
        "  ./sentaurus.ps1 -Action SWBStatus -Project /home/TCAD2022/STDB/codex_test/test1",
        "  ./sentaurus.ps1 -Action SWBReport -Project /home/TCAD2022/STDB/codex_test/test1",
        "  ./sentaurus.ps1 -Action SWBStop -Project /home/TCAD2022/STDB/codex_test/test1",
        "  ./sentaurus.ps1 -Action SWBClean -Project /home/TCAD2022/STDB/codex_test/test1",
        '',
        'Run accepts -NoPreflight and -NoFetch.'
    )
    $helpText | Write-Output
}

function Invoke-ProjectScript {
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$Capture,
        [switch]$Quiet
    )

    $scriptPath = Join-Path $root $Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Missing project script: $scriptPath"
    }

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $Quiet) { $output | Write-Output }
    if ($exitCode -ne 0) {
        throw "$Script failed with exit code $exitCode."
    }
    if ($Capture) {
        return [pscustomobject]@{ Lines = $output; ExitCode = $exitCode }
    }
}

function Invoke-Preflight {
    Write-Output '=== SENTaurus PREFLIGHT ==='
    Invoke-ProjectScript -Script 'ssh.ps1' -Arguments @('-Action', 'Check')
    Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'Version')
    Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'Probe')
    Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'License')
    Write-Output 'PREFLIGHT_OK'
}

function Get-SmokeInfo {
    $latestPath = Join-Path $resultsRoot 'latest-smoke.json'
    if (-not (Test-Path -LiteralPath $latestPath)) {
        throw "Smoke run metadata is missing: $latestPath"
    }
    $info = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$info.runId -notmatch '^diode-smoke-[A-Za-z0-9]{8}$') {
        throw "Invalid smoke run ID in $latestPath"
    }
    if ([string]$info.remoteDirectory -notmatch '^/home/TCAD2022/codex-sentaurus/runs/diode-smoke-[A-Za-z0-9]{8}$') {
        throw "Invalid smoke remote directory in $latestPath"
    }
    return $info
}

function Get-SmokeState {
    param([string[]]$Lines)
    $first = $Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1
    if ($first -match '^COMPLETED$') { return 'COMPLETED' }
    if ($first -match '^FAILED(?:\s|$)') { return 'FAILED' }
    if ($first -match '^RUNNING$') { return 'RUNNING' }
    if ($first -match '^PENDING$') { return 'PENDING' }
    return 'UNKNOWN'
}

function Wait-Smoke {
    param(
        [Parameter(Mandatory)]
        [string]$SmokeRunId
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastState = ''
    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Smoke run $SmokeRunId exceeded $TimeoutMinutes minutes."
        }

        $status = Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'SmokeStatus', '-RunId', $SmokeRunId) -Capture -Quiet
        $state = Get-SmokeState -Lines $status.Lines
        if ($state -ne $lastState) {
            Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Smoke state: $state"
            $lastState = $state
        }

        if ($state -eq 'COMPLETED') {
            $status.Lines | Write-Output
            return
        }
        if ($state -eq 'FAILED') {
            $status.Lines | Write-Output
            throw "Smoke run $SmokeRunId failed."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Fetch-SmokeArtifacts {
    param(
        [Parameter(Mandatory)]
        [object]$SmokeInfo
    )

    $scp = (Get-Command scp.exe -ErrorAction Stop).Source
    $destination = Join-Path $resultsRoot (Join-Path 'runs' ([string]$SmokeInfo.runId))
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $files = @('status.txt', 'diode_iv_des.plt', 'iv.csv', 'metrics.json', 'structure.log', 'device.log', 'launcher.log')

    foreach ($name in $files) {
        $source = 'tcad-vm:' + [string]$SmokeInfo.remoteDirectory + '/' + $name
        $arguments = @(
            '-F', $nativeConfig,
            '-o', ('UserKnownHostsFile="{0}"' -f $knownHosts),
            '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes',
            $source,
            $destination
        )
        & $scp @arguments 2>&1 | ForEach-Object { [string]$_ } | Write-Output
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Fetched $name"
        } else {
            Write-Warning "Optional artifact is unavailable: $name"
        }
    }

    $record = [ordered]@{
        runId = [string]$SmokeInfo.runId
        remoteDirectory = [string]$SmokeInfo.remoteDirectory
        fetchedAt = (Get-Date).ToString('o')
        localDirectory = (Resolve-Path -LiteralPath $destination).Path
    }
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'run.json') -Encoding UTF8
    Write-Output "Local results: $destination"
}

function Run-Smoke {
    if (-not $NoPreflight) { Invoke-Preflight }
    Write-Output '=== SUBMIT DIODE SMOKE ==='
    Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'Smoke')
    $info = Get-SmokeInfo
    $smokeRunId = [string]$info.runId
    Write-Output "Run ID: $smokeRunId"
    Wait-Smoke -SmokeRunId $smokeRunId
    if (-not $NoFetch) { Fetch-SmokeArtifacts -SmokeInfo $info }
    Write-Output "SMOKE_OK=$smokeRunId"
}

switch ($Action) {
    'Help' { Show-Help; break }
    'Check' { Invoke-ProjectScript -Script 'ssh.ps1' -Arguments @('-Action', 'Check'); break }
    'Version' { Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'Version'); break }
    'License' { Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'License'); break }
    'Probe' { Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'Probe'); break }
    'Preflight' { Invoke-Preflight; break }
    'Run' { Run-Smoke; break }
    'Smoke' { Run-Smoke; break }
    'SmokeStatus' {
        if (-not $RunId) { $RunId = [string](Get-SmokeInfo).runId }
        Invoke-ProjectScript -Script 'tcad.ps1' -Arguments @('-Action', 'SmokeStatus', '-RunId', $RunId)
        break
    }
    'SWB' {
        if (-not $NoPreflight) { Invoke-Preflight }
        Invoke-ProjectScript -Script 'swb.ps1' -Arguments @(
            '-Action', 'Run', '-Project', $Project, '-RetryCount', [string]$RetryCount,
            '-PollSeconds', [string]$PollSeconds, '-TimeoutMinutes', [string]$TimeoutMinutes
        )
        break
    }
    'SWBStatus' {
        $statusArguments = @('-Action', 'Status', '-Project', $Project, '-RetryCount', [string]$RetryCount)
        if ($RunId) { $statusArguments += @('-RunId', $RunId) }
        Invoke-ProjectScript -Script 'swb.ps1' -Arguments $statusArguments
        break
    }
    'SWBReport' {
        $reportArguments = @('-Action', 'Report', '-Project', $Project, '-RetryCount', [string]$RetryCount)
        if ($RunId) { $reportArguments += @('-RunId', $RunId) }
        Invoke-ProjectScript -Script 'swb.ps1' -Arguments $reportArguments
        break
    }
    'SWBStop' {
        $stopArguments = @('-Action', 'Stop', '-Project', $Project, '-RetryCount', [string]$RetryCount)
        if ($RunId) { $stopArguments += @('-RunId', $RunId) }
        Invoke-ProjectScript -Script 'swb.ps1' -Arguments $stopArguments
        break
    }
    'SWBClean' {
        Invoke-ProjectScript -Script 'swb.ps1' -Arguments @('-Action', 'Clean', '-Project', $Project, '-RetryCount', [string]$RetryCount, '-KeepDays', [string]$KeepDays)
        break
    }
}
