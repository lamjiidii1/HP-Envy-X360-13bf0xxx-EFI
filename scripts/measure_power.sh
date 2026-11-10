#!/bin/bash
# ==============================================================================
# measure_power.sh - Pure Shell macOS Battery & Power Drain Monitor
# Requires ZERO external packages, ZERO Python, ZERO Xcode tools.
# Works out-of-the-box on clean macOS Tahoe / Sequoia.
# ==============================================================================

INTERVAL="${1:-5}"

START_TIME=$(date +"%Y-%m-%d %H:%M:%S")
DATE_SUFFIX=$(date +"%Y%m%d_%H%M%S")
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOG_FILE="${SCRIPT_DIR}/power_log_${DATE_SUFFIX}.txt"

# Get CPU Brand and OS Version
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Intel Alder Lake Core i7-1250U")
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "macOS")
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null || echo "Unknown")

# Read initial battery specs
INIT_INFO=$(ioreg -rn AppleSmartBattery | awk '
$1 == "\"Voltage\"" { v = $3 }
$1 == "\"CurrentCapacity\"" { cap = $3 }
$1 == "\"MaxCapacity\"" { max = $3 }
$1 == "\"DesignCapacity\"" { des = $3 }
$1 == "\"CycleCount\"" { cyc = $3 }
$1 == "\"ExternalConnected\"" { ext = $3 }
END {
    wh_cur = (cap * v) / 1000000.0;
    wh_max = (max * v) / 1000000.0;
    wh_des = (des * v) / 1000000.0;
    pct = (max > 0) ? (cap / max * 100.0) : 0;
    printf "%.2f|%.2f|%.2f|%d|%d|%d|%.1f|%s\n", wh_cur, wh_max, wh_des, cap, max, cyc, pct, ext;
}')

IFS="|" read -r INIT_WH MAX_WH DES_WH INIT_CAP MAX_CAP CYC INIT_HW_PCT EXT_CONN <<< "$INIT_INFO"
INIT_UI_PCT=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -n1 | tr -d '%')
if [ -z "$INIT_UI_PCT" ]; then
    INIT_UI_PCT=$(printf "%.0f" "$INIT_HW_PCT")
fi

if [ -z "$INIT_WH" ] || [ "$INIT_WH" = "0.00" ]; then
    echo "[-] Error: AppleSmartBattery not detected. Ensure VirtualSMC & SMCBatteryManager are active."
    exit 1
fi

# Print Header Banner
HEADER="================================================================================
                    macOS POWER DRAIN & TELEMETRY MONITOR
================================================================================
System:       ${CPU_BRAND}
OS Version:   macOS ${OS_VER} (Build ${OS_BUILD})
Start Time:   ${START_TIME}
Update Rate:  Every ${INTERVAL} seconds
Battery Spec: ${MAX_WH} Wh Max Capacity (${MAX_CAP} mAh)
              ${DES_WH} Wh Design Capacity
              Cycle Count: ${CYC} | Battery: ${INIT_UI_PCT}% UI (${INIT_HW_PCT}% HW) | ${INIT_WH} Wh
Log File:     ${LOG_FILE}
Note:         To measure actual battery drain, unplug the AC adapter.
================================================================================

Time       Elapsed    State          Power (W)   Battery (Wh)   Drained (Wh)   UI / HW%   Volts     Current
---------------------------------------------------------------------------------------------------------"

echo "$HEADER"
echo "$HEADER" > "$LOG_FILE"

START_EPOCH=$(date +%s)
LAST_EPOCH=$START_EPOCH
TOTAL_DRAINED="0.0"
SAMPLES=0
SUM_WATTS="0.0"
MIN_WATTS="999.0"
MAX_WATTS="0.0"
LAST_WH="$INIT_WH"
LAST_HW_PCT="$INIT_HW_PCT"
LAST_UI_PCT="$INIT_UI_PCT"

