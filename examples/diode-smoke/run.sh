#!/usr/bin/env bash
set -eu
printf 'RUNNING\n' > status.txt
trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "FAILED exit=%s\n" "$rc" > status.txt; fi' EXIT
timeout 180 /opt/synopsys/sentaurus/T-2022.03/bin/sde -e -l structure.scm > structure.log 2>&1
test -s diode_msh.tdr
timeout 180 /opt/synopsys/sentaurus/T-2022.03/bin/sdevice --exit-on-failure device.cmd > device.log 2>&1
test -s diode_iv_des.plt
python3 validate.py
printf 'COMPLETED\n' > status.txt
