#!/bin/bash
#
# migrate-to-macos.sh - build a self-contained OpenCode + repository migration
# bundle on a macOS-readable volume (exFAT USB), run from Linux before booting
# macOS for good.
#
# The chat is not stored in the repository.  It lives in OpenCode's SQLite
# database, together with the provider credentials.  File snapshots and shell
# output live in the OpenCode data directory.  This script captures all of it,
# plus the repository and a pinned macOS OpenCode binary, so the macOS side
# needs no network and no re-authentication.
#
# Usage (run after leaving the OpenCode TUI):
#   bash scripts/migrate-to-macos.sh
#   bash scripts/migrate-to-macos.sh /run/media/lamjiidii1/MACUSB/OpenMac-migration
#
# Environment:
#   SESSION_ID   session to export (default: newest session under this repo)
#   OC_VERSION   OpenCode version to pin (default: the running version)
#
# The bundle contains the SMBIOS identity, API keys and private transcripts.
# Treat it like the identity.plist itself: never publish or share it.

set -u

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
REPO_NAME=$(basename "$REPO")
DEST=${1:-/run/media/lamjiidii1/MACUSB/OpenMac-migration}
OC_VERSION=${OC_VERSION:-$(opencode --version 2>/dev/null || echo 2.2.5)}
OC_VERSION=${OC_VERSION##* }
OC_VERSION=${OC_VERSION#v}
DATA=$(opencode debug paths data 2>/dev/null || echo "$HOME/.local/share/opencode")
CONFIG=$(opencode debug paths config 2>/dev/null || echo "$HOME/.config/opencode")
DB=$(opencode debug paths db 2>/dev/null || echo "$DATA/opencode.db")

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

[ -d "$REPO/.git" ] || die "run this from the repository checkout"
[ -f "$DB" ] || die "OpenCode database not found at $DB"
have sqlite3 || die "sqlite3 is required"
have tar || die "tar is required"
have curl || die "curl is required"
have sha256sum || die "sha256sum is required"

mkdir -p "$DEST" || die "cannot create $DEST"
DEST=$(cd "$DEST" && pwd -P)
[ "$DEST" != "$REPO" ] || die "destination must not be the repository"

SESSION_ID=${SESSION_ID:-$(sqlite3 "$DB" \
  "select id from session_v2 where directory = '$REPO' order by time_updated desc limit 1;" 2>/dev/null)}
[ -n "$SESSION_ID" ] || die "no session found for $REPO; set SESSION_ID explicitly"

say "OpenMac -> macOS migration bundle"
say "  repository : $REPO"
say "  session    : $SESSION_ID"
say "  data       : $DATA"
say "  bundle     : $DEST"
say "  version    : $OC_VERSION"
say ""

# --- 1. session transcript (clean, portable import) ------------------------
say "Exporting the session transcript"
opencode session export "$SESSION_ID" > "$DEST/openmac-session.json" \
  || die "session export failed"
bytes=$(wc -c < "$DEST/openmac-session.json" | tr -d ' ')
[ "$bytes" -gt 1024 ] || die "session export is suspiciously small ($bytes bytes)"
note "openmac-session.json ($bytes bytes)"

# --- 2. consistent SQLite snapshot (sessions + credentials) ----------------
say "Snapshotting the OpenCode database"
tmpdb="$DEST/.opencode.db.tmp"
rm -f "$tmpdb"
sqlite3 "$DB" ".backup '$tmpdb'" || die "sqlite3 backup failed"
check=$(sqlite3 "$tmpdb" "pragma integrity_check;" 2>/dev/null)
[ "$check" = "ok" ] || die "database integrity check failed: $check"
mv -f "$tmpdb" "$DEST/opencode.db"
note "opencode.db ($(wc -c < "$DEST/opencode.db" | tr -d ' ') bytes, integrity ok)"

# --- 3. config -------------------------------------------------------------
if [ -f "$CONFIG/opencode.json" ]; then
  cp -f "$CONFIG/opencode.json" "$DEST/opencode.json"
  note "opencode.json"
fi

# --- 4. snapshots / shell / tool output -----------------------------------
say "Archiving OpenCode snapshots and tool output"
members=""
for d in snapshot shell tool-output; do
  [ -d "$DATA/$d" ] && members="$members $d"
done
if [ -n "$members" ]; then
  # shellcheck disable=SC2086
  tar -C "$DATA" -czf "$DEST/opencode-data.tar.gz" $members \
    || die "could not archive the OpenCode data directories"
  note "opencode-data.tar.gz ($(wc -c < "$DEST/opencode-data.tar.gz" | tr -d ' ') bytes)"
fi

# --- 5. pinned macOS binary ------------------------------------------------
say "Fetching OpenCode $OC_VERSION for macOS x86_64"
zip="$DEST/opencode-darwin-x64.zip"
url="https://github.com/anomalyco/opencode/releases/download/v${OC_VERSION}/opencode-darwin-x64.zip"
if [ -f "$zip" ] && unzip -l "$zip" 2>/dev/null | grep -q 'opencode'; then
  note "using existing $(basename "$zip")"
else
  curl -fL --retry 3 -o "$zip.tmp" "$url" || die "download failed: $url"
  mv -f "$zip.tmp" "$zip"
  note "$(basename "$zip") ($(wc -c < "$zip" | tr -d ' ') bytes)"
fi

# --- 6. repository archive (keeps .git, private/, mine/, build/) -----------
say "Archiving the repository (this is the slow step)"
# A few root-owned captures under LOGS are unreadable as a normal user; keep the
# rest instead of failing the whole migration (GNU tar on the Linux side).
tar --ignore-failed-read -C "$(dirname "$REPO")" \
  -czf "$DEST/$REPO_NAME-repo.tar.gz" "$REPO_NAME" \
  || die "repository archive failed"
tar -tzf "$DEST/$REPO_NAME-repo.tar.gz" >/dev/null 2>&1 \
  || die "repository archive is not readable"
note "$REPO_NAME-repo.tar.gz ($(wc -c < "$DEST/$REPO_NAME-repo.tar.gz" | tr -d ' ') bytes)"

# --- 7. restore script + notes --------------------------------------------
cp -f "$REPO/scripts/macos/restore-opencode-migration.sh" "$DEST/restore-on-macos.sh" \
  || die "could not copy the restore script"
chmod 0755 "$DEST/restore-on-macos.sh"

cat > "$DEST/MIGRATION.md" <<EOF
# Move this OpenCode session to macOS

The bundle was built on $(date -u '+%Y-%m-%d %H:%M UTC') for
\`$REPO\` and session \`$SESSION_ID\`.

It contains the full transcript, the OpenCode database (including the
InferX/Google credentials), snapshots, shell output, the repository with
\`.git\` and \`private/identity.plist\`, and a pinned OpenCode $OC_VERSION
macOS x86_64 binary.

> Private: the database holds API keys, and the repository holds the SMBIOS
> identity.  Do not upload this directory anywhere.

## Linux side (already done)

\`\`\`sh
bash scripts/migrate-to-macos.sh
\`\`\`

## macOS side

1. Boot macOS.  Open Terminal.
2. Run the restore script:

\`\`\`sh
bash /Volumes/MACUSB/OpenMac-migration/restore-on-macos.sh
\`\`\`

It installs OpenCode $OC_VERSION under \`~/.opencode/bin\`, extracts the
repository to \`~/OpenMac\` (override with \`REPO_DIR=...\`), restores the
database and config, and moves session \`$SESSION_ID\` to the new directory.
It refuses to overwrite an existing repository or database; move them away
first.

3. Continue the chat:

\`\`\`sh
opencode --session $SESSION_ID ~/OpenMac
\`\`\`

## Manual fallback

If the restore script stops early:

\`\`\`sh
D="\$HOME/Library/Application Support/opencode"
mkdir -p ~/.opencode/bin "\$D"
unzip -o /Volumes/MACUSB/OpenMac-migration/opencode-darwin-x64.zip -d /tmp/oc
install -m 0755 /tmp/oc/opencode ~/.opencode/bin/opencode
export PATH="\$HOME/.opencode/bin:\$PATH"

tar -xzf /Volumes/MACUSB/OpenMac-migration/$REPO_NAME-repo.tar.gz -C "\$HOME"
cp /Volumes/MACUSB/OpenMac-migration/opencode.db "\$D/opencode.db"
cp /Volumes/MACUSB/OpenMac-migration/opencode.json "\$D/opencode.json"

cd ~/$REPO_NAME
opencode api post /api/session/$SESSION_ID/move \\
  --data '{"directory":"'"\$HOME/$REPO_NAME"'"}'
opencode --session $SESSION_ID .
\`\`\`

The paths above are what \`opencode debug paths\` reports on macOS; run that
command if they differ on your install.  The same directory holds both the
database and \`opencode.json\` on macOS.

If the move endpoint refuses (session busy or old server), import the clean
transcript instead:

\`\`\`sh
opencode session import --directory "\$HOME/$REPO_NAME" \\
  /Volumes/MACUSB/OpenMac-migration/openmac-session.json
\`\`\`

The import keeps the same session ID.  It only works when the database does
not already contain that ID, so use it instead of restoring \`opencode.db\`,
or delete the old row first.
EOF

# --- 8. manifest -----------------------------------------------------------
say "Writing checksums"
(
  cd "$DEST" || exit 1
  for f in openmac-session.json opencode.db opencode.json \
           opencode-data.tar.gz opencode-darwin-x64.zip "$REPO_NAME-repo.tar.gz" \
           restore-on-macos.sh MIGRATION.md; do
    [ -f "$f" ] && sha256sum "$f"
  done > SHA256SUMS
)
note "SHA256SUMS"

say ""
say "Bundle complete: $DEST"
du -sh "$DEST" 2>/dev/null | sed 's/^/  /'
say ""
say "Next: boot macOS, then run"
say "  bash /Volumes/MACUSB/OpenMac-migration/restore-on-macos.sh"
