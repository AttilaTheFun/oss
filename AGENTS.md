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
oss status                                       # bases (configs), capacity, leases (how many of each kind)
oss machine lease <macos|ios|android|linux|windows> [--config=NAME] [--minutes=N] [--wait]
                  [--kind=ci|session|agent|manual] [--label="what for"] [--link=URL]
oss machine list                                 # every lease: kind, holder, time, label
oss machine ssh <id> -- <command>                # VMs: as runner; sudo needs no password
oss machine simctl <id> install ./My.app         # iOS: local paths uploaded first
oss machine simctl <id> launch <bundle id> | openurl <url> | terminate … | listapps
oss machine adb <id> install ./app.apk | shell … | logcat -d   # Android
oss machine screenshot <id> /tmp/screen.png      # any lease
oss machine tap <id> <x> <y>                     # any lease, in the screenshot's pixels
oss machine swipe <id> <x> <y> <to x> <to y> [--ms=300]
oss machine type <id> <text…>
oss machine key <id> return                      # names; on a VM cmd+a…
oss machine upload|download <id> <from> <to>     # VMs (scp); containers (a file, through the server)
oss machine vnc <id>                             # VMs: vnc://host:port and its password
oss machine renew <id> --minutes=60
oss machine release <id>
```

`renew`, `release` and the others take the lease's id, or its platform
when you hold just one lease of it. On Android you can also use your own
adb: `adb connect <host>:<adbPort>` (printed with the lease).

Say who a lease is for: everyone watching the server (`oss status`, OS
Server's window, OS Monitor) sees each lease's kind and label. An agent
leasing for its work passes `--kind=agent --label="<its task>"`; a CI job
in GitHub Actions is `ci` by itself (its job and run); `oss mcp`'s leases
are `agent`. Without `--kind`, the server takes the holder's: a `visor:`
holder's container is its `session`, its other machines `agent`, anyone
else's `manual`.

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

Containers (OS Server's app on macOS 26; from any computer, a container
too): `oss machine lease container --image=REF [--volume=…] [--port=N]…`,
then `oss machine exec <id> -- <command>` and `oss machine upload|download
<id> <from> <to>` (a file; a folder as a tar through exec). They need no
SSH or screen: a command's streams, exit status and signals go straight
through (by the container's socket on the server's Mac, through the server
anywhere else). `--port` forwards a container's port to one of the
server's (`oss machine list` says which): a server under test in a
container of its own can't take you down with it. `--mount` shares the
server Mac's own folders, so only a client on that Mac may ask for one.
Prefer a container to a Linux VM for headless Linux work; release it when
done, as any lease (`--minutes=0`, held until released, is for an agent's
own session container, which its program releases).

For scripts and CI: `oss machine lease linux --exports` prints `export
OSS_ID=… OSS_SSH=… OSS_HOST=… …`; `oss machine run linux -- ./script.sh`
gives a script those in its environment.

## Storage

```sh
oss storage put build/My.ipa --name=My.ipa [--ttl=24h]   # kept while your lease lasts (at most 7d)
oss machine install <ios lease> My.ipa                    # an .ipa or zipped .app of yours, on its simulator
oss storage ls | get <sha256 | name> [out] | renew <id | name> | rm <id | name>
```

Files you put are yours (your holder: `OSS_HOLDER`, else user@host) and
deleted once no lease holds them: `rm` what you're done with. A holder may
keep 20 GB. In a container without the token, your session hands you a
grant's URL instead (`oss grant <verb> …` on its side): `oss storage put
<file> --url=<grant>`, `oss storage get --url=<grant>`, `oss machine
install --url=<grant> <object>`, and for a container lease of yours `oss
machine exec --url=<grant> -- <command>`, `oss machine upload --url=<grant>
<file> <path>`, `oss machine download --url=<grant> <path> <file>`. A
grant is a secret for a few minutes: don't paste it anywhere else.

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
  `Machines/`, served and stored files in `Files/sha256/` with storage's
  leases in `State/storage-leases.json`); its log `~/Library/Logs/OS Server.log`. Every lease's
  machine runs outside its process (since 0.10): macOS VMs and containers
  in `oss-machine` helpers (launchd jobs `oss.machine.<name>`,
  `oss.container.<name>`), Linux and Windows VMs in QEMU processes (or
  UTM's on a server from before 0.9), simulators and emulators the Mac's.
  A restart keeps the leases, starts again from its disk any machine
  whose process is gone, and deletes clones nobody holds.
- Still ask before restarting or quitting OS Server while others hold
  leases: their machines go on, but the API and forwarded ports are gone
  until it's back.
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
