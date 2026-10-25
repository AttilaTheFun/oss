# The oss app

The server, run and watched from a Mac app (macOS 15). `build.sh` makes
`build/oss.app`: the app (`OSSApp`, this package's) with the server's own
binary (`oss`, the root package's) in `Contents/Helpers`, signed with the
Mac's Apple Development identity (ad hoc without one). `--zip` also makes
`build/oss.zip`; `--install` copies the app to /Applications.

- **The server** is `Contents/Helpers/oss serve`, the app's child
  (`ServerSupervisor`): started at launch, started again a second later if
  it ends unasked (then waiting longer each time, at most a minute), its
  output appended to `~/Library/Logs/oss.log` and its last lines kept for
  the window. If another server answers on the port (the launch agent's),
  the app leaves it be until asked to take over.
- **What it shows** comes from the server's API (`Monitor`, OSSClient, every
  two seconds): `status`, `usage`, `capabilities` and `cache`.
- **The menu bar**: closing the window turns the app into a menu bar app
  (no Dock icon); its item shows the leases' count, and its panel the Mac's
  CPU and memory and each lease.
- **The canned server** (`-fixture YES`, Fixture.swift): the same leases,
  usage and log every time, nothing started; `-panel YES` shows the menu
  bar's panel in a window of its own, `-appearance light|dark` forces one.
  The proof (`../tools/proof.py`) photographs these on a macOS lease.
  Launch arguments are AppKit's `-key value` pairs: a flag without a value
  takes the next one as its value, and a word left over is a file to open,
  for which SwiftUI opens no window.
