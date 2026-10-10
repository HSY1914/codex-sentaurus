[CmdletBinding()]
param(
    [ValidateSet('Discover', 'Probe', 'Version', 'License', 'Smoke', 'SmokeStatus')]
    [string]$Action = 'Discover',
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
$ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
$nativeConfig = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ssh_config.local')) {
    Join-Path $PSScriptRoot 'ssh_config.local'
} else {
    Join-Path $PSScriptRoot 'ssh_config'
}
$knownHosts = (Join-Path $PSScriptRoot 'known_hosts').Replace('\', '/')
$sshArgs = @('-T', '-F', $nativeConfig, '-o', ('UserKnownHostsFile="{0}"' -f $knownHosts), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', 'tcad-vm')
$logDirectory = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Quote-Posix([string]$value) {
    return "'" + $value.Replace("'", "'\''") + "'"
}
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sentaurus.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$resultDirectory = Join-Path $PSScriptRoot 'results'
if ($Action -in @('Smoke', 'SmokeStatus')) {
    if ($settings.remoteRunRoot -notmatch '^/home/TCAD2022/codex-sentaurus/runs$') { throw 'Review the remote run root before changing it.' }
    New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
    $latestPath = Join-Path $resultDirectory 'latest-smoke.json'
    if ($Action -eq 'Smoke') {
        $createCommand = 'mkdir -p ' + (Quote-Posix $settings.remoteRunRoot) + ' && mktemp -d ' + (Quote-Posix ($settings.remoteRunRoot + '/diode-smoke-XXXXXXXX'))
        $created = @(& $ssh @sshArgs $createCommand)
        if ($LASTEXITCODE -ne 0) { throw 'Could not create remote run directory.' }
        $remoteDirectory = [string]($created | Select-Object -Last 1)
        if ($remoteDirectory -notmatch '^/home/TCAD2022/codex-sentaurus/runs/(diode-smoke-[A-Za-z0-9]{8})$') { throw 'Unexpected remote run path.' }
        $RunId = $Matches[1]
        $scp = (Get-Command scp.exe -ErrorAction Stop).Source
        $scpArgs = @('-F', $nativeConfig, '-o', ('UserKnownHostsFile="{0}"' -f $knownHosts), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes')
        foreach ($name in @('structure.scm', 'device.cmd', 'run.sh', 'validate.py')) { $scpArgs += Join-Path $PSScriptRoot "examples/diode-smoke/$name" }
        $scpArgs += 'tcad-vm:' + $remoteDirectory + '/'
        & $scp @scpArgs
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed; no simulation started.' }
        $script = "set -e`ncd " + (Quote-Posix $remoteDirectory) + "`nnohup bash run.sh > launcher.log 2>&1 < /dev/null &`nprintf 'SUBMITTED %s\n' " + (Quote-Posix $RunId) + "`n"
    } else {
        if (-not $RunId) {
            if (-not (Test-Path -LiteralPath $latestPath)) { throw 'Specify -RunId or submit a smoke test first.' }
            $RunId = (Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json).runId
        }
        if ($RunId -notmatch '^diode-smoke-[A-Za-z0-9]{8}$') { throw 'Invalid run ID.' }
        $remoteDirectory = $settings.remoteRunRoot + '/' + $RunId
        $script = "set -e`ncd " + (Quote-Posix $remoteDirectory) + "`nif test -f status.txt; then cat status.txt; else echo PENDING; fi`nfor log in launcher.log structure.log device.log; do if test -f " + '"$log"; then printf ''\n=== %s ===\n'' "$log"; tail -n 18 "$log"; fi; done' + "`n"
    }
} elseif ($Action -eq 'Version') {
    $script = "set -e`n" + (Quote-Posix $settings.deviceExecutable) + " -v`n"
} elseif ($Action -eq 'License') {
    $script = "timeout 25 /opt/synopsys/SCL2021.12/linux64/bin/lmutil lmstat -c 27020@localhost`n"
} elseif ($Action -eq 'Discover') {
    $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remote/discover.sh') -Raw -Encoding UTF8
} else {
    if (-not $settings.deviceExecutable) { throw 'Run discovery first and record the verified absolute sdevice path in sentaurus.json.' }
    $lines = @('set -e', 'printf ''=== SOFTWARE_ACCESS_PROBE ===\n''')
    if ($settings.environmentScript) { $lines += 'source ' + (Quote-Posix $settings.environmentScript) }
    $lines += 'test -x ' + (Quote-Posix $settings.deviceExecutable)
    $lines += 'ls -l ' + (Quote-Posix $settings.deviceExecutable)
    $lines += 'printf ''EXECUTABLE_ACCESS_OK\n'''
    $lines += 'printf ''This checks file access only; a real solver run is required to verify startup and licensing.\n'''
    $script = ($lines -join "`n") + "`n"
}
# Strip transport CR characters before interpreting the Linux shell script.
$remoteCommand = 'tr -d ''\r'' | bash -l'
$previousEncoding = $OutputEncoding
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $script | & $ssh @sshArgs $remoteCommand | Tee-Object -FilePath (Join-Path $logDirectory "$Action-$stamp.log")
    $result = $LASTEXITCODE
} finally { $OutputEncoding = $previousEncoding }
if ($result -ne 0) { throw "Remote $Action failed (exit $result). Check authentication or the recorded log." }
if ($Action -eq 'Smoke') {
    @{ runId = $RunId; remoteDirectory = $remoteDirectory; submittedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $latestPath -Encoding UTF8
    Write-Output "Submitted only; query with: ./tcad.ps1 -Action SmokeStatus -RunId $RunId"
}
