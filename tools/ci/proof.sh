#!/bin/bash
# OS Server's proof, from CI: its apps built in a macOS VM leased from OS
# Server itself (xcode_27_2), pictured with their canned servers, and each
# picture compared with the one kept for it at the proof's base
# (tools/ci/proof_baseline: a pull request's base branch, a run by hand's
# release before; Tests/Proof there). Never this tree's kept pictures: a pull
# request that changes a screen replaces its picture, so its own would
# show every screen it changed as unchanged.
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
#   before/<name>.png   each that changed, as the base kept it
#                       (Tests/Proof/<name>.png there); none for a screen
#                       the base hasn't got (new, and changed)
#   diffs/<name>.png    each that changed, faded grey with its changed
#                       pixels red (tools/ci/snapshot_diff.swift, built
#                       and run in the macOS VM)
#   proof.json          {"commit", "ref", "kind", "run",
#                        "base": {"ref", "commit"},
#                        "screens": [{"name", "changed", "changedPixels"}]}
# The script fails when the apps don't build, a picture doesn't come back
# or the base can't be fetched; pictures that differ are for review, not
# failures.
#
#   PROOF_REF     the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON  the python3 that runs tools/proof.py (default: the PATH's,
#                 given Pillow if it hasn't it)
#   GITHUB_EVENT_NAME, GITHUB_BASE_REF, GITHUB_REF_NAME  what the base is
#                 (by hand, none: main)
#
# From a CI runner's own user: no sudo here (only in the leases, as their
# runner), and no SSH key of its own. Every lease is made with the run's
# key, which an ssh-agent of the run's holds, so tools/proof.py's plain
# `oss machine ssh` reaches them too; its macOS VM is the one leased here
# (--held: its own lease would not wait for a free VM), and its app the
# one built here (--no-build). The runner may be any Unix (OS Server's
# own: a Linux container): what needs macOS (the picture tools,
# CoreGraphics) is built and run in the macOS VM.
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
mac_vm_start oss-proof
# Pillow for tools/proof.py, where the python3 hasn't it: Debian's, in an
# OS Server runner (root, apt, a python3 with no pip), else pip's.
if ! "$python" -c 'import PIL' 2> /dev/null; then
    if [ "$(id -u)" = 0 ] && command -v apt-get > /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null \
            && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pil > /dev/null
    else
        "$python" -m pip install --quiet --user Pillow
    fi
    "$python" -c 'import PIL' || { echo "proof.sh: no Pillow for $python" >&2; exit 1; }
fi

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

# The base's chooser and the proof's base first, nothing leased if it
# doesn't build or the base can't be fetched: Foundation alone, so any
# runner's Swift. The picture tools (CoreGraphics) are built in the VM.
swiftc -O -o "$work/proof_baseline" "$ROOT/tools/ci/proof_baseline/Baseline.swift" "$ROOT/tools/ci/proof_baseline/main.swift"
# A release's base is the release before: its tags, asked of origin. A run
# by hand's (proposing a release, or proving an earlier commit to bisect)
# is the release before the commit: the tags its history has before it.
tags=""
case "${GITHUB_EVENT_NAME:-}" in
    release) tags="$(git -C "$ROOT" ls-remote --tags --refs origin 'v*' | sed 's#.*refs/tags/##')" ;;
    workflow_dispatch)
        if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = true ]; then
            git -C "$ROOT" fetch --quiet --unshallow --tags origin
        else
            git -C "$ROOT" fetch --quiet --tags origin
        fi
        tags="$(git -C "$ROOT" tag --merged "$commit^" --list 'v*' 2> /dev/null || true)"
        ;;
esac
# shellcheck disable=SC2086 # the tags, a word each
baseline="$("$work/proof_baseline" "${GITHUB_EVENT_NAME:-}" "${GITHUB_BASE_REF:-}" "${GITHUB_REF_NAME:-}" "$commit" $tags)"
{ read -r base_ref; read -r base_revision; read -r base_fetch; } <<< "$baseline"
# CI's checkout is shallow, and the base comes as shallow; a whole one
# (run by hand) stays whole: its fetch without --depth.
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" != true ]; then
    # shellcheck disable=SC2086 # git fetch's arguments, a word each
    base_fetch="$(printf '%s\n' $base_fetch | grep -v '^--depth=' | tr '\n' ' ')"
