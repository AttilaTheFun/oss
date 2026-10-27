#!/usr/bin/env python3
"""OS Server's proof: the app's screens, for review before a release.

  tools/proof.py --review <dir> [--version 0.6.0] [--commit <sha>] [--held <exports file>]
                 [--guest linux=<exports file>] [--guest windows=<exports file>]
                 [--no-build] [--publish <ssh host>] [--pull-request <N>]

Builds the app (App/build.sh --zip, build/OS-Server.zip), leases a macOS VM from this Mac's oss
(or uses a held lease: `oss machine lease macos --exports > file`), installs
the app there and opens it with its canned server (`-fixture YES`: the same
leases, usage and log every time), light and dark: its window, its menu
bar's panel (`-panel YES`), its first launch's Set Up window (`-setup YES`)
and the menu bar with its icon; with --guest, a Linux or Windows VM's
Screen window (`-guestScreen YES`): a real guest's screen, through the VNC
relay of a lease held for it on an OS Server on this Mac (`oss machine lease
linux --exports > file`, kept mode 600: it holds the VNC password, which goes
to the VM on standard input), its clock held at 09:41 first (no time
service). Each screen is cut
from the VM's screenshot by the frames the app writes
(~/oss-fixture-windows.json). The run is <dir>/review-macos/manifest.json
(the review store's schema 1, app "oss"); --publish copies it to the
review store on that host (~/ReleaseReview/runs/oss/<version>/macos, the
app's icon beside its versions), where Reviews shows it against the last
approved run. The lease is released however the run ends (a held one is
left).
"""
import argparse, base64, json, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "App")
SCREENS = [  # (item, arguments: AppKit's -key value pairs)
    ("window", ["-fixture", "YES"]),
    ("panel", ["-fixture", "YES", "-panel", "YES"]),
    ("setup", ["-fixture", "YES", "-setup", "YES"]),
]
APPEARANCES = ["light", "dark"]


