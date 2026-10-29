#!/bin/bash
# OS Server's proof, from CI: its apps built in a macOS VM leased from OS
# Server itself (xcode-27.0), pictured with their canned servers, and each
# picture compared with the one kept for it (Tests/Proof).
#
#   tools/ci/proof.sh --proof <dir> [--kind quick|full]
#
# What is pictured, light and dark:
#   server-*          OS Server.app (tools/proof.py, run here against the
#                     VM): its window, its menu bar's panel, its first
#                     launch's Set Up window and its menu bar item; full
#                     adds a Linux and a Windows VM's Screen window, real
#                     guests leased for it, their clocks held at 09:41
#   monitor-mac-*     OS Monitor's Mac window, in the same VM, cut from the
#                     screen by its frame (tools/window_rect.swift there,
#                     tools/ci/window_shot.swift here)
#   monitor-ios-*     OS Monitor on an iPhone simulator leased from OS
#                     Server (its status bar held still by the server): the
#                     servers, a server, its disk and its end
#
# The proof, in <dir>, as Reviews reads it from the run's `proof` artifact:
#   screens/<name>.png  every picture at this commit
#   diffs/<name>.png    each that differs from its kept picture
#                       (Tests/Proof/<name>.png), its changed pixels red
#                       (tools/ci/snapshot_diff.swift, built here)
#   proof.json          {"commit", "ref", "kind", "run",
#                        "screens": [{"name", "changed", "changedPixels"}]}
# The script fails when the apps don't build or a picture doesn't come
# back; pictures that differ are for review, not failures.
#
#   PROOF_REF     the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON  the python3 that runs tools/proof.py, with Pillow (default:
#                 the PATH's)
#
# From a CI runner's own user: no sudo here (only in the leases, as their
# runner), and no SSH key of its own. Every lease is made with the run's
# key, which an ssh-agent of the run's holds, so tools/proof.py's plain
# `oss machine ssh` reaches them too; its macOS VM is the one leased here
# (--held: its own lease would not wait for a free VM), and its app the
# one built here (--no-build). It needs Pillow in the runner's python3.
# Every lease is released however the script ends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"

usage() { echo "usage: tools/ci/proof.sh --proof <dir> [--kind quick|full]" >&2; exit 2; }
proof=""
kind="quick"
while [ $# -gt 0 ]; do
    case "$1" in
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$proof" ] || usage
case "$kind" in quick | full) ;; *) usage ;; esac

commit="$(git -C "$ROOT" rev-parse HEAD)"
# tools/proof.py's interpreter: one with Pillow.
python="${PROOF_PYTHON:-$(command -v python3)}"
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git -C "$ROOT" branch --show-current)}}"
mac_vm_start oss-ci

# The other leases (the simulator, full's guests) and the run's ssh-agent,
# given back before the VM.
others=""
leasing=""
on_cleanup() {
    for pid in $leasing; do kill "$pid" 2> /dev/null || true; done
    for exports in $others; do
        local id
        id="$(. "$exports" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
        [ -z "$id" ] || "$OSS" machine release "$id" > /dev/null || echo "proof.sh: lease $id was not released: oss machine release $id" >&2
    done
    others=""
    # One asked for as the script was stopped, whose id never came: this
    # job's by its label (a CI job's lease is labelled with its run and job).
    if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_JOB:-}" ]; then
        "$OSS" machine list 2> /dev/null | grep -F " #$GITHUB_RUN_ID · $GITHUB_JOB" | awk '{ print $1 }' | while read -r id; do
            [ "$id" = "$lease" ] || "$OSS" machine release "$id" > /dev/null 2>&1 || true
        done
    fi
    [ -z "${SSH_AGENT_PID:-}" ] || kill "$SSH_AGENT_PID" 2> /dev/null || true
}
# A lease of another platform, its exports in $work/lease-<platform>.
lease_other() {
    "$OSS" machine lease "$1" --minutes=60 --wait --key="$work/key.pub" --exports > "$work/lease-$1"
}
others="$work/lease-linux $work/lease-windows $work/lease-ios"

# The tools first, nothing leased if one doesn't build: the diff and the
# window cutter here, the window's frame in the VM.
xcrun swiftc -O -o "$work/snapshot_diff" "$ROOT/tools/ci/snapshot_diff.swift"
xcrun swiftc -O -o "$work/window_shot" "$ROOT/tools/ci/window_shot.swift"
xcrun swiftc -O -target arm64-apple-macos14 -o "$work/vm/window_rect" "$ROOT/tools/window_rect.swift"

