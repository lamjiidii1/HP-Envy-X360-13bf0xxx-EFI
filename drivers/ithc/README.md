# ITHC.kext

A macOS driver for the Intel Touch Host Controller (THC) in legacy mode, ported
from the Linux [ithc](https://github.com/quo/ithc-linux) driver. It brings up the
THC and its SPI touch IC and receives HID reports over DMA.

It publishes the touchscreen's HID device, which VoodooI2CHID's touchscreen and
stylus event drivers attach to (multi-touch, gestures, pen). The descriptor's
keyboard collection is published as Undefined so macOS doesn't open Keyboard
Setup Assistant.

Tested target: HP Envy x360 13-bf (Alder Lake-U, THC 8086:51d0, ELAN 04F3:2FCE).

> [!WARNING]
> Work in progress. AI was used to write this driver.

## Build

To rebuild the exact kext in this repo's EFI (byte-identical with Apple clang
21.0.0 from Command Line Tools 26.6):

```bash
zsh ithc/build-ithc.sh ~/ithc-build
```

Or build it directly with [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK)
(by default at `MacKernelSDK/` in this folder):

```bash
python3 tools/build.py --sdk /path/to/MacKernelSDK
```

The kext is written to `build/ITHC.kext`. Add it to OpenCore's `Kernel > Add`
after VoodooI2C and VoodooI2CHID.

## Boot arguments

- `-ithcpoll`: poll the THC every 10 to 50 ms instead of using its MSI interrupt.

## Diagnostics

`ioreg -l -w0 -r -c ITHC | grep ITHCState` gives the touch IC's config words, then
counters (interrupts, RX messages, input reports, feature replies, descriptor
replies, reset requests, errors, malformed messages), the last error, the failed
start step, RX/TX sizes, vendor/product ID, RX count, polling flag, report
descriptor size and the Contact Count Maximum feature (report ID, value).
