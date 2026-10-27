# oss: OS Server

> [!WARNING]
> **Early and experimental.** oss is young: its API and behaviour may
> change between versions (`GET /v1/capabilities` says what a server
> offers), and it has been run on a few Macs only.

A server on a Mac that lends out operating systems, for CI, for testing,
for automation, for anything that needs a machine of its own for a while:

- **Machines**, each its own for as long as its holder needs it: macOS VMs
  (OS Server's own, on Apple's Virtualization framework), Windows and Linux
  VMs ([UTM](https://mac.getutm.app)), iOS simulators and Android
  emulators. Every one is a clone of a **base**: an APFS clone,
  ready in seconds, taking no disk until it changes, deleted when it's
  released or its time runs out.
- **A Bazel cache** (if you want one): one job writes what it builds (CI's,
  after each merge), and the server's VMs, its containers and the Mac
  itself read it, so a fresh machine downloads what was built instead of
  building it again.

**OS Server**, a Mac app, is the server: the API, the machines and the
cache run in its own process, and its window (or its menu bar item) shows
what each lease uses and any macOS VM live. `oss` is the command line
(`oss serve` runs the server without the app). The command line calls the
server's HTTP API, which programs can call too: Swift ones through the
`OSSClient` library in this package.

| Platform | What a lease is | Ready in | Reached through |
| --- | --- | --- | --- |
| `macos` | OS Server's own VM (Apple Virtualization) | ~15 s | SSH and VNC (Screen Sharing), forwarded |
| `linux` | a UTM VM (QEMU) | ~30 s | SSH and VNC (QEMU's), forwarded |
| `windows` | a UTM VM (QEMU) | ~40 s | SSH (PowerShell) and VNC (QEMU's), forwarded |
| `ios` | a simulator on the server's Mac | ~7 s | `oss machine simctl` (install, launch, openurl, …), screenshots |
| `android` | an emulator on the server's Mac | ~6 s | `adb connect <server>:<port>`, or `oss machine adb` |

Default capacity: two of each VM platform (16 GB each), four simulators
and two emulators. All of it is configurable.

A simulator's and an emulator's status bar is held still from the moment
it's ready (9:41, full Wi-Fi and battery; on iOS full signal and no
carrier, on Android no cellular network and no notifications), so
screenshots of the same screen match from run to run.
`oss machine simctl <id> status_bar clear`, or on Android `oss machine adb
<id> shell am broadcast -a com.android.systemui.demo -e command exit`,
gives the live one back.

oss is for machines with a screen. It ran Linux containers too until
0.3.0; containers for agents now belong to the program that runs the
agents (Visor runs its own), and oss stays with what needs a GUI.

## OS Monitor

OS Server's client for iPhone, iPad and Mac (`Monitor/`, its README).
- **What it shows:** each server's CPU, memory and disk, split into OS
  Server's share (its own process and every machine it lends), every other
  process's, and what's free; what's running; the other apps using the
  most; OS Server's files.
- **Adding a server:** with the code in OS Server's Settings › OS Monitor (a
  QR code, or Copy Code), or from `oss monitor code` on a server run
  without the app.
- **What the code allows:** it carries a monitor token that reads and does
  nothing else.

## Using it

### Machines

```sh
oss machine lease linux                        # an Ubuntu VM for an hour; prints how to reach it
oss machine lease macos --config=xcode-27.0 --minutes=120   # a base of the server's own (oss status lists them)
oss machine lease ios                          # an iPhone simulator
oss machine lease android --wait               # an emulator, waiting for a free one
oss machine renew <id | platform> --minutes=60
oss machine release <id | platform>            # deleted; the place is free

oss machine ssh <id> [-- command…]             # VMs
oss machine vnc <id> --open                    # VMs: VNC address and the lease's password
oss machine simctl <id> install ./My.app       # iOS: local paths are uploaded first
oss machine simctl <id> launch com.example.app
oss machine adb <id> install ./app.apk         # Android (or: adb connect <host>:<adbPort>)
oss machine screenshot <id> screen.png         # any lease
oss machine tap <id> 120 480                   # any lease: in the screenshot's pixels
oss machine swipe <id> 500 1600 500 400 --ms=400
oss machine type <id> hello world              # into what has focus
oss machine key <id> return                    # names, a VM's cmd+a, or the platform's code
oss machine upload <id> ./build ~/build        # VMs (scp; download the other way)
oss machine run windows -- ./test.sh           # lease, run with OSS_* set, release
oss usage                                      # the server's CPU and memory, and each lease's
```

Input goes in by the platform's own means: `adb input` on an emulator,
VNC's pointer and key events on a VM, and on a simulator
[AXe](https://github.com/cameroncooke/AXe) (idb's HID client: `simctl` has
no input), which the server's Mac needs for it (`brew install
cameroncooke/axe/axe`).

A lease names its platform and, optionally, a **config**: which base it's
cloned from. oss makes vanilla bases (below); a server can have as many
more as its owner builds. A lease that isn't renewed is released when its
time runs out (60 minutes unless asked otherwise, at most 480). `renew`
and `release` take the lease's id, or its platform when you hold just one.

### Containers

OS Server's app also lends Linux containers (API 6, macOS 26 or later):
each a lightweight VM of its own on Apple's
[Containerization](https://github.com/apple/containerization), from an
image in a registry. A container is lent only to a client on the server's
own Mac, since it shares that Mac's folders.

```sh
oss machine lease container --image=ghcr.io/owner/agent:1.2 --cpus=6 --memory=16 \
    --mount=$HOME/Developer/app:$HOME/Developer/app --mount=/Applications/Xcode.app:/Applications/Xcode.app:ro \
    --volume=app-build:/var/cache/bazel:128:keep --rosetta --minutes=0
oss machine exec <id> -- uname -a                     # streamed; its exit status is exec's
oss machine exec <id> --workdir=/src --env-file=agent.env -- ./agent --stdio
oss machine exec <id> --tty -- bash                    # a terminal
oss machine exec --socket=<execSocket> -- make         # by the lease's socket: no server or token needed
oss volume list                                         # volumes, kept ones too
oss volume delete app-build
```

- **The image** is pulled once and kept by its digest; its root filesystem
  is unpacked once at the size asked for (`--disk`, 64 GB by default) and
  cloned for each container, so a second container of an image starts in
  about a second. An unpacked image no container has been made from in two
  weeks is deleted.
- **Mounts** share a folder of the Mac's, read-only with `:ro`.
- **Volumes** are disks of their own by name (ext4, allocated as they
  fill): one already there at the size asked for is used again. A volume
  is deleted with its lease unless it is kept (`:keep`); `oss volume delete`
  removes a kept one, once no lease is using it.
- **Rosetta** (`--rosetta`) runs x86_64 Linux programs, where the Mac has
  Rosetta.
- **The network** is NAT (vmnet's shared mode): the container reaches the
  internet and the Mac's LAN addresses, the server's API and its Bazel
  cache included.
- **Held until released:** `--minutes=0` (a container only) is never
  reclaimed: for an agent's container, which lives as long as its session.
- **It outlives the server.** Each container runs in a helper process of
  its own (`oss-machine container`, a launchd job of OS Server's), so quitting,
  restarting or updating OS Server leaves it, and the commands running in
  it, running; OS Server takes it up again when it starts. After the Mac's
  restart, or if its helper ends, OS Server starts it again from its own
  disk.
- **exec** goes to the container directly, over its Unix socket on the
  server's Mac (`Lease.execSocket`), not through the server. stdin goes in
  with its end; stdout and stderr come back apart; TERM, INT, HUP, QUIT,
  USR1 and USR2 sent to `oss machine exec` go on to the command, and if
  `oss machine exec` ends first, so does the command (TERM, then KILL ten
  seconds on). `--env-file` keeps secrets out of the command line.
- What it runs: the image's own environment and working directory, the
  lease's over them, and by default a process that waits (`--command`
  names another): the work is done with exec.

### Self-hosted CI

```yaml
- run: oss machine run macos --config=xcode-27.0 --minutes=90 -- ci/test-in-vm.sh
```

or `oss machine lease linux --exports >> "$GITHUB_ENV"`, then `$OSS_SSH '…'`
in later steps and `oss machine release "$OSS_ID"` in an `if: always()`
step.

A job in a container, on the runner's own Mac (containers are lent there
only): `--inside` runs the command in the container, in the runner's
folder (mounted at its own path), its output and exit status passed
through, and the lease released however it ends. `--netrc=<host>` puts the
cache's read token in the container's `~/.netrc` for each host its build
names the server by, so Bazel's cache and downloader (the files served by
SHA-256) take it:

```yaml
- run: >
    oss machine run container --image=<a builder image> --rosetta
    --mount="$PWD:$PWD" --volume=<repo>-ci:/var/cache/bazel:128
    --inside --netrc=<this Mac's tailnet name> -- bazel test //...
```

### A Bazel cache

With `"cache"` in its settings (below), the server keeps a [Bazel remote
cache](https://bazel.build/remote/caching) on its port 7490, Bazel's HTTP
protocol. It has two tokens, made with it in `~/.config/oss/`:

- **The read token** is for everyone. Every VM lease is set up with it:
  runner's `.bazelrc` names the cache, read-only
  (`--noremote_upload_local_results`), and the token is in runner's
  `.netrc`, where Bazel's HTTP cache takes credentials from (not the
  bazelrc, which `--announce_rc` prints). On this Mac,
  or a computer of its own, `oss cache use` writes the same two files
  (`oss cache use --remove` takes them away); a program gets the token
  from `GET /v1/cache`. Reading is for the server's Mac, its VMs and its
  containers, and its tailnet (`tailnetReads`, on unless set off): the
  LAN can't read unless `lanReads` says so.
- **The write token** is for one job: CI's, building `main` after each
  merge, with the same flags everyone else builds with (the cache matches
  an action by its exact command line). It never leaves the server's Mac
  but piped into what keeps it, such as a GitHub environment only `main`
  may use:

  ```sh
  oss cache token --write | gh secret set OSS_CACHE_WRITE_TOKEN --env main --repo <owner>/<repo>
  ```

  and the job writes its own `.netrc` from the secret
  (`machine <server> login bazel password <token>`).

`oss cache status` says how big it is and how many lookups it answered.
It keeps to its size, and keeps the disk's free space above its floor,
by letting go of the entries read longest ago.

**Files by their SHA-256.** The same port serves files as they are, for
pinned Bazel dependencies too big or too private for anywhere else (an
Xcode SDK archive): `GET /files/sha256/<hex>`, read with the read token
and from the same places as the cache. The hash in the URL is the one a
dependency pins, so any server's copy is the same bytes and Bazel checks
them. They're added on the server's Mac only, and never evicted:

```sh
oss files add ~/Downloads/apple-sdks-27.0.tar.gz   # hashed, kept (an APFS clone); prints its URL
oss files list
oss files remove <sha256>
```

A dependency lists each server's URL, its own Mac's first (by tailnet name:
this Mac's VMs and containers reach it that way too), and Bazel takes the
token from the same `.netrc` as the cache's:

```starlark
urls = ["http://<a Mac's tailnet name>:7490/files/sha256/<sha256>", ...],
sha256 = "<sha256>",
```

### From other computers

`oss` reaches the server through the addresses in
`~/.config/oss/client.json`, tried in order; the first that answers is
used for the API, SSH, VNC and adb:

```json
{"servers": ["http://127.0.0.1:7480", "http://<server>.local:7480", "http://<server's VPN address>:7480"]}
```

The API's token goes in `~/.config/oss/token` (mode 600), copied from the
server's. Keep it secret.

### From a program: OSSClient

```swift
// Package.swift: .package(url: "https://github.com/AttilaTheFun/oss", from: "0.1.0"),
// and the product "OSSClient".
import OSSClient

let client = OSSClient(server: URL(string: "http://127.0.0.1:7480")!, token: token)
let capabilities = try await client.capabilities()
let lease = try await client.lease(LeaseRequest(platform: .ios))
try await client.release(lease.id)
```

A container's commands (`exec`) go straight to it, over its Unix socket:

```swift
let (input, feed) = AsyncStream<ExecFrame>.makeStream()   // .stdin(data), .closeStdin, .signal(15), .resize(...)
let status = try await client.exec(lease, ExecRequest(arguments: ["make", "test"], workingDirectory: "/src"), input: input) { frame in
    if case .stdout(let data) = frame { FileHandle.standardOutput.write(data) }
}
```

`OSSClient.exec(socket:…)` does the same with the lease's `execSocket`
alone: no server or token, for a process that runs a long command in a
container (an agent's host) and should go on whatever the server does.

`OSSPool` leases from several servers as one: from the nearest (this
computer, then the LAN, then the tailnet) that has a base for the machine
and room for it, a container only from this computer's own. It returns the
lease and the client of the server that lent it:

```swift
let pool = OSSPool(entries: [OSSServerEntry(name: "MacBook Pro", servers: [here], token: { ... }),
                             OSSServerEntry(name: "Mac mini", servers: [minisLAN, minisTailnet], token: { ... })])
let (client, lease) = try await pool.lease(LeaseRequest(platform: .ios), waitForCapacity: true)
```

Requests go through URLSession; pass another `OSSTransport` (one
method: a request in, status, headers and body out) where that can't
reach the server, or to fake the server in tests (macOS lets only Apple's
own tools reach the LAN without the user's leave, so the CLI goes through
`curl`). The token can be a closure, asked on every request
(`OSSClient(server:token: { try await secrets.ossToken() })`), and
`timeout` bounds every request but a long poll (its wait and a minute
more). Errors are `OSSError`, with the server's own message.

## The API

Every request but `/v1/hello` and `/v1/capabilities` carries
`Authorization: Bearer <token>`: the server's. The monitor token (OS
Monitor's, from its connection code) is accepted for `GET /v1/status`,
`/v1/usage`, `/v1/usage/history`, `/v1/volumes` and `/v1/cache` (without
the cache's read token) and refused for everything else.
Bodies are JSON; errors are `{"error": "…"}`. A client says the API level
it speaks in an `OSS-API` header (OSSClient does): one below 6 is shown no
containers, which it couldn't read.

| Method and path | Does |
| --- | --- |
| `GET /v1/hello` | `{"server": "oss"}`: is this an oss server |
| `GET /v1/capabilities` | its version, API level, features and platforms |
| `GET /v1/status` | bases, capacity, leases |
| `GET /v1/doctor` | whether the server can drive UTM, simulators and emulators |
| `POST /v1/machines` `{"platform", "config"?, "minutes"?, "holder"?, "sshPublicKey"?, "container"?}` | a lease (state `creating`; poll it until `ready`). A container's `container` is a `ContainerSpec` (`image`, `cpus`, `memoryBytes`, `diskBytes`, `mounts`, `volumes`, `rosetta`, `environment`, `workingDirectory`, `command`); `minutes: 0` holds it until released; only a client on the server's Mac gets one |
| `GET /v1/machines`, `GET /v1/machines/<id>` | leases; one lease: ports, VNC password, UDID, adb port… |
| `POST /v1/machines/<id>/renew` `{"minutes"?}` | its time set again |
| `DELETE /v1/machines/<id>` | released |
| `PUT /v1/machines/<id>/files/<name>` (raw body) | a file for its commands, as `@<name>` (a `.zip` is unpacked: an `.app`) |
| `POST /v1/machines/<id>/simctl` or `/adb` `{"arguments": [...]}` | `simctl` against the simulator / `adb` against the emulator: `{"status", "output", "error"}` |
| `GET /v1/machines/<id>/screenshot` | a PNG of its screen |
| `POST /v1/machines/<id>/input` `{"action": "tap"\|"swipe"\|"type"\|"key", "x"?, "y"?, "toX"?, "toY"?, "milliseconds"?, "text"?, "key"?}` | a tap, swipe, text or key on its screen, in its screenshot's pixels |
| `GET /v1/usage` | the server's CPU and memory, and each lease's (its processes on the Mac; 100% CPU is one core), against what it was given; from API 5 also OS Server's share (`ours`), everyone else's (`others`), the disk and OS Server's files on it (`disk`), and the other apps using the most (`topProcesses`) |
| `GET /v1/usage/history` | the last day of the server's Mac, a sample a minute: CPU, memory and disk, OS Server's and everyone else's |
| `GET /v1/volumes`, `DELETE /v1/volumes/<name>` | containers' volumes (size, disk taken, the lease using one); a kept one deleted (from the server's Mac) |
| `GET /v1/cache` | the Bazel cache's port and read token, its size and how many lookups it answered (404 without one) |

A container lease's commands go to its Unix socket (`execSocket`), a
stream of frames each way: a kind byte, the payload's length (four bytes,
big-endian), the payload. The client's first is `start` (7, an
`ExecRequest` as JSON: `arguments`, `tty`, `columns`, `rows`,
`environment`, `workingDirectory`), then `stdin` (0), `closeStdin` (1),
`resize` (2, columns and rows as four bytes each), `signal` (6, Linux's
number); the container's are `stdout` (3), `stderr` (4) and last `exit`
(5, the status as four bytes).

The Bazel cache is on a port of its own (7490): `GET`, `HEAD` and `PUT` of
`/ac/<sha256>` and `/cas/<sha256>`, with the read or the write token as
`Authorization: Bearer <token>` or as Basic's password (what Bazel sends
from a `.netrc`).

`oss mcp` serves the machine commands as [Model Context
Protocol](https://modelcontextprotocol.io) tools on stdio (`oss_status`,
`oss_lease`, `oss_renew`, `oss_release`, `oss_ssh`, `oss_simctl`,
`oss_adb`, `oss_screenshot`), for programs that speak it.

## Setting it up (the server's Mac)

1. **OS Server**, the app: put `OS Server.app` in /Applications and open
   it (from a checkout, `App/build.sh --install`). It is the server (in its
   own process), and shows what the Mac and each lease use: CPU, memory
   and disk against what each was given, the capacity per platform, the
   Bazel cache, the server's log, and **Screen** beside a VM's lease for
   its screen, live. Closing its window leaves it in the menu bar (no Dock
   icon). Quitting it keeps every lease: each machine runs in a process of
   its own, taken up again when it starts.
2. **Set Up**: its first launch asks what this Mac lends; Settings ›
   Components adds or removes any later. Each component is installed from
   a download, or a file you give it, with no one at its screen, into OS
   Server's folder, and removed on its own:
   - **Linux containers**: the kernel (Kata Containers' arm64 build, as
     Apple's `container` uses) and Containerization's init; Rosetta, if
     the Mac hasn't it (the system asks). macOS 26 or later.
   - **macOS VMs**: the newest macOS this Mac runs, from Apple's restore
     image (or an `.ipsw` you give it), installed and `runner` made with
     no one at its screen (macOS 27 here), then the vanilla layer.
   - **Ubuntu VMs**: Ubuntu 26.04's arm64 cloud image (checked against
     Ubuntu's SHA256SUMS), GNOME, `runner` and OS Server's key set up by
     cloud-init, then the vanilla layer; about five minutes.
   - **Windows VMs**: Windows 11 on Arm from Microsoft's ISO, downloaded
     as Microsoft's page downloads it and checked against the SHA-256 the
     page lists (about 9 GB, kept; or an ISO you give it, should Microsoft
     refuse), installed by an answer file in about fifty minutes: Windows' own drivers for its disk (NVMe),
     screen and input, Fedora's virtio-win (signed Arm64 drivers,
     downloaded and checked) for its network card and GPU (1920 × 1080),
     OpenSSH with OS Server's key, then the vanilla layer. It installs with
     Windows' generic key: activate it yourself.
   - **Android emulators**: Google's emulator, platform-tools and an
     Android 15 phone image, from Google's repository (no Java).
   - **iOS simulators**: an iPhone simulator of the newest runtime Xcode
     has. Xcode is the one thing OS Server takes from outside.

   A base's `runner` gets a password OS Server makes and keeps
   (`guest-passwords.json`); a lease carries it.
3. **Its command line**: Settings › Install in ~/.local/bin links
   `~/.local/bin/oss` to the app's own (the same version as the server).

Everything else it needs is inside it: QEMU for the Linux and Windows VMs
(Homebrew's, with its libraries, made to stand alone by
`tools/bundle_qemu.py`; `Contents/Resources/qemu/SOURCES.txt` says which
versions, whose sources are QEMU's and Homebrew's), AXe for a simulator's
input (MIT), the machines' helper, the layers' provisioning scripts, and
its own SSH key, made the first time. It needs no Homebrew and no UTM.
Settings › **Remove Everything** ends every lease and deletes all it keeps,
so moving the app to the Trash afterwards leaves the Mac as it was.

**A server from before 0.9** keeps what it has: its UTM bases (`useUTM`,
on where UTM is installed) and the user's `~/.ssh/id_ed25519` as its key
(written into its settings at the first start, since its bases trust it).
A Mac still running `oss serve` from the launch agent (`./install.sh
--service`, before 0.6) shows "Another server answers": **Run It Here
Instead** unloads the agent and starts the app's. Without the app,
`./install.sh` puts the command line in `~/.local/bin`; on a client,
`./install.sh` alone.

OS Server's files are `~/Library/Application Support/OS Server` (on Linux
`~/.config/oss`, `~/.local/state/oss` and `~/.local/share/oss`): its
settings, its token, the leases (`State/`), the macOS bases (`Machines/`).
0.7's first start moves them there from where an earlier oss kept them.
Settings (`server.json` there, every field optional):

```json
{"port": 7480, "capacity": {"macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2, "container": 4},
 "defaultMinutes": 60, "maxMinutes": 480, "defaultConfig": {"macos": "vanilla", "ios": "iphone", "android": "phone"},
 "managementKey": "<OS Server's folder>/ssh/id_ed25519"}
```

A Bazel cache (off without `"cache"`; `{}` for these defaults):

```json
{"cache": {"port": 7490, "directory": "<OS Server's folder>/State/bazel-cache", "maxGigabytes": 20,
           "minFreeGigabytes": 30, "lanReads": false, "tailnetReads": true}}
```

`"lends": ["macos"]` lends only those platforms, and leaves every other
platform's machines alone, however they're named (a server deletes the
clones it doesn't hold of each platform it lends); `"useUTM": false`
leaves UTM out. With `OSS_HOME` (a folder of its own, a port and a port
range of its own), that is a second server to try a change beside a
running one.

`"headlessVMs": true` runs Linux and Windows leases without UTM's windows:
a clone has its displays taken away before it starts (UTM opens a window
for each), and its graphics card goes on QEMU's own command line beside
its VNC, so its screen is still there for screenshots, input and VNC. A
macOS lease keeps its display, and so its window: an Apple VM without one
has no screen for Screen Sharing to show.

The VM bases' `runner` passwords, if you want leases to carry them (for
logging in at a VM's screen, or unlocking it):
`guest-passwords.json` in OS Server's folder, mode 600, `{"macos": "…", "linux":
"…", "windows": "…"}` (or `"macos/xcode-27.0"` for one config).

Keep the installers (`*.ipsw`, `*.iso`) in this folder if you like: they
are ignored by git. Keep the folder out of backups.

## Bases, and making them your own

Every lease is a clone of a base, so whatever you put in a base, every
lease has. Bases are named `oss-<platform>-<config>`; the config is what a
lease asks for. oss makes **vanilla** ones: the operating system as it
comes, with only what oss needs to manage it. Build your own on top of
them (a base with your tools, one per Xcode version, a simulator with
your app installed, an emulator signed in to a test account), and rebuild
one whenever it should change: leases made after have the change.

### VMs (macOS, Linux, Windows)

OS Server makes the first base of each platform itself, its component
(above), or from the command line on the server's Mac:

```sh
oss image install macos base [--ipsw=PATH]                 # macOS 27 here; then:
oss image build macos vanilla --from=base
oss image install linux base [--image=<a cloud image>]     # Ubuntu 26.04 by default
oss image build linux vanilla --from=base
oss image install windows base --iso=<Windows 11 on Arm's ISO> [--edition="Windows 11 Pro"]   # or: oss component install windows
oss image build windows vanilla --from=base
```

Each takes `--cpus`, `--memory` and `--disk` (GB). The vanilla layer
(`provision/<platform>/vanilla`): `runner` logged in at boot, sudo without
a password, SSH by the server's key only, no sleep, lock, update notice or
first-run welcome. Bases are folders in `Machines/<platform>/`: macOS's run
on Apple's Virtualization, a lease's in a helper of its own (`oss-machine
macos`, a launchd job); Linux's and Windows' on its QEMU, each in a QEMU
process of its own, with QEMU's own NAT (the guest is 10.0.2.15, the Mac
10.0.2.2), SSH forwarded to a loopback port, and the screen QEMU's VNC.
Either way a lease's machine outlives OS Server's restarts, and one whose
process is gone (the Mac restarted, it crashed, its guest shut down) is
started again from its own disk, its lease and ports kept.

One manual step remains for macOS: once, at its live view (OS Server's
Screen while a layer builds, or a lease of it), System Settings → General →
Sharing → **Screen Sharing** on (only that switch lets Screen Sharing
capture the screen; a script can't turn it on).

**From UTM** (a server before 0.9): UTM's macOS VMs become OS Server's own
with `oss image import-utm <name> [--as=<config>]` (an APFS clone: no
space, a moment); each start takes in every `oss-macos-` VM UTM has whose
config OS Server hasn't got of its own. UTM's Linux and Windows bases keep
being lent from UTM while `useUTM` is on, until OS Server has its own of
the same config.

**Your own layers.** `oss image build <platform> <config> --from=<base config> --script=PATH [--copy=HOST:GUEST,…]`
clones `oss-<platform>-<base>`, boots it, copies in what `--copy` names
(rsync over SSH), runs the script over SSH as `runner` (`.sh`, or `.ps1`
on Windows), shuts it down cleanly and names it `oss-<platform>-<config>`.
For example, a layer with Homebrew and Git on macOS:

```sh
# tools.sh
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)" && brew install git
```

`oss image build macos tools --from=vanilla --script=tools.sh`, and leases
ask for `--config=tools`. A layer with this Mac's Xcode (Apple's licence
lets it run in a VM on the same Mac) copies it in:
`oss image build macos xcode-27.0 --from=tools --copy=/Applications/Xcode.app:/Applications/Xcode.app --script=xcode.sh`,
where `xcode.sh` accepts the licence and installs the platforms
(`sudo xcodebuild -license accept; sudo xcodebuild -runFirstLaunch; xcodebuild -downloadPlatform iOS`).

### iOS simulators

`oss image build ios <config> [--device="iPhone 17 Pro"] [--runtime=<id>] [--script=PATH]`
makes a simulator named `oss-ios-<config>`, boots it once, runs the
script with its UDID in `OSS_UDID`, and shuts it down. Without a script
it's a vanilla simulator. In a script: `xcrun simctl install "$OSS_UDID"
My.app`, `xcrun simctl privacy "$OSS_UDID" grant photos com.example.app`,
`xcrun simctl addmedia "$OSS_UDID" photo.jpg`. A lease is `simctl clone`
of it (an APFS clone of the device's directory).

### Android emulators

`oss image build android <config> [--api=35] [--tag=google_apis] [--script=PATH]`
makes an AVD named `oss-android-<config>` (a phone: 1080×2400, 4 GB),
boots it cold, runs the script with `ANDROID_SERIAL` and `ADB` set, and
saves its state as the `default_boot` snapshot. Without a script it's a
vanilla emulator. In a script: `"$ADB" install app.apk`, `"$ADB" shell
settings put …`, `"$ADB" shell pm grant …`. A lease is an APFS clone of
the AVD's directory (`cp -c`), started from that snapshot (`-feature
AllowSnapshotMigration`: its path differs from the base's) with nothing
saved back. For another device shape, edit the generated `config.ini`
(`~/.local/share/oss/avd/oss-android-<config>.avd`) and rebuild the
snapshot.

## How it works, and what bit

- **A macOS lease's VM runs in a helper** (`oss-machine macos <helper.json>`,
  the launchd job `oss.machine.<name>`: Virtualization's
  `VZVirtualMachine`, headless). Its socket (`$TMPDIR/oss/<name>.sock`)
  answers `status`, `screen` and `stop`; Screen opens the helper's own
  window (`VZVirtualMachineView` must be in the machine's process), the app
  yielding its activation to it. Installs and layer builds run in OS
  Server's process, their Screen in its window. A base's folder holds the
  hardware model and machine identifier it was installed with; a lease
  clones the folder (clonefile: the disk's blocks are shared until
  written) and gives the clone a network card of its own, so the NAT's
  DHCP server gives it an address of its own. A Mac runs at most two macOS
  VMs at once (Apple's limit), UTM's and OS Server's together.
- **macOS's local network privacy** refuses connections to UTM's network
  and the LAN from binaries that aren't Apple's unless the user allows
  them. So oss reaches guests and other computers only through Apple's own
  `ssh`, `nc` and `curl`: forwarded ports carry each connection through `nc`.
- **Each VM clone gets a MAC of its own** (clones keep their base's), and
  its address is found by that MAC in macOS's DHCP leases
  (`/var/db/dhcpd_leases`), with `utmctl ip-address` as a fallback.
- **A VM lease is ready when its desktop is**: SSH takes the key (an SFTP
  handshake, which starts no shell: PowerShell takes half a minute to start
  on a fresh Windows clone) and runner's desktop is up. It takes the
  server's time zone.
- **VNC.** UTM's QEMU has no DES, so QEMU's VNC server (Windows, Linux)
  listens without a password on the server's loopback, and the forwarder
  in front of it asks the client for the lease's password itself. macOS's
  Screen Sharing needs `VNCAlwaysStartOnConsole` (else a password-only
  viewer gets a new login window) and its System Settings switch turned
  on once (else black frames). QEMU's VNC can't show a GL display: use
  non-GL cards (`virtio-ramfb`, `virtio-gpu-pci`).
- **Windows bases must be settled**: booted once after any change and
  shut down from inside, or every clone shows "Getting devices ready" for
  minutes. `image build` restarts a Windows clone and waits for its
  desktop before sealing it.
- **UTM's scripting** edits a VM's settings as a record that can only be
  changed outside its `tell` block, and answers a VM it has only just made
  with `-600` for a moment (oss retries). `utmctl` prints `OSStatus error
  -10004` for commands that work.
- **UTM must not be hidden** (⌘H, or launched with `open -j`): starting a
  VM opens its window, which a hidden UTM answers with an exception
  (`-[NSWindow _changeJustMain]`); the start never finishes, and since UTM
  handles scripting one request at a time, every request after it times
  out (`-1712`) until UTM is restarted. Run it as usual, in the background
  (`open -g -a UTM`). A permission prompt waiting for an answer (oss → UTM)
  holds every request the same way.
- **Ubuntu hangs on a reboot from inside** under UTM; leases are never
  rebooted. A clone that doesn't come up is made again, once.
- **Credentials for Bazel's HTTP cache**: a `.netrc` (or a credential
  helper), or `--remote_header`; `--remote_cache_header` never reaches an
  HTTP cache (Bazel 9.1). oss uses `.netrc`, so no bazelrc holds a token
  (`--announce_rc` prints a bazelrc's lines). In a bazelrc a header's value
  must be quoted: an unquoted `Authorization=Bearer <token>` is two words,
  the second taken for a target and printed in the error.
  Bazel warns once a build that the credentials go in plaintext; they stay
  on the Mac's own networks (its bridges), which is also how the cache
  tells a VM or container from the LAN: by the bridge subnets the Mac has
  at that moment (vmnet makes them as VMs and containers start).
- **PowerShell reads a script from standard input a line at a time**
  (`-Command -`), which breaks a here-string: Windows scripts are one line
  per command.
- **macOS's Screen Sharing offers Apple's own authentication first**
  (type 30, ARD) and VNC's password (type 2) after it. A VNC client must ask
  for type 2 by name (oss's own does); one that takes the first offered
  asks for a macOS user and password instead of the lease's VNC password.
- **A lease's usage** is its processes on the server's Mac: a VM's are those
  with files open in its `.utm` bundle (`lsof`: UTM's QEMU, or
  Virtualization's VM service), a simulator's its `launchd_sim` and what it
  started, an emulator's its process tree. CPU is `ps`'s decaying average;
  memory each process's physical footprint, as Activity Monitor counts it
  (resident sizes count shared libraries once a process, and a simulator's
  hundred processes added up to six times its memory).
- **Emulators** use oss's own adb server port (5137) so they never meet
  another adb on the Mac, and keep running when the server restarts
  (launchd's job leaves its process group alone).

## License

Apache License 2.0: see [LICENSE](LICENSE).
