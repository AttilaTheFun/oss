# OS Server, the app

The server, in a Mac app (macOS 15) that is the server's process.
`build.sh` makes `build/OS Server.app`: the app (`OSSApp`, this package's,
hosting `OSSServer` from the root package) with the command line (`oss`,
the root package's) in `Contents/Helpers`, both signed with the Mac's
Apple Development identity (ad hoc without one) and Virtualization's
entitlement. `--zip` also makes `build/OS-Server.zip`; `--install` copies
the app to /Applications. Its icon is `Icon/OSServer.icon` (Icon Composer:
a glass stack of machines), rendered with Xcode's `ictool`; the
repository's `.github/icon.png` is the same document at 512 px.

- **The server** is `ServerHost`, started at launch in this process
  (`ServerRunner`): its log lines appended to `~/Library/Logs/OS Server.log`
  and the last kept for the window. Leases' machines run in processes of
  their own (macOS VMs and containers in `oss-machine` helpers, launchd
  jobs), so quitting keeps them; installs and layer builds run here. If
  another server answers on
  the port (the launch agent's, before 0.7), the app leaves it be until
  asked to take over.
- **A VM's screen**, live, by Screen beside its lease: a macOS VM's is
  Virtualization's own `VZVirtualMachineView`, in a window of its helper's
  (`MachineScreens.showInHelper`; a base being built, in the app's:
  `MachineScreen`); a Linux or Windows VM's is OS Server's own VNC viewer
  on its QEMU (`GuestScreen`, over `RFBSession`): the pointer, wheel and
  keys go to the guest, Command as its Super key.
- **Remove Everything** (Settings): every lease ended and everything OS
  Server keeps on the Mac deleted (`ServerHost.removeEverything`, then the
  log, the launch agent's plist, the command line's link and the login
  item), then it quits.
- **What it shows** comes from the server's API (`Monitor`, OSSClient, every
  two seconds): `status`, `usage`, `capabilities` and `cache`.
- **The menu bar**: closing the window turns the app into a menu bar app
  (no Dock icon); its item shows the leases' count, and its panel the Mac's
  CPU and memory and each lease.
- **The canned server** (`-fixture YES`, Fixture.swift): the same leases,
  usage and log every time, nothing started; `-panel YES` shows the menu
  bar's panel in a window of its own, `-appearance light|dark` forces one.
  The proof (`../tools/proof.py`) photographs these on a macOS lease (`tools/proof.py`).
  Launch arguments are AppKit's `-key value` pairs: a flag without a value
  takes the next one as its value, and a word left over is a file to open,
  for which SwiftUI opens no window.
