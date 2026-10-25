#!/bin/bash
# Builds the oss app: App/build/oss.app, the window and menu bar app with
# the server's binary (the same `oss` as the command line) in
# Contents/Helpers, signed with your Apple Development identity (ad hoc
# without one).
#
#   App/build.sh                 # build/oss.app
#   App/build.sh --zip           # and build/oss.zip (for a VM, or Reviews)
#   App/build.sh --install       # and copy it to /Applications (not opened)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/oss.app
VERSION="$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' ../Sources/OSSClient/Models.swift | head -1)"
BUILD="${OSS_APP_BUILD:-1}"

(cd .. && swift build -c release --product oss)
swift build -c release --product OSSApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/OSSApp "$APP/Contents/MacOS/oss"
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
sign --identifier oss "$APP/Contents/Helpers/oss"
sign --entitlements entitlements.plist "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION, build $BUILD)"

case "${1:-}" in
  --zip)
    ditto -c -k --keepParent "$APP" build/oss.zip
    echo "zipped build/oss.zip" ;;
  --install)
    rm -rf /Applications/oss.app
    ditto "$APP" /Applications/oss.app
    echo "installed /Applications/oss.app" ;;
esac
