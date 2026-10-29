# Changelog

## 0.13.0

- **An iOS lease of any device type** (API 11): `oss machine lease ios
  --device="iPad Pro 13-inch (M5)" [--runtime="iOS 27.0"]`, and `run`'s
  and `oss mcp`'s `oss_lease` too; `LeaseRequest.device` and `runtime`.
  A device type by its name or identifier (or the identifier's last part),
  in any case, among the iPhones and iPads of `simctl list devicetypes`; a
  runtime by its name, version or identifier. The simulator is made of
  that type on that runtime (the config's base's for the one not asked
  for) and set up as the base was: its first boot, the script the base was
  built with (`oss image build ios --script` keeps its path,
  `Simulators/<config>.json` in OS Server's folder) with the device's UDID
  in OSS_UDID, then booted again, and the status bar held still. One that
  asks for neither, or for the base's own type and runtime, is a clone of
  the base, as before. A type the server's Xcode hasn't got is refused
  (400 `noDevice`) with the close ones (its words together in their names,
  else each of them somewhere), or every iPhone and iPad the runtime runs;
  so is a type the runtime doesn't run, and a runtime it hasn't got. A
  client asks a server before API 11 for neither (it would make its base's).
- Every iOS lease says what it is (`Lease.device` and `runtime`, by name;
  a clone its base's): `oss machine list` (`ios/iphone (iPad Pro 13-inch
  (M5))`), the lease's JSON, `oss machine lease`'s description and
  `--exports` (`OSS_DEVICE`), OS Server's window and menu bar panel, and
  OS Monitor; the canned servers' iOS lease is an iPhone 18 Pro.
- An iPad's status bar is held still too: it shows the date beside the
  time, so every iOS lease's `--time` is 9:41 on 9 January 2007 in the
  Mac's time zone (an ISO 8601 date with fractional seconds, the only kind
  simctl takes; plain 9:41 where it takes none).
- An iOS lease's input (`oss machine tap|swipe|type|key`) is tried up to
  three times, two seconds apart, when AXe timed out creating the
  simulator's remote automation session: a busy simulator (just booted,
  or in a VM under load) is slow to make it, and the same input goes
  through a moment later.
- Tests: device types by name and identifier in any case, the close ones
  and the full list for unknown ones, types a runtime doesn't run,
  runtimes, and what a lease is made of, against simctl's lists; with
  OSS_TEST_SIMCTL=1 (a leased macOS VM's simulators), real simulators of
  an iPad and an iPhone made, checked and deleted.
- **CI** (`.github/workflows/ci.yml`, on a self-hosted runner that leases
  from OS Server itself): `build-and-test` (swift build and test, the App
  package, OS Monitor's Bazel build, in a macOS VM), `linux` (the command
  line built in a container), `proof` (OS Server.app and OS Monitor built
  in a macOS VM and pictured, compared with `Tests/Proof/`; the `proof`
  artifact, quick for a pull request, full for main), `beta` and `release`
  (both apps built in a macOS VM and published to Applications Server,
  which signs them; OS Server.app's not fatal until its Signer signs QEMU's
  and AXe's executables). README.md, "This repository's CI".

- **iOS tests on a lease's simulator** (API 10): `oss machine xctest <ios
  lease> --tests=<object | file> [--host=<object | file>] [--ui]
  [--only-testing=X]… [--result=out.xcresult.zip] [--junit=out.xml]` runs
  what `bazel build` of rules_apple's `ios_unit_test` or `ios_ui_test`
  leaves, on a Mac or in a Linux container (rules_applecross): the test
  bundle's `<name>.zip` (or a `.xctest` folder zipped) and its host's
  `.ipa` (or a zipped `.app`), files put in storage first, objects by
  sha256 or name. The server does what rules_apple's
  `ios_xctestrun_runner` does on a Mac: the bundles unpacked into a
  folder of the run's own in the lease's (`__TESTROOT__`) and made
  writable; for a UI test, `<bundle>-Runner.app` made from Xcode's
  XCTRunner.app (the bundle in its PlugIns, XCTest's frameworks in its
  Frameworks, its Info.plist naming it, unsigned for the simulator); the
  .xctestrun from rules_apple's template as its runner fills it in; then
  `xcodebuild test-without-building` against the lease's simulator
  (without test diagnostics: xcodebuild's `simctl diagnose` of a failing
  or interrupted run took its whole ten minutes in a VM, and outlived it),
  the result bundle and derived data in the run's folder, and JUnit made
  from `xcresulttool`'s report of the result bundle. xcodebuild's output
  is streamed and its status is `oss`'s (1 if it passed with no test run,
  as rules_apple's runner fails it). `--only-testing` filters Swift
  Testing's tests too (`Suite/function()`).
- `POST /v1/machines/<id>/xctest`, upgraded to `oss-exec` as an exec is:
  its body an `XCTestRequest` (`tests`, `host`, `ui`, `onlyTesting`), made
  ready before the answer (so a bundle that isn't one is a 400, an object
  the holder hasn't got a 404), then `101` with the run's id
  (`OSS-XCTest-Run`) and frames: xcodebuild's output (`stdout`), the
  server's notes (`stderr`), xcodebuild's status (`exit`). One run at a
  time a lease (409 `busy`; one asked for while the last is being stopped,
  its client gone, waits for it); the client's connection closing ends its
  run, xcodebuild stopped (SIGINT, then SIGKILL ten seconds on for it and
  everything it started). `GET …/xctest/<run>/junit` and `…/result` (the
  result bundle zipped,
  streamed) read a run's results, kept as long as the lease. With the
  token in the lease's holder's name, or a `machine.xctest` grant (`oss
  grant machine.xctest <lease>`; it was reserved), which runs the lease's
  tests and reads their results, for `--url=<grant>`. OSSClient's
  `xctest`, `xctestJUnit` and `downloadXCTestResult`, and
  `OSSGrantClient`'s.
- **A container from anywhere** (API 9): a container is lent to a client
  on another Mac or in a container itself (an agent running a server under
  test in a container of its own, so a crash takes out the server, not the
  agent). Everything `oss machine lease container` takes works over the
  API (image, CPUs, memory, disk, volumes and `:keep`, environment,
  working directory, command, Rosetta, ports) but mounts, which share the
  server Mac's folders: from elsewhere a lease with one is refused (403
  `notLocal`), saying so. `OSSPool` leases a container without mounts from
  the nearest server with room.
- **Exec through the server**: `POST /v1/machines/<id>/exec`, an HTTP/1.1
  upgrade (`Upgrade: oss-exec`) whose body is the `ExecRequest`; after `101
  Switching Protocols` the connection carries the exec socket's frames, the
  server starting the command and relaying the rest, and waiting while a
  container starts again. With the token in its holder's name
  (`OSS-Holder`; another holder's lease is 404) or a `machine.exec` grant.
  `oss machine exec` goes this way from anywhere but the server's Mac
  (where the socket is quicker and outlives the server's restarts), and
  with `--url=<grant>` and no token; so does `run --inside`. On a Mac,
  `oss` reaches another computer for it through Apple's `nc`, as curl for
  the rest; off a Mac (in a container), exec builds now. In OSSClient,
  `exec(_:_:…)` picks the same way, `exec(_:holder:…)` always goes through
  the server, and `OSSGrantClient.exec`; `OSSTransport.connect` makes the
  connection (a socket of the process's own unless the transport makes it).
- **A container's files**: `PUT /v1/machines/<id>/files?path=…&mode=…`
  streams a file into it (relative to its working directory, `~/` its
  home; its folders made; written beside its path and moved into place
  only once all of it has come), `GET` streams one out; through its
  `/bin/sh`. `oss machine upload|download` take a container (a file, its
  mode kept; a folder goes as an archive through exec), from this Mac too,
  and `--url=<grant>`: `machine.upload` and `machine.download` grants, a
  verb each way as the store's are. OSSClient's `uploadFile` and
  `downloadFile`, and `OSSGrantClient`'s.
- **A container's ports**: `--port=N` (repeatable, TCP, at most 16;
  `ContainerSpec.ports`) forwards the container's port from one of the
  server Mac's, out of the range VMs' SSH and VNC come from, on the LAN
  and the tailnet as theirs are, until the lease ends; after the
  container starts again they follow it. `Lease.ports` says where
  (`{"port", "host", "hostPort"}`, the host as the asker reached the
  server); `oss machine lease` and `oss machine list` (and its new
  `--json`) show `8080 → <host>:47512`, `--exports` `OSS_PORT_8080`. A new
  forward now passes over every port a lease has, forwarded at the moment
  or not (a VM's, an emulator's adb, a container's), as well as those
  listening. The container's helper writes its address beside its spec,
  where OS Server forwards to.

- `oss machine run` holds a five-minute lease, renewed each minute while
  its command runs, and SIGTERM releases it at once. A CI runner cancelling
  a job sends SIGINT, SIGTERM, then SIGKILL within seconds, before Bazel
  has stopped: the killed client left its lease (and the CI volume it held)
  for up to an hour, and the next job was refused the volume.
- The README's CI example keeps its volume (`:keep`): without it the
  volume, Bazel's tree, went with each lease, so every job built cold.
- **Storage** (API 7): files kept on the server by their SHA-256 while a
  lease holds them. `oss storage put <file> [--name=N] [--ttl=24h]`, `get
  <sha256 | name> [out]`, `ls`, `renew <id | name> [--ttl]`, `rm <id |
  name>`; `PUT`/`HEAD`/`GET /v1/storage/objects…` and `/v1/storage/leases…`,
  the holder in an `OSS-Holder` header (a holder's leases are its own:
  another's are 404). A lease lasts 24 hours unless asked otherwise, at
  most 7 days; bytes put twice are kept once (a put sends its SHA-256
  first and no bytes if the server has them); a name moves to the object
  last put with it; an object no lease holds is swept within a minute,
  never one being read or written. 20 GB a holder and 100 GB in all
  (`"storage"` in server.json), a put past either refused before its bytes
  are read (413). Objects and their uploads stream: neither the server nor
  `oss` holds one in memory.
- **The files served by their SHA-256 are storage's too**: in the same
  folder, each held for good by the server's own lease (its entry beside
  it). Only a file with an entry is served on the cache's port, so a
  holder's object never is; `oss files remove` ends the server's lease, and
  the bytes go at the next sweep unless a holder's lease holds them. A
  server's first start gives any file without an entry one.
- **Grants**: `POST /v1/grants` (`oss grant <verb> [lease | object]
  [--ttl=5m]`), with the API's token, makes a URL that does one thing in a
  holder's name without the token: `storage.put` (with the name and TTL its
  lease will get), `storage.get` or `machine.install`, on a lease or object
  the holder has, for 5 minutes unless asked otherwise (at most 15), as
  often as it's used until then. It carries its claims and an HMAC-SHA256
  under a key only the server keeps (`grant-key`); any other use is the same
  403. `oss storage put|get` and `oss machine install` take `--url=<grant>`
  in place of the token: what an agent in a container holds, its session's
  Visor keeping the token.
- `oss machine install <ios lease> <sha256 | name>` (`POST
  /v1/machines/<id>/install`): an .ipa or a zipped .app from storage, one
  the lease's holder holds, installed on its simulator; it answers the
  app's bundle identifier.
- `oss status` shows the store's use (`Status.storage`): its objects and
  bytes against its caps, its leases, the served files.
- **Who a lease is for** (API 8): every machine lease has a `kind` (`ci`,
  `session`, `agent` or `manual`), and may have a `label` (a short line:
  a session's title, a CI job's name) and a `link` (the CI run's page),
  all optional in a `LeaseRequest` and kept with the lease across
  restarts. `oss machine lease` and `oss machine run` take `--kind`,
  `--label` and `--link`; in a GitHub Actions job, a lease with no
  `--kind` is `ci`, labelled `<repository> · <workflow> #<run id> · <job>`
  and linked to the run; `oss mcp`'s are `agent`. A lease that says no
  kind (an older client's) is taken by its holder, on the server, so every
  view agrees: a `visor:` holder's container is a `session`, its other
  machines `agent`, anyone else's `manual` (the leases a server kept from
  before take theirs the same way). A label is kept to one line of at
  most 200 characters; a link that isn't http or https is refused.
- Kinds are shown wherever leases are: `oss machine list` (a kind column
  and the label; `--json` too), `oss status` (how many of each), `oss
  usage` and `oss volume list` (the lease's kind; `--json`), the JSON
  (`Lease`, `MachineUsage.kind`, `VolumeInfo.kind`), and a badge (CI,
  Session, Agent, Manual) on each lease in OS Server's window and menu bar
  panel and in OS Monitor, with its label (a link to its page where it has
  one), and beside a volume's lease. The canned servers of the proofs have
  one lease of each kind.
- **A forwarded port carries everything the guest sends before it
  closes.** The relay behind every forwarded port (a container's `--port`,
  a VM's SSH and VNC) closed as soon as its `nc` exited, which it does once
  the guest has closed: the last of the guest's bytes, still in nc's pipe
  or waiting to be sent, were dropped with the client's connection. A 1 MB
  download through a container's port came back short most times (every
  time over the LAN), and some small pages empty. nc's exit now ends
  nothing by itself: its output is read to its end, all of it sent, then
  the end of the stream, and the relay closes once the client has closed
  its side too (or 30 seconds on). Each direction reads no more until the
  other side has taken what it has, so a slow client holds back the guest,
  not the server's memory.
- **A client that shuts its side for writing gets its answer.** A client
  that sends its request and then its end of input (`printf … | nc host
  port`) ended the relay, and nc with it, before the guest answered. Its
  end now closes only nc's stdin, so nc shuts its connection to the guest
  for writing (the guest sees the client's end, as it would directly), and
  the guest's answer comes until the guest closes.
- **`oss` builds and runs on Linux** (Swift 6.4, aarch64), as a client:
  `lease`, `exec`, `upload` and `download`, `storage`, `grant`, `xctest`,
  `status` and the rest, as Visor puts it in its container sessions. What
  needs CryptoKit (`oss files add`'s hashing, storage's routes, grants'
  keys) is the server's, on its Mac; `oss serve` and `oss forward` off a
  Mac say that they run on one.
- **`--url` takes a grant's path**: `oss storage put|get`, `oss machine
  install|xctest|exec|upload|download` take the grant's `path`
  (`/v1/…?grant=…`, from `oss grant --json`) as well as its URL, on the
  first of this computer's servers that answers (`client.json`, or
  `OSS_SERVERS`), as the commands with the token find theirs. A grant asked
  for on the server's Mac names it `127.0.0.1` in its `url`, the address it
  was asked at, which a container or another computer reaches by another;
  its path is the same grant wherever the server is reached. OSSClient's
  `OSSGrantClient.resolving(_:servers:)`, and `OSSClient.firstAnswering(_:)`,
  the first of a list of servers that answers.

## 0.12.1

- **OS Server no longer dies of SIGPIPE.** A forwarded connection's relay
  that had exited (a lease's SSH connection the guest closed) while its
  client still sent bytes made the server write into a closed pipe, and
  SIGPIPE's default ended it, every lease's ports and the API with it (the
  MacBook's, 2026-10-27, after 3 hours up). Every oss process (the server
  and app, `oss`, the machine helpers) now ignores SIGPIPE, and the pipe
  writes that could meet a closed reader throw: the connection closes, the
  server goes on.
- The proofs hold still across releases: OS Server's and OS Monitor's
  canned servers show a version of their own (1.0.0), not the build's; a
  Windows guest's taskbar is hidden in its Screen window's proof (its
  tray's icons came and went between leases); each screen is cut from its
  own window, by title, with no window restored from the launch before;
  a window's rounded corners and outer pixel are cut away (transparent),
  where its edge blended with its shadow and the desktop behind; scroll
  bars are overlays, set for the VM's user (a legacy one ran down the
  window); and the Windows guest's desktop is clicked after Explorer
  restarts, so its hidden taskbar doesn't keep the focus and stay up.

## 0.12.0

- `oss machine run container … --inside -- <command>` runs the command in
  the leased container, in this folder (mounted at its own path), and
  releases the lease however it ends: CI's job in a container.
  `--cache=<host>` has its Bazel read this server's cache there
  (`~/.bazelrc`, read-only, the token in `~/.netrc`); `--netrc=<host>` puts
  the cache's read token in its `~/.netrc` for each other host given.

## 0.11.0

- **Files served by their SHA-256**, on the Bazel cache's port:
  `GET /files/sha256/<hex>` with the cache's read token, for pinned
  dependencies such as an Xcode SDK archive. Added on the server's Mac only
  (`oss files add | list | remove`), never evicted. OS Server's disk shows
  them, and its Linux and Windows bases.
- **The cache and its files can be read over the server's tailnet**
  (`tailnetReads`, on unless set off), as from the Mac, its VMs and its
  containers; the token still decides.
- OS Server answers over a tailnet: its API, Bazel cache and leases'
  forwarded ports listened through one IPv6 socket that also took IPv4,
  which never saw connections that came in over Tailscale's tunnel (the
  LAN's and loopback's it did). They listen on IPv4 now. A client away from
  the LAN (OS Monitor on a phone, another Mac's `oss`) had fallen back to
  the tailnet for nothing.
- Windows' vanilla layer turns off OneDrive (its "Turn On Windows Backup"
  toast came some minutes after logon) and apps' toasts: a screen that
  holds still.
- `oss` no longer crashes (SIGTRAP) when curl answers with nothing: that's
  no answer from that server, and the next is tried.
- OS Server's and OS Monitor's version lines use digits of one width, so a
  new version moves nothing after it (a proof's diff landed on the server's
  address for that).

## 0.10.1

- OS Server could crash as it started: its log's last line (which a
  component's install shows) was written from several threads at once
  with no lock (since 0.9).

## 0.10.0

- **macOS VMs in helpers of their own**, as containers are: each lease's VM
  runs in `oss-machine macos`, a launchd job, so quitting, restarting or
  updating OS Server leaves it running. Its Screen window is the helper's
  (Virtualization's view needs the machine in its process). The helper is
  `Contents/Helpers/oss-machine` (`oss-container` before), containers'
  too. Installs and layer builds still run in OS Server.
- **Every VM starts again from its own disk** when its process is gone:
  after the Mac restarts, a crash, or its guest shutting down; macOS VMs
  and Linux and Windows ones on OS Server's QEMU alike, the lease, its
  ports and its address kept.
- **The Windows component downloads Windows 11 on Arm's ISO** from
  Microsoft, as Microsoft's download page does (no account), checks it
  against the SHA-256 the page lists and keeps it in `Machines/images`.
  When Microsoft refuses, the component says so: an ISO of your own is
  still taken (From a File…, `oss component install windows --file=`).
- **A live Screen window for Linux and Windows VMs**: OS Server's own VNC
  viewer (`RFBSession`) on the VM's QEMU, scaled to the window, with the
  pointer, the wheel and the keyboard.
- **Windows VMs keep the right time**: QEMU's clock is UTC, which Windows
  took for local time (its clock ran the zone's hours off). Their vanilla
  layer also holds the screen still: no taskbar widgets (live weather), no
  Spotlight (a new wallpaper each day).
- OSSClient's API is unchanged (API 6).

## 0.9.0

- **Containers** (API 6, OS Server's app on macOS 26 or later): a lease
  platform, `container`, a Linux container on Apple's Containerization
  from an image in a registry, lent only to a client on the server's Mac.
  - Its `ContainerSpec`: the image, CPUs, memory, its disk, the Mac's
    folders to share (read-only or not), named volumes (kept or deleted
    with the lease), Rosetta, environment, working directory and command.
    `minutes: 0` holds a container until it is released.
  - Each runs in a helper of its own (`oss-container`, a launchd job), so
    containers and their commands outlive OS Server's restarts and
    updates; after the Mac's, OS Server starts them again from their disks.
  - Commands: `oss machine exec` and `OSSClient.exec`, straight to the
    container over its Unix socket: stdin with its end, stdout and stderr,
    the exit status, signals passed on, a terminal with `--tty`.
  - Images pulled once and kept by digest, unpacked once and cloned.
  - The kernel (Kata Containers' arm64 build, as Apple's `container` uses)
    is fetched once into OS Server's folder.
  - `oss volume list | delete`, `GET /v1/volumes`, `DELETE /v1/volumes/<name>`.
  - A client below API 6 (an OSSClient before 0.9, which can't read the
    new platform) is shown no containers: clients send `OSS-API`.
- **OSSPool**: several servers leased from as one, the nearest with room
  first (this computer, the LAN, the tailnet), a container only from this
  computer's.
- **Disk**: each lease's (`MachineUsage.diskBytes`: a VM's clone, a
  simulator's or emulator's data, a container's root filesystem), the
  containers' files among OS Server's, and a day of the Mac's CPU, memory
  and disk kept by the server (`GET /v1/usage/history`).
- **OS Monitor** shows them: each lease's disk, the disk over the last day,
  the volumes, containers ("until released").
- **Self-contained**: OS Server needs no Homebrew and no UTM.
  - **Components** (the first launch's Set Up, Settings › Components): Linux
    containers, macOS, Ubuntu and Windows VMs, Android emulators, iOS
    simulators, each installed from a download (or a file you give it) with
    no one at its screen and removed on its own.
  - **Linux and Windows VMs on its own QEMU** (Homebrew's, bundled with its
    libraries and data): each in a process of its own (it outlives OS
    Server's restarts), QEMU's NAT, SSH forwarded on loopback, the screen
    QEMU's VNC. `oss image install linux` (Ubuntu 26.04's cloud image and
    cloud-init) and `oss image install windows --iso=` (an answer file;
    Fedora's virtio-win for the network card and GPU) make their bases;
    layers build on them as on any. `oss component list|install|remove`.
  - Its own SSH key in its folder (a server from before keeps the user's),
    the provisioning scripts and AXe inside the app, guest passwords it
    makes itself.
- `OS Server --headless`: the server alone, no window (to try a change
  beside the running app, with an `OSS_HOME` of its own).

## 0.8.0

- **A simulator's screenshots have their corners and Dynamic Island masked
  black** (`simctl io screenshot --mask=black`): a fresh simulator draws
  the island and another doesn't, so shots of one screen differed there.
- **OS Monitor's iPhone build is signed as itself**: its own application
  identifier and keychain group over the wildcard profile's `TEAM.*`.

- **OS Monitor** (Monitor/), OS Server's client for iPhone, iPad and Mac, as
  Visor is Visor Server's.
  - For each server it shows:
    - what its Mac's CPU, memory and disk go to: OS Server with its
      machines, every other process, and what's free, with the last
      minutes of CPU and memory;
    - what's running;
    - the other apps using the most;
    - OS Server's files;
    - capacity and the Bazel cache.
  - It reads, and does nothing else.
  - Built with Bazel (`//Monitor:os_monitor_ios`, `//Monitor:os_monitor_macos`).
  - Its proof is `tools/monitor_proof.py`.
- **A monitor token** (API 5): kept beside the server's token, it's
  accepted for `GET /v1/status`, `/v1/usage` and `/v1/cache` (without the
  cache's read token), and refused for everything else.
  - OS Server's Settings › OS Monitor show it in a connection code
    (`MonitorConnection`: the server's name, its LAN, tailnet and .local
    addresses, the token), as a QR code and to copy. **New Code** makes a
    new token.
  - `oss monitor code [--new]` gives the code where there is no app (piped).
- **Usage says whose it is** (API 5; every field new and optional, so older
  clients and servers are unaffected):
  - `ours`: OS Server's own process and every machine it lends;
  - `others`: every other process;
  - `disk`: the volume's size and free space, and OS Server's files by kind
    (macOS bases, their leases' clones, the Bazel cache, the Android SDK and
    emulators), measured every ten minutes;
  - `topProcesses`: the other apps using the most memory, an app's helpers
    counted with it (another app's VMs as "Virtual machines", Bazel's JVMs
    as "Bazel").
- **OS Server's window** shows the same CPU, memory and disk split as OS
  Monitor (OSSMonitorKit's `UsageOverview`, on its own server).
- The repository builds OS Monitor with Bazel beside the Swift package
  (MODULE.bazel; the package is unchanged for the server and its command
  line).

## 0.7.1

- **An emulator's status bar is the same on every lease**: 09:41, Wi-Fi,
  a full battery, no cellular network, no notifications. 0.7.0 showed the
  cellular network, which the emulator drew differently from one lease to
  the next (white, or beside a second Wi-Fi icon, with "3G"); it's hidden
  now, and the demo commands are sent twice, a few seconds apart, as a lease
  is handed over while SystemUI may still be settling after boot.

## 0.7.0

- **OS Server, the app, is the server.** The server runs in the app's own
  process (`OSSServer`, a library; `ServerHost`), with no helper; the app
  is `OS Server.app` (it was `oss.app`), and `Contents/Helpers/oss` is the
  command line alone (Settings links `~/.local/bin/oss` to it). It opens at
  login as macOS keeps it for the app (no launch agent), and takes over
  from a launch agent's `oss serve` as before.
- **macOS VMs are OS Server's own**, on Apple's Virtualization framework,
  in the app's process: no UTM for macOS. A base is a folder in
  `Machines/macos/<config>.vm` (its disk, auxiliary storage and
  `machine.json`); a lease is an APFS clone of it with a network card of
  its own, ready in about fifteen seconds, deleted with the lease. They run
  headless; **Screen** beside a macOS lease in the window shows it live.
  Quitting OS Server ends the macOS leases (it asks first).
- **`oss image install macos [config] [--ipsw=PATH]`** installs macOS into
  a new base and makes `runner` on its first boot with no one at its
  screen (macOS 27's guest provisioning; about four minutes from an IPSW).
  `oss image build macos <layer> --from=<base>` builds layers on these
  bases as on UTM's. Screen Sharing still needs its switch turned on once
  in a new base's System Settings (at its live view).
- **`oss image import-utm <name>…`** takes UTM's macOS VMs in as OS
  Server's own bases (UTM exports an APFS clone: no space, a moment). Each
  start does it for every `oss-macos-` VM in UTM whose config OS Server
  hasn't got of its own (the first start of 0.7: all of them), so the
  configs stay what they were.
- **Its files are in `~/Library/Application Support/OS Server`**: settings
  (server.json), the token, the guest passwords, the cache's tokens, the
  leases (`State/`), the macOS bases (`Machines/`). The first start moves
  them from `~/.config/oss` and `~/.local/state/oss` (the token is copied:
  a client on the same Mac still reads `~/.config/oss/token`), writing into
  server.json where the Android SDK and the Bazel cache already were, so
  neither moves. Linux keeps `~/.config/oss` and `~/.local/{state,share}/oss`.
- **Remove Everything** (Settings) ends every lease and deletes all OS
  Server keeps on the Mac (its folder, what an earlier oss kept in
  `~/.config`, `~/.local/state` and `~/.local/share`, its log, the launch
  agent's plist, the command line's link, the login item; UTM's `oss-` VMs
  if asked), then quits: removing the app leaves the Mac as it was.
- **A simulator's and an emulator's status bar is held still** from the
  moment the lease is ready, so screenshots of the same screen match from
  run to run:
  - the time 9:41, full Wi-Fi, a full battery;
  - full signal and no carrier on iOS; no cellular network and no
    notifications on Android;
  - simctl's status bar override on iOS, SystemUI's demo mode on Android;
  - `status_bar clear` or the demo's `exit` command gives the live one back.
- **`"lends"` and `"useUTM"`** in server.json: a server lends only the
  platforms named (and leaves every other platform's machines alone,
  however they're named), and can leave UTM out. A second server, to try a
  change beside a running one, is `OSS_HOME` with both set.
- No change to the API (level 4).

## 0.6.0

- **The oss app** (App/, `App/build.sh`): a Mac app that runs the server
  (the same `oss` binary, in the app) and shows what is used through it:
  the Mac's CPU and memory with their last minutes, each lease's CPU and
  memory against what it was given, the capacity per platform with the
  bases, the Bazel cache, the server's log. It collapses to the menu bar
  (the leases' count beside its icon, a panel with the Mac and the leases)
  when its window is closed; opens at login if asked; links
  `~/.local/bin/oss` to its own. It replaces the launch agent
  (`./install.sh --service`), whose server it can take over.
- **Its proof** (`tools/proof.py`): the app's window, its menu bar panel and
  its menu bar item, light and dark, from a macOS lease running it with a
  canned server (`-fixture YES`), for review before a release.
- No change to the server or the API (level 4).

## 0.5.0

- **Input.** `oss machine tap|swipe|type|key` (and `POST
  /v1/machines/<id>/input`, OSSClient's `input`, the MCP tools `oss_tap`,
  `oss_swipe`, `oss_type`, `oss_key`): in a screenshot's pixels, on any
  lease. An emulator by `adb input`; a VM by VNC's pointer and key events
  (with modifiers: `cmd+a`); a simulator by AXe, which the server's Mac needs
  (`brew install cameroncooke/axe/axe`, or `axePath` in server.json).
- **Usage.** `oss usage` (and `GET /v1/usage`, OSSClient's `usage()`, the
  MCP tool `oss_usage`): the server's CPU and memory, and each lease's, from
  its processes on the Mac, against what it was given (`cpus`,
  `memoryLimitBytes`, now on a VM's and an emulator's lease too).
- **A VM lease's `guestPassword`**, from `~/.config/oss/guest-passwords.json`
  where the server's owner keeps the bases' `runner` passwords.
- `oss machine upload` and `download` (scp, VMs).
- **Headless VMs** (`"headlessVMs": true` in server.json): a Linux or
  Windows clone has no displays, so UTM opens no window; its graphics card
  moves to QEMU's command line beside its VNC. A macOS VM keeps its display
  (without one it has no screen to share).
- **A QEMU VM's VNC pointer is absolute.** UTM gives its QEMU VMs a USB
  mouse beside the tablet, and while the guest followed the mouse a VNC
  client's clicks landed wherever the pointer already was. oss takes the
  mouse out (over QMP, which it now asks QEMU for on a loopback port a
  thousand below the VM's VNC), and its own input tells QEMU's VNC its
  encodings first, which is when QEMU looks at the pointer's kind.
- **VNC screenshots and input no longer hold up the server.** They ran on
  the server's one actor with no deadline, so a guest that never drew a
  frame stopped every other request; they run beside it now, and a VNC
  connection gives up after 60 seconds.
- The README says why a VNC client must ask macOS's Screen Sharing for
  VNC's password by name.
- API level 4. A 0.4 client keeps working: the API only gained things.

## 0.4.0

- **A Bazel cache.** With `"cache"` in server.json the server keeps a
  Bazel remote cache (HTTP, port 7490): a read token for everyone, a write
  token for the one job that populates it (CI's, after each merge to
  main). Every VM lease reads it (its `.bazelrc` and `.netrc`, set up
  with the lease); `oss cache use` sets up a computer of its own;
  `oss cache status` and `oss cache token --write|--read` (piped only);
  `oss cache serve` runs the cache alone. Reads are for the server's Mac,
  its VMs and its containers unless `lanReads`. It keeps to
  `maxGigabytes` and keeps `minFreeGigabytes` free on the disk, letting go
  of the entries read longest ago.
- API level 3: `GET /v1/cache` (`CacheInfo`, OSSClient's `cache()`), and
  the `cache` feature in `Capabilities` where a server keeps one.

## 0.3.0

- **Machines only.** oss lends VMs, iOS simulators and Android emulators,
  and no longer runs containers: `oss container …`, `oss setup
  containers`, `oss image build container`, `/v1/containers…`, a
  container's own token, and the container settings (`containerLimit`,
  `containerImage`, `containerCPUs`, `containerMemory`, `container.env`,
  `container-home/`, `images/`) are gone, and so is OSSClient's container
  half (`Container`, `ContainerRequest`, `ContainerProcess`, the process
  and file calls). Containers for agents belong to the program that runs
  the agents: Visor runs its own (Apple's container) from 0.38, and leases
  machines from oss in its sessions' names.
- API level 2: `Status` has no `containers` or `containerLimit` and
  `Capabilities` no `containers`, on the wire and in OSSClient, and the
  features are `machines` and `screenshots`. No compatibility with 0.2:
  its clients don't read a 0.3 server's status or capabilities (Visor
  moves to OSSClient 0.3.0 with it).

## 0.2.0

- **Containers are bare.** A container's home (`/root`) is on its own disk,
  not a folder of the server's shared in: only the container's own small
  folder is (`/oss`: oss's runner, its processes' output, files on their
  way in or out). A shared folder costs the server a file handle for every
  file the container looks at in it, and a Bazel tree in a shared home ran
  macOS out of them. Files in and out (`cp`, the files API), the template
  files, the container's token, archives and restores pass through that
  folder, read and written by the container: its files need it running,
  and an image needs `tar` (and `find` for templates) besides `/bin/sh`.
- `OSS_HOME` gives an oss files of its own (settings, token, state): a
  second one tested beside a running server (`oss container … --local`).
- `oss container cp` of a directory from a Mac carries no AppleDouble
  files (`._name`, for extended attributes).
- An absolute path through the server is the container's: `cp f
  id:/root/x` is the home's `x` (the server dropped the leading slash, and
  wrote `/root/root/x`), and `id:/etc/x` is refused.
- install.sh signs with the first Apple Development identity by its SHA-1:
  a keychain with two of the same name (a renewed certificate) made
  `codesign` refuse the name.
- `Container.home` is gone (it was the server's folder). Containers made
  by 0.1 still mount that folder as their home, and 0.2 can't archive
  them: archive them with 0.1 before upgrading to keep a home (0.2 restores
  the archive into a bare container), or remove them.

## 0.1.1

- `oss … --help` (or `-h`) prints the usage and does nothing else: a
  subcommand's `--help` used to run it (`oss container start --help` started
  a container).
- A container's files at absolute paths as the container sees them:
  `oss container cp f id:/root/x` (and the API's file paths) are the home's
  `x`, not `root/x`; a path outside /root is refused.
- `oss container list` shows each container's labels and takes
  `--label key=value` to list only those with it.
- `oss machine adb|simctl <id> …` passes everything after the lease to the
  device command as written: its options were taken for oss's own
  (`am start --es key value` lost its extras).
- A container is the VMs' size by default: 6 CPUs and 16 GB (it was 2 and
  4 GB, which made a Swift build crawl).
- A container is removed (or archived) only once its runtime says it is
  gone: one whose guest didn't answer was reported removed, its home
  deleted under it, and left running unknown to oss. A remove that times
  out kills it and deletes it again, else answers with an error and keeps
  the home.
- The README says to keep big trees (a build's output) on a container's
  own disk, not in its home: the server holds a file handle for every file
  the container looks at in the home.

## 0.1.0

The first public version. API level 1.

- Machines: macOS, Linux and Windows VMs (UTM), iOS simulators and Android
  emulators, leased as clones of bases; SSH, VNC, simctl, adb and
  screenshots.
- Containers of any image: processes with input written and output read
  from any offset, files (followed as they grow), labels, limits, archives
  and restores, a token of their own for leasing machines, settings for
  every container and per image.
- `GET /v1/capabilities`: the version, API level and features.
- `OSSClient`: the API's types and an async Swift client (macOS 13, iOS 16,
  Linux), over any transport (URLSession by default), its token asked on
  every request, a timeout per client.
- `oss mcp`: the machine commands as Model Context Protocol tools.
