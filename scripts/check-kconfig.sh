#!/usr/bin/env bash
# Fail if any option requested in the fragment didn't survive olddefconfig
# (unmet dependency, renamed symbol...). A silently-dropped RISCV_IOMMU or a
# default of PASSTHROUGH would make every later measurement meaningless.
set -euo pipefail
config=$1 fragment=$2
bad=0
while IFS= read -r line; do
    if [[ $line =~ ^(CONFIG_[A-Z0-9_]+)=(.*)$ ]]; then
        want="${BASH_REMATCH[0]}"
        grep -qxF "$want" "$config" || { echo "kconfig: wanted $want, got: $(grep -E "^(# )?${BASH_REMATCH[1]}[= ]" "$config" || echo unset)"; bad=1; }
    elif [[ $line =~ ^#\ (CONFIG_[A-Z0-9_]+)\ is\ not\ set$ ]]; then
        ! grep -q "^${BASH_REMATCH[1]}=" "$config" || { echo "kconfig: wanted ${BASH_REMATCH[1]} unset, got: $(grep "^${BASH_REMATCH[1]}=" "$config")"; bad=1; }
    fi
done < "$fragment"
exit $bad