# Trap Ctrl+C (SIGINT) and exit signals to print final summary
finish() {
    END_EPOCH=$(date +%s)
    TOTAL_SEC=$((END_EPOCH - START_EPOCH))
    H=$((TOTAL_SEC/3600))
    M=$(( (TOTAL_SEC%3600)/60 ))
    S=$((TOTAL_SEC%60))
    ELAPSED_TOTAL=$(printf "%02d:%02d:%02d" $H $M $S)

    SUMMARY=$(awk -v dur="$ELAPSED_TOTAL" -v sec="$TOTAL_SEC" -v cnt="$SAMPLES" \
                  -v init_wh="$INIT_WH" -v last_wh="$LAST_WH" \
                  -v init_pct="$INIT_UI_PCT" -v last_pct="$LAST_UI_PCT" \
                  -v drained="$TOTAL_DRAINED" -v sum_w="$SUM_WATTS" \
                  -v min_w="$MIN_WATTS" -v max_w="$MAX_WATTS" \
                  -v max_wh="$MAX_WH" -v logfile="$LOG_FILE" '
    BEGIN {
        avg_w = (cnt > 0) ? (sum_w / cnt) : 0.0;
        if (min_w == 999.0) min_w = 0.0;
        proj_hrs = (avg_w > 0.5) ? (max_wh / avg_w) : 0.0;
        cap_drop_wh = (init_wh > last_wh) ? (init_wh - last_wh) : 0.0;
        pct_drop = init_pct - last_pct;

        printf "\n"
        printf "================================================================================\n"
        printf "                           TEST RUN SUMMARY REPORT\n"
        printf "================================================================================\n"
        printf "Total Test Duration:    %s (%d seconds)\n", dur, sec
        printf "Samples Recorded:       %d\n", cnt
        printf "\n"
        printf "--- Battery Drain Metrics ---\n"
        printf "Starting Energy:        %.2f Wh (%s%% UI)\n", init_wh, init_pct
        printf "Ending Energy:          %.2f Wh (%s%% UI)\n", last_wh, last_pct
        printf "Battery Drop:           %.0f%%\n", pct_drop
        printf "Total Energy Drained:   %.3f Wh (integrated discharge)\n", drained
        printf "                        %.3f Wh (capacity delta)\n", cap_drop_wh
        printf "\n"
        printf "--- Power Consumption (Discharge) ---\n"
        printf "Average Power Draw:     %.2f Watts\n", avg_w
        printf "Lowest Power (Idle):    %.2f Watts\n", min_w
        printf "Peak Power (Burst):     %.2f Watts\n", max_w
        if (proj_hrs > 0) {
            printf "Projected Battery Life: %.1f hours at this average power draw\n", proj_hrs
        }
        printf "\n"
        printf "Log File Saved:         %s\n", logfile
        printf "================================================================================\n"
    }')

    echo "$SUMMARY"
    echo "$SUMMARY" >> "$LOG_FILE"
    exit 0
}

trap finish SIGINT SIGTERM

while true; do
    NOW_EPOCH=$(date +%s)
    ELAPSED_SEC=$((NOW_EPOCH - START_EPOCH))
    DT=$((NOW_EPOCH - LAST_EPOCH))
    LAST_EPOCH=$NOW_EPOCH
    
    H=$((ELAPSED_SEC/3600))
    M=$(( (ELAPSED_SEC%3600)/60 ))
    S=$((ELAPSED_SEC%60))
    ELAPSED_FMT=$(printf "%02d:%02d:%02d" $H $M $S)
    NOW_TIME=$(date +"%H:%M:%S")

    UI_PCT=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -n1 | tr -d '%')

    SAMPLE=$(ioreg -rn AppleSmartBattery | awk -v now="$NOW_TIME" -v elapsed="$ELAPSED_FMT" \
                                              -v ui_pct="$UI_PCT" \
                                              -v prev_drained="$TOTAL_DRAINED" -v dt="$DT" '
    $1 == "\"Voltage\"" { v = $3 }
    $1 == "\"CurrentCapacity\"" { cap = $3 }
    $1 == "\"MaxCapacity\"" { max = $3 }
    $1 == "\"InstantAmperage\"" { iamp = $3 }
    $1 == "\"Amperage\"" { amp = $3 }
    $1 == "\"ExternalConnected\"" { ext = $3 }
    END {
        if (iamp != "") amp = iamp;

        # Exact signed 64-bit integer conversion without IEEE-754 mantissa loss
        if (amp ~ /^-/) {
            amp_num = amp + 0;
        } else if (length(amp) >= 18) {
            # Subtract 2^64 by taking last 8 digits (9551616)
            tail = substr(amp, length(amp)-7) + 0;
            amp_num = tail - 9551616;
        } else if (amp + 0 > 2147483647) {
            amp_num = (amp + 0) - 4294967296;
        } else {
            amp_num = amp + 0;
        }

        volt_v = v / 1000.0;
        wh_cur = (cap * v) / 1000000.0;
        wh_max = (max * v) / 1000000.0;

        if (amp_num < 0) {
            watts = (-amp_num * v) / 1000000.0;
            state = "Discharging";
            new_drained = prev_drained + (watts * dt / 3600.0);
        } else if (amp_num > 0) {
            watts = (amp_num * v) / 1000000.0;
            state = "Charging";
            new_drained = prev_drained;
        } else {
            watts = 0.0;
            state = (ext ~ /Yes/) ? "AC Connected" : "Idle";
            new_drained = prev_drained;
        }

        hw_pct = (max > 0) ? (cap / max * 100.0) : 0;
        pct_display = (ui_pct != "") ? sprintf("%2s%% (%4.1f%%)", ui_pct, hw_pct) : sprintf("%5.1f%%", hw_pct);

        # Formatted line for display & log
        line = sprintf("%s   %s    %-14s %6.2f W    %6.2f Wh        %6.3f Wh   %-10s %5.2f V   %+6d mA",
                       now, elapsed, state, watts, wh_cur, new_drained, pct_display, volt_v, amp_num);

        # Internal raw data passed back to bash
        printf "%s|%.4f|%.2f|%.2f|%.1f|%s\n", line, new_drained, watts, wh_cur, hw_pct, state;
    }')

    IFS="|" read -r DISPLAY_LINE NEW_DRAINED SAMPLE_WATTS CUR_WH CUR_HW_PCT SAMPLE_STATE <<< "$SAMPLE"

    if [ -n "$DISPLAY_LINE" ]; then
        echo "$DISPLAY_LINE"
        echo "$DISPLAY_LINE" >> "$LOG_FILE"

        TOTAL_DRAINED="$NEW_DRAINED"
        LAST_WH="$CUR_WH"
        LAST_HW_PCT="$CUR_HW_PCT"
        LAST_UI_PCT="$UI_PCT"

        if [ "$SAMPLE_STATE" = "Discharging" ]; then
            SAMPLES=$((SAMPLES + 1))
            SUM_WATTS=$(awk -v s="$SUM_WATTS" -v w="$SAMPLE_WATTS" 'BEGIN { printf "%.4f", s + w }')
            MIN_WATTS=$(awk -v m="$MIN_WATTS" -v w="$SAMPLE_WATTS" 'BEGIN { printf "%.2f", (w < m ? w : m) }')
            MAX_WATTS=$(awk -v m="$MAX_WATTS" -v w="$SAMPLE_WATTS" 'BEGIN { printf "%.2f", (w > m ? w : m) }')
        fi
    fi

    sleep "$INTERVAL"
done
