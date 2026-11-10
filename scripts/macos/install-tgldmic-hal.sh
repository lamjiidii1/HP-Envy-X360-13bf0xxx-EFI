#!/usr/bin/env bash
# Install the TGLDmic Core Audio HAL plug-in into /Library/Audio/Plug-Ins/HAL/
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_SRC="${DIR}/TGLDmic.driver"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET="${TARGET_DIR}/TGLDmic.driver"

if [ ! -d "${DRIVER_SRC}" ]; then
  echo "error: ${DRIVER_SRC} not found" >&2
  exit 1
fi

echo "Installing TGLDmic Core Audio HAL driver..."
sudo mkdir -p "${TARGET_DIR}"
sudo rm -rf "${TARGET}"
sudo cp -R "${DRIVER_SRC}" "${TARGET}"
sudo chown -R root:wheel "${TARGET}"
sudo chmod -R 755 "${TARGET}"
sudo xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true

echo "Restarting coreaudiod daemon..."
sudo killall coreaudiod 2>/dev/null || sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || true

echo "Done! 'Internal Microphone (TGLDmic)' is now available in System Settings > Sound > Input."