fi
# shellcheck disable=SC2086 # git fetch's arguments, a word each
git -C "$ROOT" fetch --quiet $base_fetch
base_commit="$(git -C "$ROOT" rev-parse --verify "$base_revision^{commit}")"
echo "proof.sh: the proof compares with $base_ref ($base_commit)"

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
    tools)
        # The picture tools, which need macOS (CoreGraphics), built where they run.
        xcrun swiftc -O -o bin/snapshot_diff oss/tools/ci/snapshot_diff.swift || exit
        xcrun swiftc -O -o bin/window_shot oss/tools/ci/window_shot.swift || exit
        xcrun swiftc -O -target arm64-apple-macos14 -o window_rect oss/tools/window_rect.swift || exit
        ;;
    shot)
        # A window cut from a screenshot uploaded here: shot <screen.png> <x> <y> <width> <height> <window.png>
        bin/window_shot "$@"
        ;;
    compare)
        # Each picture in compare/new against the base's of its name in
        # compare/base (none: a new screen): its diff in compare/diffs, and
        # "<name> <pixels changed>" a line out.
        mkdir -p compare/diffs || exit
        for new in compare/new/*.png; do
            [ -e "$new" ] || continue
            name="$(basename "$new" .png)"
            pixels="$(bin/snapshot_diff "compare/base/$name.png" "$new" "compare/diffs/$name.png")" || exit
            echo "$name $pixels"
        done
        ;;
STEPS

echo "::group::A macOS VM (xcode_27_2)"
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
run in_vm tools || { echo "::error::the picture tools didn't build in the VM"; exit 1; }
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
    # shellcheck disable=SC2086 # the frame's four numbers, a word each
    if run in_vm monitor "$appearance" \
        && run "$OSS" machine screenshot "$lease" "$work/monitor-$appearance-screen.png" > /dev/null \
        && frame="$(in_vm frame)" && [ "$(echo "$frame" | wc -w)" -eq 4 ] \
        && run "$OSS" machine upload "$lease" --identity="$work/key" "$work/monitor-$appearance-screen.png" ci/screen.png > /dev/null \
        && in_vm shot screen.png $frame window.png \
        && run "$OSS" machine download "$lease" --identity="$work/key" ci/window.png "$recorded/monitor-mac-window-$appearance.png" > /dev/null; then
        :
    else
        echo "::error::OS Monitor's Mac window ($appearance) wasn't pictured"
        status=1
    fi
done
echo "::endgroup::"

echo "::group::OS Monitor on an iPhone simulator"
rm -rf "$work/ipa" && mkdir "$work/ipa" && ditto -x -k "$work/out/OS-Monitor.ipa" "$work/ipa"
if lease_other ios; then
    ios="$(. "$work/lease-ios"; printf '%s' "$OSS_ID")"
    "$OSS" machine simctl "$ios" install "$work/ipa/Payload/OS Monitor.app"
    for appearance in light dark; do
        # name, launch arguments, swipes down the dashboard (its CI and disk cards are scrolled to by the app)
        for screen in "servers::0" "server:-fixture.open YES:0" "server-ci:-fixture.open YES -fixture.scroll ci:0" \
                      "server-disk:-fixture.open YES -fixture.scroll disk:0" \
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

# Each picture with the one kept at the base, if the base has one (one it
# hasn't is new, and every pixel of it changed): compared in the VM, where
# the diff tool runs, before it goes.
echo "::group::The pictures compared with $base_ref's"
mkdir -p "$work/compare/new" "$work/compare/base"
for picture in "$recorded"/*.png; do
    [ -e "$picture" ] || continue
    name="$(basename "$picture" .png)"
    cp "$picture" "$work/compare/new/$name.png"
    if git -C "$ROOT" cat-file -e "$base_commit:Tests/Proof/$name.png" 2> /dev/null; then
        git -C "$ROOT" show "$base_commit:Tests/Proof/$name.png" > "$work/compare/base/$name.png"
    fi
done
if run "$OSS" machine upload "$lease" --identity="$work/key" "$work/compare" ci/compare > /dev/null \
    && in_vm compare > "$work/pixels" \
    && run "$OSS" machine download "$lease" --identity="$work/key" ci/compare/diffs "$work/diffs" > /dev/null; then
    :
else
    echo "::error::the pictures weren't compared"
    status=1
fi
echo "::endgroup::"
mac_vm_release

# The proof, from the pictures, the base's and their comparison.
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
mkdir -p "$proof/screens" "$proof/diffs" "$proof/before"
screens=""
summary=""
count=0
for picture in "$recorded"/*.png; do
    [ -e "$picture" ] || continue
    name="$(basename "$picture" .png)"
    cp "$picture" "$proof/screens/$name.png"
    kept="$work/compare/base/$name.png"
    pixels="$(awk -v name="$name" '$1 == name { print $2 }' "$work/pixels" 2> /dev/null)"
    if [ -z "$pixels" ]; then
        echo "::error::$name wasn't compared"
        status=1
        continue
    fi
    [ ! -e "$work/diffs/$name.png" ] || cp "$work/diffs/$name.png" "$proof/diffs/$name.png"
    changed=false
    [ "$pixels" -eq 0 ] || changed=true
    # A changed screen as it was, to be seen beside it.
    if [ "$changed" = true ] && [ -e "$kept" ]; then cp "$kept" "$proof/before/$name.png"; fi
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
  "base": {"ref": "$(json "$base_ref")", "commit": "$base_commit"},
  "screens": [$screens
  ]
}
EOF
cat "$proof/proof.json"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Proof (%s) of %s\n\n| Screen | Against %s (%s) |\n| --- | --- |\n%s' "$kind" "${commit:0:7}" "$base_ref" "${base_commit:0:7}" \
        "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

# Every picture: OS Server's 8 (12 with the guests'), OS Monitor's 2 on the Mac and 8 on the iPhone.
expected=20
[ "$kind" = quick ] || expected=24
if [ "$count" -lt "$expected" ]; then
    echo "::error::$count of $expected pictures came back"
    status=1
fi
finished=1
exit "$status"
