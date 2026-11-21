#!/usr/bin/env bash
set -euo pipefail

echo "Disk space before cleanup:"
df -h /

# Remove large GitHub-hosted tools that are not used by this Android APK build.
sudo rm -rf \
  /usr/share/dotnet \
  /opt/ghc \
  /usr/local/share/boost \
  /usr/local/share/powershell

SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$SDK_ROOT" ] || [ ! -d "$SDK_ROOT" ]; then
  echo "ERROR: Android SDK root is not available for safe cleanup."
  exit 1
fi

# Emulator binaries and system images are not required to compile an APK.
sudo rm -rf "$SDK_ROOT/system-images" "$SDK_ROOT/emulator"

echo "Disk space after cleanup:"
df -h /
