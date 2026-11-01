#!/bin/bash
# A macOS VM leased from OS Server (xcode_27_2: Xcode 27.2 and its iOS
# simulator) for one CI script, which sources this file rather than run it:
# tools/ci/mac_vm_tests.sh (the build and the tests), tools/ci/proof.sh
# (the apps built and pictured) and tools/ci/mac_vm_package.sh (the Mac
# apps CI publishes). The VM is the script's alone: leased for an hour,
# renewed while it runs, released however it ends (a kill nothing can trap
# leaves it an hour at most). The checkout's tree goes in with the runner's
# bazelisk; Bazel there reads OS Server's cache, as every lease's does.
# Copied from the scripts other repositories' CI runs, with oss's steps.
#
#   ROOT=<the checkout>
#   . "$ROOT/tools/ci/mac_vm.sh"
#   mac_vm_start <key comment>  the script's folder, $work, and the trap that
#                               releases the VM and deletes $work however
#                               the script ends (after on_cleanup, if the
#                               script defines one: its other leases)
#   mac_vm_steps << 'EOF'       the script's steps in the VM: arms of a
#       <step>) … ;;            `case` on the step's name, run by /bin/bash
#   EOF                         (3.2) in ~/ci, the tree in oss/, Bazel on
#                               the PATH, the step's arguments in "$@"
#   mac_vm_lease                the VM leased and reached over SSH
#   mac_vm_copy_tree            the tree, Bazel and the steps copied in
#   in_vm <step> [args…]        one of the steps, in the VM
#   vm <command…>               a command in the VM, over SSH
#   run <command…>              a long command, in the background, waited for
#   mac_vm_release              the VM given back now, before the script ends
#
# $OSS is OS Server's command line, $lease the VM's id, $work/key its SSH
# key. A script sets finished=1 before its last exit: macOS's bash (3.2)
# runs the EXIT trap with $? 0 when an unset variable stops the script
# (set -eu), so an end before that is a failure, whatever it says.

OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"

mac_vm_start() {
    me="$(basename "$0")"
    bazelisk="$(command -v bazelisk)" || { echo "$me: no bazelisk on the PATH to copy in" >&2; exit 1; }
    key_comment="${1:?mac_vm_start takes a comment for the SSH key}"
    work="$(mktemp -d)"
    chmod 700 "$work"
    mkdir "$work/vm"
    lease=""
    renewer=""
    child=""
    finished=""
    trap mac_vm_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# The VM given back now, not left to its hour.
mac_vm_release() {
    if [ -n "$renewer" ]; then
        kill "$renewer" 2> /dev/null || true
        wait "$renewer" 2> /dev/null || true
        renewer=""
    fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "$me: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}

mac_vm_cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    # The script's own, first: its other leases, its SSH agent.
    ! type on_cleanup > /dev/null 2>&1 || on_cleanup || true
    mac_vm_release
    rm -rf "$work"
    exit "$status"
}

# Long commands run in the background and are waited for, so a signal (the
# runner cancelling the job) reaches the trap at once, not when they end.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}
vm() { "$OSS" machine ssh "$lease" --identity="$work/key" -- "$@"; }
# ssh hands the VM's shell one line, so each argument is quoted for it.
in_vm() { vm bash ci/in_vm.sh "$(printf '%q ' "$@")"; }

mac_vm_steps() {
    {
        cat << 'EOF'
#!/bin/bash
# In the VM, in ~/ci: the tree in oss/ (App/Package.swift names the package
# above it by its folder's name), Bazel in bin/ (tools/ci/mac_vm.sh).
set -uo pipefail
cd ~/ci
# Homebrew last: the layer's, for what a step installs (QEMU, for OS Server.app).
export PATH="$HOME/ci/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
step="$1"
shift
case "$step" in
    unpack)
        mkdir -p oss bin && tar -xzf tree.tar.gz -C oss && mv bazel bin/bazel && chmod +x bin/bazel || exit
        xcodebuild -version | head -1
        xcrun simctl list runtimes | grep -i '^ios'
        ;;
EOF
        cat
        cat << 'EOF'
    *)
        echo "in_vm.sh: no step $step" >&2
        exit 2
        ;;
esac
EOF
    } > "$work/vm/in_vm.sh"
}

mac_vm_lease() {
    # A key of the run's own for the VM's SSH, gone with the run.
    ssh-keygen -q -t ed25519 -N '' -C "$key_comment" -f "$work/key"
    run "$OSS" machine lease macos --config=xcode_27_2 --minutes=60 --wait --key="$work/key.pub" --exports > "$work/lease"
    lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
    echo "Leased $lease"
    # Renewed every ten minutes; told to stop, it stops its sleep too.
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        while :; do
            sleep 600 &
            wait $!
            "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
        done
    ) &
    renewer=$!
    for _ in $(seq 1 30); do vm true 2> /dev/null && break; sleep 5; done
}

# The checkout's tracked files as they stand, Bazel, and the steps, into
# ~/ci there. As they stand: the committed tree with what the job changed
# since its checkout (the Version step's stamped Info.plists, never
# committed), by `git stash create`, which makes them a commit without
# touching the checkout or its stash (and makes none when nothing
# changed: HEAD's tree then). Untracked files stay behind.
mac_vm_copy_tree() {
    [ -f "$work/vm/in_vm.sh" ] || mac_vm_steps < /dev/null
    local tree
    tree="$(git -C "$ROOT" -c user.name=CI -c user.email=ci@localhost stash create)"
    git -C "$ROOT" archive --format=tar.gz -o "$work/vm/tree.tar.gz" "${tree:-HEAD}"
    cp "$(readlink -f "$bazelisk")" "$work/vm/bazel"
    run "$OSS" machine upload "$lease" --identity="$work/key" "$work/vm" ci
    run in_vm unpack
}
