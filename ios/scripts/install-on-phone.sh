#!/bin/zsh
# Builds NETRIX and installs it on the iPhone plugged into this Mac.
# Works even when Xcode is too old to "Run" on the phone's iOS version
# (Xcode then calls the phone a "build-only device").
# Needs: Xcode signed in (Settings > Accounts), iPhone unlocked with Developer Mode on.
set -euo pipefail
cd "$(dirname "$0")/.."

# Two builds at once corrupt Xcode's build database ("disk I/O error"), so allow one at a time.
LOCK=/tmp/netrix-build.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another NETRIX build is already running. Wait for it to finish, then try again."
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /iPhone/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-/) {print $i; exit}}')
if [[ -z "$DEVICE" ]]; then
  echo "No iPhone connected. Plug it in, unlock it, and try again."
  exit 1
fi

echo "Building NETRIX..."
xcodebuild -project NETRIX.xcodeproj -scheme NETRIX -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build -quiet

echo "Installing on your iPhone..."
xcrun devicectl device install app --device "$DEVICE" build/DerivedData/Build/Products/Debug-iphoneos/NETRIX.app > /dev/null
xcrun devicectl device process launch --device "$DEVICE" com.alkhaldi.netrix > /dev/null 2>&1 || true
echo "Done. NETRIX is updated on your iPhone."
