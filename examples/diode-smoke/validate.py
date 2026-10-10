"""Validate this original smoke test's ASCII curve; no external dependencies."""
import csv
import json
import math
import re
from pathlib import Path

text = Path("diode_iv_des.plt").read_text()
dataset_match = re.search(r"datasets\s*=\s*\[(.*?)\]", text, re.S)
data_match = re.search(r"\bData\s*\{(.*?)\}", text, re.S)
if not dataset_match or not data_match:
    raise ValueError("Missing dataset names or curve data")
names = re.findall(r'"([^"]+)"', dataset_match.group(1))
values = [float(value) for value in data_match.group(1).split()]
if not names or not values or len(values) % len(names):
    raise ValueError("Incomplete curve rows")
if not all(math.isfinite(value) for value in values):
    raise ValueError("Non-finite curve value")
rows = [values[i:i + len(names)] for i in range(0, len(values), len(names))]
voltage_index = names.index("anode OuterVoltage")
anode_index = names.index("anode TotalCurrent")
cathode_index = names.index("cathode TotalCurrent")
voltages = [row[voltage_index] for row in rows]
if len(rows) < 3 or abs(voltages[0]) > 1e-9 or abs(voltages[-1] - 0.2) > 1e-9:
    raise ValueError("Target voltage sweep not completed")
if any(right < left - 1e-9 for left, right in zip(voltages, voltages[1:])):
    raise ValueError("Unexpected reverse step in voltage sweep")
residual = max(abs(row[anode_index] + row[cathode_index]) for row in rows)
current_scale = max(abs(row[index]) for row in rows for index in (anode_index, cathode_index))
if residual > max(1e-20, 1e-6 * current_scale):
    raise ValueError("Terminal current conservation check failed")
with Path("iv.csv").open("w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow(["anode_voltage_V", "anode_current_raw", "cathode_current_raw"])
    writer.writerows((row[voltage_index], row[anode_index], row[cathode_index]) for row in rows)
metrics = {
    "validated": True,
    "purpose": "connectivity and numerical workflow smoke test; not a calibrated device",
    "curve_file": "diode_iv_des.plt",
    "sample_count": len(rows),
    "final_voltage_V": voltages[-1],
    "final_anode_current_raw": rows[-1][anode_index],
    "max_current_balance_residual_raw": residual,
    "current_note": "Raw simulator terminal values; no device width or area normalization applied here",
}
Path("metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
print(json.dumps(metrics))
