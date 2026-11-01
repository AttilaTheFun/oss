#!/usr/bin/env python3
"""OS Monitor's proof: its screens, for review before a release.

  tools/monitor_proof.py --review <dir> [--version 0.8.0] [--commit <sha>]
                         [--targets ios,macos] [--publish <ssh host>] [--pull-request <N>]

Builds the apps (Bazel: //Monitor:os_monitor_ios for the simulator,
//Monitor:os_monitor_macos), and shows them their canned servers
(`-fixture YES`: two servers, the same leases and usage every time), light
and dark:

  ios    an iPhone simulator leased from this Mac's oss (its status bar
         held still by OS Server): the servers, a server's dashboard
         (`-fixture.open YES`), and the dashboard scrolled to its disk and
         to its end.
  macos  a macOS VM leased from oss: the window (the list beside a server),
         cropped to it (tools/window_rect.swift, in the guest's session).

Each target's run is <dir>/review-<target>/manifest.json (the review
store's schema 1, app "OS Monitor"); --publish copies them to the review
store on that host (~/ReleaseReview/runs/os-monitor/<version>/<target>, the
app's icon beside them). Leases are released however the run ends.
"""
import argparse, json, os, shlex, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE = "com.LoganShire.OSMonitor"
APPEARANCES = ["light", "dark"]


