#!/bin/bash
# Builds OS Server: App/build/OS Server.app, the server (in the app's own
# process) with its window and menu bar, the command line (`oss`), the
# machines' helper (`oss-machine`: a container or a macOS VM each), AXe and
# QEMU in Contents/Helpers, the provisioning scripts in Contents/Resources;
# all signed with your Apple Development identity (ad hoc without one;
# OSS_SIGN_IDENTITY for another, a Developer ID's for notarizing), with
# App/entitlements.plist (Apple events for UTM, Virtualization for its
# macOS VMs and containers). The version is OSS.version
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
swift build -c release --product OSSMachine

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/OSSApp "$APP/Contents/MacOS/OS Server"
cp ../.build/release/oss "$APP/Contents/Helpers/oss"
cp .build/release/OSSMachine "$APP/Contents/Helpers/oss-machine"
# The layers' provisioning scripts, and AXe (simulator input; MIT), pinned
# and checked: OS Server needs neither this checkout nor Homebrew.
cp -R ../provision "$APP/Contents/Resources/provision"
AXE_VERSION=1.8.0
AXE_SHA256=7b76340b72e90d0f211bc7c4636f15009076eff07acef2f2b632b175debd8834
AXE_ARCHIVE="build/cache/AXe-macOS-v$AXE_VERSION-universal.tar.gz"
if [ ! -f "$AXE_ARCHIVE" ] || ! echo "$AXE_SHA256  $AXE_ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  mkdir -p build/cache
  curl -sSfL "https://github.com/cameroncooke/AXe/releases/download/v$AXE_VERSION/AXe-macOS-v$AXE_VERSION-universal.tar.gz" -o "$AXE_ARCHIVE"
  echo "$AXE_SHA256  $AXE_ARCHIVE" | shasum -a 256 -c - >/dev/null
fi
# QEMU for the Linux and Windows VMs: Homebrew's, with every library it
# loads, made to stand alone (tools/bundle_qemu.py); kept between builds
# while Homebrew's is the same version.
QEMU_CACHE="build/cache/qemu-$(/opt/homebrew/bin/qemu-system-aarch64 --version | head -1 | awk '{print $4}')"
[ -x "$QEMU_CACHE/bin/qemu-system-aarch64" ] || python3 ../tools/bundle_qemu.py "$QEMU_CACHE"
mkdir -p "$APP/Contents/Helpers/qemu" "$APP/Contents/Resources/qemu"
cp -R "$QEMU_CACHE/bin" "$QEMU_CACHE/lib" "$APP/Contents/Helpers/qemu/"
cp -R "$QEMU_CACHE/share/" "$APP/Contents/Resources/qemu/"   # its firmware, ROMs and keymaps
cp "$QEMU_CACHE/SOURCES.txt" "$APP/Contents/Resources/qemu/"  # what was bundled, for its sources
mkdir -p "$APP/Contents/Helpers/axe"
tar -xzf "$AXE_ARCHIVE" -C "$APP/Contents/Helpers/axe" --exclude "./AXe_AXe.bundle*"  # its agent skill, not code
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
sign --identifier oss-machine --entitlements entitlements.plist "$APP/Contents/Helpers/oss-machine"
for framework in "$APP/Contents/Helpers/axe/Frameworks/"*.framework; do sign "$framework"; done
for library in "$APP/Contents/Helpers/qemu/lib/"*; do sign "$library"; done
sign --identifier qemu-img "$APP/Contents/Helpers/qemu/bin/qemu-img"
sign --identifier qemu-system-aarch64 --entitlements qemu.entitlements "$APP/Contents/Helpers/qemu/bin/qemu-system-aarch64"
sign --identifier axe "$APP/Contents/Helpers/axe/axe"
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
