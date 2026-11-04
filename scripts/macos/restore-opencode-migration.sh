#!/bin/bash
#
# restore-opencode-migration.sh - restore the OpenMac OpenCode session on macOS
# from the bundle written by scripts/migrate-to-macos.sh.
#
# Run it from Terminal.app after booting macOS:
#
#   bash /Volumes/MACUSB/OpenMac-migration/restore-on-macos.sh
#
# What it does, in order:
#   1. verifies the bundle checksums (unless SKIP_VERIFY=1);
#   2. installs the pinned OpenCode x86_64 binary under ~/.opencode/bin;
#   3. extracts the repository to ~/OpenMac (override with REPO_DIR=...);
#   4. restores the OpenCode database (sessions and credentials) and config;
#   5. restores snapshots, shell history and tool output;
#   6. starts the background service and moves the session to REPO_DIR;
#   7. prints the command that reopens this chat.
#
# Existing data is preserved: an old database/config is renamed, never deleted.
# A non-empty REPO_DIR stops the script unless FORCE=1, in which case it is
# renamed to REPO_DIR.pre-migration-<timestamp>.
#
# The bundle contains the SMBIOS identity and API keys.  Keep it private.

set -u

BUNDLE=$(cd -- "$(dirname -- "$0")" && pwd -P)
REPO_DIR=${REPO_DIR:-"$HOME/OpenMac"}
BIN_DIR="$HOME/.opencode/bin"
OPENCODE="$BIN_DIR/opencode"
STAMP=$(date +%Y%m%d-%H%M%S)

# OpenCode uses per-platform data directories.  On macOS it uses
# ~/Library/Application Support/opencode, not ~/.local/share/opencode, so these
# are resolved from the installed binary with `opencode debug paths` below.
DATA_DIR=${DATA_DIR:-}
CONFIG_DIR=${CONFIG_DIR:-}
STATE_DIR=${STATE_DIR:-}

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "run this on macOS"

