#!/bin/bash
# The Mac apps CI publishes, built in a macOS VM leased from OS Server
# (tools/ci/mac_vm.sh), unsigned for Applications Server to sign:
#   OS-Server.zip   OS Server.app (App/build.sh --zip, ad hoc signed in the
#                   VM, its nested code each with its own entitlements:
#                   oss and oss-machine Virtualization's, QEMU the
#                   hypervisor's), its QEMU Homebrew's, installed first
#   OS-Monitor.zip  OS Monitor for the Mac (bazel build
#                   //Monitor:os_monitor_macos), its Icon Composer icon
#                   checked for the dark appearance, as every published Mac
#                   app's is (OS Server's icon is an .icns, rendered flat by
#                   App/build.sh, so it isn't)
#
#   tools/ci/mac_vm_package.sh <dir> [<build number>]
#
# The checkout's tree as it stands goes in; the apps come back into <dir>,
# emptied first. OS Server's version is OSS.version
# (Sources/OSSClient/Models.swift), its build number <build number> (1); OS
# Monitor's are its Info.mac.plist's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"

[ $# -ge 1 ] || { echo "usage: tools/ci/mac_vm_package.sh <dir> [<build number>]" >&2; exit 2; }
out="$1"
build="${2:-1}"
case "$build" in "" | *[!0-9]*) echo "mac_vm_package.sh: the build number is a number" >&2; exit 2 ;; esac
mac_vm_start oss-ci

mac_vm_steps << 'STEPS'
    package)
        cd oss || exit
        command -v qemu-system-aarch64 > /dev/null || brew install --quiet qemu > ~/ci/brew.log 2>&1 || { tail -30 ~/ci/brew.log; exit 1; }
        OSS_APP_BUILD="$1" App/build.sh --zip > ~/ci/app.log 2>&1 || { tail -60 ~/ci/app.log; exit 1; }
        tail -1 ~/ci/app.log
        rm -rf ~/ci/packages && mkdir ~/ci/packages && cp App/build/OS-Server.zip ~/ci/packages/ || exit
        bazel build //Monitor:os_monitor_macos || exit
        cp "$(bazel cquery --output=files //Monitor:os_monitor_macos 2> /dev/null)" ~/ci/packages/OS-Monitor.zip || exit
        ls -l ~/ci/packages
        ;;
    icons)
        # OS Monitor's Assets.car: its renditions in the dark appearance,
        # counted. A flat icon has none.
        rm -rf ~/ci/unzipped && mkdir ~/ci/unzipped && ditto -x -k ~/ci/packages/OS-Monitor.zip ~/ci/unzipped || exit
        car=~/ci/unzipped/'OS Monitor.app'/Contents/Resources/Assets.car
        [ -f "$car" ] || { echo "::error::OS Monitor has no Assets.car: no icon compiled by actool"; exit 1; }
        dark="$(xcrun --sdk macosx assetutil --info "$car" | grep -c NSAppearanceNameDarkAqua)" || true
        [ "${dark:-0}" -gt 0 ] || { echo "::error::OS Monitor's icon has no dark appearance (no NSAppearanceNameDarkAqua)"; exit 1; }
        echo "OS Monitor: $dark renditions in the dark appearance"
        # What OS Server.app's nested code was signed with, as it goes to be signed again.
        rm -rf ~/ci/unzipped && mkdir ~/ci/unzipped && ditto -x -k ~/ci/packages/OS-Server.zip ~/ci/unzipped || exit
        cd ~/ci/unzipped/'OS Server.app'/Contents || exit
        for code in MacOS/'OS Server' Helpers/oss Helpers/oss-machine Helpers/qemu/bin/qemu-system-aarch64 Helpers/axe/axe; do
            echo "$code: $(codesign -d --entitlements - --xml "$code" 2> /dev/null | grep -o 'com\.apple\.security\.[a-z.-]*' | tr '\n' ' ')"
        done
        rm -rf ~/ci/unzipped
        ;;
STEPS

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

echo "::group::OS Server.app (build $build) and OS Monitor"
run in_vm package "$build" || { echo "::error::OS Server.app and OS Monitor didn't build in the VM"; exit 1; }
echo "::endgroup::"

echo "::group::OS Monitor's icon, in the dark appearance; OS Server's entitlements"
run in_vm icons || { echo "::error::OS Monitor's icon has no dark appearance"; exit 1; }
echo "::endgroup::"

# scp makes the folder (one already here would get it inside).
run "$OSS" machine download "$lease" --identity="$work/key" ci/packages "$work/packages"
mac_vm_release
mkdir -p "$out"
rm -f "$out"/*
cp "$work/packages"/* "$out"/
ls -l "$out"
finished=1
