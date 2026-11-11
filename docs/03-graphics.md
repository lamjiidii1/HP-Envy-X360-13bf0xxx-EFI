# 03 — Graphics: what is happening and how to fix it

This is the open problem. Everything else on the machine works. Read this
before changing boot arguments.

## Current state: Tahoe default, Sequoia supported

The machine dual-boots **macOS 26 Tahoe** and **macOS Sequoia 15.8.2
(24H232, Darwin 24.6.0)**. The default `make build` now targets Tahoe with the
dynamic-MMIO 0.8.0 port; the 0.6.0 `adlp-edp` build is kept as the proven
Sequoia pairing:

| Half | Version | Why |
|---|---|---|
| EFI kext (default) | WhateverXe 0.8.0, `adlp-0.8.0` branch, binary `cc7b83a2…` (`gpu-wex080-adlp`) | Default for macOS 26; upstream 0.8.0 rebase; resolves MMIO dynamically without binary patching; masks unprobed Type-C routes to drive internal OLED; Metal POSH leak fix and flip deduplication |
| EFI kext (Sequoia) | WhateverXe 0.6.0, `adlp-edp` branch, patch series 54, published binary `197da23b…`; the `hp-adlp-edp` build applies the 24H232 Sequoia constant | Proven base driver for macOS 15.8.2; parses this VBT and drives internal OLED |
| Installed package | WhateverXe Graphics 0.4.1 (`AppleIntelTGLCompat` 0.8.0) | Installed 2026-11-09; pairs with the default `wex080-adlp`. Graphics 0.3.1 remains the package for the 0.6.0 Sequoia build |

WhateverXe 0.6.0 picks its MMIO protection routine by OS family
(`tglPrepareMMIOUC()` dispatches to `…TahoeMMIOUC`, `…SequoiaMMIOUC`,
`…SonomaMMIOUC`, …). The Tahoe patch never ran on the Sequoia install. Sequoia
has its own build-matched check, and **24H232 does not match the constant in
either WhateverXe 0.6.0 or 0.6.1**, so the published 0.6.0 binary cannot start the
accelerator without patching. The `hp-adlp-edp` build rewrites the one stale
byte in the built kext; the pinned payload in `efi/variants` stays as published.
On **WhateverXe 0.8.0-adlp**, MMIO protection is resolved dynamically at
runtime (`TGLMMIOStrongUCRouted = Yes`), requiring zero binary patching on
24H232 or future point updates.

### Graphics package 0.4.1 (2026-11-09)

The installed userspace half is now **WhateverXe Graphics 0.4.1**, released
2026-11-07 with WhateverXe 0.8.0. It ships `AppleIntelTGLCompat` **0.8.0** and
the same patched Apple TGL kernel drivers and Metal/VA bundles as 0.3.1 (the
OpenGL driver was rebuilt for the extra GPU IDs). The upgrade was checked
before installation:

- `AppleIntelTGLCompat` 0.8.0 keeps `OSBundleCompatibleVersion = 0.5.0` and
  exports the identical 14-symbol set as 0.6.0, so the `wex080-adlp` kext binds
  without a rebuild.
- `AppleIntelTGLGraphics`, `AppleIntelTGLGraphicsFramebuffer`, and the Metal
  and VA bundle executables have **byte-identical `__TEXT,__text`** to the
  installed 0.3.1 payload, so every hard-coded symbol offset WhateverXe
  validates is unchanged. `GLDriver` was rebuilt in 0.4.0 for the extra GPU
  IDs; it is userspace and contains none of those offsets.
- The packaged Compat source hashes match this repository's fork exactly:
  `AppleIntelTGLCompat.cpp` `2a5f7622…`, `GraphicsPolicy.plist` `dd955549…`,
  `kern_xelp_os.hpp` `0a1e96c4…`, `kern_xelp_devices.hpp` `7df14948…`.
- The 0.4.1 package rebuilds the AuxKC from `/Library/Extensions` and includes
  the port's Compat 0.8.0, the framebuffer, the accelerator and the two
  HighPoint kexts.

The only change between 0.4.0 and 0.4.1 is the Compat fix: macOS kernel
updates are accepted by OS family and ABI instead of an exact build string.
Relative to 0.3.1, 0.4.0 also rebuilt the OpenGL driver for the extra GPU IDs
and included the fixed Metal and VA shims, so
`patch-mtl-impostor.sh` and `patch-va-tglva.sh` are no longer needed on 0.4.1;
they remain for a 0.3.1 rollback. The package SHA-256 is
`7f7ce3b924ad421cff0c4f30534598858474b8c9539c4b889a461bc1d5fed02c`, matching
upstream `SHA256SUMS`.

After the installer the on-disk versions were confirmed (`Compat 0.8.0`,
Apple kexts `16.0.32` / `16.0.0`), the three binaries matched the package
payload byte-for-byte, and `kmutil inspect` listed Compat 0.8.0
(`F6997294-0598-30BD-98B3-38E0EEB2FA7E`) in the rebuilt AuxKC. After the
required reboot, **the 0.8.0 + Graphics 0.4.1 pair was verified on macOS 26
Tahoe on 2026-11-11**: the accelerator loads, the internal panel runs at
HiDPI, Metal 2 is reported, and the Battery pane and App Store paint
correctly. The commands below remain the regression check.

What to check after booting Tahoe (0.8.0 default) or Sequoia (0.6.0):

```sh
# On 0.6.0: guard[19] must be 01
ioreg -lw0 | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'

# On 0.8.0: dynamic MMIO route must be active (Yes)
ioreg -lw0 | grep -o '"TGLMMIOStrongUCRouted" = [^<]*'

# Both variants: internal panel route and link training hooks
ioreg -lw0 | grep -o '"WEXDisplay13ComboDPReady" = [^<]*'
ioreg -lw0 | grep -o '"WEXDisplay13TrainingReady" = [^<]*'
ioreg -rc IntelAccelerator | head -1                     # must print a match
system_profiler SPDisplaysDataType | grep -i metal
```

`TGLSequoiaMMIOGuard` is a 20-entry array; entry 19 is the overall verdict, and
entries 8–16 are the individual byte comparisons. Entry 16 is the ninth and
last comparison, at `_IOProtectCacheMode + 0xCA`. If entry 19 is still `0`,
decode the array and read the next section.

## The 24H232 MMIO signature

`tglPrepareSequoiaMMIOUC()` compares nine kernel byte patterns. On 24H232 the
first eight match and the ninth does not:

| | |
|---|---|
| Expected by WhateverXe (build 24H32) | `_IOProtectCacheMode+0xCA` = `E8 71 CB 02 00` (call rel32 `0x2CB71`) |
| Actual on build 24H232 | `E8 A1 CB 02 00` (call rel32 `0x2CBA1`, target shifted `+0x30`) |

The failed comparison sets `tglMMIOUCRouted` and `tglActive` to false; the
accelerator probe is then rejected and the machine falls back to a framebuffer
with about 19 MB VRAM and no Metal. This is the same failure shape as the
Tahoe one, at a different routine and a different offset.

