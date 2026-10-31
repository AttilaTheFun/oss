#!/bin/bash
# OS Server's build and tests, in a macOS VM leased from OS Server itself
# (xcode-27.0: Xcode 27.0 and its iOS simulator):
#   - swift build and swift test of the package, one test at a time (the
#     forwarder's tests time real sockets), with OSS_TEST_SIMCTL=1: the VM's
#     simulators are the run's own, so real ones of an iPad and an iPhone
#     are made and deleted (Tests/OSSServerTests/SimulatorTypeTests.swift);
#   - the App package's build (OS Server.app's sources: swift build in App/);
#   - the containers' network made, attached to and given back for real
#     (`oss-machine network-check`: vmnet runs in the VM, though a
#     container's VM, with no nested virtualization, wouldn't);
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
        cd oss && swift build --build-tests && OSS_TEST_SIMCTL=1 swift test --skip-build --no-parallel
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

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

status=0
for step in package app network monitor; do
    case "$step" in
        package) title="swift build, swift test (OSS_TEST_SIMCTL=1)" ;;
        app) title="App: swift build" ;;
        network) title="The containers' network for real: oss-machine network-check (vmnet)" ;;
        monitor) title="OS Monitor: bazel build, Mac and iPhone simulator" ;;
    esac
    echo "::group::$title"
    step_status=0
    run in_vm "$step" || step_status=$?
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::$title failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
mac_vm_release
finished=1
exit "$status"
