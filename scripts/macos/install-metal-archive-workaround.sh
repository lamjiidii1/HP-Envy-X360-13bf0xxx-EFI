#!/bin/bash
#
# Install, verify or remove the WhateverXe Metal archive workaround.
#
# The old manual instructions copied the plist as
#   ~/Library/LaunchAgents/metal-archive-workaround.plist
# but bootstrapped
#   ~/Library/LaunchAgents/local.wex.metal-archive-workaround.plist
# That file never existed, so launchctl failed with "No such file or
# directory".  This script always installs the plist under the label name and
# bootstraps that exact path.
#
# Usage:
#   bash install-metal-archive-workaround.sh
#   bash install-metal-archive-workaround.sh --dry-run
#   bash install-metal-archive-workaround.sh --uninstall
#
# No root is needed.  Run it from Terminal.app in the logged-in desktop
# session, not over SSH.
#
# Measured on 2026-11-04: the agent loads and launchd exposes all three
# variables to new GUI processes, but PowerPreferences still aborts in
# MTLLoader line 685.  This is an experiment, not a fix for this machine.

set -u

LABEL="local.wex.metal-archive-workaround"
DOMAIN="gui/$(id -u)"
USER_DOMAIN="user/$(id -u)"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$SCRIPT_DIR/metal-archive-workaround.plist"
AGENTS_DIR="$HOME/Library/LaunchAgents"
DEST="$AGENTS_DIR/$LABEL.plist"
STALE="$AGENTS_DIR/metal-archive-workaround.plist"

DRY_RUN=0
NO_RESTART=0
ACTION=install

# Keep these in one place; the plist must set exactly the same values.
VARS="RB_USE_BINARY_ARCHIVE=0
MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES=1
MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS=1"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '  +'
		printf ' %q' "$@"
		printf '\n'
		return 0
	fi
	"$@"
}

is_loaded() {
	launchctl print "$1/$LABEL" >/dev/null 2>&1
}

usage() {
	# Print the leading comment block, stopping at the first code line, so the
	# help text does not have to be kept in sync with line numbers.
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

for arg in "$@"; do
	case "$arg" in
		--dry-run)   DRY_RUN=1 ;;
		--no-restart) NO_RESTART=1 ;;
		--uninstall) ACTION=uninstall ;;
		-h|--help)   usage; exit 0 ;;
		*)           die "unknown argument: $arg" ;;
	esac
done

say "WhateverXe Metal archive workaround"
say "  label : $LABEL"
say "  domain: $DOMAIN"
say "  plist : $DEST"
[ "$DRY_RUN" -eq 1 ] && say "  mode  : dry run (nothing will be changed)"
say ""

bootout_all() {
	for d in "$DOMAIN" "$USER_DOMAIN"; do
		if is_loaded "$d"; then
			say "Booting out existing agent from $d"
			run launchctl bootout "$d/$LABEL" || warn "launchctl bootout $d/$LABEL failed"
		fi
	done
}

set_env_now() {
	for pair in $VARS; do
		run launchctl setenv "${pair%%=*}" "${pair#*=}"
	done
}

verify_env() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	sleep 2
	bad=0
	for pair in $VARS; do
		key=${pair%%=*}
		want=${pair#*=}
		got=$(launchctl getenv "$key" 2>/dev/null || true)
		if [ "$got" = "$want" ]; then
			say "  $key=$got"
		else
			warn "$key is '${got:-<unset>}', expected '$want'"
			bad=1
		fi
	done
	return "$bad"
}

restart_controlcenter() {
	[ "$NO_RESTART" -eq 1 ] && return 0
	say "Restarting ControlCenter"
	run killall ControlCenter 2>/dev/null || true
	sleep 1
	run open -a /System/Library/CoreServices/ControlCenter.app \
		|| warn "could not reopen ControlCenter; open it from the menu bar"
}

