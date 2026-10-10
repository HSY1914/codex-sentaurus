[CmdletBinding()]
param(
    [ValidateSet('Run', 'Status', 'Report', 'Stop', 'Clean')]
    [string]$Action = 'Run',
    [string]$Project = '/home/TCAD2022/STDB/codex_test/test1',
    [string]$RunId,
    [ValidateRange(0, 10)]
    [int]$RetryCount = 1,
    [ValidateRange(2, 3600)]
    [int]$PollSeconds = 10,
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 240,
    [ValidateRange(0, 3650)]
    [int]$KeepDays = 14
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$nativeConfig = if (Test-Path -LiteralPath (Join-Path $root 'ssh_config.local')) {
    Join-Path $root 'ssh_config.local'
} else {
    Join-Path $root 'ssh_config'
}
$knownHosts = (Join-Path $root 'known_hosts').Replace('\', '/')
$ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
$sshArgs = @(
    '-T', '-F', $nativeConfig,
    '-o', ('UserKnownHostsFile="{0}"' -f $knownHosts),
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ConnectTimeout=8',
    'tcad-vm'
)
$remoteController = Join-Path $root 'remote/swb-controller.sh'
if (-not (Test-Path -LiteralPath $remoteController)) { throw "Missing remote controller: $remoteController" }
$logDirectory = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$resultsDirectory = Join-Path $root 'results'
$runStateDirectory = Join-Path $resultsDirectory 'runs'
$latestStatePath = Join-Path $resultsDirectory 'latest-swb.json'
New-Item -ItemType Directory -Force -Path $runStateDirectory | Out-Null

function Quote-Posix([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Controller([string]$RemoteAction) {
    $arguments = @($RemoteAction, $Project, [string]$RetryCount, [string]$KeepDays)
    $quoted = ($arguments | ForEach-Object { Quote-Posix $_ }) -join ' '
    $command = 'tr -d ''\r'' | bash -s -- ' + $quoted
    $script = Get-Content -LiteralPath $remoteController -Raw -Encoding UTF8
    # Keep the remote command as one final SSH argument and include the host
    # in $sshArgs.  PowerShell 7 otherwise lets the command occupy the host
    # position, and bash needs CR stripping when input crosses Windows pipes.
    $sshInvocation = @($sshArgs + @($command))
    $output = @($script | & $ssh @sshInvocation 2>&1)
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

function Save-Log([string]$Path, [object[]]$Lines) {
    if ($Lines) { $Lines | ForEach-Object { [string]$_ } | Add-Content -LiteralPath $Path -Encoding UTF8 }
}

function Parse-Fields([object[]]$Lines) {
    $fields = @{}
    foreach ($line in $Lines) {
        $text = [string]$line
        if ($text -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
    }
    return $fields
}

function Get-Field([hashtable]$Fields, [string]$Name, [string]$Fallback = '') {
    if ($Fields.ContainsKey($Name) -and $null -ne $Fields[$Name]) {
        return [string]$Fields[$Name]
    }
    return $Fallback
}

function Get-FieldAny([hashtable]$Fields, [string[]]$Names, [string]$Fallback = '') {
    foreach ($name in $Names) {
        $value = Get-Field $Fields $name
        if ($value) { return $value }
    }
    return $Fallback
}

function Save-RunMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$RunId,
        [hashtable]$Fields = @{},
        [string]$StateOverride,
        [string]$Message
    )

    if ($RunId -notmatch '^swb-[0-9]{8}-[0-9]{6}-[0-9]+$') { return }
    $runDirectory = Join-Path $runStateDirectory $RunId
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $runPath = Join-Path $runDirectory 'run.json'
    $existing = if (Test-Path -LiteralPath $runPath) {
        Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        [pscustomobject]@{}
    }
    $state = if ($StateOverride) { $StateOverride } else { Get-Field $Fields 'STATE' ([string]$existing.state) }
    $metadata = [ordered]@{
        runId = $RunId
        project = Get-Field $Fields 'PROJECT' ([string]$existing.project)
        state = $state
        process = Get-Field $Fields 'PROCESS' ([string]$existing.process)
        swbStatus = Get-Field $Fields 'SWB_STATUS' (Get-Field $Fields 'SWBSTATUS' ([string]$existing.swbStatus))
        pid = Get-Field $Fields 'PID' ([string]$existing.pid)
        nodesTotal = Get-Field $Fields 'NODES_TOTAL' ([string]$existing.nodesTotal)
        nodesDone = Get-Field $Fields 'NODES_DONE' ([string]$existing.nodesDone)
        nodesRunning = Get-Field $Fields 'NODES_RUNNING' ([string]$existing.nodesRunning)
        nodesQueued = Get-Field $Fields 'NODES_QUEUED' ([string]$existing.nodesQueued)
        nodesFailed = Get-Field $Fields 'NODES_FAILED' ([string]$existing.nodesFailed)
        attempt = Get-Field $Fields 'ATTEMPT' ([string]$existing.attempt)
        exitCode = Get-Field $Fields 'EXITCODE' ([string]$existing.exitCode)
        startedAt = Get-FieldAny $Fields @('STARTED_AT', 'STARTEDAT') ([string]$existing.startedAt)
        updatedAt = Get-FieldAny $Fields @('UPDATED_AT', 'UPDATEDAT') ([string]$existing.updatedAt)
        observedAt = Get-FieldAny $Fields @('OBSERVED_AT', 'OBSERVEDAT') ([string]$existing.observedAt)
        finishedAt = Get-FieldAny $Fields @('FINISHED_AT', 'FINISHEDAT') ([string]$existing.finishedAt)
        log = Get-Field $Fields 'LOG' ([string]$existing.log)
        message = if ($Message) { $Message } else { [string]$existing.message }
        clientUpdatedAt = (Get-Date).ToString('o')
    }
    $json = $metadata | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $runPath -Value $json -Encoding UTF8
    Set-Content -LiteralPath $latestStatePath -Value $json -Encoding UTF8
}

function Assert-RunId([string]$Value) {
    if ($Value -and $Value -notmatch '^swb-[0-9]{8}-[0-9]{6}-[0-9]+$') {
        throw "Invalid SWB run ID: $Value"
    }
}

function Invoke-WithRetry([string]$RemoteAction, [int]$Attempts = 3) {
    for ($try = 1; $try -le $Attempts; $try++) {
        $result = Invoke-Controller $RemoteAction
        if ($result.ExitCode -eq 0) { return $result }
        if ($try -eq $Attempts) { return $result }
        Start-Sleep -Seconds ([Math]::Min(5, $try * 2))
    }
}

if ($Action -eq 'Status') {
    Assert-RunId $RunId
    $result = Invoke-WithRetry 'status'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB status failed (exit $($result.ExitCode))." }
    $fields = Parse-Fields $result.Output
    $statusRunId = Get-FieldAny $fields @('RUN_ID', 'RUNID')
    if ($RunId -and $statusRunId -and $RunId -ne $statusRunId) {
        throw "Requested run $RunId is not the current remote run ($statusRunId)."
    }
    if (-not $statusRunId -and (Test-Path -LiteralPath $latestStatePath)) {
        $statusRunId = [string](Get-Content -LiteralPath $latestStatePath -Raw -Encoding UTF8 | ConvertFrom-Json).runId
    }
    if ($statusRunId) { Save-RunMetadata -RunId $statusRunId -Fields $fields }
    exit 0
}

if ($Action -eq 'Report') {
    Assert-RunId $RunId
    $result = Invoke-WithRetry 'report'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB report failed (exit $($result.ExitCode))." }
    $fields = Parse-Fields $result.Output
    $reportRunId = Get-FieldAny $fields @('RUN_ID', 'RUNID')
    if ($RunId -and $reportRunId -and $RunId -ne $reportRunId) {
        throw "Requested run $RunId is not the current remote run ($reportRunId)."
    }
    if (-not $reportRunId -and (Test-Path -LiteralPath $latestStatePath)) {
        $reportRunId = [string](Get-Content -LiteralPath $latestStatePath -Raw -Encoding UTF8 | ConvertFrom-Json).runId
    }
    if ($reportRunId) { Save-RunMetadata -RunId $reportRunId -Fields $fields }
    exit 0
}

if ($Action -eq 'Stop') {
    Assert-RunId $RunId
    $result = Invoke-WithRetry 'stop'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB stop failed (exit $($result.ExitCode))." }
    $fields = Parse-Fields $result.Output
    $stopRunId = if (Test-Path -LiteralPath $latestStatePath) {
        [string](Get-Content -LiteralPath $latestStatePath -Raw -Encoding UTF8 | ConvertFrom-Json).runId
    } else { '' }
    if ($stopRunId) { Save-RunMetadata -RunId $stopRunId -Fields $fields -StateOverride 'stopped' }
    exit 0
}

if ($Action -eq 'Clean') {
    $result = Invoke-WithRetry 'clean'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB clean failed (exit $($result.ExitCode))." }
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$start = Invoke-Controller 'start'
$start.Output | Write-Output
if ($start.ExitCode -ne 0) {
    if ($start.ExitCode -eq 20) { throw 'A SWB run is already active for this project. Use -Action Status or -Action Stop.' }
    throw "Could not start remote SWB controller (exit $($start.ExitCode))."
}
$startFields = Parse-Fields $start.Output
$runId = [string]$startFields['RUN_ID']
if ($runId -notmatch '^swb-[0-9]{8}-[0-9]{6}-[0-9]+$') { throw 'Remote controller returned an invalid run ID.' }
$localLog = Join-Path $logDirectory "SWB-$stamp-$runId.log"
Save-Log $localLog $start.Output
Save-RunMetadata -RunId $runId -Fields $startFields -StateOverride 'running'
Write-Output "SWB run submitted: $runId"
Write-Output "Remote project: $Project"
Write-Output "Polling every $PollSeconds seconds; timeout $TimeoutMinutes minutes."

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastState = ''
while ($true) {
    if ((Get-Date) -gt $deadline) {
        Write-Warning "SWB run exceeded $TimeoutMinutes minutes; requesting remote stop."
        $stopResult = Invoke-WithRetry 'stop'
        Save-Log $localLog $stopResult.Output
        Save-RunMetadata -RunId $runId -StateOverride 'timeout' -Message "Exceeded $TimeoutMinutes minutes."
        throw "SWB run timed out. Remote run $runId was stopped; inspect $localLog."
    }
    Start-Sleep -Seconds $PollSeconds
    $statusResult = Invoke-WithRetry 'status'
    Save-Log $localLog $statusResult.Output
    if ($statusResult.ExitCode -ne 0) {
        Save-RunMetadata -RunId $runId -StateOverride 'unknown' -Message 'Temporary status query failure; the remote run was left intact.'
        Write-Warning 'Temporary status query failure; the remote run is left intact and will be queried again.'
        continue
    }
    $fields = Parse-Fields $statusResult.Output
    Save-RunMetadata -RunId $runId -Fields $fields
    $state = "state=$($fields['STATE']); process=$($fields['PROCESS']); swb=$($fields['SWB_STATUS']); done=$($fields['NODES_DONE'])/$($fields['NODES_TOTAL']); failed=$($fields['NODES_FAILED'])"
    if ($state -ne $lastState) { Write-Output "[$(Get-Date -Format 'HH:mm:ss')] $state"; $lastState = $state }
    if ($fields['STATE'] -eq 'done' -and $fields['PROCESS'] -eq 'stopped' -and $fields['SWB_STATUS'] -eq 'done') { break }
    if ($fields['STATE'] -in @('failed', 'stopped', 'stale')) {
        $report = Invoke-WithRetry 'report'
        Save-Log $localLog $report.Output
        $report.Output | Write-Output
        Save-RunMetadata -RunId $runId -StateOverride ([string]$fields['STATE']) -Message "Remote run ended with state $($fields['STATE'])."
        throw "SWB run $runId ended with state $($fields['STATE']). Inspect $localLog and the remote node logs."
    }
}

$reportResult = Invoke-WithRetry 'report'
Save-Log $localLog $reportResult.Output
Save-RunMetadata -RunId $runId -Fields (Parse-Fields $reportResult.Output) -StateOverride 'done'
Write-Output "SWB run completed successfully: $runId"
Write-Output "Execution log: $localLog"
Write-Output "Remote results remain under: $Project"
