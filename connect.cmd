@echo off
setlocal
pushd "%~dp0" || exit /b 1
set "sshConfig=ssh_config"
if exist ssh_config.local set "sshConfig=ssh_config.local"
ssh.exe -F "%sshConfig%" -o UserKnownHostsFile=known_hosts tcad-vm
set "connectionExitCode=%errorlevel%"
popd
exit /b %connectionExitCode%
