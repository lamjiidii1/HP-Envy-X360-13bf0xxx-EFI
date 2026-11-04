#!/bin/bash
#
# check-metal-env.sh - report whether the WhateverXe Metal archive workaround
# is installed, loaded, and visible to freshly launched GUI applications.
#
# This exists because the workaround can look installed while the crashing
# processes still do not inherit the three variables.  It prints a verdict at
# the end; no root is needed.
#
# Usage:
#   bash check-metal-env.sh
#
# Run from Terminal.app in the logged-in desktop session.

set -u

LABEL="local.wex.metal-archive-workaround"
DOMAIN="gui/$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
VARS="RB_USE_BINARY_ARCHIVE
MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES
MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS"

say() { printf '%s\n' "$*"; }
sec() { printf '\n===== %s =====\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "run this on macOS" >&2; exit 1; }

sec "plist files"
ls -l "$AGENTS" 2>/dev/null | grep -i 'metal\|wex' || say "(no matching files in $AGENTS)"

for f in "$AGENTS/$LABEL.plist" "$AGENTS/metal-archive-workaround.plist"; do
  [ -f "$f" ] || continue
  say ""
  say "$f"
  say "  Label: $(plutil -extract Label raw -o - "$f" 2>/dev/null || echo '<unreadable>')"
  say "  RunAtLoad: $(plutil -extract RunAtLoad raw -o - "$f" 2>/dev/null || echo '<unset>')"
done

sec "agent state"
launchctl print "$DOMAIN/$LABEL" 2>&1 | sed -n '1,25p'

sec "launchd GUI-domain environment"
# The environment block launchd hands to new GUI processes.
launchctl print "$DOMAIN" 2>/dev/null | awk '
  /^[[:space:]]*environment = \{/ { inside = 1 }
  inside { print }
  inside && /^[[:space:]]*\}/ { exit }
'

sec "launchctl getenv (caller domain)"
for k in $VARS; do
  v=$(launchctl getenv "$k" 2>/dev/null || true)
  say "  $k=${v:-<unset>}"
done

sec "fresh GUI process environment"
# Launch a second TextEdit instance, then read its real environment with
# ps eww.  This is what a new app actually receives, not what launchd stores.
open -n -a TextEdit 2>/dev/null || say "(could not launch TextEdit)"
sleep 3
pid=$(pgrep -n -x TextEdit 2>/dev/null || true)
if [ -n "$pid" ]; then
  say "TextEdit pid $pid"
  if ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^(RB_USE_BINARY_ARCHIVE|MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES|MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS)='; then
    :
  else
    say "  (none of the three variables are visible in ps eww)"
  fi
else
  say "(TextEdit pid not found)"
fi

sec "verdict"
missing=0
for k in $VARS; do
  v=$(launchctl getenv "$k" 2>/dev/null || true)
  if [ -z "$v" ]; then
    say "launchctl getenv $k: missing"
    missing=$((missing + 1))
  else
    say "launchctl getenv $k: $v"
  fi
done

if [ ! -f "$AGENTS/$LABEL.plist" ]; then
  say "RESULT: the agent is NOT installed under the label filename."
elif ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  say "RESULT: the plist exists but the agent is NOT loaded in $DOMAIN."
elif [ "$missing" -ne 0 ]; then
  say "RESULT: the agent is loaded, but launchd has no values for the variables."
else
  say "RESULT: the agent is loaded and launchd has all three values."
  say "        If TextEdit above did not show them, new GUI processes are not"
  say "        inheriting them, so a per-user LaunchAgent is the wrong delivery."
  say "        If TextEdit did show them, the variables reach apps and the"
  say "        workaround simply does not prevent this MTLLoader assertion."
fi

say ""
say "Also useful:"
say "  sudo ls -l /Library/Logs/DiagnosticReports | grep -i power"
say "  log show --last 10m --predicate 'process == \"PowerPreferences\"' --style compact"
