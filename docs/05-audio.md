# 05 — Audio

## Hardware chain

```
ALC245 codec  →  Intel Smart Sound Technology controller (8086:51CC)
              →  headphone jack (Node 0x21) / internal microphone (Node 0x19)
              →  2x Cirrus Logic CS35L41 smart amplifiers (I2C1: 0x40 Left, 0x41 Right)
              →  stereo internal speakers (Node 0x17 via DAC 0x03)
```

Both internal stereo speakers, headphone output, and internal microphone are fully supported and functional on macOS Sequoia 15.8.2.

---

## Architecture & Driver Stack

On this laptop, audio output to the physical speaker cones is driven by two smart amplifiers rather than the Realtek codec's analog stage. This requires three coordinated components:

| Component | Version / Setting | Function |
|---|---|---|
| **`AppleALC.kext`** | 1.9.8 (`alcid=13`) | Routes PCM audio stream through ALC245 Node `0x17` (DAC `0x03`) for speakers, Node `0x21` for headphones, and Node `0x19` for the microphone. |
| **`CirrusAudioFixup.kext`** | 1.2.1 | Initializes the CS35L41 amplifiers: asserts Intel Alder Lake PCH GPIO hardware reset (pin 305), parses EFI calibration (exact silicon UID match), loads DSP protective firmware (`halo_cspl_RAM_revB2_29.63.1.wmfw`), loads HP Envy tuning coefficients, configures internal boost converter (1000nH / 4100mA / 24µF), and tracks codec power/volume events. |
| **`VoodooI2C.kext`** | 2.9.2 | Core I2C controller driver with Alder Lake-LP (`0x51e88086&0xFFFCFFFF`) personality and `transferI2CToAddress` platform bridge. Bundles `VoodooGPIOTigerLakeLP` (`INTC1055`) to ensure simultaneous, glitch-free operation of both the I2C trackpad (`SYNA32CF`) and the I2C audio amplifiers (`SPKR`). |

---

## Layout 13 Routing

We use AppleALC Layout 13 (`alcid=13`):

* **Internal Speakers**: Node `0x17` pincap (`0x0000001c`, non-EAPD), fed by DAC `0x03`. PCM audio is passed to the dual CS35L41 amplifiers over I2C/I2S.
* **Headphone Jack**: Node `0x21` with automatic jack sense. Plugging in headphones smoothly redirects audio from speakers to headphones.
* **Internal Microphone**: Node `0x19`.

---

## Hardware Calibration

Each HP Envy unit contains factory-measured speaker DC resistance ($R_0$) stored in an EFI NVRAM variable table.
`CirrusAudioFixup` reads the hardware silicon UIDs from the chips and automatically matches them to the EFI calibration records:

* **Left Speaker (`0x40`)**: $R_0 = 10398$
* **Right Speaker (`0x41`)**: $R_0 = 10201$
* **Status**: `APPLIED_FROM_EFI_VARIABLE` (`reason=EXACT_SILICON_UID`)

Because factory calibration is applied directly from the system EFI variable, manual boot-argument calibration overrides are not required.

---

## Verifying Audio & Amplifier Health

Run in Terminal:

```sh
# Verify sound devices recognized by macOS
system_profiler SPAudioDataType

# Check amplifier and DSP operational status
ioreg -lw0 -p IOService -r -c CirrusAudioFixup | grep -E "Cirrus_Amplifier_Status|Cirrus_Calibration|Cirrus_DSP|Cirrus_Driver_Verdict"
```

Expected output:
* `Cirrus_Amplifier_Status = "READY"`
* `Cirrus_DSP_BOOT_VERDICT_i2c0 = "HEALTHY"`
* `Cirrus_DSP_BOOT_VERDICT_i2c1 = "HEALTHY"`
* `Cirrus_Driver_Verdict = "READY_DSP"`
* `Cirrus_Calibration_Status_i2c0 = "APPLIED_FROM_EFI_VARIABLE"`
* `Cirrus_Calibration_Status_i2c1 = "APPLIED_FROM_EFI_VARIABLE"`

---

## Controls

* **F5**: Mute / Unmute
* **F6**: Volume Down
* **F7**: Volume Up
* **Menu Bar**: Native macOS volume slider responds smoothly.