repo_tar=$(ls "$BUNDLE"/*-repo.tar.gz 2>/dev/null | head -1)
[ -n "$repo_tar" ] || die "repository archive not found in $BUNDLE"
REPO_NAME=$(basename "$repo_tar" -repo.tar.gz)

for f in opencode.db opencode.json openmac-session.json \
         opencode-darwin-x64.zip; do
  [ -f "$BUNDLE/$f" ] || die "missing $BUNDLE/$f"
done

say "OpenMac migration restore"
say "  bundle     : $BUNDLE"
say "  repository : $REPO_DIR"
say ""

# --- 0. checksums ----------------------------------------------------------
if [ "${SKIP_VERIFY:-0}" = "1" ]; then
  say "Skipping checksum verification (SKIP_VERIFY=1)"
elif [ -f "$BUNDLE/SHA256SUMS" ] && command -v shasum >/dev/null 2>&1; then
  say "Verifying bundle checksums"
  ( cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS ) || die "checksum mismatch; copy the bundle again"
  say ""
else
  say "No SHA256SUMS or shasum; skipping verification"
fi

# --- 1. binary -------------------------------------------------------------
say "Installing OpenCode under $BIN_DIR"
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/openmac.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
unzip -oq "$BUNDLE/opencode-darwin-x64.zip" -d "$tmp" || die "cannot unpack the OpenCode zip"
[ -f "$tmp/opencode" ] || die "zip has no opencode binary"
install -m 0755 "$tmp/opencode" "$OPENCODE" || die "cannot install the binary"
xattr -dr com.apple.quarantine "$OPENCODE" 2>/dev/null || true
ver=$("$OPENCODE" --version 2>/dev/null) || die "the installed binary does not run"
note "opencode $ver"

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    added=0
    for rc in "$HOME/.zprofile" "$HOME/.bash_profile"; do
      [ -f "$rc" ] || continue
      added=1
      if ! grep -q 'opencode/bin' "$rc" 2>/dev/null; then
        {
          printf '\n# OpenCode\n'
          printf 'export PATH="$HOME/.opencode/bin:$PATH"\n'
        } >> "$rc"
        note "added $BIN_DIR to PATH in $rc"
      fi
    done
    if [ "$added" = "0" ]; then
      {
        printf '\n# OpenCode\n'
        printf 'export PATH="$HOME/.opencode/bin:$PATH"\n'
      } >> "$HOME/.zprofile"
      note "added $BIN_DIR to PATH in $HOME/.zprofile"
    fi
    ;;
esac
export PATH="$BIN_DIR:$PATH"

# Resolve the real per-platform locations from the binary itself.  On macOS
# this is ~/Library/Application Support/opencode, not ~/.local/share/opencode.
[ -n "$DATA_DIR" ]   || DATA_DIR=$("$OPENCODE" debug paths data 2>/dev/null)   || DATA_DIR=""
[ -n "$CONFIG_DIR" ] || CONFIG_DIR=$("$OPENCODE" debug paths config 2>/dev/null) || CONFIG_DIR=""
[ -n "$STATE_DIR" ]  || STATE_DIR=$("$OPENCODE" debug paths state 2>/dev/null)  || STATE_DIR=""
DB_PATH=$("$OPENCODE" debug paths db 2>/dev/null) || DB_PATH=""
[ -n "$DATA_DIR" ] && [ -n "$CONFIG_DIR" ] && [ -n "$DB_PATH" ] \
  || die "could not resolve OpenCode data paths (opencode debug paths)"
say "  data       : $DATA_DIR"
say "  config     : $CONFIG_DIR"
say ""

# --- 2. repository ---------------------------------------------------------
if [ -e "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
  if [ "${FORCE:-0}" = "1" ]; then
    backup="$REPO_DIR.pre-migration-$STAMP"
    mv "$REPO_DIR" "$backup" || die "cannot move $REPO_DIR aside"
    note "existing repository moved to $backup"
  else
    die "$REPO_DIR already exists and is not empty; move it away or rerun with FORCE=1"
  fi
fi
say "Extracting the repository to $REPO_DIR"
mkdir -p "$REPO_DIR" || die "cannot create $REPO_DIR"
tar -xzf "$repo_tar" -C "$(dirname "$REPO_DIR")" \
  || die "repository extraction failed"
if [ "$(basename "$REPO_DIR")" != "$REPO_NAME" ] && [ -d "$(dirname "$REPO_DIR")/$REPO_NAME" ]; then
  # REPO_DIR was overridden: move the extracted tree into place.
  if [ -z "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
    rmdir "$REPO_DIR" 2>/dev/null || true
    mv "$(dirname "$REPO_DIR")/$REPO_NAME" "$REPO_DIR" || die "cannot move repository to $REPO_DIR"
  fi
fi
[ -d "$REPO_DIR/.git" ] || die "extracted repository has no .git"
note "$(du -sh "$REPO_DIR" 2>/dev/null | cut -f1) in $REPO_DIR"
cd "$REPO_DIR" || die "cannot enter $REPO_DIR"

# --- 3. stop any running service ------------------------------------------
if "$OPENCODE" service status >/dev/null 2>&1; then
  say "Stopping the running OpenCode service"
  "$OPENCODE" service stop >/dev/null 2>&1 || true
  sleep 1
fi
if pgrep -x opencode >/dev/null 2>&1; then
  die "an opencode process is still running; quit OpenCode and rerun"
fi

# --- 4. database and config -----------------------------------------------
say "Restoring the OpenCode database and config"
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$(dirname "$DB_PATH")" \
  || die "cannot create the OpenCode directories"
for f in "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"; do
  if [ -e "$f" ]; then
    mv "$f" "$f.pre-migration-$STAMP" \
      || die "cannot move the old $(basename "$f") aside"
    note "old $(basename "$f") -> $(basename "$f").pre-migration-$STAMP"
  fi
done
cp -f "$BUNDLE/opencode.db" "$DB_PATH" || die "cannot restore the database"
chmod 0600 "$DB_PATH" 2>/dev/null || true
note "opencode.db restored to $DB_PATH"

if [ -f "$CONFIG_DIR/opencode.json" ]; then
  mv "$CONFIG_DIR/opencode.json" "$CONFIG_DIR/opencode.json.pre-migration-$STAMP" \
    || die "cannot move the old opencode.json aside"
  note "old opencode.json -> opencode.json.pre-migration-$STAMP"
fi
cp -f "$BUNDLE/opencode.json" "$CONFIG_DIR/opencode.json" || die "cannot restore opencode.json"
chmod 0600 "$CONFIG_DIR/opencode.json" 2>/dev/null || true

# remove the old background-service password so the new server writes its own
[ -n "$STATE_DIR" ] && rm -f "$STATE_DIR/service.json" 2>/dev/null || true

if [ -f "$BUNDLE/opencode-data.tar.gz" ]; then
  say "Restoring snapshots, shell history and tool output"
  tar -xzf "$BUNDLE/opencode-data.tar.gz" -C "$DATA_DIR" \
    || die "could not restore the OpenCode data directories"
  note "snapshot/, shell/, tool-output/ merged into $DATA_DIR"
fi

# --- 5. session ------------------------------------------------------------
SESSION_ID=${SESSION_ID:-$(sqlite3 "$DB_PATH" \
  "select id from session_v2 where directory like '%OpenMac' order by time_updated desc limit 1;" 2>/dev/null)}
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(sed -n 's/.*"id": *"\(ses_[A-Za-z0-9]*\)".*/\1/p' \
    "$BUNDLE/openmac-session.json" | head -1)
fi
[ -n "$SESSION_ID" ] || die "could not determine the session ID"

# The database still records the old Linux directory.  The move endpoint
# re-homes the session into the project for REPO_DIR; if it is unavailable,
# fall back to importing the clean transcript after deleting the old row.
say "Starting the OpenCode background service"
"$OPENCODE" service start >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do
  "$OPENCODE" service status >/dev/null 2>&1 && break
  sleep 1
done

say "Moving session $SESSION_ID to $REPO_DIR"
moved=0
for attempt in 1 2 3; do
  if "$OPENCODE" api post "/api/session/$SESSION_ID/move" \
       --data "{\"directory\":\"$REPO_DIR\"}" >/dev/null 2>&1; then
    moved=1
    break
  fi
  sleep 2
done

if [ "$moved" != "1" ]; then
  say "Move endpoint failed; importing the clean transcript instead"
  "$OPENCODE" service stop >/dev/null 2>&1 || true
  sleep 1
  pgrep -x opencode >/dev/null 2>&1 && sleep 2
  sqlite3 "$DB_PATH" \
    "PRAGMA foreign_keys=ON; delete from session_v2 where id='$SESSION_ID';" \
    || die "could not remove the old session row"
  "$OPENCODE" session import --directory "$REPO_DIR" \
    "$BUNDLE/openmac-session.json" || die "session import failed"
  "$OPENCODE" service start >/dev/null 2>&1 || true
fi

# verify the finished state
newdir=$(sqlite3 "$DB_PATH" \
  "select directory from session_v2 where id='$SESSION_ID';" 2>/dev/null)
say ""
if [ "$newdir" = "$REPO_DIR" ]; then
  say "Session restored and moved to $REPO_DIR"
else
  say "Session restored, but its directory still reads: ${newdir:-<missing>}"
  say "The chat will still open; the move can be retried later:"
  say "  $OPENCODE api post /api/session/$SESSION_ID/move --data '{\"directory\":\"$REPO_DIR\"}'"
fi

say ""
say "Continue this chat with:"
say "  $OPENCODE --session $SESSION_ID $REPO_DIR"
say ""
say "Old data was kept as *.pre-migration-$STAMP next to the new files."
