[CmdletBinding()]
param(
    [ValidateSet('Run', 'Status', 'Stop', 'Clean')]
    [string]$Action = 'Run',
    [string]$Project = '/home/TCAD2022/STDB/codex_test/test1',
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
    '-o', 'ConnectTimeout=8'
)
$remoteController = Join-Path $root 'remote/swb-controller.sh'
if (-not (Test-Path -LiteralPath $remoteController)) { throw "Missing remote controller: $remoteController" }
$logDirectory = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

function Quote-Posix([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Controller([string]$RemoteAction) {
    $arguments = @($RemoteAction, $Project, [string]$RetryCount, [string]$KeepDays)
    $quoted = ($arguments | ForEach-Object { Quote-Posix $_ }) -join ' '
    $command = 'tr -d ''\r'' | bash -s -- ' + $quoted
    $script = Get-Content -LiteralPath $remoteController -Raw -Encoding UTF8
    $output = @($script | & $ssh @sshArgs $command 2>&1)
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

function Invoke-WithRetry([string]$RemoteAction, [int]$Attempts = 3) {
    for ($try = 1; $try -le $Attempts; $try++) {
        $result = Invoke-Controller $RemoteAction
        if ($result.ExitCode -eq 0) { return $result }
        if ($try -eq $Attempts) { return $result }
        Start-Sleep -Seconds ([Math]::Min(5, $try * 2))
    }
}

if ($Action -eq 'Status') {
    $result = Invoke-WithRetry 'status'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB status failed (exit $($result.ExitCode))." }
    exit 0
}

if ($Action -eq 'Stop') {
    $result = Invoke-WithRetry 'stop'
    $result.Output | Write-Output
    if ($result.ExitCode -ne 0) { throw "Remote SWB stop failed (exit $($result.ExitCode))." }
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
        throw "SWB run timed out. Remote run $runId was stopped; inspect $localLog."
    }
    Start-Sleep -Seconds $PollSeconds
    $statusResult = Invoke-WithRetry 'status'
    Save-Log $localLog $statusResult.Output
    if ($statusResult.ExitCode -ne 0) {
        Write-Warning 'Temporary status query failure; the remote run is left intact and will be queried again.'
        continue
    }
    $fields = Parse-Fields $statusResult.Output
    $state = "state=$($fields['STATE']); process=$($fields['PROCESS']); swb=$($fields['SWB_STATUS']); done=$($fields['NODES_DONE'])/$($fields['NODES_TOTAL']); failed=$($fields['NODES_FAILED'])"
    if ($state -ne $lastState) { Write-Output "[$(Get-Date -Format 'HH:mm:ss')] $state"; $lastState = $state }
    if ($fields['STATE'] -eq 'done' -and $fields['PROCESS'] -eq 'stopped' -and $fields['SWB_STATUS'] -eq 'done') { break }
    if ($fields['STATE'] -in @('failed', 'stopped', 'stale')) {
        $report = Invoke-WithRetry 'report'
        Save-Log $localLog $report.Output
        $report.Output | Write-Output
        throw "SWB run $runId ended with state $($fields['STATE']). Inspect $localLog and the remote node logs."
    }
}

$reportResult = Invoke-WithRetry 'report'
Save-Log $localLog $reportResult.Output
Write-Output "SWB run completed successfully: $runId"
Write-Output "Execution log: $localLog"
Write-Output "Remote results remain under: $Project"
