# For agents: oss

When you need a machine (a Mac app to try, a Windows or Linux build, a
GUI, a clean OS), an iOS simulator or an Android emulator, lease one from
the oss server instead of making your own. oss lends machines only;
containers for agents are Visor's (`visor machine …` leases through it).

## The rules

- **Always give it back.** `oss machine release <id>` when you're done, or
  `oss machine run … -- <command>`, which releases however the command
  ends. A lease left alone is released when its time runs out (60 minutes
  unless you asked for more; `oss machine renew <id>` to keep it).
- **Capacity is shared** by everyone using the server. If a lease says
  busy, use `--wait` or come back; don't hold what you aren't using.
- **A lease is yours alone and is deleted afterwards**: install what you
  like, use sudo (it asks nothing), break it. Copy back what you need first.
- **Never touch the bases or the server's tools directly**: no `utmctl`
  against an `oss-*` VM, no `simctl` against an `oss-ios-*` simulator, no
  starting a base, no clicking UTM's or OS Server's windows, nothing in
  `~/Library/Application Support/OS Server`. Bases change only through
  `oss image build` on the server's Mac, by whoever keeps it.
- **The token is a secret**: `~/.config/oss/token` on a client (the
  server's own in its folder). Never print it, paste it into a message or
  commit it.

## Machines

```sh
oss status                                       # bases (configs), capacity, leases
oss machine lease <macos|ios|android|linux|windows> [--config=NAME] [--minutes=N] [--wait]
oss machine ssh <id> -- <command>                # VMs: as runner; sudo needs no password
oss machine simctl <id> install ./My.app         # iOS: local paths uploaded first
oss machine simctl <id> launch <bundle id> | openurl <url> | terminate … | listapps
oss machine adb <id> install ./app.apk | shell … | logcat -d   # Android
oss machine screenshot <id> /tmp/screen.png      # any lease
oss machine tap <id> <x> <y>                     # any lease, in the screenshot's pixels
oss machine swipe <id> <x> <y> <to x> <to y> [--ms=300]
oss machine type <id> <text…>
oss machine key <id> return                      # names; on a VM cmd+a…
oss machine upload|download <id> <from> <to>     # VMs (scp)
oss machine vnc <id>                             # VMs: vnc://host:port and its password
oss machine renew <id> --minutes=60
oss machine release <id>
```

`renew`, `release` and the others take the lease's id, or its platform
when you hold just one lease of it. On Android you can also use your own
adb: `adb connect <host>:<adbPort>` (printed with the lease).

Configs are the bases the server has (`oss status`). `vanilla` is the OS
as it comes with only what oss needs (no Git, no package manager): the
place to prove something needs nothing else. A server's owner builds
others on top (tools, Xcode versions); pick the lowest that has what you
need. For simulator-only work, lease `ios`: it's seconds, not a VM.

Inside VMs: macOS and Ubuntu SSH into zsh/bash as `runner`; on macOS use
`zsh -lc '…'` so a layer's tools are on PATH. Windows SSHes into
PowerShell 5.1, already elevated. A desktop session is logged in on all
three. On macOS, run GUI work in it with `sudo launchctl asuser $(id -u
runner) …`.

Containers (on the server's own Mac only, OS Server's app on macOS 26):
`oss machine lease container --image=REF [--mount=…] [--volume=…]`, then
`oss machine exec <id> -- <command>`. They need no SSH or screen: a
command's streams, exit status and signals go straight through. Prefer one
to a Linux VM for headless Linux work; release it when done, as any lease
(`--minutes=0`, held until released, is for an agent's own session
container, which its program releases).

For scripts and CI: `oss machine lease linux --exports` prints `export
OSS_ID=… OSS_SSH=… OSS_HOST=… …`; `oss machine run linux -- ./script.sh`
gives a script those in its environment.

## The Bazel cache

A server may keep a Bazel cache (`oss cache status` says). A VM lease
already reads it: its `.bazelrc` and `.netrc` are set up, and Bazel
downloads what the cache's populate job built instead of building it. On
the server's Mac, `oss cache use` does the same for you. You read it;
only its populate job writes it. Build with your repository's own flags
(the cache matches exact command lines). Never print a cache token: `oss
cache token` only ever piped into what keeps it.

## Reaching the server

`oss` tries the servers in `~/.config/oss/client.json` in order (this
computer, then the LAN, then a VPN) and uses the first that answers, for
SSH, VNC and adb too. With no `client.json` it tries `127.0.0.1` only.

## Keeping it (the server's Mac)

- `README.md` is the setup, the API and how to make each kind of base
  your own; `provision/<platform>/vanilla` are the vanilla layers' scripts.
- The server is OS Server, the app (since 0.7: in the app's own process,
  `App/`). Its files are `~/Library/Application Support/OS Server`
  (server.json, the token, `State/leases.json`, the macOS bases in
  `Machines/`); its log `~/Library/Logs/OS Server.log`. macOS leases are
  OS Server's own VMs (Apple's Virtualization, in its process): quitting
  the app ends them. Linux and Windows are still UTM's, iOS simulators
  and Android emulators the Mac's; a restart keeps those leases and
  deletes clones nobody holds.
- Never restart or quit OS Server while others hold leases without
  asking them first: their macOS machines end with it.
- `oss doctor` says whether the server can drive UTM, simulators and
  emulators.
- To try a change beside the running server: a server of its own with
  `OSS_HOME` (its own folder, port and ports range) and `"lends":
  ["macos"], "useUTM": false` in its server.json, so it leaves the running
  server's machines alone (a server deletes clones it doesn't hold, of
  every platform it lends). `oss serve` there, from a build signed with
  Virtualization's entitlement (`codesign --force --sign - --entitlements
  App/entitlements.plist .build/debug/oss`).
- After changing oss: `App/build.sh --install`, then OS Server quit and
  opened again (when no one holds a macOS lease). A change to the API
  raises `OSS.apiLevel` and goes in CHANGELOG.md.
