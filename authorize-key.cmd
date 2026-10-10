@echo off
setlocal
pushd "%~dp0" || exit /b 1
echo Install the project public key for Codex SSH access to the VM.
echo Enter your Linux password when SSH asks. Nothing is displayed while typing.
echo The private key stays on this Windows computer.
if not exist codex_vm_key.pub exit /b 1
type codex_vm_key.pub | ssh.exe -F ssh_config -o UserKnownHostsFile=known_hosts -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no tcad-vm "umask 077; mkdir -p .ssh && printf '\n' >> .ssh/authorized_keys && cat >> .ssh/authorized_keys && chmod 700 .ssh && chmod 600 .ssh/authorized_keys"
if errorlevel 1 goto failed
ssh.exe -F ssh_config -o UserKnownHostsFile=known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -T tcad-vm "printf 'KEY_AUTH_OK\n'; id -un; hostname"
if errorlevel 1 goto failed
echo Key authentication verified. Return to Codex and report completion.
popd
exit /b 0
:failed
echo Authorization failed. Keep the error message for diagnosis.
popd
exit /b 1
