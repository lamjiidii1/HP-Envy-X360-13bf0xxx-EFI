#!/usr/bin/env bash
# test-mute-leds.sh - Test F5 (Speaker Mute) and F8 (Mic Mute) LEDs via Realtek ALC245 verbs
# Requires booting with alcverbs=1 (already configured in EFI boot-args)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALC_VERB="$SCRIPT_DIR/alc-verb"

if [ ! -x "$ALC_VERB" ]; then
    echo "Error: alc-verb not found at $ALC_VERB"
    exit 1
fi

ACTION="${1:-status}"

case "$ACTION" in
    spk-on)
        echo "Turning ON Speaker Mute LED (F5 Orange)..."
        "$ALC_VERB" 0x20 0x500 0x0b
        "$ALC_VERB" 0x20 0x400 0x08
        ;;
    spk-off)
        echo "Turning OFF Speaker Mute LED (F5 Orange)..."
        "$ALC_VERB" 0x20 0x500 0x0b
        "$ALC_VERB" 0x20 0x400 0x00
        ;;
    mic-on)
        echo "Turning ON Mic Mute LED (F8 Orange)..."
        "$ALC_VERB" 0x20 0x500 0x35
        "$ALC_VERB" 0x20 0x400 0x08
        ;;
    mic-off)
        echo "Turning OFF Mic Mute LED (F8 Orange)..."
        "$ALC_VERB" 0x20 0x500 0x35
        "$ALC_VERB" 0x20 0x400 0x04
        ;;
    *)
        echo "Usage: $0 {spk-on|spk-off|mic-on|mic-off}"
        ;;
esac
