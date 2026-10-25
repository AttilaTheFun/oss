#!/bin/bash
# Builds OS Server: App/build/OS Server.app, the server (in the app's own
# process) with its window and menu bar, and the command line (`oss`) in
# Contents/Helpers; both signed with your Apple Development identity (ad hoc
# without one), with Virtualization's entitlement (they run macOS VMs).
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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/OSSApp "$APP/Contents/MacOS/OS Server"
cp ../.build/release/oss "$APP/Contents/Helpers/oss"
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

identity="${OSS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -v REVOKED | awk '/"Apple Development: / {print $2; exit}')}"
sign() {
  if [ -n "$identity" ]; then codesign --force --options runtime --timestamp=none --sign "$identity" "$@"
  else codesign --force --sign - "$@"; fi
}
sign --identifier oss --entitlements entitlements.plist "$APP/Contents/Helpers/oss"
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
