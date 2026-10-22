# oss: OS Server

> [!WARNING]
> **Early and experimental.** oss is young: its API and behaviour may
> change between versions (`GET /v1/capabilities` says what a server
> offers), and it has been run on a few Macs only.

A server on a Mac that lends out operating systems, for CI, for testing,
for automation, for anything that needs a machine of its own for a while:

- **Machines**, each its own for as long as its holder needs it: macOS,
  Windows and Linux VMs ([UTM](https://mac.getutm.app)), iOS simulators and
  Android emulators. Every one is a clone of a **base**: an APFS clone,
  ready in seconds, taking no disk until it changes, deleted when it's
  released or its time runs out.
- **Containers**: Linux containers of any image (Apple's
  [`container`](https://github.com/apple/container) on a Mac; Podman or
  Docker when oss runs on Linux), with commands run in them as processes
  whose input a client writes and whose output it reads from any offset,
  their home kept on the server, archived and restored at will.

One binary, `oss`, is the server (`oss serve`) and the command line. The
command line calls the server's HTTP API, which programs can call too:
Swift ones through the `OSSClient` library in this package.

| Platform | What a lease is | Ready in | Reached through |
| --- | --- | --- | --- |
| `macos` | a UTM VM (Apple Virtualization) | ~20 s | SSH and VNC (Screen Sharing), forwarded |
| `linux` | a UTM VM (QEMU) | ~30 s | SSH and VNC (QEMU's), forwarded |
| `windows` | a UTM VM (QEMU) | ~40 s | SSH (PowerShell) and VNC (QEMU's), forwarded |
| `ios` | a simulator on the server's Mac | ~7 s | `oss machine simctl` (install, launch, openurl, …), screenshots |
| `android` | an emulator on the server's Mac | ~6 s | `adb connect <server>:<port>`, or `oss machine adb` |

Default capacity: two of each VM platform (16 GB each), four simulators,
two emulators, eight containers. All of it is configurable.

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
oss machine run windows -- ./test.sh           # lease, run with OSS_* set, release
```

A lease names its platform and, optionally, a **config**: which base it's
cloned from. oss makes vanilla bases (below); a server can have as many
more as its owner builds. A lease that isn't renewed is released when its
time runs out (60 minutes unless asked otherwise, at most 480). `renew`
and `release` take the lease's id, or its platform when you hold just one.

### Containers

```sh
oss container start                            # Ubuntu, as it comes; prints its id
oss container start --image=my-image --label=job=1234 --cpus=4 --memory=8g --env-file=job.env
oss container exec <id> -- uname -a            # a process in it, its output followed
oss container exec <id> --input -- sh -c 'cat > notes.txt' < notes.txt
oss container cp ./project <id>:work/project   # files in (directories too) and out of its home
oss container stop <id>                        # stopped, kept
oss container restart <id>                     # a stopped one started; an archived one restored into a new container
oss container archive <id>                     # its home as a tarball (the path is printed), its container deleted
oss container start --from=/path/to/<id>.tar.gz   # a home brought in from an archive
oss container remove <id>                      # its container, home and archive deleted
oss container list | shell <id> | logs <id>
```

oss keeps a container running with a command of its own (the image's
entrypoint set aside: all an image needs is `/bin/sh`), so any image will
do. What runs in it runs as a **process**: its input a pipe the client
writes to, its output and errors files on the server that the client
reads from any offset, while the process runs on its own; the client (or
the server) can go away and pick up where it left off.

A container's home (`/root`) is a directory on the server,
`~/.local/state/oss/containers/<id>/`. Archiving tars it to
`~/.local/state/oss/archives/<id>.tar.gz`, leaving out the container's own
token, the server's template files (below), the files it was started with
as `secretFiles`, and oss's own `~/.oss`.

**Its own token.** Every container has an oss token of its own, in its
home with the server's address (`~/.config/oss/token` and `client.json`):
`oss` (or anything that speaks the API) inside it leases machines as the
holder `container-<id>`. That token reaches the container's own leases and
nothing else; they're released when the container is archived or removed.
From the container, the server's computer is the container's
`hostAddress` (192.168.64.1 under Apple's container).

**Settings for every container, and per image.** The server's
`~/.config/oss/container.env` (KEY=VALUE lines) gives every process
variables; `~/.config/oss/container-home/` holds files copied into every
new home where it lacks them. An image can have its own:
`~/.config/oss/images/<image>.env` and `~/.config/oss/images/<image>.home/`
(`<image>` is the image's name with anything but letters, digits, `.`, `_`
and `-` as `_`: `my-image`, `docker.io_library_ubuntu_24.04`). Variables a
request gives win over all of them. These are the place for credentials
an image's programs need: they reach only the containers of that image,
and archives never carry them.

On Linux, `oss container …` runs containers on that computer itself with
Podman or Docker when it reaches no server (or with `--local`).

### Self-hosted CI

```yaml
- run: oss machine run macos --config=xcode-27.0 --minutes=90 -- ci/test-in-vm.sh
```

or `oss machine lease linux --exports >> "$GITHUB_ENV"`, then `$OSS_SSH '…'`
in later steps and `oss machine release "$OSS_ID"` in an `if: always()`
step.

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

let container = try await client.startContainer(ContainerRequest(labels: ["job": "1234"]))
let process = try await client.startProcess(container.id, ProcessRequest(command: ["uname", "-a"]))
var offset = 0
while true {
    let chunk = try await client.output(container.id, process.id, from: offset, wait: 30)
    offset = chunk.offset
    if chunk.state != .running && chunk.data.isEmpty { break }
}
try await client.remove(container: container.id)
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
`Authorization: Bearer <token>`: the server's, or a container's own, which
reaches `/v1/status` and `/v1/machines…` for that container's leases only.
Bodies are JSON; errors are `{"error": "…"}`.

| Method and path | Does |
| --- | --- |
| `GET /v1/hello` | `{"server": "oss"}`: is this an oss server |
| `GET /v1/capabilities` | its version, API level, features, platforms, and whether it runs containers |
| `GET /v1/status` | bases, capacity, leases, containers |
| `GET /v1/doctor` | whether the server can drive UTM, simulators, emulators and containers |
| `POST /v1/machines` `{"platform", "config"?, "minutes"?, "holder"?, "sshPublicKey"?}` | a lease (state `creating`; poll it until `ready`) |
| `GET /v1/machines`, `GET /v1/machines/<id>` | leases; one lease: ports, VNC password, UDID, adb port… |
| `POST /v1/machines/<id>/renew` `{"minutes"?}` | its time set again |
| `DELETE /v1/machines/<id>` | released |
| `PUT /v1/machines/<id>/files/<name>` (raw body) | a file for its commands, as `@<name>` (a `.zip` is unpacked: an `.app`) |
| `POST /v1/machines/<id>/simctl` or `/adb` `{"arguments": [...]}` | `simctl` against the simulator / `adb` against the emulator: `{"status", "output", "error"}` |
| `GET /v1/machines/<id>/screenshot` | a PNG of its screen |
| `POST /v1/containers` `{"holder"?, "image"?, "archive"?, "environment"?, "secretFiles"?, "labels"?, "cpus"?, "memory"?}` | a container (its `labels`: a client's own names for it; `cpus`/`memory` ("4g")/`image`: else the server's defaults) |
| `GET /v1/containers[?label=key=value]`, `GET /v1/containers/<id>` | containers (those labelled so): state, home, archive, labels, `hostAddress` |
| `POST /v1/containers/<id>/stop`, `/archive`; `/restart` `{"environment"?}` | as the commands; stopping and archiving send its running processes SIGTERM first and give them 10 s |
| `DELETE /v1/containers/<id>` | removed |
| `GET /v1/containers/<id>/files/<path>` | a file in its home (relative to `/root`); a directory as a gzipped tarball (`OSS-Kind: directory`) |
| `GET …/files/<path>?from=N&wait=S&limit=N` | a file followed as it grows: its bytes from byte N, waiting up to S seconds (at most 60) while there's nothing new; `OSS-Size` (its length now: below N, it shrank or was replaced) and `OSS-Offset`; 404 until it exists |
| `PUT /v1/containers/<id>/files/<path>` (raw body) `?unpack=1` | a file written; with `unpack`, a gzipped tarball unpacked into that directory |
| `DELETE /v1/containers/<id>/files/<path>` | removed |
| `POST /v1/containers/<id>/processes` `{"command": [...], "environment"?, "directory"?}` | a process: `{"id", "state", "status", "pid", "outputSize", "errorSize", …}` |
| `GET /v1/containers/<id>/processes`, `…/processes/<p>` | processes: `running`, `exited` (with `status`) or `lost` (its container stopped under it) |
| `GET …/processes/<p>/output?stream=out\|err&from=N&wait=S&limit=N` | its output (or errors) from byte N, waiting up to S seconds (at most 60) while there's nothing new; `OSS-Offset`, `OSS-State`, `OSS-Status` |
| `POST …/processes/<p>/input` (raw body) `?close=1` | bytes for its input, in order; `close` then ends it (end of file) |
| `POST …/processes/<p>/signal?signal=TERM\|KILL\|INT\|HUP` | signalled |

`oss mcp` serves the machine commands as [Model Context
Protocol](https://modelcontextprotocol.io) tools on stdio (`oss_status`,
`oss_lease`, `oss_renew`, `oss_release`, `oss_ssh`, `oss_simctl`,
`oss_adb`, `oss_screenshot`), for programs that speak it.

## Setting it up (the server's Mac)

1. **oss**: `./install.sh` builds it, signs it with the Mac's Apple
   Development identity if it has one (so macOS's permissions survive
   rebuilds) and puts it in `~/.local/bin`. `./install.sh --service` also
   runs `oss serve` under launchd (`~/Library/LaunchAgents/oss.server.plist`,
   log `~/Library/Logs/oss.log`). On a client, `./install.sh` alone.
2. **UTM** (VMs): `brew install --cask utm` (5.0.8 or later), and its CLI
   on PATH: `ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /opt/homebrew/bin/utmctl`.
   The first time oss drives UTM, macOS asks whether `oss` may control it:
   **Allow** (System Settings → Privacy & Security → Automation, if a
   "Don't Allow" needs undoing; while a prompt waits, UTM answers no one).
3. **Xcode** (simulators): any Xcode with the iOS runtime you want.
4. **Android**: `oss setup android [--api=35] [--tag=google_apis]` puts
   the emulator, platform-tools and a system image in
   `~/.local/share/oss/android-sdk`, from Google's repository (no Java).
5. **Containers**: `brew install container && container system start`,
   then `oss setup containers` pulls the default image (Ubuntu 24.04).
6. **The bases**, below. `oss doctor` says what's ready.

Settings (`~/.config/oss/server.json`, every field optional):

```json
{"port": 7480, "capacity": {"macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2}, "containerLimit": 8,
 "defaultMinutes": 60, "maxMinutes": 480, "defaultConfig": {"macos": "vanilla", "ios": "iphone", "android": "phone"},
 "managementKey": "~/.ssh/id_ed25519", "containerImage": "docker.io/library/ubuntu:24.04", "containerCPUs": 2,
 "containerMemory": "4g"}
```

Apple's container gives a container one CPU more than it's asked for
(`containerCPUs` 2 shows 3 inside).

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

The first base of each platform starts with an OS install in UTM's
window (UTM reads only installers a person picks there), then
`oss image build <platform> vanilla --from=base` makes `oss-<platform>-vanilla`:
the `runner` account (logged in at boot, sudo without a password), SSH by
the server's key only, no sleep or screen lock (`provision/<platform>/vanilla`).

- **macOS** (Virtualize → macOS 12+, the IPSW, 16 GB, 6 cores, 192 GB,
  named `oss-macos-base`): **Save, don't start it.** Then
  `OSS_GUEST_PASSWORD=<password> oss image provision-macos --vm=oss-macos-base --install`
  installs macOS and sets it up with no clicks (UTM's provisioning, macOS
  27 on host and guest): `runner` logged in at boot, SSH with the server's
  key, a fixed-resolution display. Once, in its window: System Settings →
  General → Sharing → **Screen Sharing** on (only that switch lets Screen
  Sharing capture the screen). Then `oss image build macos vanilla --from=base`.
- **Windows 11** (Virtualize → Windows, the ISO, "Install drivers and
  SPICE tools", 16 GB, 6 cores, 128 GB; display card `virtio-ramfb`, not
  `-gl`): a local account `runner`; UTM's guest tools from its CD; then
  `provision/windows/bootstrap.ps1` (the server's public key in it) in an
  administrator's PowerShell. Name it `oss-windows-base`, shut it down,
  `OSS_GUEST_PASSWORD=<password> oss image build windows vanilla --from=base`.
- **Ubuntu Desktop** (Virtualize → Linux, the ISO, QEMU, display
  `virtio-gpu-pci`, 16 GB, 6 cores, 128 GB): user `runner`, no disk
  encryption; then `sudo apt-get install -y openssh-server` and the server's
  key in `~/.ssh/authorized_keys`. Name it `oss-linux-base`, shut it down,
  `oss image build linux vanilla --from=base`.

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

### Container images

Containers run Ubuntu 24.04 as it comes unless they name an image. Use
any image a container tool can pull, or build your own:

```dockerfile
FROM docker.io/library/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*
```

`oss image build container my-image --dockerfile=path/to/Dockerfile [--context=DIR]`,
then `oss container start --image=my-image` (or make it the default with
`server.json`'s `containerImage`). oss sets the image's entrypoint aside,
so an image's own is never run; settings and credentials for its
programs go in `~/.config/oss/images/<image>.env` and `.home/` (above).

## How it works, and what bit

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
- **Processes in a container** run under oss's runner (`~/.oss/run`,
  written into every home, so any image works), started with the
  container tool's detached exec: the command's input is a FIFO in the
  container, held open by a placeholder writer until the client closes it
  (a write is one `exec … cat`, ~60 ms); its output, errors, pid and exit
  status are files in the home, which the server reads directly. A symlink
  the container makes is resolved as the container sees it (`/root` is
  the home): one that leads out of the home is refused, not followed onto
  the server's own files.
- **Containers can't resolve `.local` names** (no mDNS inside); other
  computers are reached as from the server (its LAN and VPN, through its
  NAT), by address or a name its DNS answers.
- **Emulators** use oss's own adb server port (5137) so they never meet
  another adb on the Mac, and keep running when the server restarts
  (launchd's job leaves its process group alone).

## License

Apache License 2.0: see [LICENSE](LICENSE).
