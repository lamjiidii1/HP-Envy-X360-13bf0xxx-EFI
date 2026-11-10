#!/bin/bash
# One-click launcher for macOS Battery & Power Drain Monitor
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR" || exit 1

clear
python3 scripts/measure_power.py "$@"

echo ""
echo "Press Enter to exit..."
read -r
