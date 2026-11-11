# 05 — Audio & Microphone

## Hardware Chain

```
Playback (Speakers):
  PCM Stream  →  Realtek ALC245 (Node 0x17 via DAC 0x03)
              →  2x Cirrus Logic CS35L41 Smart Amplifiers (I2C1: 0x40 Left, 0x41 Right)
              →  Stereo Internal Speakers

Playback / Input (3.5mm Headphone Jack):
  Headphone Out: Realtek ALC245 (Node 0x21 via DAC 0x02)
  Headset Mic  : Realtek ALC245 (Node 0x19, combo jack external mic)

Capture (Internal Digital Microphone Array):
  2-ch PDM Mic Array  →  Intel Alder Lake PCH cAVS 2.5 / Audio DSP (8086:51CC)
                      →  Sound Open Firmware (SOF v2.2 production signed)
                      →  TGLDmic.kext (Kernel DMA & IPC)
                      →  TGLDmic.driver (Core Audio HAL Plug-In)
                      →  macOS CoreAudio: "Internal Microphone (TGLDmic)"
```

Both internal stereo speakers, headphone auto-switching, combo jack microphone, and internal digital microphone array are fully supported and functional on macOS Sequoia 15.8.2.

---

## Architecture & Driver Stack

On this laptop, audio output to physical speaker cones is driven by two smart amplifiers, and internal microphone capture is driven by the Intel cAVS audio DSP. This requires coordinated components:

| Component | Version / Setting | Function |
|---|---|---|
| **`AppleALC.kext`** | 1.9.8 (`alcid=13`) | Routes PCM audio stream through ALC245 Node `0x17` (DAC `0x03`) for speakers, Node `0x21` for headphones, and Node `0x19` for external headset mic. |
| **`CirrusAudioFixup.kext`** | 1.2.1 | Initializes the CS35L41 amplifiers: asserts Intel Alder Lake PCH GPIO hardware reset (pin 305), parses EFI calibration (exact silicon UID match), loads DSP protective firmware (`halo_cspl_RAM_revB2_29.63.1.wmfw`), loads HP Envy tuning coefficients, configures internal boost converter (1000nH / 4100mA / 24µF), and tracks codec power/volume events. |
| **`VoodooI2C.kext`** | 2.9.2 | Core I2C controller driver with Alder Lake-LP (`0x51e88086&0xFFFCFFFF`) personality and `transferI2CToAddress` platform bridge. Bundles `VoodooGPIOTigerLakeLP` (`INTC1055`) to ensure simultaneous operation of both the I2C trackpad (`SYNA32CF`) and I2C audio amplifiers (`SPKR`). |
| **`TGLDmic.kext`** | 0.6.0 (`-tgldmic`) | Boots official Intel-signed Sound Open Firmware (`sof-adl.ri` v2.2 production release) on the Intel Alder Lake PCH cAVS 2.5 DSP (`8086:51CC`). Sets up 2-channel 48 kHz S32_LE DMA capture pipeline (`DMIC0.IN -> EQIIR10.0 -> Dmic0 -> PCM6C`) and exposes ring buffer via IOKit UserClient. Dynamic power gating keeps the DSP off until an application records audio. Source: [lamjiidii1/TGLDmic](https://github.com/lamjiidii1/TGLDmic). |
| **`TGLDmic.driver`** | 0.6.0 (HAL plug-in) | Core Audio AudioServerPlugIn in `/Library/Audio/Plug-Ins/HAL/`. Maps the kernel ring buffer, synchronizes timestamps to the DSP clock, and exposes **"Internal Microphone (TGLDmic)"** with stereo 48 kHz input and software gain control. |
| **`SSDT-HP-MICMUTE.aml`** | 1.0.0 (`_Q28 -> XQ28`) | Hooks EC query method `_Q28` for the F8 function key. Forwards call to `XQ28()` and dispatches scancode `0x036b` (F20) to `PS2K`. |

---

## Layout 13 Routing

We use AppleALC Layout 13 (`alcid=13`):

* **Internal Speakers**: Node `0x17` pincap (`0x0000001c`, non-EAPD), fed by DAC `0x03`. PCM audio is passed to the dual CS35L41 amplifiers over I2C/I2S.
* **Headphone Jack**: Node `0x21` with automatic jack sense. Plugging in headphones smoothly redirects audio from speakers to headphones.
* **External Headset Mic**: Node `0x19` (available when a 3.5mm headset is plugged into the combo jack).

---

## Internal Digital Microphone (TGLDmic)

### Why AppleALC Cannot Detect the Internal Mic
On 10th-gen through 13th-gen Intel laptops, built-in microphones are digital PDM microphone arrays wired directly to the Intel cAVS/DSP rather than analog pins on the Realtek codec. Because AppleALC operates exclusively on HDA codec nodes, macOS shows "No input devices" when headphones are unplugged.

### TGLDmic Solution
`TGLDmic` solves this by booting signed Intel Sound Open Firmware (SOF v2.2) on the cAVS DSP and interfacing with macOS CoreAudio through a lightweight HAL driver.

To install or reinstall the Core Audio HAL plug-in:

```sh
# Run the included installer script
sudo ./scripts/macos/install-tgldmic-hal.sh
```

---

## F5 and F8 Mute Keys & Indicator LEDs

### 1. F5 Speaker Mute & Orange LED
* **Function**: Mutes and unmutes speaker/headphone audio output natively in macOS.
* **Orange LED Hardware Control**: The orange LED embedded in the F5 key is controlled directly through the Realtek ALC245 HDA processing widget:
  * **HDA Node**: `0x20`
  * **Processing Coefficient**: Index `0x0b`, Bit 3 (`0x08`)
  * **Turn ON**: `alc-verb 0x20 0x500 0x0b && alc-verb 0x20 0x400 0x08`
  * **Turn OFF**: `alc-verb 0x20 0x500 0x0b && alc-verb 0x20 0x400 0x00`
  * Requires OpenCore boot argument `alcverbs=1` (enabled by default across all EFI variants). A testing utility is provided in `scripts/macos/test-mute-leds.sh` (`./test-mute-leds.sh spk-on` / `spk-off`).

### 2. F8 Microphone Mute & LED Technical Findings
* **ACPI Event**: Pressing F8 triggers Embedded Controller query `_Q28`.
* **ACPI Patch (`_Q28 -> XQ28`)**: Renames OEM `_Q28` in DSDT.
* **`SSDT-HP-MICMUTE` Implementation**:
  * Calls original `XQ28()` to keep HP WMI firmware state consistent.
  * Dispatches `Notify (PS2K, 0x036b)` to send scancode `0x6b` (mapped to **F20**) to `VoodooPS2Keyboard`.
* **Microphone Mute Status**:
  * Microphone input can be muted or unmuted cleanly in macOS System Settings > Sound > Input (or by lowering input volume).
  * The physical orange LED on F8 is independent of the ALC245 codec (unlike F5) and is routed through the HP Embedded Controller / GPIO. Active experimentation on the F8 LED is parked for future development to preserve stability.

---

## Hardware Calibration

Each HP Envy unit contains factory-measured speaker DC resistance ($R_0$) stored in an EFI NVRAM variable table.
`CirrusAudioFixup` reads the hardware silicon UIDs from the chips and automatically matches them to the EFI calibration records:

* **Left Speaker (`0x40`)**: $R_0 = 10398$
* **Right Speaker (`0x41`)**: $R_0 = 10201$
* **Status**: `APPLIED_FROM_EFI_VARIABLE` (`reason=EXACT_SILICON_UID`)

---

## Verifying Audio, Amplifier & Microphone Health

Run in Terminal:

```sh
# 1. Check amplifier and DSP operational status
ioreg -lw0 -p IOService -r -c CirrusAudioFixup | grep -E "Cirrus_Amplifier_Status|Cirrus_Calibration|Cirrus_DSP|Cirrus_Driver_Verdict"

# 2. Check TGLDmic DSP microphone status
ioreg -lw0 -c TGLDmic | grep -E "TGLDmicPhase|TGLDmicVersion|TGLDmicDSP|Streaming"

# 3. Verify audio input devices in macOS
system_profiler SPAudioDataType | grep -A 10 "Input Source"
```

Expected output:
* `Cirrus_Amplifier_Status = "READY"`
* `Cirrus_DSP_BOOT_VERDICT_i2c0 = "HEALTHY"`
* `Cirrus_DSP_BOOT_VERDICT_i2c1 = "HEALTHY"`
* `Cirrus_Driver_Verdict = "READY_DSP"`
* `TGLDmicPhase = 4` (Service ready)
* `Internal Microphone (TGLDmic)` listed under Input Sources.

---

## Function Key Controls

* **F5**: Speaker Mute / Unmute (with LED)
* **F6**: Speaker Volume Down
* **F7**: Speaker Volume Up
* **F8**: Microphone Key (emits F20; mute/unmute via macOS System Settings)