def sh(command, check=True, **kwargs):
    print("$ " + " ".join(shlex.quote(c) for c in command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        sys.exit(f"failed: {' '.join(command)}\n{result.stdout}{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", required=True)
    parser.add_argument("--version", default=None)
    parser.add_argument("--commit", default=sh(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip())
    parser.add_argument("--held", default=None, help="a held macOS lease's `oss machine lease macos --exports` output")
    parser.add_argument("--guest", action="append", default=[], metavar="PLATFORM=EXPORTS",
                        help="a held Linux or Windows lease's `--exports` output, for its Screen window")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--publish", default=None, metavar="HOST", help="the review store's host (ssh)")
    parser.add_argument("--pull-request", type=int, default=None, metavar="N",
                        help="a pull request's run: filed as pr-<N>-<commit>, never counted toward a release")
    args = parser.parse_args()
    version = args.version or open(os.path.join(ROOT, "Sources/OSSClient/Models.swift")).read().split('public static let version = "')[1].split('"')[0]
    if not args.no_build:
        sh([os.path.join(APP, "build.sh"), "--zip"])
    zip_path = os.path.join(APP, "build", "OS-Server.zip")

    def exports(path):
        values = {}
        for line in open(path).read().splitlines():
            if line.startswith("export ") and "=" in line:
                key, value = line[len("export "):].split("=", 1)
                values[key] = shlex.split(value)[0] if value else ""
        return values

    guests = [(platform, exports(path)) for platform, path in (g.split("=", 1) for g in args.guest)]
    if args.held:
        env = exports(args.held)
    else:
        lease = json.loads(sh(["oss", "machine", "lease", "macos", "--json"]).stdout)
        env = {"OSS_ID": lease["id"]}
    lease_id = env["OSS_ID"]
    out = os.path.join(args.review, "review-macos")
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="oss-proof-")
    items = []
    try:
        def ssh(command, check=True):
            return sh(["oss", "machine", "ssh", lease_id, "--", command], check=check)

        sh(["oss", "machine", "upload", lease_id, zip_path, "/Users/runner/OS-Server.zip"])
        ssh("rm -rf ~/Applications/'OS Server.app' && mkdir -p ~/Applications && ditto -x -k ~/OS-Server.zip ~/Applications")
        # This Mac, as the VM reaches it (its NAT's gateway): the guests' relays.
        gateway = ssh("route -n get default | awk '/gateway/ {print $2}'").stdout.strip()
        screens = list(SCREENS) + [
            (f"screen-{platform}", ["-fixture", "YES", "-guestScreen", "YES", "-guestScreenHost", gateway,
                                    "-guestScreenPort", guest["OSS_VNC_PORT"],
                                    # The canned lease's name, the same every run.
                                    "-guestScreenName", f"oss-lease-{platform}-{CANNED[platform]}"])
            for platform, guest in guests]
        for appearance in APPEARANCES:
            for item, arguments in screens:
                guest = next((g for p, g in guests if item == f"screen-{p}"), None)
                if guest:
                    hold_clock(guest)
                    sh(["oss", "machine", "ssh", lease_id, "--", "umask 077; cat > ~/oss-fixture-vnc-password"],
                       input=guest["OSS_VNC_PASSWORD"] + "\n")
                # Without the window sizes the last launch kept.
                ssh("pkill -x 'OS Server'; defaults delete com.LoganShire.OSS; rm -f ~/oss-fixture-windows.json", check=False)
                time.sleep(1)
                launch = arguments + ["-appearance", appearance]
                ssh("sudo launchctl asuser $(id -u runner) open -n ~/Applications/'OS Server.app' --args " + " ".join(launch))
                # The app writes its windows' frames as they settle (at 2,
                # 4, 6 and 8 s): the last is read.
                for _ in range(30):
                    time.sleep(1)
                    if ssh("test -s ~/oss-fixture-windows.json", check=False).returncode == 0:
                        break
                time.sleep(7)
                text = ssh("cat ~/oss-fixture-windows.json 2>/dev/null", check=False).stdout
                frames = json.loads(text) if text.strip() else None
                if not frames or not frames["windows"]:
                    print(f"{item} ({appearance}): no window")
                    continue
                time.sleep(1)
                screen = os.path.join(work, f"{item}-{appearance}-screen.png")
                sh(["oss", "machine", "screenshot", lease_id, screen])
                window = max(frames["windows"], key=lambda w: w["width"] * w["height"])
                capture = f"{item}-{appearance}.png"
                crop(screen, os.path.join(out, capture), window["x"], window["y"], window["width"], window["height"])
                items.append({"name": f"{item} ({appearance})", "status": "new", "capture": capture})
                if item == "window":
                    # The app's menu bar item (its icon and lease count), with
                    # a few pixels of the bar around it (no neighbour, whose
                    # state changes from run to run).
                    item_frame = frames.get("statusItem")
                    if item_frame:
                        bar = f"menubar-{appearance}.png"
                        margin = 6
                        crop(screen, os.path.join(out, bar), max(0, item_frame["x"] - margin), 0,
                             item_frame["width"] + 2 * margin, frames["menuBarHeight"])
                        items.append({"name": f"menu bar ({appearance})", "status": "new", "capture": bar})
        ssh("pkill -x 'OS Server'; rm -f ~/oss-fixture-vnc-password", check=False)
    finally:
        if not args.held:
            sh(["oss", "machine", "release", lease_id], check=False)

    folder = f"pr-{args.pull_request}-{args.commit[:8]}" if args.pull_request else version
    json.dump({"schema": 1, "app": "oss", "version": version if not args.pull_request else f"{version} (#{args.pull_request})",
               "release": None if args.pull_request else version, "commit": args.commit,
               "kind": "snapshots", "target": "macos", "device": "macOS VM (an oss lease)", "orientation": "landscape",
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items},
              open(os.path.join(out, "manifest.json"), "w"), indent=1)
    expected = len(APPEARANCES) * (len(SCREENS) + 1 + len(guests))
    print(f"review-macos: {len(items)} of {expected} screens")
    if args.publish:
        store = f"ReleaseReview/runs/oss/{folder}/macos"
        sh(["ssh", "-o", "BatchMode=yes", args.publish, f"mkdir -p {store}"])
        sh(["rsync", "-a", "--delete", out + "/", f"{args.publish}:{store}/"])
        icon = os.path.join(work, "icon.png")
        sh(["sips", "-s", "format", "png", "-Z", "512", os.path.join(APP, "build/OS Server.app/Contents/Resources/AppIcon.icns"), "--out", icon])
        sh(["rsync", "-a", icon, f"{args.publish}:ReleaseReview/runs/oss/icon.png"])
        print(f"published to {args.publish}:{store}")
    if len(items) < expected:
        sys.exit("missing screens")


# The fixture's Linux and Windows leases (App/Sources/OSSApp/Fixture.swift).
CANNED = {"linux": "a90c3e17", "windows": "7b1e04d2"}


def hold_clock(guest):
    """The guest's desktop held still: its clock at the fixture's 09:41, its
    time service off, so it reads the same every run. On Windows the
    taskbar is hidden as well (auto-hide): its tray's icons come and go from
    one lease to the next (the notification bell, with or without its "do
    not disturb" mark), which no setting held still."""
    if guest["OSS_PLATFORM"] == "windows":
        script = "\n".join([
            "$ProgressPreference = 'SilentlyContinue'",
            "Stop-Service w32time",
            "Set-Date -Date '2026-11-01 09:41:00' | Out-Null",
            # StuckRects3's byte 8: 3 hides the taskbar until the pointer reaches it.
            "$key = 'HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StuckRects3'",
            "$settings = (Get-ItemProperty -Path $key).Settings",
            "$settings[8] = 3",
            "Set-ItemProperty -Path $key -Name Settings -Value $settings",
            # Explorer starts again by itself, taking it up.
            "Stop-Process -Name explorer -Force",
            "Start-Sleep -Seconds 5",
        ])
        # Encoded, so no shell between here and PowerShell reads its quotes.
        command = "powershell -NoProfile -EncodedCommand " + base64.b64encode(script.encode("utf-16-le")).decode()
    else:
        command = "sudo timedatectl set-ntp false && sudo timedatectl set-time '2026-11-01 09:41:00'"
    sh(shlex.split(guest["OSS_SSH"]) + ["-o", "BatchMode=yes", command])


def crop(source, destination, x, y, width, height):
    sh(["sips", "-c", str(height), str(width), "--cropOffset", str(y), str(x), source, "--out", destination])


if __name__ == "__main__":
    main()