clear_user_caches() {
	say "Clearing user Metal caches"
	run rm -rf "$HOME/Library/Caches/com.apple.Metal"
	run rm -rf "$HOME/Library/Caches/com.apple.MetalShaderCache"
}

if [ "$ACTION" = uninstall ]; then
	[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS"
	say "Removing the workaround"
	bootout_all
	run rm -f "$DEST"
	# Only remove the wrong-named copy if it is ours; never delete a file that
	# happens to share the name but belongs to something else.
	if [ -f "$STALE" ]; then
		stale_label=$(plutil -extract Label raw -o - "$STALE" 2>/dev/null || true)
		if [ "$stale_label" = "$LABEL" ]; then
			run rm -f "$STALE"
		fi
	fi
	for pair in $VARS; do
		run launchctl unsetenv "${pair%%=*}"
	done
	clear_user_caches
	restart_controlcenter
	say ""
	say "Removed. Reboot to clear any cached Metal state."
	exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS"
[ -f "$SRC" ] || die "missing $SRC; keep this script next to metal-archive-workaround.plist"

if [ "$DRY_RUN" -eq 0 ] && ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
	die "no GUI session at $DOMAIN; run this from Terminal.app in the logged-in desktop session"
fi

say "Installing the LaunchAgent"
run mkdir -p "$AGENTS_DIR"

# A previous manual attempt may have left a copy under the wrong name.  Remove
# it only if it carries our label, so an unrelated file is never deleted.
if [ -f "$STALE" ] && [ "$STALE" != "$DEST" ]; then
	stale_label=$(plutil -extract Label raw -o - "$STALE" 2>/dev/null || true)
	if [ "$stale_label" = "$LABEL" ]; then
		say "Removing stale copy at $STALE"
		run rm -f "$STALE"
	fi
fi

bootout_all
run install -m 0644 "$SRC" "$DEST"
run chmod 0644 "$DEST"
run xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

if [ "$DRY_RUN" -eq 0 ]; then
	plutil -lint "$DEST" >/dev/null || die "plist validation failed: $DEST"
fi

# Clear the old archives before anything restarts.  The agent restarts
# ControlCenter itself, so this must happen first or the fresh process would
# start against the stale caches.
clear_user_caches

# Set the variables immediately as well.  This makes the workaround effective
# even if the agent cannot be bootstrapped for some reason.
say "Setting the Metal environment for this session"
set_env_now

say "Bootstrapping $DEST"
BOOTSTRAP_OK=0
if run launchctl bootstrap "$DOMAIN" "$DEST"; then
	BOOTSTRAP_OK=1
else
	warn "launchctl bootstrap failed"
	warn "the environment is set for this session, but it will not survive logout"
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$BOOTSTRAP_OK" -eq 1 ]; then
	sleep 1
	if is_loaded "$DOMAIN"; then
		say "Agent is loaded"
	else
		warn "bootstrap returned success but the agent is not loaded"
		BOOTSTRAP_OK=0
	fi
fi

say "Verifying environment"
if ! verify_env; then
	warn "one or more variables are wrong; the workaround is not fully active"
fi

# On a successful bootstrap the agent has already restarted ControlCenter.
if [ "$BOOTSTRAP_OK" -ne 1 ]; then
	restart_controlcenter
fi

say ""
if [ "$BOOTSTRAP_OK" -eq 1 ]; then
	say "Installed and verified."
else
	say "Installed for this session only; the LaunchAgent is not loaded."
fi
say ""
say "Note: measured on 2026-11-04, this agent does NOT stop the"
say "PowerPreferences / MTLLoader assertion even when all three variables"
say "are present in the gui domain. Treat it as an experiment, not a fix."
say ""
say "Next:"
say "  1. Reboot (or log out and back in) so every process starts with the variables."
say "  2. Open System Settings > Battery and the App Store video again."
say "  3. If it still crashes, run:"
say "       bash $0"
say "     and send the output together with an openmac-diag report."
say ""
say "To undo:"
say "  bash $0 --uninstall"
