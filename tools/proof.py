#!/usr/bin/env python3
"""OS Server's proof: the app's screens, for review before a release.

  tools/proof.py --review <dir> [--version 0.6.0] [--commit <sha>] [--held <exports file>]
                 [--no-build] [--publish <ssh host>] [--pull-request <N>]

Builds the app (App/build.sh --zip, build/OS-Server.zip), leases a macOS VM from this Mac's oss
(or uses a held lease: `oss machine lease macos --exports > file`), installs
the app there and opens it with its canned server (`-fixture YES`: the same
leases, usage and log every time), light and dark: its window, its menu
bar's panel (`-panel YES`) and the menu bar with its icon. Each screen is cut
from the VM's screenshot by the frames the app writes
(~/oss-fixture-windows.json). The run is <dir>/review-macos/manifest.json
(the review store's schema 1, app "oss"); --publish copies it to the
review store on that host (~/ReleaseReview/runs/oss/<version>/macos, the
app's icon beside its versions), where Reviews shows it against the last
approved run. The lease is released however the run ends (a held one is
left).
"""
import argparse, json, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "App")
SCREENS = [  # (item, arguments: AppKit's -key value pairs)
    ("window", ["-fixture", "YES"]),
    ("panel", ["-fixture", "YES", "-panel", "YES"]),
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
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--publish", default=None, metavar="HOST", help="the review store's host (ssh)")
    parser.add_argument("--pull-request", type=int, default=None, metavar="N",
                        help="a pull request's run: filed as pr-<N>-<commit>, never counted toward a release")
    args = parser.parse_args()
    version = args.version or open(os.path.join(ROOT, "Sources/OSSClient/Models.swift")).read().split('public static let version = "')[1].split('"')[0]
    if not args.no_build:
        sh([os.path.join(APP, "build.sh"), "--zip"])
    zip_path = os.path.join(APP, "build", "OS-Server.zip")

    if args.held:
        env = dict(line.split("=", 1) for line in open(args.held).read().replace("export ", "").split() if "=" in line)
        env = {k: v.strip("'\"") for k, v in env.items()}
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
        for appearance in APPEARANCES:
            for item, arguments in SCREENS:
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
        ssh("pkill -x 'OS Server'", check=False)
    finally:
        if not args.held:
            sh(["oss", "machine", "release", lease_id], check=False)

    folder = f"pr-{args.pull_request}-{args.commit[:8]}" if args.pull_request else version
    json.dump({"schema": 1, "app": "oss", "version": version if not args.pull_request else f"{version} (#{args.pull_request})",
               "release": None if args.pull_request else version, "commit": args.commit,
               "kind": "snapshots", "target": "macos", "device": "macOS VM (an oss lease)", "orientation": "landscape",
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items},
              open(os.path.join(out, "manifest.json"), "w"), indent=1)
    expected = len(APPEARANCES) * (len(SCREENS) + 1)
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


def crop(source, destination, x, y, width, height):
    sh(["sips", "-c", str(height), str(width), "--cropOffset", str(y), str(x), source, "--out", destination])


if __name__ == "__main__":
    main()