The constant appears **twice** in the binary, and only one copy is live:

| Offset | What it is | Referenced? |
|---|---|---|
| `0x16FCE` | four-byte `imm32` of `movl $0x02CB71E8,-0x58(%rbp)` at `0x16FCB`; the fifth byte `00` comes from the adjacent `movb $0,-0x54(%rbp)` | yes — the guard's ninth `memcmp` |
| `0xCF211` | five-byte copy in the literal pool, immediately before the `TGLSequoiaMMIOGuard` string | no — left over from the guard table |

The fork's `tglPrepareSequoiaMMIOUC()` is byte-identical to upstream 0.6.1's,
so the finding transfers exactly. Credit for the diagnosis and the first
working binary goes to
[dwiwinarno911/opencore-msi-tigerlake-irisxe](https://github.com/dwiwinarno911/opencore-msi-tigerlake-irisxe),
who patched 0.6.1 at `0x16703` (live `movl`) and `0xcbabe` (pool copy) and got
`IntelAccelerator` and Metal 2 on the same macOS build.

Two tools apply the change:

- `make build` patches the built `WhateverXe.kext` from `E8 71 CB 02` to
  `E8 A1 CB 02` and records the result in `BUILD-INFO.plist`
  (`gpu_patches.sequoia_mmio`). `--skip-sequoia-mmio-patch` disables it when
  building for a different macOS build. The resulting default binary is
  `6bf93338…`; the pinned payload remains `197da23b…`.
- `scripts/macos/patch-wex-sequoia-mmio.sh` repairs a stick or ESP in place.
  With `--kernel` it reads the actual bytes from the matching KDK kernel and
  refuses a kernel whose `_IOProtectCacheMode` prologue does not match;
  without a KDK it uses the known 24H232 value and says so. `--dry-run` and
  `--restore` work like the Tahoe tool. It patches only `C7 45`-prefixed live
  immediates and the literal-pool copy, and requires the
  `TGLSequoiaMMIOGuard` anchor.

After any macOS update, re-check `TGLSequoiaMMIOGuard`. A point update can move
the call again; in that case decode entry 16 and run the script with the new
KDK rather than guessing.

## Metal archives on 24H232

Getting the accelerator to start is only the first half. WhateverXe Graphics
0.3.1 could still crash on Apple's **precompiled Metal archives**, because its
`impostor.dylib` shim only activated the archive hook on 24H32. This was not the
MMIO guard: here Metal existed but mishandled an archive.

Confirmed on 2026-11-03 on this machine:

| Process | Path | Result |
|---|---|---|
| ControlCenter | `RB::load_library_archive` | crash loop |
| `PowerPreferences` (Battery settings) | `MTLLoader sliceIDForDevice:…` | `SIGABRT` on pane open |
| App Store | `CA::Render::prepare_image` → HEIC decode | hang; separate VA-driver gate, see below |
| Safari video | archive load | freeze |

The assertion is always the same:

```text
+[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]:685:
  failed assertion `Target device architecture is nil'
```

Upstream's known-issues list names both "some image-conversion operations can
crash applications" and "App Store video can freeze the GPU on Sequoia". The
first is this archive gate; on this machine the App Store hang turned out to be
a second, independent VA-driver gate, covered in
[§ HEIC/HEVC decode](#heichevc-decode-and-the-tglva-guard).

### The `impostor.dylib` version gate and the 0.4.x fix

The bundle that WhateverXe installs beside Apple's TGL Metal driver is:

```text
/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS/
    impostor.dylib
    descriptor.dylib
    libigdmd.dylib
```

`impostor.dylib` hooks `-[MTLDevice newBinaryArchiveWithDescriptor:error:]` and,
for a legacy Intel device, returns a normal `NSError`
(`MTLBinaryArchiveDomain`, code 4, "This legacy driver has no target
architecture for binary archives") instead of letting `MTLLoader` assert. The
0.3.1 build gates that hook on the **exact build string**:

```text
kern.osversion == "24H32"
```

This machine is **24H232**, so the hook was never installed — which is why the
launchd environment workaround could not help. WhateverXe Graphics **0.4.0**
rebuilt only that shim and gated it on `kern.osrelease` 24.6.0+ (and 25.x);
`descriptor.dylib` and `libigdmd.dylib` are byte-identical to 0.3.1. The
installed **0.4.1** package contains the same shim
(`1cc38c7941333d3f4b88316795c78ca0095addf945fa35b6ff8634ecc93a1060`), so no
separate shim installation is required on the current package.

For a 0.3.1 rollback, apply the shim with:

```sh
sudo bash scripts/macos/patch-mtl-impostor.sh --test
```

The script pins the 0.4.x SHA-256
`1cc38c7941333d3f4b88316795c78ca0095addf945fa35b6ff8634ecc93a1060`, backs up
the whole driver bundle first, verifies signatures, clears the user Metal
caches and restarts System Settings/ControlCenter. Verified on this machine on
2026-11-04: the Battery pane opened at 21:09 and ControlCenter stayed up with no
`MTLLoader` errors. `--status` reports the installed shim, `--rollback` restores
the newest bundle backup. Only reinstall the shim if you deliberately roll the
package back to 0.3.1; 0.4.1 already ships it.

The earlier per-user LaunchAgent (`RB_USE_BINARY_ARCHIVE=0`,
`MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES=1`, `MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS=1`)
was a plausible mitigation but is **not a fix**: measured on 2026-11-04, all
three variables were present in the `gui/501` environment (and inherited by a
new Terminal shell), yet a fresh System Settings still aborted at `MTLLoader`
line 685. Remove it if it is still installed:

```sh
bash scripts/macos/install-metal-archive-workaround.sh --uninstall
```

The script is kept only as an experiment and as the record of that negative
result; do not present it as the Battery or App Store fix. On 2026-11-04 the
agent was uninstalled **after** the shim fix and the Battery pane still opened
with none of the three variables set, so the fix does not depend on it.

### HEIC/HEVC decode and the TGLVA guard

The App Store hang is **not** the Metal archive gate. Its hang report shows the
main thread inside:

```text
CA::Render::prepare_image
  → HEIFReadPlugin::decodeImageImp
    → VTTileDecompressionSessionCopyProperty
      → dispatch_sync … waiting for com.apple.coremedia.videodecoder
```

App Store screenshots and previews are HEIC, and HEIC tile decode goes through
VideoToolbox and the WhateverXe VA shim:

```text
/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle/Contents/MacOS/
    TGLVA
    AppleIntelTGLGraphicsVADriver
```

The 0.3.1 `TGLVA` gates its SPS/donor hook on the exact build string
`ProductBuildVersion == "24H32"`. On 24H232 it aborts:

```text
TGLVA adapter fatal: SPS OS/donor ABI guard
```

`VTDecoderXPCService` then exits, launchd marks
`com.apple.coremedia.videodecoder` inactive, and every synchronous decoder
caller waits forever. That is the App Store "hang": no crash, just a spinner.
The same guard breaks the dynamic wallpaper and video conferencing
(`avconferenced` also logs it).

Graphics 0.4.0 rebuilt `TGLVA` with an OS-family guard keyed on
`kern.osrelease` (`24.6.0` here). Its `AppleIntelTGLGraphicsVADriver` differs
from 0.3.1 only in the PCI device-ID dispatch table. The installed **0.4.1**
package ships the same fixed `TGLVA`
(`db879dbae1c708b5fcdb3c39e251e63e635016d19885e9186fdc6baca68414aa`), so no
separate VA patch is needed.

For a 0.3.1 rollback, install the shim with:

```sh
sudo bash scripts/macos/patch-va-tglva.sh --test
```

The script pins the 0.4.x SHA-256
`db879dbae1c708b5fcdb3c39e251e63e635016d19885e9186fdc6baca68414aa`, backs up
the whole VA bundle, restarts `VTDecoderXPCService` / `WallpaperVideoExtension`
/ `avconferenced`, and runs a HEIC decode through `sips` with a 15 s timeout.
Verified 2026-11-05: the HEIC decoded in under a second, no fatal was logged,
and the App Store loaded normally. `--status` and `--rollback` work like the
Metal script.

The simplest manual reproduction, and the regression test, is:

```sh
sips -s format png "/System/Library/Desktop Pictures/.thumbnails/Valley Light.heic" --out /tmp/t.png
```

With the 0.3.1 shim this hangs indefinitely; with the 0.4.x shim it finishes at
once.

> **GPU resets after enabling decode.** On 2026-11-05, while the App Store was
> first loading many HEIC previews, the kernel logged two GPU resets ten
> seconds apart (`Kernel_2026-11-05-1435*.gpuRestart`, application
> `VTDecoderXPCServ`, RCS ring hung). Decode continued to work afterwards. This
> is not the guard bug and not the archive bug; if resets recur during ordinary
> browsing, capture a fresh `.gpuRestart` and consider software decode for the
> affected path rather than reverting this shim.

### Runtime shader compilation works; the compiler denials are cosmetic

`MTLCompilerService` logs a denial every time a Metal app compiles shaders from
source:

```text
Sandbox: MTLCompilerService(pid) deny(1) file-read-data
  /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib
Sandbox: MTLCompilerService(pid) deny(1) file-map-executable
  /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/libigc-tgl.dylib
```

The reason is in Apple's own profile,
`/System/Library/Sandbox/Profiles/com.apple.mtlcompilerservice.sb`. Read access
to `/Library/GPUBundles` (and `file-map-executable`) is wrapped in:

```text
(with-filter (system-attribute apple-internal) ...)
```

This is a normal install with `Apple Internal: disabled`, so the filter is
false and the WhateverXe compiler bundle can never be mapped into the sandboxed
service. `XeCompilerAdapter.bundle` also has no `Info.plist` and reports
`bundle format unrecognized` to `codesign`, but that is not what blocks it.

**This does not disable shader compilation.** WhateverXe Graphics 0.3.1 and
0.4.1 already
changed the path to the OS-native AIR converter, so after the plugin load fails
`MTLCompilerService` converts the AIR itself. Measured on 2026-11-05 with a
Swift program that called `device.makeLibrary(source:)` and then
`makeComputePipelineState`:

```text
device: Intel(R) TGL Unknown
LIBRARY OK: ["addone"]
PIPELINE OK: maxThreads=1024
```

It completed in well under a second and exited 0 while the denials above were
being logged. The denials are therefore **log noise, not a functional block**,
and they are not a reason to patch `/System` or weaken SIP further. The
regression test is:

```sh
bash scripts/macos/test-metal-runtime-compile.sh
```

The practical cost of the archive gate is one runtime compile per app and
pipeline on first use, cached afterwards. That is much smaller than the memory
pressure described in
[08-troubleshooting.md](08-troubleshooting.md#7-battery-power-cpu-and-display).

## Why the fork is still required

Upstream 0.7.0 (2026-11-02) states Sequoia 15.8.x support, removes the
exact-build MMIO requirement, and its changelog says internal eDP for Alder
Lake-H/P/U is implemented. It was still rejected as the default, because of two
facts about *this* firmware, both checked off-hardware by compiling the parsers
from `b00t0x/WhateverXe@main` and `retropineaple/WhateverXe@adlp-edp` and
feeding them this machine's real VBT
(`LOGS/linux-evidence-2026-10-31-133508/debugfs/1-i915_vbt`, 8704 bytes):

| Parser | Result on this VBT |
|---|---|
| upstream `VBT::parse(..., AlderLakeP)` | `Status::Conflict`, `present = 0x03`, no ports used |
| fork `VBT::parse(..., AlderLakeP, firstWins=true)` | `Status::Valid`, `present = 0x7b`, `duplicates = 1` |
| either parser, panel facts | `panel.valid = 0` (block 40 holds `panel_type = 0xFF`) |

The VBT describes the internal DP panel on **Combo A** (`aux 0x40`) and again
on **Combo B** (`aux 0x10`), plus a third child on DVO1 that maps to DDI 1. Two
digital children claim DDI 1, and upstream treats that as `Conflict` and
discards the table. Separately, `panel_type = 0xFF` means "the panel is chosen
by PnP id", so no `panel` record is produced even when the table parses.

The fork addresses both in two small pieces of code that upstream does not
have:

- `parse(..., firstWins)`: keeps the first child per DDI, counts the rest as
  duplicates, and prefers DDI A when choosing the internal panel.
- `display13PanelDP()` behind `-wex-adlp-edp`: adds Combo A as a **fixed DP
  output** — a panel that has no usable VBT panel record but a valid internal
  DP port at `aux 0x40`.

That fixed-DP path is what the same-model reference used to reach a working
panel on Tahoe 26.7.1, and it is why the fork remains the default.
Upstream 0.7.0 is shipped on the stick as `EFI-wex070` so the claim can be
tested directly — it pairs with WhateverXe Graphics 0.4.0
(`AppleIntelTGLCompat` 0.7.0), which is **not** installed.

Rebasing those two behaviours onto current upstream was the remaining work;
the `wex080-adlp` port below now does it on 0.8.0.

In November 2026, WhateverXe 0.8.0 was released with dynamic MMIO resolution.
The `adlp-edp` logic was ported to 0.8.0 as `efi/variants/gpu-wex080-adlp`,
resolving the VBT conflict, adding the fixed Combo A DP route, and fixing a
Display 13 Type-C conflict described below.

## The stack

macOS has no driver for Alder Lake Iris Xe (`8086:46AA`). WhateverXe makes
Apple's **Tiger Lake** driver accept it:

| Component | Where it lives | Role |
|---|---|---|
| `WhateverXe.kext` | EFI `Kernel/Add` (injected) | Lilu plugin; rewrites the driver's expectations at runtime (device selection, memory layout, display 13 wiring, accelerator bring-up) |
| `AppleIntelTGLCompat.kext` | installed by WhateverXe Graphics into `/Library/Extensions`, loaded from AuxKC | Provides the Compatibility ABI the patched framebuffer/accelerator link against |
| `AppleIntelTGLGraphicsFramebuffer.kext` | installed by the Graphics package into `/Library/Extensions` + AuxKC | Patched Apple framebuffer |
| `AppleIntelTGLGraphics.kext` (accelerator) | same | Patched Apple 3D driver |
| `AppleIntelTGLGraphicsVADriver.bundle` | `/Library/GPUBundles` | Hardware video decode (optional) |
| `AMFIPass.kext` (Mod) | EFI | Lets the signed Xe bundles load without disabling AMFI globally |

The two halves must match ABI compatibility: the package installs
`AppleIntelTGLCompat` providing the symbols required by WhateverXe and the
patched Apple drivers.

| EFI kext | Required package | `AppleIntelTGLCompat` | Status |
|---|---|---|---|
| WhateverXe 0.8.0 + `adlp-edp` (`wex080-adlp`, default) | WhateverXe Graphics 0.4.1 | 0.8.0 | Installed 2026-11-09; boots Tahoe 26 and Sequoia (native dynamic MMIO, zero patching) |
| WhateverXe 0.6.0 + `adlp-edp` (Sequoia build) | WhateverXe Graphics 0.3.1 | 0.6.0 | Verified working on 15.8.2 (requires 24H232 build-time patch) |
| upstream WhateverXe 0.7.0 (`EFI-wex070`) | WhateverXe Graphics 0.4.0 | 0.7.0 | Control experiment (internal panel dark) |
| upstream WhateverXe 0.8.0 | WhateverXe Graphics 0.4.1 | 0.8.0 | Control experiment (Tahoe only; internal panel dark) |

The 0.5.0 compatibility floor is what matters. Compat 0.6.0, 0.7.0 and 0.8.0
all accept clients that request 0.5.0, but only a matching package installs the
Apple kexts the kext was built and tested against. Graphics 0.4.1 keeps the
same `__TEXT,__text` in the two Apple TGL kexts and the Metal/VA bundles as
0.3.1 (only the OpenGL driver changed), so the `wex080-adlp` default runs
unchanged; the 0.6.0 Sequoia build has the same ABI but has not been re-tested
with 0.4.1. Keep 0.3.1 with the Sequoia build, or record a fresh boot test
before changing the table above.

### WhateverXe 0.8.0-adlp: Dynamic MMIO and the Type-C conflict fix

The `wex080-adlp` port incorporates the `adlp-edp` patchset (first-child-wins
VBT parsing, Combo A DP route) into WhateverXe 0.8.0 and addresses two key
areas:

1. **Native Dynamic MMIO Resolution (`TGLMMIOStrongUCRouted = Yes`)**:
   Upstream 0.8.0 resolves MMIO cache mode pointers dynamically in memory
   rather than checking rigid OS-build byte patterns. On macOS Sequoia 15.8.2
   (24H232), MMIO UC is routed cleanly at boot with no binary patching or
   `scripts/macos/patch-wex-sequoia-mmio.sh` required.

2. **Display 13 Type-C Conflict & Black Screen Fix**:
   Upstream 0.8.0 introduced automatic DP-alt Type-C port routing in
   `display13Fixed()` (`kern_display13_firmware.hpp`). On the HP Envy VBT,
   Thunderbolt 4 / USB-C ports are declared on DDIs 3–6. This added `0x78` to
   `board.dp` and `board.typeC`, causing `adlnOutputWiring.selected()` to return
   `0x79` (Combo A `0x01` + Type-C `0x78`).
   In `kern_xe.cpp`, line 5598 gates Display 13 link training:
   ```cpp
   if (display13PanelDP && (adlnOutputWiring.dp & 3) && !(adlnOutputWiring.selected() & 0x78))
   ```
   Because `selected() & 0x78` was non-zero, `display13ComboDPReady` was never set,
   `processDisplay13Training()` never attached, and
   `AppleIntelFramebuffer::allocateBootDisplayResources` failed with error
   `0xe00002bc` (`FB0: Resources allocation failed` / `FB0: Failed to commit boot display resources`),
   leaving the OLED panel completely dark.

   **The Fix**: In `display13BoardWiring`, when `-wex-adlp-edp` (`display13PanelDP`)
   is active, speculative Type-C routes are explicitly cleared:
   ```cpp
   if (display13PanelDP) {
       board.dp &= ~0x78U;
       board.typeC = 0;
   }
   ```
   This ensures `selected() == 0x01` (Combo A OLED), allowing link training and
   modeset commit to succeed immediately.

   **Trade-off:** clearing the speculative Type-C routes also removes external
   DisplayPort over USB-C from the fixed wiring while `-wex-adlp-edp` is active.
   USB data and USB-C charging are unaffected. The internal OLED is the priority
   for this variant; keeping USB-C video would require probing for an external
   sink before masking the routes.

3. **Metal POSH leak and flip deduplication**: the 2026-11-10 build
   (`REL-080-2026-11-10`, binary `cc7b83a2…`) adds `-wex-mtl-poshfix` and
   `-wex-flip-dedupe`. `build_efi.py` puts both in the default `wex080-adlp`
   boot arguments.

## What the logs show

From `LOGS/macOS_Logs_20261030_180840` (macOS 26.7.2, build 25G332):

```
kextstat: org.b00t0x.WhateverXe (0.6.0)
kextstat: org.b00t0x.AppleIntelTGLCompat (0.6.0)
kextstat: com.apple.driver.AppleIntelTGLGraphicsFramebuffer (16.0.0)  0 references
kextstat: com.apple.driver.AppleIntelTGLGraphics (16.0.0)             0 references
Boot args: ... -wex-adlp-edp ... -wex-reset-restore -wex-no-multicontext ...
```

All three pieces load, but no Apple framebuffer ever attaches to the GPU:

| Property | Value | Meaning |
|---|---|---|
| `WhateverXeDeviceSelection` | `01000000 8680aa46 ...` | WhateverXe matched the iGPU (`8086:46AA`) |
| `WEXDisplay13BootReady` | `Yes` | Display 13 bootstrap ran |
| `WEXDisplay13ComboDPReady` | `Yes` | the fixed Combo A panel route was admitted |
| `WEXDisplay13TrainingReady` | `Yes` | link-training hooks installed |
| `N97Admission` / `N97NativePreflight` | `Yes` | memory/topology checks passed |
| `N97GTTopologyReady` | `Yes` | GGTT/stolen-memory layout accepted |
| **`TGLMMIOStrongUCRouted`** | **`No`** | **the MMIO user-copy hook was not installed** |
| **`TGLMMIOStrongUCPreflight`** | **`No`** | **the MMIO mapping was never made UC** |
| `N97NativeKernelReady` | `No` | `tglActive` is false |
| `N97NativeStartAllowed` | `No` | native framebuffer/accelerator start blocked |
| `N97NativeProbeBlocked` | `Yes` | WhateverXe installed its reject-probe guard |
| class counts | `IONDRVFramebuffer=1`, `AppleIntelFramebuffer=0`, `IntelAccelerator=0` | generic boot framebuffer only |
| `SPDisplaysDataType` | 19 MB VRAM, "No Kext Loaded" | consequence of the above |

The chain is explicit in the source: `tglActive = tglVM.enabled &&
tglMMIOUCRouted && tglMMIOUCReady`. With the MMIO hook missing, `tglActive`
stays false, so `processKext()` installs
`processAlderLakeNRejectedAccelerator()` and the donor driver never starts.
The panel work (`-wex-adlp-edp`, Combo A, training) already succeeded; this is
the last gate, not a display or VBT problem.

> This table is the state **before** the MMIO patch. It is kept as the record
> of the guard failure. The patched boot now passes this gate; see
> *Where the 26.7.2 bring-up stops now* below for the current failure.

## The VBT is valid

The root collector captured the real firmware table from Linux
(`LOGS/linux-evidence-2026-10-31-133508/debugfs/1-i915_vbt`):

- `$VBT ALDERLAKE-P`, version 100, BDB version **247**, 8701 bytes;
- internal DP child `0x1806` on **DDI A** (`aux 0x40`) and on **DDI B**
  (`aux 0x10`);
- a third child `0x60d2` on DVO1 that also maps to **DDI 1** — a duplicate;
- panel block 40 has `panel_type = 0xFF`, i.e. the panel is selected by PnP ID,
  so `WhateverXeFirmwarePanel.valid = false` is **expected**, not a fault.

The file is **byte-identical** to the reference fork's own fixture
`tests/fixtures/hp-envy-x360-13-bf-vbt.bin` (SHA-256
`4d790a72…fa30c`). BIOS F.35, the VBT and the panel are therefore not the
difference between this machine and the working one.

## Why unmodified upstream 0.6.1, 0.7.0 and 0.8.0 are not the answer

Upstream 0.6.1 (2026-10-27) added generic eDP support, but it cannot be used
on this unit:

1. **It rejects this VBT.** 0.6.1's `kern_vbt.hpp` returns `Status::Conflict`
   on the second child for DDI 1. Only the `adlp-edp` fork keeps the first
   child per DDI (Linux semantics) and prefers DDI A. With no ports, there is
   no panel.
2. **It has no `-wex-adlp-edp`.** The option was a 0.6.0-fork feature and was
   never merged upstream.
3. **It has the same stale Sequoia constant.** `tglPrepareSequoiaMMIOUC()` is
   byte-identical in 0.6.0 and 0.6.1, so 0.6.1 fails the ninth check on
   24H232 unless it gets the same patch (the MSI EFI does exactly that).
   0.7.0 removed the exact-build requirement, but not the parser problem.

0.7.0 is in the same position: it fixed the VBT *version* range and the MMIO
build matching, but the duplicate-DDI rule and the `panel_type = 0xFF` case are
unchanged (see [above](#why-the-fork-is-still-required)).

### Upstream WhateverXe 0.8.0 (2026-11-07) does not change this

0.8.0 adds Raptor Lake-U support, experimental MIPI DSI system sleep/wake,
an optional 60 Hz MiniBook panel mode, and fixes the 0.7.0 acceleration
regression (#27). None of that touches this panel. The release was checked
against tag `0.8.0` (`db438fd`, release asset SHA-256
`5b71e14ce10c673f6baba276183f268d7f04766d298cd34f1df0bb96f11c8e4b`) and
against the real HP Envy VBT fixture:

- `WhateverXe/kern_vbt.hpp` still rejects a second child for an already-used
  DDI with `Status::Conflict`; there is no `firstWins` mode and no duplicate
  counter.
- `panelFacts()` still requires `options[0] < 16`, so `panel_type = 0xFF`
  produces no panel record. It also refuses to associate two internal DP
  children, which this VBT has (Combo A and Combo B).
- `display13Fixed()` can mark an eDP panel only when
  `PanelPower::nativePPS0()` succeeds. That function requires a valid VBT
  panel record **and** a PWM backlight record; both are absent for this OLED,
  which is dimmed over DPCD AUX.
- The release binary contains none of the fork's markers
  (`-wex-adlp-edp`, `-wex-scanout-coherent`, `-wex-pm`, `WEXADLPPanelDP`).

Compiling the 0.8.0 parser from that tag and feeding it the machine's 8704-byte
VBT gives the same result as 0.7.0:

```
status=7 (Status::Conflict)  valid=0  version=247  present=0x3
ddi=0 type=0x1806 aux=0x40  internal=1 dp=1
ddi=1 type=0x1806 aux=0x10  internal=1 dp=1
panel valid=0
```

So upstream 0.8.0 plus WhateverXe Graphics 0.4.1 is **not** a route to the
internal 2880×1800 OLED. The two blockers are independent: even if the duplicate
DDI were ignored, the panel would still have no VBT panel/PWM record, and the
upstream code has no fixed-Combo-A DP fallback. A Tahoe experiment with
unmodified 0.8.0 can only test external HDMI/USB-C output and accelerator
bring-up; it will not light the laptop panel.

**The port now exists.** The `wex080-adlp` variant on `master` does exactly the
source port described here — `firstWins` VBT parsing, the Combo A internal-DP
panel association, the `display13PanelDP()` fixed-DP route, and the DPCD-AUX
backlight and scanout fixes — and it drives the panel under Sequoia with native
dynamic MMIO and no binary patching. Prefer that variant over unmodified 0.8.0
when testing on Tahoe; the remaining question is only whether the Tahoe donor
ABI accepts the same route. The previously known-good Tahoe panel path was the
0.6.0 `adlp-edp` fork paired with Graphics 0.3.1.

## The 26.7.2 MMIO signature (Tahoe history)

Everything in this section applies to **Tahoe 26.7.2 only**. On Sequoia a
different routine runs and these bytes are never read. It is kept as the
method that found the analogous 24H232 check described
[above](#the-24h232-mmio-signature), and as a tool for a future Tahoe boot.

`tglPrepareTahoeMMIOUC()` validates `_IOProtectCacheMode` by comparing nine
kernel byte patterns. On 25G332, eight match and only the call at
`_IOProtectCacheMode + 0xCC` differs. The published guard proves it:

```
TGLTahoeMMIOGuard = [1, 1, 0x4011000000, 0x1000000, 0x1040600070406,
                     1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, …, 0]
                                                              ^ guard[16]
```

`guard[16]` is the ninth byte match (`protect + 0xCC`); `guard[19]` is the
overall `ok`, which is zero. Everything else — the prologue, the pmap entry
sites, `kernel_map`, the PAT and the 16 MB BAR — passes.

The constant in the shipped kext is the 26.7.1 value
`E8 2F F3 02 00`. On 26.7.2 the call target moved, so the check fails even
though the function is the same.

The value appears **twice** in the kext binary, and only one copy is live:

| Offset | What it is | Referenced? |
|---|---|---|
| `0xCDF8E` | five bytes immediately before the `TGLTahoeMMIOGuard` string | no — dead data |
| `0x17907` | `imm32` of `movl $imm32,-0x58(%rbp)` at `0x17904` (`C7 45 A8 E8 2F F3 02`) | yes — the live comparison |

The next instruction, `movb $0,-0x54(%rbp)`, supplies the fifth byte, and the
`memcmp` at `0x17D7B` reads the five-byte stack array from `-0x58(%rbp)`.
Nothing loads or compares the data copy next to the string.

This distinction matters. The first version of the repair script anchored on
the string and rewrote the dead copy at `0xCDF8E`. The file hash changed and
the script reported success, but the guard after reboot was still `0x0` at
index 16. The script now finds the unique `C7 45`-prefixed immediate, requires
exactly one candidate, and rewrites only those four bytes. It also restores
the dead copy if an earlier run changed it, so every starting state converges
to the same binary.

Measured from the 25G332 KDK (`_IOProtectCacheMode` at file offset `0x19b410`,
`__TEXT` at `0xffffff8000200000`), the real bytes on this build are:

```
E8 5F F3 02 00
```

`E8` is `call rel32`; the displacement is `+0x2F35F` from the next
instruction, so the call goes to `0xffffff80003ca840`, which the KDK symbol
table names `_pmap_enter_options` — exactly the function WhateverXe resolves as
`fn` and patches at `+0x10C1`/`+0x1197`. The check therefore keeps its original
meaning; only the link-time displacement changed (26.7.1 used `+0x2F32F`, a
difference of `0x30`).

For this build, the default `WhateverXe.kext` binary goes from SHA-256
`c090b9dd35398c72e9567b38b9bb9b61415ab7fcfe22ffc78cbafc93ee67e49b`
to `d76d850e3907066df4e5facb38d8c7f2e2d7a4b5ab574ad1102acee8382f7787`
when patched for 25G332. (The intermediate hash `7fab9aa3…` from the first
attempt is **not** a valid result: it has the wrong byte patched.) The kernel
file extracted from
`Kernel_Debug_Kit_26.7.2_build_25G332.dmg` reports the same version string as
the running kernel (`root:xnu-12377.161.15.701.48~2/RELEASE_X86_64`) and has
SHA-256 `a91aad0da9d0a2f545c06859524bb048f4e2e392e46aa12da9fabe652081be53`,
so the bytes read from it apply to the booted kernel.

## The fix

`scripts/macos/patch-wex-tahoe-mmio.sh` reads the real five bytes from the
kernel Mach-O and replaces the stale four-byte immediate in the injected
WhateverXe binary. It keeps a `.orig` backup, matches the unique
`C7 45`-prefixed initialiser rather than the dead data copy, and does not touch
the kernel or the installed graphics package.

The system kernel on disk is usually stripped, so the script needs the
**Kernel Debug Kit for this exact macOS build** (25G332 here). The KDK provides
`_IOProtectCacheMode` with symbols; the script parses that Mach-O with perl,
so Xcode Command Line Tools, `nm` and `otool` are **not** needed.

```sh
# On macOS, with the ESP mounted at /Volumes/EFI:
ls /Library/Developer/KDKs/          # KDK_26.7.2_25G332.kdk expected

sudo ./scripts/macos/patch-wex-tahoe-mmio.sh \
  --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext \
  --kernel /Library/Developer/KDKs/KDK_26.7.2_25G332.kdk/System/Library/Kernels/kernel
sudo reboot
```

Without `--kernel` the script searches the KDK directories and the system
kernel paths and prints the candidate paths it tried. It prints the old and new
signatures, the kext SHA-256 before and after, then verifies the patched bytes.
`--dry-run` only reports; `--restore` puts the backup back.

If the script prints nothing at all, it exited before patching: update to this
version, because the older one depended on `nm` from the Command Line Tools and
could stop silently when that prompt was cancelled. If it reports
`patched`/`verify: e85ff302` but `guard[16]` is still `0` after the reboot,
check the two things in [docs/08-troubleshooting.md](08-troubleshooting.md):
the on-disk bytes at `0x17907`, and which ESP OpenCore actually booted.

This is a local binary change to an OpenCore-injected kext, not to a signed
system extension. Keep the backup; if the machine behaves worse, restore it
and boot the old EFI.

### Verify after the reboot

```sh
ioreg -l | grep -E 'TGLMMIOStrongUC|TGLTahoeMMIOGuard'
ioreg -l | grep -E 'N97Native(StartAllowed|KernelReady|ProbeBlocked)'
ioreg -rc AppleIntelFramebuffer        # count 1
ioreg -rc IntelAccelerator             # count 1
system_profiler SPDisplaysDataType     # GB-range VRAM, Metal support
```

Success looks like `TGLMMIOStrongUCRouted = Yes`,
`TGLMMIOStrongUCPreflight = Yes`, `N97NativeStartAllowed = Yes`,
`N97NativeKernelReady = Yes`, `N97NativeProbeBlocked` absent or `No`. In
`TGLTahoeMMIOGuard`, the ninth byte pattern (index 16) must now be `1`; if it
is still `0`, the firmware loaded an unpatched kext — check that you patched
the ESP OpenCore actually booted.

If `UCRouted` becomes `Yes` but `UCPreflight` stays `No`, the pmap check found
a different mapping; collect the new `TGLMMIOMappingEvidence` blob and stop.

## Where the 26.7.2 bring-up stops now (2026-11-01)

The corrected MMIO patch works, and the boot captured in
`LOGS/macOS_Logs_20261031_191812` runs further than the table at the top of
this document. The chain, in order:

| Time | Event |
|---|---|
| 19:13:49.042 | `IntelAccelerator::probe`: device `0x46aa8086`, revision `0xc` |
| 19:13:49.419 | TGL HWCAPS, host-preemptive scheduler, multi-context disabled |
| 19:13:49.450 | `IntelAccelerator` published |
| 19:13:50.44 | framebuffer `start`; Combo A AUX reads OK; AGDP `Framebuffer` events |
| 19:14:01.18 | AGDP validates 2880 x 1800 at 329.63 MHz (8 bpc accepted) |
| 19:14:02–38 | `FB0: This fb does not have FB memory`, `FB has no memory allocated, err = 0xe00002bc`, `Surface mode contains bad bits`, `Flip called without enabling VBL` |
| 19:14:38.49 | WindowServer tears down its virtual display; loginwindow and SecurityAgent exit |
| 19:14:38.68 | `kAGDCRegisterLinkModesetCallback`: FB0 -> 2880 x 1800, 329630000 Hz |
| 19:15:47 | next boot (safe mode) |

The old `guard[16]`/`UCPreflight` gate and the accelerator probe are resolved.
The failure is now in the framebuffer/WindowServer hand-off: FB0 has no scanout
memory, accelerated surfaces are rejected, the VBL enable is lost, and the
session dies at the first modeset. There is no panic and no WhateverXe message:
the last kernel line is the AGDP modeset callback itself.

WhateverXe 0.6.0 already contains the fork's fixes for these exact messages
(patches 18, 21 and 22 replay the dropped VBL request and treat an empty
aperture as "not ready"). Their presence does not prove the path ran. The live
properties are the only way to see which check refused the mapping:

```
N97FBApertureNotReady, N97FBApertureFirstFailure, N97FBMemory,
N97FBScanoutAllocate, N97FBBinding, N97FBBacking
```

The 2026-10-31 capture was taken in safe mode, so it contains none of them. A
black-screen boot cannot be typed into, so use the boot-capture daemon in
[docs/08-troubleshooting.md](08-troubleshooting.md#9-capturing-a-boot-that-dies-with-a-black-screen).

### What the live capture showed (2026-11-01 21:22)

`wex-capture-20261101-212217` is the first normal boot recorded from inside
macOS. It changes the picture in two ways.

First, the machine was **not** resetting by itself. The kernel lived for the
whole 136 s run and the reboot at the end was the capture daemon's own
`shutdown -r now`. The earlier "two minute reboot" was the same thing.

Second, the failure is a sequence, not a single rejection:

| Time | Event |
|---|---|
| 21:22:17.162 | `IntelAccelerator::probe`, then HWCAPS, host-preemptive scheduler |
| 21:22:17.553 | `IntelAccelerator` published (`N97NativeStartAllowed = Yes`) |
| 21:22:27.992 | AGDP `kAGDCRegisterLinkModesetCallback` 2880 x 1800, 329.63 MHz |
| 21:22:28.711 | `FB0: Partial modeset by updating plane` — succeeds |
| 21:22:29.762 | `FB0: Partial modeset by updating scaler` — succeeds |
| 21:22:28.95 | `IOAccelLegacySurface::set_id_mode`: `Surface mode contains bad bits` (x4) |
| 21:22:30.834 | first `FB0: Flip called without enabling VBL` |
| 21:22:30.232 | WindowServer gives up on the panel and activates a `VirtualDisplay` |
| 21:22:33.714 | `FB0: This fb does not have FB memory`, `FB has no memory allocated, err = 0xe00002bc` |
| 21:24:21.03 | WindowServer's second session exits; loginwindow restarts |

So the panel is detected (`AppleBacklightDisplay`, EDID `4c83:4166`, brightness
17497), the mode is accepted, and plane/scaler updates work. What is missing is
the **vertical-blank enable**: the first flip is refused, WindowServer cannot
present a frame, falls back to a virtual display, and from then on the
framebuffer has no memory at all.

`N97FBApertureNotReady` holds a two-entry record, `N97FBMemory` reports
configured/enabled, and `N97FBScanoutAllocate`/`ScanoutMemoryOwner` carry live
pointers — the aperture path did run. Nothing in the capture points at DVMT,
the MMIO gate or the accelerator probe. Everything points at the display
hand-off, which is exactly the class of fix the reference lists as *"Frame
flips failing, picture stuck — a vertical-blank enable was dropped during the
modeset; replay it once the display path exists"*.

### Decision: use the reference build of the same fork

The installed WhateverXe was a pre-patch-49 snapshot of the `adlp-edp` branch:
it lacks `-wex-scanout-coherent` and `-wex-pm`, and it predates the VBL replay.
The hardware-identical reference ships a later build of the same branch.

| | Installed before | Now |
|---|---|---|
| Build | `c090b9dd…`, 1,456,256 bytes, pre-patch-49 | `44ce24dd…`, 1,466,816 bytes, patch series 54 |
| Upstream SHA-256 | — | `197da23b…` (retropineaple/whateverxe-hp-envy-x360, `EFI/OC/Kexts/WhateverXe.kext`) |
| MMIO constant | patched `e85ff302` at `0x17907` | patched `e85ff302` at `0x17893` |
| Boot args | `-wex-adlp-edp -wex-reset-restore -wex-no-multicontext` | plus `-wex-scanout-coherent -wex-pm` |

That comparison was made for the Tahoe 26.7.2 install. The 25G332 patch was
applied with the four-byte immediate (`e8 2f f3 02` → `e8 5f f3 02`) in the
live `movl $imm32,-0x58(%rbp)` initialiser, leaving the unreferenced copy
before the `TGLTahoeMMIOGuard` anchor at the original constant.

**After the downgrade the Tahoe patch is no longer applied.** The stored
payload is the published `197da23b…` binary; on Sequoia the Tahoe routine is
not called. The build does apply the separate 24H232 Sequoia constant described
in *The 24H232 MMIO signature* above. `scripts/macos/patch-wex-tahoe-mmio.sh`
stays in the tree for a future Tahoe boot, not as a build step.

Two separate findings remain from the same boot:

- `MTLCompilerService` is sandbox-denied `file-read-data` and
  `file-map-executable` for
  `/Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib`
  and `libigc-tgl.dylib`. The sandbox allows that directory only for
  `apple-internal` systems, so the denial is expected; compilation still works
  through the OS-native AIR converter. See
  [§ Runtime shader compilation works](#runtime-shader-compilation-works-the-compiler-denials-are-cosmetic).
- `AppleIntelTGLCompat` logs `revision 0.5.0 started` while `kextstat` reports
  package 0.6.0. That is the internal ABI string, not a package mismatch.


## Fallback: 26.7.1 (Tahoe history)

Before the downgrade this was the documented fallback: the same kext, same
Graphics 0.3.1 and same VBT are proven to give Metal on macOS 26.7.1 (25G241).
It is kept here because it is the one Tahoe combination that is known to work;
macOS does not install an older build over a newer one, so it needs a full
reinstall.

## Boot arguments

| Argument | Why it is there |
|---|---|
| `-allow3d` | Allows the accelerator path to be considered |
| `-disablegfxfirmware` | Skips GuC firmware loading, which Apple's driver cannot do here |
| `-igfxdvmt` | Compensates for the BIOS's 60 MB DVMT pre-allocation (`framebuffer-stolenmem 0x3c00000`) |
| `keepsyms=1` | Keeps symbols in panics |
| `msgbuf=4194304` | Larger kernel log buffer for bring-up diagnostics |
| `shda-lang=en` | SimpleHDA language |
| `alcid=13` | AppleALC layout 13 (ALC245 with CS35L41 smart amps) |
| `-wex-adlp-edp` | Drive the internal panel as a fixed DP output on Combo A (0.6.0 fork only; this is the argument that makes this panel work) |
| `-wex-reset-restore` | Restore display/render state after a GPU reset |
| `-wex-no-multicontext` | Avoid the second compute ring that deadlocks on recovery |
| `-wex-scanout-coherent` | Mark every flipped surface displayable (HiDPI above 1440x900) |
| `-wex-pm` | XE-PM CPU profile: HWP units and the idle table on hybrid Alder Lake. On this kernel its HWP route does not install, so it does not change CPU power; see the note below |
| `-wex-mtl-poshfix` | 0.8.0 build only: fixes the Metal POSH resource leak reported on this port |
| `-wex-flip-dedupe` | 0.8.0 build only: deduplicates repeated flip transactions before they reach the display pipe |
| `-ithcoff`, `-ithcpoll` | `-ithcoff` disables `ITHC.kext`; `-ithcpoll` polls the THC instead of using its MSI interrupt |
| `-v`, `debug=0x100` | `--debug` builds only |

All five `-wex-*` arguments of the `adlp-edp` patchset (supported in both the
0.6.0 fork and `wex080-adlp`) are present in both patched builds; `wex080-adlp`
adds `-wex-mtl-poshfix` and `-wex-flip-dedupe`. They are deliberately **absent**
from the `EFI-wex070` build, because its parsing is intended to be the upstream
one. Do not copy them across without knowing which of the variants is under test.

Do not add `-wex-noaccel`: it deliberately disables the accelerator and would
guarantee the 19 MB fallback.

### CPU power: `-wex-pm` is inert on this kernel

WhateverXe 0.6.0 parses `-wex-pm`, registers the `debug.xepm.*` sysctls, and
then tries to route a hook onto XCPM's set-multiplier function. On 24H232 that
route fails, and the failure is visible at runtime:

```sh
sysctl debug.xepm.hwp debug.xepm.route debug.xepm.d3
# debug.xepm.hwp: 0      <- hook not installed
# debug.xepm.route: 3    <- 1 would mean installed
# debug.xepm.d3: 5       <- compiled-in default, unchanged
```

`xpSetMult` only writes MSR `0x774` (IA32_HWP_REQUEST) when `gXpHwp` is
non-zero, so the profile's `EPP=0` and EE-turbo-off never reach the hardware.
`sysctl -w debug.xepm.epp=...` is root-only and cannot help either: it changes
a variable that the same gate ignores.

The argument is harmless and stays in the default boot-args; `_xcpm_cstate_table`
resolves on this kernel, so its idle-table patch may still apply, but no EPP
tuning does. CPU power and heat are managed with XCPM low power mode instead:
`scripts/macos/power-profile.sh` and
[§ 6](06-usb-acpi-power.md#power-management).

## Install order (Sequoia build)

1. Boot Sequoia with the `hp-adlp-edp` EFI. WhateverXe Graphics 0.3.1 is
   already installed on this machine, so this should be the usable state.
2. Confirm the pair:
   ```sh
   kmutil showloaded | grep -iE 'whateverxe|AppleIntelTGLCompat'   # 0.6.0 / 0.6.0
   ```
   If `AppleIntelTGLCompat` is missing or is not 0.6.0, install **WhateverXe
   Graphics 0.3.1** and restart. 0.3.1 is the package that matches the fork.
3. The `hp-adlp-edp` build already contains the 24H232 Sequoia MMIO constant.
   If you copied an older stick, run
   `scripts/macos/patch-wex-sequoia-mmio.sh` on it first; the build does not
   patch a stick that was assembled elsewhere.
4. Check the Sequoia MMIO verdict and acceleration with the commands in
   *Verify after the reboot* and in *Current state* above.

### Running WhateverXe 0.8.0-adlp

The 0.8.0-adlp variant is the default; `make build` already produces it. To
build it explicitly:

1. Build `build/EFI` (or an explicit copy):
   ```sh
   ./scripts/build_efi.py --gpu wex080-adlp --out build/EFI-wex080-adlp --force
   ```
2. Copy `build/EFI` / `build/EFI-wex080-adlp` over the ESP of your boot disk or
   USB stick.
3. Boot into macOS. The matching userspace package is WhateverXe Graphics
   0.4.1 (`AppleIntelTGLCompat` 0.8.0); it is installed on this machine. The
   port also remains ABI-compatible with Graphics 0.3.1 if you need to compare.
4. Confirm dynamic MMIO and panel bringup:
   ```sh
   ioreg -lw0 | grep -o '"VersionInfo" = [^<]*'            # REL-080-...
   ioreg -lw0 | grep -o '"TGLMMIOStrongUCRouted" = [^<]*'  # Yes
   ioreg -lw0 | grep -o '"WEXDisplay13ComboDPReady" = [^<]*' # Yes
   ioreg -rc IntelAccelerator | head -1                     # present
   system_profiler SPDisplaysDataType | grep -i metal       # Metal 2
   ```
   No binary patching or MMIO script execution is required.

### Testing upstream 0.7.0 or 0.8.0 instead

This swaps the ABI half of the stack, so both steps are required and the
machine is not accelerated in between:

1. Copy `EFI-wex070` from the stick over the EFI you boot from. For 0.8.0,
   build a separate EFI with the 0.8.0 kext; the boot arguments stay upstream
   (no `-wex-*`).
2. Boot, then install the matching package — `WhateverXe-Graphics-0.4.0.pkg`
   for 0.7.0, `WhateverXe-Graphics-0.4.1.pkg` for 0.8.0 — and restart.
3. Expect the internal panel to stay dark — upstream discards this VBT. The
   useful outcome of the experiment is the IORegistry evidence
   (`WhateverXeFirmwarePorts` status, `TGLSequoiaMMIOGuard`) and external
   HDMI/USB-C output, not a picture on the laptop panel.
4. To go back, restore the default `wex080-adlp` EFI and keep Graphics 0.4.1.
   Restore Graphics 0.3.1 only if you go back to the 0.6.0 `hp-adlp-edp`
   Sequoia build.

## Rollback

The previous EFI is preserved at `mine/EFI` (local, not in Git). Copying it
back to the ESP restores the exact previous state. The graphics rollback is
`WhateverXe-Graphics-0.3.1.pkg`
(SHA-256 `bd8b449431b1bf3815f9011ad3e13c7038012d17aed54dfb2aecfce6b9089623`),
which restores Compat 0.6.0 and the 0.3.1 shims. The 0.4.1 install was
preceded by a verified copy of `/Library/Extensions`, `/Library/GPUBundles`
and `AuxiliaryKernelExtensions.kc` in
`~/MacOS/Backups/Graphics-0.3.1-pre-0.4.1-20261109/`; use it only if the
installer rollback is unavailable, and rebuild the AuxKC afterwards.

## Optional: disable the VA bundle

If video playback or the camera crashes, the EliteBook and XPS projects both
move Apple's video-acceleration bundle out of the way to force CPU decode:

```sh
sudo mkdir -p /Library/GPUBundles.disabled
sudo mv /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle /Library/GPUBundles.disabled/
sudo killall UVCAssistant VTDecoderXPCService
```

This costs hardware decode. Keep it as a troubleshooting step, not a default.