mac_vm_steps << 'STEPS'
    package)
        # OS Server.app (QEMU first: Homebrew's, which App/build.sh bundles)
        # and OS Monitor, for the Mac and the simulator, into ~/ci/out.
        cd oss || exit
        command -v qemu-system-aarch64 > /dev/null || brew install --quiet qemu > ~/ci/brew.log 2>&1 || { tail -30 ~/ci/brew.log; exit 1; }
        App/build.sh --zip > ~/ci/app.log 2>&1 || { tail -60 ~/ci/app.log; exit 1; }
        tail -1 ~/ci/app.log
        rm -rf ~/ci/out && mkdir ~/ci/out && cp App/build/OS-Server.zip ~/ci/out/ || exit
        bazel build //Monitor:os_monitor_macos || exit
        cp "$(bazel cquery --output=files //Monitor:os_monitor_macos 2> /dev/null)" ~/ci/out/OS-Monitor.zip || exit
        bazel build --ios_multi_cpus=sim_arm64 //Monitor:os_monitor_ios || exit
        cp "$(bazel cquery --ios_multi_cpus=sim_arm64 --output=files //Monitor:os_monitor_ios 2> /dev/null)" ~/ci/out/OS-Monitor.ipa || exit
        ls -l ~/ci/out
        ;;
    monitor)
        # OS Monitor in place of OS Server, opened with its canned servers in
        # the session's desktop, light or dark ("$1"), and its window's frame.
        pkill -x 'OS Server'
        pkill -x 'OS Monitor'
        defaults delete com.LoganShire.OSMonitor.Mac > /dev/null 2>&1
        # Scroll bars as overlays, shown only while scrolling (as proof.py sets them).
        defaults write -g AppleShowScrollBars -string WhenScrolling
        rm -rf ~/Library/'Saved Application State'/com.LoganShire.OSMonitor.Mac.savedState
        if [ ! -d ~/Applications/'OS Monitor.app' ]; then
            mkdir -p ~/Applications && ditto -x -k ~/ci/out/OS-Monitor.zip ~/Applications || exit
        fi
        sleep 1
        sudo launchctl asuser "$(id -u)" open -n ~/Applications/'OS Monitor.app' --args \
            -fixture YES -fixture.open YES -appearance "$1" -ApplePersistenceIgnoreState YES || exit
        sleep 8
        ;;
    frame)
        sudo launchctl asuser "$(id -u)" ~/ci/window_rect 'OS Monitor'
        ;;
STEPS

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
# The run's key in an agent of its own, for what tools/proof.py runs.
eval "$(ssh-agent -s)" > /dev/null
ssh-add -q "$work/key"
# Full: a Linux and a Windows VM for the Screen windows, leased meanwhile.
if [ "$kind" = full ]; then
    for platform in linux windows; do
        # oss itself in the background (no shell between), so the cleanup's kill reaches it.
        "$OSS" machine lease "$platform" --minutes=60 --wait --key="$work/key.pub" --exports > "$work/lease-$platform" &
        leasing="$leasing $!"
    done
fi
mac_vm_copy_tree
echo "::endgroup::"

status=0
echo "::group::OS Server.app and OS Monitor, built in the VM"
run in_vm package || { echo "::error::OS Server.app and OS Monitor didn't build in the VM"; exit 1; }
run "$OSS" machine download "$lease" --identity="$work/key" ci/out "$work/out"
mkdir -p "$ROOT/App/build"
cp "$work/out/OS-Server.zip" "$ROOT/App/build/OS-Server.zip"
echo "::endgroup::"

recorded="$work/recorded"
mkdir -p "$recorded"

echo "::group::OS Server.app (tools/proof.py)"
guests=()
for pid in $leasing; do wait "$pid" || { echo "::error::a guest VM wasn't leased"; status=1; }; done
leasing=""
if [ "$kind" = full ]; then
    for platform in linux windows; do
        [ -s "$work/lease-$platform" ] && guests+=(--guest "$platform=$work/lease-$platform")
    done
fi
run "$python" "$ROOT/tools/proof.py" --review "$work/review" --no-build --held "$work/lease" --commit "$commit" \
    ${guests[@]+"${guests[@]}"} || { echo "::error::tools/proof.py failed"; status=1; }
