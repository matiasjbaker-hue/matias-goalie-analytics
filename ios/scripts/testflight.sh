#!/bin/zsh
# Archives NETRIX and uploads it to App Store Connect for TestFlight.
# Needs: Xcode signed in to the Apple ID on team 7SACARPT7P (Xcode > Settings > Accounts),
# and an app record for bundle ID com.alkhaldi.netrix in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE=build/NETRIX.xcarchive
rm -rf "$ARCHIVE" build/export
echo "Archiving build $BUILD_NUMBER..."
xcodebuild -project NETRIX.xcodeproj -scheme NETRIX -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive | tail -3
echo "Uploading to App Store Connect..."
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates | tail -5
echo "Done. Build $BUILD_NUMBER appears in TestFlight after Apple finishes processing (usually 5-30 min)."