def sh(command, check=True, **kwargs):
    print("$ " + " ".join(shlex.quote(c) for c in command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        sys.exit(f"failed: {' '.join(command)}\n{result.stdout}{result.stderr}")
    return result


def bazel_output(target, *flags):
    sh(["bazel", "build", *flags, target], cwd=ROOT)
    files = sh(["bazel", "cquery", *flags, "--output=files", target], cwd=ROOT).stdout.split()
    return os.path.join(ROOT, files[0])


def lease(platform):
    """A lease of our own (`oss machine lease` returns once it's ready)."""
    return json.loads(sh(["oss", "machine", "lease", platform, "--json"]).stdout)["id"]


def ios(out, items):
    ipa = bazel_output("//Monitor:os_monitor_ios", "--ios_multi_cpus=sim_arm64")
    work = tempfile.mkdtemp(prefix="osm-proof-")
    sh(["unzip", "-q", ipa, "-d", work])
    app = os.path.join(work, "Payload", "OS Monitor.app")
    lease_id = lease("ios")
    try:
        sh(["oss", "machine", "simctl", lease_id, "install", app])
        for appearance in APPEARANCES:
            # Swipes down the dashboard: none, or to its end; its CI and disk cards are scrolled to by the app.
            for name, args, scroll in [("servers", [], 0), ("server", ["-fixture.open", "YES"], 0),
                                       ("server-ci", ["-fixture.open", "YES", "-fixture.scroll", "ci"], 0),
                                       ("server-disk", ["-fixture.open", "YES", "-fixture.scroll", "disk"], 0),
                                       ("server-end", ["-fixture.open", "YES"], 6)]:
                sh(["oss", "machine", "simctl", lease_id, "terminate", BUNDLE], check=False)
                sh(["oss", "machine", "simctl", lease_id, "launch", BUNDLE, "-fixture", "YES", "-appearance", appearance, *args])
                time.sleep(4)
                if scroll:
                    for _ in range(scroll):
                        sh(["oss", "machine", "swipe", lease_id, "600", "2000", "600", "900", "--ms=300"])
                        time.sleep(1)
                    time.sleep(1.5)
                capture = f"{name}-{appearance}.png"
                sh(["oss", "machine", "screenshot", lease_id, os.path.join(out, capture)])
                items.append({"name": f"{name} ({appearance})", "status": "new", "capture": capture})
    finally:
        sh(["oss", "machine", "release", lease_id], check=False)


def macos(out, items):
    bundle = bazel_output("//Monitor:os_monitor_macos")
    work = tempfile.mkdtemp(prefix="osm-proof-")
    zip_path = os.path.join(work, "OS-Monitor.zip")
    if bundle.endswith(".zip"):
        shutil.copy(bundle, zip_path)
    else:
        sh(["ditto", "-c", "-k", "--keepParent", bundle, zip_path])
    helper = os.path.join(work, "window_rect")
    sh(["swiftc", "-O", "-target", "arm64-apple-macos14", os.path.join(ROOT, "tools", "window_rect.swift"), "-o", helper])
    lease_id = lease("macos")

    def ssh(command, check=True):
        return sh(["oss", "machine", "ssh", lease_id, "--", command], check=check)

    try:
        sh(["oss", "machine", "upload", lease_id, zip_path, "/Users/runner/OS-Monitor.zip"])
        sh(["oss", "machine", "upload", lease_id, helper, "/tmp/window_rect"])
        ssh("rm -rf ~/Applications/'OS Monitor.app' && mkdir -p ~/Applications && ditto -x -k ~/OS-Monitor.zip ~/Applications && chmod +x /tmp/window_rect")
        for appearance in APPEARANCES:
            ssh("pkill -x 'OS Monitor'; defaults delete com.LoganShire.OSMonitor.Mac", check=False)
            time.sleep(1)
            ssh("sudo launchctl asuser $(id -u runner) open -n ~/Applications/'OS Monitor.app' --args "
                f"-fixture YES -fixture.open YES -appearance {appearance}")
            time.sleep(6)
            screen = os.path.join(work, f"window-{appearance}-screen.png")
            sh(["oss", "machine", "screenshot", lease_id, screen])
            rect = ssh("sudo launchctl asuser $(id -u runner) /tmp/window_rect 'OS Monitor'", check=False).stdout.split()
            capture = f"window-{appearance}.png"
            if len(rect) == 4:
                x, y, w, h = map(int, rect)
                sh(["sips", "-c", str(h), str(w), "--cropOffset", str(y), str(x), screen, "--out", os.path.join(out, capture)])
            else:
                shutil.copy(screen, os.path.join(out, capture))
            items.append({"name": f"window ({appearance})", "status": "new", "capture": capture})
        ssh("pkill -x 'OS Monitor'", check=False)
    finally:
        sh(["oss", "machine", "release", lease_id], check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", required=True)
    parser.add_argument("--version", default=None)
    parser.add_argument("--commit", default=sh(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip())
    parser.add_argument("--targets", default="ios,macos")
    parser.add_argument("--publish", default=None, metavar="HOST")
    parser.add_argument("--pull-request", type=int, default=None, metavar="N")
    args = parser.parse_args()
    version = args.version or open(os.path.join(ROOT, "Sources/OSSClient/Models.swift")).read().split('public static let version = "')[1].split('"')[0]
    # The apps say OS Server's version (their Info.plists are written by hand).
    for plist in ["Info.ios.plist", "Info.mac.plist"]:
        text = open(os.path.join(ROOT, "Monitor", plist)).read()
        if f"<key>CFBundleShortVersionString</key><string>{version}</string>" not in text:
            sys.exit(f"Monitor/{plist} doesn't say {version}: set its CFBundleShortVersionString")
    folder = f"pr-{args.pull_request}-{args.commit[:8]}" if args.pull_request else version
    devices = {"ios": ("iPhone 17 (simulator, an oss lease)", "portrait"), "macos": ("macOS VM (an oss lease)", "landscape")}
    for target in args.targets.split(","):
        out = os.path.join(args.review, f"review-{target}")
        os.makedirs(out, exist_ok=True)
        items = []
        {"ios": ios, "macos": macos}[target](out, items)
        json.dump({"schema": 1, "app": "OS Monitor", "version": version if not args.pull_request else f"{version} (#{args.pull_request})",
                   "release": None if args.pull_request else version, "commit": args.commit, "kind": "snapshots",
                   "target": target, "device": devices[target][0], "orientation": devices[target][1],
                   "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items},
                  open(os.path.join(out, "manifest.json"), "w"), indent=1)
        print(f"review-{target}: {len(items)} screens")
        if args.publish:
            store = f"ReleaseReview/runs/os-monitor/{folder}/{target}"
            sh(["ssh", "-o", "BatchMode=yes", args.publish, f"mkdir -p {store}"])
            sh(["rsync", "-a", "--delete", out + "/", f"{args.publish}:{store}/"])
    if args.publish:
        icon = os.path.join(tempfile.mkdtemp(), "icon.png")
        ictool = sh(["xcode-select", "-p"]).stdout.strip() + "/../Applications/Icon Composer.app/Contents/Executables/ictool"
        sh([ictool, os.path.join(ROOT, "Monitor", "Icon", "OSMonitor.icon"), "--export-image", "--output-file", icon,
            "--platform", "iOS", "--rendition", "Default", "--width", "512", "--height", "512", "--scale", "1"])
        sh(["rsync", "-a", icon, f"{args.publish}:ReleaseReview/runs/os-monitor/icon.png"])


if __name__ == "__main__":
    main()
