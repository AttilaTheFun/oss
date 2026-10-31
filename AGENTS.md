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
oss machine lease ios --device="iPad Pro 13-inch (M5)" [--runtime="iOS 27.0"]   # any iPhone or iPad its Xcode has
oss machine list                                 # every lease: kind, holder, time, label
oss machine ssh <id> -- <command>                # VMs: as runner; sudo needs no password
oss machine simctl <id> install ./My.app         # iOS: local paths uploaded first
oss machine simctl <id> launch <bundle id> | openurl <url> | terminate … | listapps
oss machine xctest <id> --tests=<Tests.zip> [--host=<App.ipa>] [--ui] [--junit=out.xml] [--result=out.xcresult.zip]
                                                 # iOS: rules_apple's tests on its simulator (built here or on Linux)
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

iOS tests built where they can't run (a Linux container, with
rules_applecross) run on an `ios` lease: `oss machine xctest` takes what
`bazel build` of an `ios_unit_test` or `ios_ui_test` leaves (the bundle's
`<name>.zip`, the host's `.ipa`; `--ui` for a UI test), runs them as `bazel
test` would on a Mac, streams xcodebuild's output and exits with its
status; `--junit` and `--result` fetch the run's JUnit and result bundle.
One run at a time a lease.

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
An iPad, or another iPhone, is `--device=<its name or identifier>`
(`xcrun simctl list devicetypes` names them; an unknown one is refused
with the close ones): a new simulator set up as the config's base, in
about a minute rather than seconds.

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
install --url=<grant> <object>`, `oss machine xctest --url=<grant>
--tests=<object> …` (its bundles put first), and for a container lease of yours `oss
machine exec --url=<grant> -- <command>`, `oss machine upload --url=<grant>
<file> <path>`, `oss machine download --url=<grant> <path> <file>`.
`--url` takes the grant's path alone too (`/v1/…?grant=…`, `oss grant
--json`'s `path`), on the first of your servers that answers: a grant
asked for on the server's Mac names `127.0.0.1`, which a container reaches
otherwise. A grant is a secret for a few minutes: don't paste it anywhere
else.

## The Bazel cache

A server may keep a Bazel cache (`oss cache status` says). A VM lease
already reads it: its `.bazelrc` and `.netrc` are set up, and Bazel
downloads what the cache's populate job built instead of building it. On
the server's Mac, `oss cache use` does the same for you. You read it;
only its populate job writes it. Build with your repository's own flags
(the cache matches exact command lines). Never print a cache token: `oss
cache token` only ever piped into what keeps it.

## CI jobs in OS Server's containers (0.14)

A server with a GitHub App (`~/.config/oss/ci-github-app.json` and `.pem`
on its Mac, mode 600) and server.json's `ci` runs the named repositories'
jobs that ask for `[self-hosted, <its label>]` itself: a just-in-time
runner a job, in a container lease of kind `ci` (Visor's agent image),
deleted when the job ends (README.md, "CI in OS Server's containers").
`oss ci list` shows them. For now one repository's trial label
(`gh_mcp-oss`) beside its old runner (`gh_mcp-ci`); every repository and
retiring the old runners are next (TODO.md).

- **In such a job** there is no token or key: `OSS_GRANT` (a grant's URL,
  the job's `<job>-<run>@ci`) is what `oss` uses, and only while the job
  runs. Lease, use and release machines, put and get objects, read the
  cache's token, as anywhere; whatever the job leased and stored is
  released when it ends. No `--mount` (the job isn't on the server's Mac):
  upload, or pipe files in. Scripts find `oss` by `command -v oss` where
  `/Applications/OS Server.app` isn't (`~/.local/bin/oss` there).
- **Never print `OSS_GRANT`**, the App's key or a token GitHub gave: the
  server logs none of them.
- Testing the poller and runners needs neither GitHub nor containers:
  `Tests/OSSServerTests/CITests.swift` fakes both (`swift test --filter
  CITests`, on Linux too).

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
  `Machines/`, the containers in `Containers/`, served and stored files in
  `Files/sha256/` with storage's leases in `State/storage-leases.json`, the
  containers' network in `Network/`: `network.json`, `addresses.json` (each
  container's address and MAC address), `network.sock`, `launchd.plist`,
  `network.log`); its log `~/Library/Logs/OS Server.log`. Every lease's
  machine runs outside its process (since 0.10): macOS VMs and containers
  in `oss-machine` helpers (launchd jobs `oss.machine.<name>`,
  `oss.container.<name>`), Linux and Windows VMs in QEMU processes (or
  UTM's on a server from before 0.9), simulators and emulators the Mac's.
  Every container is on one vmnet network (since 0.14), kept by
  `oss-machine network` (the launchd job `oss.network`, KeepAlive),
  started before the first container's helper and never stopped while
  containers are lent: never boot it out by hand, as that takes every
  container's network down with it (README.md, "The containers' network
  has one owner").
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

## CI (this repository's)

`.github/workflows/ci.yml`, on the self-hosted runner labelled `oss-ci`
(README.md, "This repository's CI"): `build-and-test` (swift build and
test, the App package, OS Monitor's Bazel build, in a macOS VM), `linux`
(the command line in a container), `proof`, `beta` and `release` (OS
Server.app and OS Monitor for the Mac, built in a macOS VM, published to
Applications Server, which signs them). Every job leases from the same OS
Server it tests, and releases however it ends.

- **The proof** (`tools/ci/proof.sh`) pictures OS Server.app and OS
  Monitor with their canned servers and compares each picture with the one
  kept in `Tests/Proof/` at its base, a pull request's base branch or the
  commit before a push (`tools/ci/proof_baseline`; `proof.json` names it,
  and `before/` beside `screens/` and `diffs/` in the run's `proof`
  artifact has a changed screen as it was): after each merge to main, full
  (with a Linux and a Windows guest's Screen window); a pull request gets
  its build and tests alone, and a release is reviewed by its commit's proof. Never
  this tree's kept pictures, which a change to a screen replaces. A
  change that means to change a screen replaces its kept picture in the
  same pull request, from the run's `screens/`, after looking at its
  diff and `before/`. Anything that changes from run to run without the
  app changing is held still (the fixtures' dates, the status bar, the
  guests' clocks, the windows' corners cut away), not kept as a picture.
- tools/proof.py and tools/monitor_proof.py stay for a person's run with
  `--publish`; CI runs proof.py as it is (`--held`, `--no-build`) and does
  OS Monitor's part in proof.sh. Porting them to Swift is on TODO.md.
- `swift test` there sets `OSS_TEST_SIMCTL=1`: the VM's simulators are the
  run's own. Never set it on the server's Mac.
