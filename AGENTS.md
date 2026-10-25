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
  starting a base, no clicking UTM's window. Bases change only through
  `oss image build` on the server's Mac, by whoever keeps it.
- **The token is a secret**: `~/.config/oss/token`. Never print it, paste
  it into a message or commit it.

## Machines

```sh
oss status                                       # bases (configs), capacity, leases
oss machine lease <macos|ios|android|linux|windows> [--config=NAME] [--minutes=N] [--wait]
oss machine ssh <id> -- <command>                # VMs: as runner; sudo needs no password
oss machine simctl <id> install ./My.app         # iOS: local paths uploaded first
oss machine simctl <id> launch <bundle id> | openurl <url> | terminate … | listapps
oss machine adb <id> install ./app.apk | shell … | logcat -d   # Android
oss machine screenshot <id> /tmp/screen.png      # any lease
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
- `oss doctor` says whether the server can drive UTM, simulators and
  emulators. The server: `launchctl kickstart -k gui/$(id -u)/oss.server`;
  its log `~/Library/Logs/oss.log`; its state `~/.local/state/oss/`
  (leases.json). A restart keeps running leases, and deletes clones nobody
  holds.
- After changing oss: `./install.sh --service`, and copy the binary to the
  clients that use it. A change to the API raises `OSS.apiLevel` and goes
  in CHANGELOG.md.
