#!/usr/bin/env bash
# Read-only discovery. Do not print the complete environment or license secrets.
printf '=== USER ===\n'
id -un
hostname
printf 'HOME_DIR=%s\n' "$HOME"
printf 'LOGIN_SHELL=%s\n' "$SHELL"
printf '=== SYSTEM ===\n'
if [ -r /etc/os-release ]; then cat /etc/os-release; fi
printf '=== TOOLS_ON_PATH ===\n'
for name in sdevice sde snmesh sprocess swb svisual inspect gsub; do
    command -v "$name" 2>/dev/null || true
done
printf '=== TCAD_ROOT_HINTS ===\n'
printf 'STROOT=%s\nSTRELEASE=%s\n' "${STROOT-}" "${STRELEASE-}"
printf '=== INSTALLATION_CANDIDATES ===\n'
for root in /opt /usr/local /tools /apps /eda /software "$HOME"; do
    if [ -d "$root" ]; then
        find "$root" -maxdepth 7 \( -type f -o -type l \) \( -name sdevice -o -name swb -o -name sde -o -iname '*sentaurus*sh' -o -iname '*tcad*sh' \) -print 2>/dev/null | head -n 60
    fi
done
printf '=== DISCOVERY_COMPLETE ===\n'
