#!/usr/bin/env bash
# toggle-micmute.sh - Toggle internal microphone mute with on-screen notification
# Can be bound to F20 or executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALC_VERB="$SCRIPT_DIR/alc-verb"

CURRENT_VOL=$(osascript -e 'input volume of (get volume settings)' 2>/dev/null || echo "50")

if [ "$CURRENT_VOL" -gt 0 ]; then
    osascript -e 'set volume input volume 0'
    osascript -e 'display notification "Microphone MUTED" with title "Mic Mute" sound name "Pop"' 2>/dev/null
    if [ -x "$ALC_VERB" ]; then
        "$ALC_VERB" 0x20 0x500 0x35 >/dev/null 2>&1
        "$ALC_VERB" 0x20 0x400 0x08 >/dev/null 2>&1
    fi
    echo "Microphone MUTED"
else
    osascript -e 'set volume input volume 75'
    osascript -e 'display notification "Microphone UNMUTED (75%)" with title "Mic Mute" sound name "Pop"' 2>/dev/null
    if [ -x "$ALC_VERB" ]; then
        "$ALC_VERB" 0x20 0x500 0x35 >/dev/null 2>&1
        "$ALC_VERB" 0x20 0x400 0x04 >/dev/null 2>&1
    fi
    echo "Microphone UNMUTED (75%)"
fi
