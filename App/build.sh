#!/bin/bash
# Builds OS Server: App/build/OS Server.app, the server (in the app's own
# process) with its window and menu bar, the command line (`oss`) and the
# containers' helper (`oss-container`) in Contents/Helpers; all signed with your Apple Development identity (ad hoc
# without one; OSS_SIGN_IDENTITY for another, a Developer ID's for
# notarizing), with App/entitlements.plist (Apple events for UTM,
# Virtualization for its macOS VMs). The version is OSS.version
# (Sources/OSSClient/Models.swift); the build number OSS_APP_BUILD (1).
#
#   App/build.sh                 # build/OS Server.app
#   App/build.sh --zip           # and build/OS-Server.zip (for a VM, or Reviews)
#   App/build.sh --install       # and copy it to /Applications (not opened)
set -euo pipefail
cd "$(dirname "$0")"
APP="build/OS Server.app"
VERSION="$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' ../Sources/OSSClient/Models.swift | head -1)"
BUILD="${OSS_APP_BUILD:-1}"

(cd .. && swift build -c release --product oss)
swift build -c release --product OSSApp
swift build -c release --product OSSContainer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/OSSApp "$APP/Contents/MacOS/OS Server"
cp ../.build/release/oss "$APP/Contents/Helpers/oss"
cp .build/release/OSSContainer "$APP/Contents/Helpers/oss-container"
# The icon: Icon/OSServer.icon (Icon Composer), rendered at each size an
# .icns holds by Xcode's ictool.
ICTOOL="${ICTOOL:-$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool}"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=$([ "$scale" = 2 ] && echo "@2x" || true)
    "$ICTOOL" Icon/OSServer.icon --export-image --output-file "$ICONSET/icon_${points}x${points}${suffix}.png" \
      --platform macOS --rendition Default --width "$points" --height "$points" --scale "$scale" >/dev/null
  done
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" Info.plist > "$APP/Contents/Info.plist"

# OSS_SIGN_IDENTITY names another identity: a Developer ID's signature
# carries a secure timestamp, which notarization requires.
identity="${OSS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -v REVOKED | awk '/"Apple Development: / {print $2; exit}')}"
timestamp=--timestamp=none
case "$identity" in *"Developer ID"*) timestamp=--timestamp ;; esac
sign() {
  if [ -n "$identity" ]; then codesign --force --options runtime "$timestamp" --sign "$identity" "$@"
  else codesign --force --sign - "$@"; fi
}
sign --identifier oss --entitlements entitlements.plist "$APP/Contents/Helpers/oss"
sign --identifier oss-container --entitlements entitlements.plist "$APP/Contents/Helpers/oss-container"
sign --entitlements entitlements.plist "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION, build $BUILD)"

case "${1:-}" in
  --zip)
    ditto -c -k --keepParent "$APP" build/OS-Server.zip
    echo "zipped build/OS-Server.zip" ;;
  --install)
    rm -rf "/Applications/OS Server.app"
    ditto "$APP" "/Applications/OS Server.app"
    echo "installed /Applications/OS Server.app" ;;
esac