for picture in "$work/review/review-macos"/*.png; do
    [ -e "$picture" ] && cp "$picture" "$recorded/server-$(basename "$picture")"
done
echo "::endgroup::"

echo "::group::OS Monitor for the Mac"
for appearance in light dark; do
    if run in_vm monitor "$appearance" \
        && run "$OSS" machine screenshot "$lease" "$work/monitor-$appearance-screen.png" > /dev/null \
        && frame="$(in_vm frame)" && [ "$(echo "$frame" | wc -w)" -eq 4 ]; then
        # shellcheck disable=SC2086
        "$work/window_shot" "$work/monitor-$appearance-screen.png" $frame "$recorded/monitor-mac-window-$appearance.png"
    else
        echo "::error::OS Monitor's Mac window ($appearance) wasn't pictured"
        status=1
    fi
done
echo "::endgroup::"
mac_vm_release

echo "::group::OS Monitor on an iPhone simulator"
rm -rf "$work/ipa" && mkdir "$work/ipa" && ditto -x -k "$work/out/OS-Monitor.ipa" "$work/ipa"
if lease_other ios; then
    ios="$(. "$work/lease-ios"; printf '%s' "$OSS_ID")"
    "$OSS" machine simctl "$ios" install "$work/ipa/Payload/OS Monitor.app"
    for appearance in light dark; do
        # name, launch arguments, swipes down the dashboard (its disk card is scrolled to by the app)
        for screen in "servers::0" "server:-fixture.open YES:0" "server-disk:-fixture.open YES -fixture.scroll disk:0" \
                      "server-end:-fixture.open YES:6"; do
            name="${screen%%:*}"
            rest="${screen#*:}"
            arguments="${rest%:*}"
            swipes="${rest##*:}"
            "$OSS" machine simctl "$ios" terminate com.LoganShire.OSMonitor > /dev/null 2>&1 || true
            # shellcheck disable=SC2086
            "$OSS" machine simctl "$ios" launch com.LoganShire.OSMonitor -fixture YES -appearance "$appearance" $arguments > /dev/null
            sleep 4
            for _ in $(seq 1 "$swipes"); do
                # Once more after a pause: the server lending the simulator may be older
                # than this tree's, which retries AXe itself (Input.swift).
                "$OSS" machine swipe "$ios" 600 2000 600 900 --ms=300 \
                    || { sleep 5; "$OSS" machine swipe "$ios" 600 2000 600 900 --ms=300; }
                sleep 1
            done
            [ "$swipes" -eq 0 ] || sleep 1.5
            "$OSS" machine screenshot "$ios" "$recorded/monitor-ios-$name-$appearance.png" > /dev/null \
                || { echo "::error::OS Monitor's $name ($appearance) wasn't pictured"; status=1; }
        done
    done
else
    echo "::error::no iPhone simulator was leased"
    status=1
fi
on_cleanup
echo "::endgroup::"

# The proof, from the pictures and the kept ones of the same commit.
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
mkdir -p "$proof/screens" "$proof/diffs"
screens=""
summary=""
count=0
for picture in "$recorded"/*.png; do
    [ -e "$picture" ] || continue
    name="$(basename "$picture" .png)"
    cp "$picture" "$proof/screens/$name.png"
    pixels="$("$work/snapshot_diff" "$ROOT/Tests/Proof/$name.png" "$picture" "$proof/diffs/$name.png")"
    changed=false
    [ "$pixels" -eq 0 ] || changed=true
    count=$((count + 1))
    screens="$screens${screens:+,}
    {\"name\": \"$(json "$name")\", \"changed\": $changed, \"changedPixels\": $pixels}"
    summary="$summary| $name | $([ "$changed" = true ] && echo "$pixels pixels changed" || echo unchanged) |
"
done
cat > "$proof/proof.json" << EOF
{
  "commit": "$commit",
  "ref": "$(json "$ref")",
  "kind": "$kind",
  "run": ${GITHUB_RUN_ID:-null},
  "screens": [$screens
  ]
}
EOF
cat "$proof/proof.json"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Proof (%s) of %s\n\n| Screen | Against its kept picture |\n| --- | --- |\n%s' "$kind" "${commit:0:7}" "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

# Every picture: OS Server's 8 (12 with the guests'), OS Monitor's 2 on the Mac and 8 on the iPhone.
expected=18
[ "$kind" = quick ] || expected=22
if [ "$count" -lt "$expected" ]; then
    echo "::error::$count of $expected pictures came back"
    status=1
fi
finished=1
exit "$status"
