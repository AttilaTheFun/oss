#!/usr/bin/env python3
"""QEMU for OS Server.app: Homebrew's build, made to stand on its own.

  tools/bundle_qemu.py <destination>     # e.g. "OS Server.app/Contents/Helpers/qemu"

Copies qemu-system-aarch64 and qemu-img into <destination>/bin, every
library they load from Homebrew (and those libraries' own, all the way down)
into <destination>/lib with their install names pointed there
(@executable_path/../lib, @loader_path), and the aarch64 UEFI firmware into
<destination>/share. What the app runs then needs no Homebrew; App/build.sh
signs it. QEMU is GPL-2.0 and its libraries LGPL or more permissive:
<destination>/SOURCES.txt says which Homebrew versions were bundled, whose
sources are Homebrew's (each formula's url).

The build Mac needs Homebrew's qemu (`brew install qemu`); a Mac that runs
OS Server doesn't.
"""
import json, os, shutil, subprocess, sys

PREFIX = "/opt/homebrew"
BINARIES = ["qemu-system-aarch64", "qemu-img"]
# QEMU's data (passed with -L): the aarch64 UEFI firmware and its licences,
# the network cards' and displays' option ROMs, VNC's keymaps.
DATA = ["edk2-aarch64-code.fd", "edk2-arm-vars.fd", "edk2-licenses.txt", "keymaps"]
DATA_PREFIXES = ["efi-", "vgabios-"]


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def dependencies(path):
    """The Homebrew libraries a Mach-O file loads (its own install name aside)."""
    lines = run("otool", "-L", path).splitlines()[1:]
    found = []
    for line in lines:
        name = line.strip().split(" (")[0]
        if name.startswith(PREFIX):
            found.append(name)
    return found


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    destination = sys.argv[1]
    for folder in ["bin", "lib", "share"]:
        os.makedirs(os.path.join(destination, folder), exist_ok=True)
    copied = {}  # install name -> bundled file name
    queue = []
    for binary in BINARIES:
        source = os.path.realpath(os.path.join(PREFIX, "bin", binary))
        target = os.path.join(destination, "bin", binary)
        shutil.copy2(source, target)
        os.chmod(target, 0o755)
        queue.append(target)
    while queue:
        path = queue.pop()
        for name in dependencies(path):
            if name in copied:
                continue
            base = os.path.basename(name)
            target = os.path.join(destination, "lib", base)
            if not os.path.exists(target):
                shutil.copy2(os.path.realpath(name), target)
                os.chmod(target, 0o755)
                queue.append(target)
            copied[name] = base
    # Every reference to Homebrew pointed into the bundle.
    for folder, prefix in [("bin", "@executable_path/../lib/"), ("lib", "@loader_path/")]:
        for file in os.listdir(os.path.join(destination, folder)):
            path = os.path.join(destination, folder, file)
            changes = []
            for name in dependencies(path):
                changes += ["-change", name, prefix + copied[name]]
            if folder == "lib":
                changes += ["-id", "@rpath/" + file]
            if changes:
                run("install_name_tool", *changes, path)
    share = os.path.join(PREFIX, "share", "qemu")
    for name in sorted(os.listdir(share)):
        if name in DATA or any(name.startswith(prefix) for prefix in DATA_PREFIXES):
            source, target = os.path.join(share, name), os.path.join(destination, "share", name)
            if os.path.isdir(source):
                shutil.copytree(source, target, dirs_exist_ok=True)
            else:
                shutil.copy2(source, target)
    # What was bundled, for its sources.
    formulae = json.loads(run(os.path.join(PREFIX, "bin", "brew"), "info", "--json=v2", "--installed"))["formulae"]
    used = sorted({name.split("/opt/")[1].split("/")[0] for name in copied if "/opt/" in name} | {"qemu"})
    with open(os.path.join(destination, "SOURCES.txt"), "w") as out:
        out.write("QEMU and the libraries it loads, from Homebrew; each one's source is its formula's url.\n\n")
        for formula in formulae:
            if formula["name"] in used:
                stable = formula["versions"]["stable"]
                version = formula["installed"][0]["version"] if formula.get("installed") else stable
                # The url of the version bundled (the formula's names its newest).
                url = formula["urls"]["stable"]["url"].replace(stable, version.split("_")[0])
                out.write(f"{formula['name']} {version} ({formula.get('license')}): {url}\n")
    print(f"bundled QEMU: {len(BINARIES)} programs, {len(copied)} libraries")


if __name__ == "__main__":
    main()
