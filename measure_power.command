#!/bin/bash
# One-click pure shell launcher for macOS Battery & Power Drain Monitor
# Requires ZERO Python, ZERO Xcode Tools, ZERO external packages.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR" || exit 1

clear
if [ -f "scripts/measure_power.sh" ]; then
    bash scripts/measure_power.sh "$@"
elif [ -f "tools/measure_power.sh" ]; then
    bash tools/measure_power.sh "$@"
elif [ -f "measure_power.sh" ]; then
    bash measure_power.sh "$@"
else
    echo "[-] Error: measure_power.sh not found."
fi

echo ""
echo "Press Enter to exit..."
read -r
