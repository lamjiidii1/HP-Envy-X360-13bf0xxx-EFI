# Moving the work to macOS

The chat is not part of the repository.  OpenCode keeps it in a SQLite
database, next to the provider credentials, file snapshots and shell output.
Copying the `OpenMac` directory alone moves the code but not the conversation.

This page describes the bundle that moves both, so work can continue on the
installed macOS system without booting back into Linux.

> The bundle contains the SMBIOS identity (`private/identity.plist`), API keys
> and the full private transcript.  Treat it like the identity file: do not
> publish it, upload it, or leave it on a shared machine.

## What moves

| Piece | Linux source | macOS destination |
| --- | --- | --- |
| Session transcript | `opencode session export` | imported or moved into the project |
| Sessions + credentials | `~/.local/share/opencode/opencode.db` | `opencode debug paths db` (this install: `~/.local/share/opencode`) |
| Provider config | `~/.config/opencode/opencode.json` | `opencode debug paths config` (this install: `~/.config/opencode`) |
| Snapshots, shell, tool output | `~/.local/share/opencode/{snapshot,shell,tool-output}` | same names under the data directory |
| Repository | this checkout (with `.git`, `build/`, `LOGS/`, `mine/`, `private/`) | `~/OpenMac` |
| OpenCode binary | — | pinned `opencode-darwin-x64` under `~/.opencode/bin` |

The directories differ between OpenCode builds.  On this install macOS reports
`~/.local/share/opencode` and `~/.config/opencode`, while some builds use
`~/Library/Application Support/opencode`.  The restore script therefore asks the
installed binary with `opencode debug paths` instead of assuming a path.

## Build the bundle on Linux

Quit the OpenCode interface first, then:

```sh
bash scripts/migrate-to-macos.sh
```

The default destination is `/run/media/lamjiidii1/MACUSB/OpenMac-migration`.
Pass another path as the first argument.  The script:

1. exports session `ses_e722e4a32ffe04JF2JD5pNNxt1` as portable JSON;
2. takes a consistent `sqlite3 .backup` snapshot and checks its integrity;
3. copies `opencode.json`;
4. archives snapshots, shell history and tool output;
5. downloads (or reuses) the matching macOS x86_64 OpenCode release;
6. archives the repository, keeping `.git` and the private files;
7. writes `MIGRATION.md`, `restore-on-macos.sh` and `SHA256SUMS`.

Files under `LOGS/linux-evidence-*/acpi` that were captured as root are
unreadable to a normal user; the archive skips them and keeps everything else.

## Restore on macOS

Boot macOS, open Terminal, and run:

```sh
bash /Volumes/MACUSB/OpenMac-migration/restore-on-macos.sh
```

The script verifies the checksums, installs the binary, extracts the repository,
restores the database and config, starts the background service, and moves the
session to `~/OpenMac` with the API endpoint:

```text
POST /api/session/<id>/move   {"directory":"/Users/<you>/OpenMac"}
```

It then prints:

```sh
opencode --session ses_e722e4a32ffe04JF2JD5pNNxt1 ~/OpenMac
```

If the move endpoint is unavailable, the script stops the service, removes the
old session row and imports the clean JSON transcript instead; the import keeps
the same session ID.  Never restore `opencode.db` **and** import the same
session — the import refuses duplicates.

Existing data is renamed, not deleted:

- old `opencode.db` / `opencode.json` → `*.pre-migration-<timestamp>`;
- non-empty `~/OpenMac` → `~/OpenMac.pre-migration-<timestamp>` with `FORCE=1`,
  otherwise the script stops.

## After the move

- Run `opencode doctor` (or open the chat) once to confirm the provider and the
  credential survived; `opencode debug paths` should list the macOS paths.
- The old Linux checkout is untouched and can stay as a backup.
- The USB bundle is still private after a successful restore; delete it or keep
  it somewhere safe.
- Diagnostics, EFI work and the remaining Battery/App Store investigation
  continue from `~/OpenMac` exactly as before; the git history is in the bundle.
