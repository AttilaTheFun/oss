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
- **A Bazel cache** (if you want one): one job writes what it builds (CI's,
  after each merge), and the server's VMs, its containers and the Mac
  itself read it, so a fresh machine downloads what was built instead of
  building it again.

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

Default capacity: two of each VM platform (16 GB each), four simulators
and two emulators. All of it is configurable.

oss is for machines with a screen. It ran Linux containers too until
0.3.0; containers for agents now belong to the program that runs the
agents (Visor runs its own), and oss stays with what needs a GUI.

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

### Self-hosted CI

```yaml
- run: oss machine run macos --config=xcode-27.0 --minutes=90 -- ci/test-in-vm.sh
```

or `oss machine lease linux --exports >> "$GITHUB_ENV"`, then `$OSS_SSH '…'`
in later steps and `oss machine release "$OSS_ID"` in an `if: always()`
step.

### A Bazel cache

With `"cache"` in its settings (below), the server keeps a [Bazel remote
cache](https://bazel.build/remote/caching) on its port 7490, Bazel's HTTP
protocol. It has two tokens, made with it in `~/.config/oss/`:

- **The read token** is for everyone. Every VM lease is set up with it:
  runner's `.bazelrc` names the cache, read-only
  (`--noremote_upload_local_results`), and the token is in runner's
  `.netrc`, where Bazel's HTTP cache takes credentials from. On this Mac,
  or a computer of its own, `oss cache use` writes the same two files
  (`oss cache use --remove` takes them away); a program gets the token
  from `GET /v1/cache`. Reading is for the server's Mac, its VMs and its
  containers: the LAN can't read unless `lanReads` says so.
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
`Authorization: Bearer <token>`: the server's.
Bodies are JSON; errors are `{"error": "…"}`.

| Method and path | Does |
| --- | --- |
| `GET /v1/hello` | `{"server": "oss"}`: is this an oss server |
| `GET /v1/capabilities` | its version, API level, features and platforms |
| `GET /v1/status` | bases, capacity, leases |
| `GET /v1/doctor` | whether the server can drive UTM, simulators and emulators |
| `POST /v1/machines` `{"platform", "config"?, "minutes"?, "holder"?, "sshPublicKey"?}` | a lease (state `creating`; poll it until `ready`) |
| `GET /v1/machines`, `GET /v1/machines/<id>` | leases; one lease: ports, VNC password, UDID, adb port… |
| `POST /v1/machines/<id>/renew` `{"minutes"?}` | its time set again |
| `DELETE /v1/machines/<id>` | released |
| `PUT /v1/machines/<id>/files/<name>` (raw body) | a file for its commands, as `@<name>` (a `.zip` is unpacked: an `.app`) |
| `POST /v1/machines/<id>/simctl` or `/adb` `{"arguments": [...]}` | `simctl` against the simulator / `adb` against the emulator: `{"status", "output", "error"}` |
| `GET /v1/machines/<id>/screenshot` | a PNG of its screen |
| `GET /v1/cache` | the Bazel cache's port and read token, its size and how many lookups it answered (404 without one) |

The Bazel cache is on a port of its own (7490): `GET`, `HEAD` and `PUT` of
`/ac/<sha256>` and `/cas/<sha256>`, with the read or the write token as
`Authorization: Bearer <token>` or as Basic's password (what Bazel sends
from a `.netrc`).

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
5. **The bases**, below. `oss doctor` says what's ready.

Settings (`~/.config/oss/server.json`, every field optional):

```json
{"port": 7480, "capacity": {"macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2},
 "defaultMinutes": 60, "maxMinutes": 480, "defaultConfig": {"macos": "vanilla", "ios": "iphone", "android": "phone"},
 "managementKey": "~/.ssh/id_ed25519"}
```

A Bazel cache (off without `"cache"`; `{}` for these defaults):

```json
{"cache": {"port": 7490, "directory": "~/.local/state/oss/bazel-cache", "maxGigabytes": 20,
           "minFreeGigabytes": 30, "lanReads": false}}
```

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
- **Bazel's HTTP cache takes credentials only from a `.netrc`** (or a
  credential helper): `--remote_cache_header` reaches gRPC caches, not an
  HTTP one. And an unquoted `Authorization=Bearer <token>` in a bazelrc is
  two words, the second taken for a target and printed in the error.
  Bazel warns once a build that the credentials go in plaintext; they stay
  on the Mac's own networks (its bridges), which is also how the cache
  tells a VM or container from the LAN: by the bridge subnets the Mac has
  at that moment (vmnet makes them as VMs and containers start).
- **PowerShell reads a script from standard input a line at a time**
  (`-Command -`), which breaks a here-string: Windows scripts are one line
  per command.
- **Emulators** use oss's own adb server port (5137) so they never meet
  another adb on the Mac, and keep running when the server restarts
  (launchd's job leaves its process group alone).

## License

Apache License 2.0: see [LICENSE](LICENSE).
