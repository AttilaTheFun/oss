# Changelog

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
