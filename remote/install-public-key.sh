#!/usr/bin/env bash
# Run as the intended Linux user in the VMware guest terminal.
# Adds only the public key; preserves existing authorized keys.
set -eu
if [ "$(id -un)" != 'TCAD2022' ]; then
    printf 'Please run this as TCAD2022, without sudo.\n' >&2
    exit 1
fi
tcad_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINpBU4AMqRVykzSqlc4u61BYiPtXmS0fRt6Egx8ezWG1 codex-sentaurus-vm'
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if ! grep -qxF -- "$tcad_key" "$HOME/.ssh/authorized_keys"; then
    printf '\n%s\n' "$tcad_key" >> "$HOME/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"
printf 'KEY_READY\n'
