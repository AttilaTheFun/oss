#!/bin/bash
# OS Server's build and tests, on a slot of OS Server's primary macOS VM
# (xcode_27_2: Xcode 27.2 and its iOS simulator; `mac` leases, API 18), or
# with MAC_CI=vm in a macOS VM of the run's own as before:
#   - swift build and swift test of the package, one test at a time (the
#     forwarder's tests time real sockets); in a VM with OSS_TEST_SIMCTL=1:
#     the VM's simulators are the run's own, so real ones of an iPad and an
#     iPhone are made and deleted (Tests/OSSServerTests/SimulatorTypeTests.swift),
#     which a slot's user, with no login session, can't;
#   - the App package's build (OS Server.app's sources: swift build in App/);
#   - in a VM only: the containers' network made, attached to and given
#     back for real (`oss-machine network-check`: vmnet runs in a VM of the
#     run's own; a slot's user is no administrator, and the primary's
#     network is everyone's);
#   - OS Monitor's Bazel build, for the Mac and for the iPhone's simulator.
#
#   tools/ci/mac_vm_tests.sh
#
# The VM (tools/ci/mac_vm.sh) is the script's alone, released however it
# ends. The script fails as the first of them that fails, after all ran.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"
mac_vm_start oss-ci

mac_vm_steps << 'STEPS'
    package)
        cd oss && swift build --build-tests && OSS_TEST_SIMCTL="${1:-0}" swift test --skip-build --no-parallel
        ;;
    app)
        cd oss/App && swift build
        ;;
    network)
        cd oss/App && codesign --force --sign - --entitlements entitlements.plist .build/debug/OSSMachine \
            && .build/debug/OSSMachine network-check
        ;;
    monitor)
        cd oss && bazel build //Monitor:os_monitor_macos && bazel build --ios_multi_cpus=sim_arm64 //Monitor:os_monitor_ios
        ;;
STEPS

on_vm=""
[ "${MAC_CI:-slot}" != vm ] || on_vm=1
if [ -n "$on_vm" ]; then
    echo "::group::A macOS VM (xcode_27_2)"
    mac_vm_lease
else
    echo "::group::A slot of the primary macOS VM"
    mac_slot_lease
fi
mac_vm_copy_tree
echo "::endgroup::"

status=0
steps="package app monitor"
[ -z "$on_vm" ] || steps="package app network monitor"
for step in $steps; do
    case "$step" in
        package) title="swift build, swift test" ;;
        app) title="App: swift build" ;;
        network) title="The containers' network for real: oss-machine network-check (vmnet)" ;;
        monitor) title="OS Monitor: bazel build, Mac and iPhone simulator" ;;
    esac
    echo "::group::$title"
    step_status=0
    if [ "$step" = package ] && [ -n "$on_vm" ]; then run in_vm package 1 || step_status=$?; else run in_vm "$step" || step_status=$?; fi
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::$title failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
mac_vm_release
finished=1
exit "$status"
