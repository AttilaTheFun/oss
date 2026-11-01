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
- **Storage**: files kept by their SHA-256 while a lease of their holder's
  lasts (a build to install on a simulator, a test's output), and URLs
  that do one thing with them without the server's token (grants).

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
| `ios` | a simulator on the server's Mac | ~7 s | `oss machine simctl` (install, launch, openurl, …), screenshots, `oss machine xctest` |
| `android` | an emulator on the server's Mac | ~6 s | `adb connect <server>:<port>`, or `oss machine adb` |

What it lends is limited two ways (Limits, below): a count cap for a type
where server.json sets one (by default only macOS's two, Apple's limit),
and a memory budget that every lease counts against (by default the
Mac's memory less what macOS keeps). A type with no cap takes whatever
the budget has room for; CPUs are shared out, at most `maxCPUs` a
machine.

A simulator's and an emulator's status bar is held still from the moment
it's ready (9:41, full Wi-Fi and battery; on iOS full signal and no
carrier, and on an iPad, which shows the date, 9 January 2007; on Android
no cellular network and no notifications), so
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
  process's, and what's free; what's running, and whose (CI's, a
  session's, an agent's, by hand); the other apps using the most; OS
  Server's files.
- **Adding a server:** with the code in OS Server's Settings › OS Monitor (a
  QR code, or Copy Code), or from `oss monitor code` on a server run
  without the app.
- **What the code allows:** it carries a monitor token that reads and does
  nothing else.

## Using it

### Machines

```sh
oss machine lease linux                        # an Ubuntu VM for an hour; prints how to reach it
oss machine lease macos --config=xcode_27_2 --minutes=120   # a base of the server's own (oss status lists them)
oss machine lease ios                          # an iPhone simulator
oss machine lease ios --device="iPad Pro 13-inch (M5)"      # an iPad (any type the server's Xcode has; below)
oss machine lease android --wait               # an emulator, waiting for a free one
oss machine renew <id | platform> --minutes=60
oss machine release <id | platform>            # deleted; the place is free

oss machine ssh <id> [-- command…]             # VMs
oss machine vnc <id> --open                    # VMs: VNC address and the lease's password
oss machine simctl <id> install ./My.app       # iOS: local paths are uploaded first
oss machine simctl <id> launch com.example.app
oss machine xctest <id> --tests=Tests.zip      # iOS: rules_apple's tests on its simulator (below)
oss machine adb <id> install ./app.apk         # Android (or: adb connect <host>:<adbPort>)
oss machine screenshot <id> screen.png         # any lease
oss machine tap <id> 120 480                   # any lease: in the screenshot's pixels
oss machine swipe <id> 500 1600 500 400 --ms=400
oss machine type <id> hello world              # into what has focus
oss machine key <id> return                    # names, a VM's cmd+a, or the platform's code
oss machine upload <id> ./build ~/build        # VMs (scp; download the other way)
oss machine run windows -- ./test.sh           # lease, run with OSS_* set, release
oss machine list                               # every lease: its kind, holder, time and label
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

An **iOS lease of another device type** (API 11): `--device` takes any
iPhone or iPad the server's Xcode has (`xcrun simctl list devicetypes`),
by its name (`"iPad Pro 13-inch (M5)"`, `"iPhone 18 Pro"`) or its
identifier (`com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB`,
or just `iPad-Pro-13-inch-M5-12GB`), in any case; `--runtime` an iOS
runtime it has (`"iOS 27.0"`, `27.0` or its identifier). The simulator is
made of that type, on that runtime (else the config's base's), and set up
as the config's base was (its first boot, the script the base was built
with, the status bar held still); without either, it's a clone of the base,
as before, and so is one that asks for the base's own type. It takes
longer than a clone (a first boot: about a minute). A type the server
hasn't got, or one the runtime doesn't run, is refused with the close ones
(`"ipad pro"`: every iPad Pro), or every iPhone and iPad the runtime runs.
`oss machine list`, the lease's JSON (`device`, `runtime`), OS Server's
window and OS Monitor say which each iOS lease is.

Every lease says who it is for (API 8), so a server's leases can be told
apart wherever they're shown (`oss machine list` and `oss status`, OS
Server's window and menu bar, OS Monitor, a volume's lease):

- **Its kind**: `ci` (a CI job's), `session` (a Visor session's own
  machine: the container it runs in), `agent` (a machine an agent in a
  session leased for its work) or `manual` (someone's at a terminal).
- **A label**, a short line (a session's title, a CI job's name), and **a
  link** to a page about it (the CI run's).
- **Labels** (API 12), names and values its holder gave it, kept with it
  and returned with it: what a program that leases finds its own by
  (`oss container-host`'s, Visor's session and server). At most 32; a name
  is letters, digits and `. _ - /`, at most 100 of them; a value one line.

`oss machine lease` and `oss machine run` take `--kind`, `--label` and
`--link`. In a GitHub Actions job a lease with no `--kind` is `ci`,
labelled `<repository> · <workflow> #<run id> · <job>` and linked to the
run, from the variables the runner sets; `oss mcp`'s leases are `agent`.
A lease that says no kind (from a client before API 8, or one that left
it out) is taken by its holder: Visor's, `visor:<session>`, are a
`session` for a container and an `agent` for anything else; any other
holder's are `manual`.

### Limits

A lease is granted only while its type's cap and the server's memory
budget both have room for it:

- **Caps**, a type's leases at once, where server.json's `limits` names it
  (`{"macos": 2, "windows": 1}`); by default only macOS's two (Apple's
  limit of macOS VMs a Mac runs at once). A type it doesn't name has no
  cap.
- **The budget**, `budget.memoryGB`, which every lease's memory counts
  against, summed over the leases held: how many VMs and containers, and
  how large, the server lends at once. By default the Mac's memory less
  what macOS and its own apps keep (16 GB or a quarter, whichever is more,
  never more than half); macOS pages out what doesn't fit, so past it
  every lease slows down, and the Mac with them.
- **What isn't OS Server's leases** takes its memory out of the budget:
  every other VM on the Mac (Virtualization's, each in its
  `com.apple.Virtualization.VirtualMachine` XPC service, whatever app
  made it: an agent's containers, Podman's, Apple's `container`'s; and
  QEMU's), every other process, and OS Server itself, by their footprint.
  OS Server reads the Mac's process table every 15 seconds (libproc: each
  process's executable, parent, footprint and CPU time, the process
  responsible for it, a VM's open files), and tells its own leases' VMs,
  simulators and emulators from the rest by their processes. Whatever the
  budget, the Mac keeps its reserve: the leases' use (each the more of its
  size and its footprint) and everything else's together stay under the
  Mac's memory less the reserve.
- **CPUs are shared out, not budgeted**: most machines leave most of
  theirs idle, and at worst everything slows down. One VM or container may
  have at most `maxCPUs` (by default the Mac's cores); a lease asking for
  more is refused.
- **A lease's size** (`Lease.size`): a VM's is its base's (what
  `machine.json` gives it; a UTM base's the estimate until it is made), a
  container's what it asks for (`--cpus`, `--memory`; else 4 and 8 GB),
  and a simulator's and an emulator's memory an estimate, 2 GB and 4 GB
  (server.json's `sizes`), while they run on the Mac itself.

Past a limit a lease is refused, 409 `busy` naming the one that is full
(`busy: macos 2 of 2 leased`, `busy: memory 120 of 128 GB leased; this
needs 16`, `busy: memory 100 of 112 GB taken (20 of it outside OS Server's
leases); this needs 16`, `busy: memory 45 of the Mac's 48 GB in use (it
keeps the rest for itself); this needs 4`); one with more memory than the
whole budget, or more CPUs than `maxCPUs`, is 409 `tooBig`, which no wait
would get. With `--wait` (`waitForCapacity`), it asks again every 15
seconds with a ticket of its own (`waitTicket`), and keeps its place in
line, oldest first, while it does. Each lease is granted as soon as its own
limits allow, whatever waits for other ones, but the oldest in line is
kept room for: a later lease (waiting or not) that would fit only by
taking room it needs, its type's next place or the memory it waits for,
waits too (`busy: a macos lease waiting 3 min goes first (…)`). `oss
status` shows the budget and what takes it, each type's cap, the line,
and the Mac by whom: OS Server's leases (memory as given and as used, CPU,
disk), OS Server itself, the other VMs by the app they are for (their
footprint, CPU and, where their open files say, disks), everything else
with the apps of it using the most, and the disk free.

### Containers

OS Server's app also lends Linux containers (API 6, macOS 26 or later):
each a lightweight VM of its own on Apple's
[Containerization](https://github.com/apple/containerization), from an
image in a registry. Since API 9 a container is lent to a client anywhere:
on the server's Mac, on another Mac, or in a container itself (an agent
that runs a server under test in a container of its own, so a crash takes
out the server and not the agent). Only a client on the server's own Mac
may share that Mac's folders into it (`--mount`).

```sh
oss machine lease container --image=ghcr.io/owner/agent:1.2 --cpus=6 --memory=16 \
    --mount=$HOME/Developer/app:$HOME/Developer/app --mount=/Applications/Xcode.app:/Applications/Xcode.app:ro \
    --volume=app-build:/var/cache/bazel:128:keep --rosetta --minutes=0
oss machine lease container --image=postgres:17 --port=5432 --env=POSTGRES_PASSWORD=test   # from anywhere
oss machine exec <id> -- uname -a                     # streamed; its exit status is exec's
oss machine exec <id> --workdir=/src --env-file=agent.env -- ./agent --stdio
oss machine exec <id> --tty -- bash                    # a terminal
oss machine exec --socket=<execSocket> -- make         # by the lease's socket: no server or token needed
oss machine upload <id> build/server /usr/local/bin/server   # a file, its mode kept (--mode=755 for another)
oss machine download <id> /var/log/server.log ./server.log
tar -c -C ./src . | oss machine exec <id> -- sh -c 'mkdir -p /src && tar -x -C /src'   # a folder
oss machine list                                       # a container's ports: 5432 → <host>:47512
oss volume list                                         # volumes, kept ones too
oss volume delete app-build
```

- **The image** is pulled once and kept by its digest; its root filesystem
  is unpacked once at the size asked for (`--disk`, 64 GB by default) and
  cloned for each container, so a second container of an image starts in
  about a second. An unpacked image no container has been made from in two
  weeks is deleted.
- **Mounts** share a folder of the Mac's, read-only with `:ro`: for a
  client on the server's Mac only. From anywhere else a lease with one is
  refused (403, `notLocal`); put files in with `oss machine upload` (or
  exec, as an archive), or keep them on a volume.
- **Volumes** are disks of their own by name (ext4, allocated as they
  fill): one already there at the size asked for is used again. A volume
  is deleted with its lease unless it is kept (`:keep`); `oss volume delete`
  removes a kept one, once no lease is using it, from the server's Mac.
- **Ports** (`--port=N`, as many as 16, TCP): each of the container's is
  forwarded from a port of the server's Mac, taken from the range VMs'
  SSH and VNC come from (`firstPort`…`lastPort`), so a VM's and a
  container's never meet. Reached on every interface: this Mac, the LAN,
  the tailnet. The lease says where (`Lease.ports`: the container's port,
  the server's host as the asker reached it, the Mac's port), `oss machine
  lease` and `list` show `5432 → <host>:47512`, `--exports` gives
  `OSS_PORT_5432=<host>:47512`. They're the lease's until it ends, and
  follow the container when it starts again.
- **Rosetta** (`--rosetta`) runs x86_64 Linux programs, where the Mac has
  Rosetta.
- **The network** is NAT (vmnet's shared mode): the container reaches the
  internet and the Mac's LAN addresses, the server's API and its Bazel
  cache included. Every container is on the same one (since 0.14),
  `192.168.127.0/24` unless server.json's `containerSubnet` names another:
  the Mac is `.1` there, each container's gateway and DNS (vmnet's DNS
  proxy), and each container has an address and a MAC address of its own
  until its lease ends, the same when it starts again. The network is kept
  by a process of its own (`oss-machine network`, the launchd job
  `oss.network`), started before the first container and kept while OS
  Server runs, restarts or is updated: a lease ending gives its address
  back and takes no network down. (Until 0.14 each container made a
  network of its own and took it down when it ended; macOS, taking one
  network's bridge down, could take another live one's bridge address and
  route with it, and leave its container with a gateway that answered
  nothing.) With the owner not answering, a container doesn't start, and
  says so; it never makes a network of its own.
- **Held until released:** `--minutes=0` (a container only) is never
  reclaimed: for an agent's container, which lives as long as its session.
- **It outlives the server.** Each container runs in a helper process of
  its own (`oss-machine container`, a launchd job of OS Server's), so quitting,
  restarting or updating OS Server leaves it, and the commands running in
  it, running; OS Server takes it up again when it starts. After the Mac's
  restart, or if its helper ends, OS Server starts it again from its own
  disk.
- **exec** goes to the container directly on the server's Mac, over its
  Unix socket (`Lease.execSocket`), not through the server. From anywhere
  else it goes through the server (`POST /v1/machines/<id>/exec`, below),
  which relays the same frames, and waits for a container that is starting
  again. stdin goes in with its end; stdout and stderr come back apart;
  TERM, INT, HUP, QUIT, USR1 and USR2 sent to `oss machine exec` go on to
  the command, and if `oss machine exec` ends first, so does the command
  (TERM, then KILL ten seconds on). `--env-file` keeps secrets out of the
  command line.
- **Files** go through the server, from this Mac too: `oss machine upload`
  puts a file at a path in the container (relative to its working
  directory, `~/` its home; its folders made; written beside it and moved
  into place only once all of it has come), `download` reads one back. A
  folder goes as an archive through exec. They go through the container's
  `/bin/sh` (`cat`, `wc`, `mkdir`, `mv`, `chmod`), which an image without a
  shell hasn't got.
- What it runs: the image's own environment and working directory, the
  lease's over them, and by default a process that waits (`--command`
  names another): the work is done with exec.

#### A container host for Visor

`oss container-host` is OS Server as a Visor Server's container host
(Visor's [docs/container-host.md](https://github.com/AttilaTheFun/visor/blob/main/docs/container-host.md)):
set in Visor Server's settings (`visor-server containers host
/usr/local/bin/oss container-host`), its sessions' containers are this
server's container leases, so they are counted and shown with
everything else it lends.

```sh
oss container-host health                      # {"ok", "version", "api": 1, "limits"}: needs API 12
oss container-host create < request.json       # {"id", …}: a container lease, once its network resolves names
oss container-host exec <id> [--tty] [--workdir=DIR] [--env-file=F] -- command…   # oss machine exec's
oss container-host put <id> <path> [--mode=600] < bytes
oss container-host rm <id> [--volumes]         # released, and gone, before it answers
oss container-host ls                          # its containers, with their labels
oss container-host network <id>                # {"ok", "dns", "reach", "detail"}
```

- Each container is a lease held until released (`minutes: 0`), its kind
  `session`, its holder the container's name (with a key,
  `<name>@<application>`), its volumes kept when it goes, so one made
  again by the same name finds them.
- It is labelled with the request's labels (`visor.session`,
  `visor.server`) and two of the host's (`oss.container-host.name`, the
  request's digest), by which `ls` finds them and `create` asked again
  answers the one the same request made (another of that name is
  `exists`).
- It uses this computer's client settings (`~/.config/oss/client.json`,
  its key or token), never Visor's, unless `--server=URL` and
  `--key-file=FILE` (before the operation) name a server and a key. A
  session's folder is a mount, which needs the server's own Mac: where the
  settings name another server first, give this Mac's
  (`--server=http://127.0.0.1:7480`).

### Storage

Files kept on the server for a while, by their content's SHA-256: a build
to install on a simulator, a test's output to look at later. Each is held
by a **lease** of its holder's (`OSS_HOLDER`, else user@host; a Visor
session's is `visor:<session>`), for 24 hours unless asked otherwise (at
most 7 days), renewed or released as a machine's is. An object no lease
holds is deleted within a minute.

```sh
oss storage put build/My.ipa --name=My.ipa --ttl=2h   # its bytes go only if the server hasn't got them
oss storage ls                                        # your leases: id, sha256, size, name, until when
oss storage get My.ipa ./My.ipa                       # by name or sha256
oss storage renew My.ipa --ttl=24h
oss storage rm My.ipa
oss machine install <ios lease> My.ipa                # an .ipa or a zipped .app of yours, on its simulator
```

- **Kept once.** Bytes put twice, by anyone, are one file. A put asks first,
  by the hash, whether the server has them, and sends none if it has.
- **Names** are the holder's own: a put with a name already used moves it
  to the new object (the lease that had it is released).
- **Caps**: 20 GB a holder and 100 GB in all (`"storage"` in its settings,
  below). A put past either is refused before its bytes are sent (413,
  `quota`).
- **Beside the served files** (below), in `Files/sha256/` in OS Server's
  folder: a served file is held by the server itself, for good, and a
  holder's object isn't served on the cache's port. The holders' leases are
  `State/storage-leases.json`.

**Grants.** Whoever holds the API's token (Visor) can hand out a URL that
does one thing, on one lease or object of a holder's, for a few minutes (5
unless asked otherwise, at most 15), with no token: what an agent in a
container gets from its session, which keeps the token.

```sh
oss grant storage.put --name=My.ipa --object-ttl=2h   # prints the URL
oss storage put build/My.ipa --url=<the URL>           # in the container: no token
oss grant storage.get My.ipa                           # then: oss storage get --url=<the URL> ./My.ipa
oss grant machine.install <ios lease>                  # then: oss machine install --url=<the URL> My.ipa
oss grant machine.xctest <ios lease>                   # then: oss machine xctest --url=<the URL> --tests=Tests.zip …
oss grant machine.exec <container lease>               # then: oss machine exec --url=<the URL> -- make test
oss grant machine.upload <container lease>             # then: oss machine upload --url=<the URL> ./app /srv/app
oss grant machine.download <container lease>           # then: oss machine download --url=<the URL> /srv/log ./log
```

A container's files have a verb each way, as the store's do: a grant that
puts files in a container reads none out of it. `machine.xctest` runs
tests on its iOS lease and reads what they leave (a run's JUnit and result
bundle).

A grant's URL is the route it opens with `?grant=…`: its claims (the verb,
the lease or object, the holder, when it expires; for a put, the name and
TTL its lease will get) and an HMAC-SHA256 of them under a key only the
server has. It works any number of times until it expires, on that route
alone (an xctest's, and its runs' results below it); anything else gets the
same 403, whatever was wrong.

Its `url` names the server as the grant's asker reached it (`127.0.0.1` on
the server's Mac); its `path` (`oss grant --json`) is the same grant at any
of the server's addresses. `--url` takes either: a path goes to the first
of the computer's servers that answers (`client.json`, or `OSS_SERVERS`), as
the commands with the token do, so a grant made on the server's Mac works
from its containers and from other computers.

### iOS tests

A Linux container builds rules_apple's iOS targets (with
[rules_applecross](https://github.com/AttilaTheFun/rules_applecross), as
rules_apple builds them on a Mac) but can't run them. An `ios` lease runs
them on its simulator, as `bazel test` runs them on a Mac (rules_apple's
`ios_xctestrun_runner`), since API 10:

```sh
oss machine lease ios
oss machine xctest <id> --tests=bazel-bin/app/HelloWorldTests.zip                      # a logic test
oss machine xctest <id> --tests=bazel-bin/app/HelloWorldAppTests.zip --host=bazel-bin/app/HelloWorld.ipa
oss machine xctest <id> --tests=bazel-bin/app/HelloWorldUITests.zip --host=bazel-bin/app/HelloWorld.ipa --ui \
    --only-testing=HelloWorldUITests/testLaunch --junit=test.xml --result=HelloWorldUITests.xcresult.zip
```

- **What it takes**: what `bazel build` of an `ios_unit_test` or
  `ios_ui_test` leaves, on a Mac or on Linux: the test bundle's
  `<name>.zip` (holding `<name>.xctest`; or a `.xctest` folder zipped),
  and the test host's `.ipa` (or a zipped `.app`), which a hosted unit test
  and a UI test need and a logic test doesn't. A file is put in your
  storage first (by its file's name); anything else names an object you
  have there (by sha256 or name). On a Mac, a `.xctest` or `.app` folder is
  zipped first.
- **On the server**, as rules_apple's runner does on a Mac: the bundles
  unpacked into a folder of the run's own in the lease's (xcodebuild's
  `__TESTROOT__`), made writable; for a UI test, `<bundle>-Runner.app`
  made from Xcode's XCTRunner.app (the bundle in its PlugIns, XCTest's
  frameworks in its Frameworks, its Info.plist naming it; unsigned, as a
  simulator needs); the .xctestrun from rules_apple's template, as its
  runner fills it in; then `xcodebuild test-without-building` against the
  lease's simulator, `-only-testing` for each `--only-testing` (under the
  bundle's name unless it has it; XCTest's `Class/method` or Swift
  Testing's `Suite/function()`), the result bundle and derived data in the
  run's folder, and no test diagnostics (xcodebuild's `simctl diagnose` of
  a failing run, which can take ten minutes).
- **What comes back**: xcodebuild's output as it comes, and its exit
  status, which is `oss`'s (0 passed, 65 a test failed; 1 if it passed
  with no test run, as rules_apple's runner fails it). The run's result
  bundle (`--result`, zipped) and its JUnit (`--junit`: each bundle a
  suite, each test a case under its suites, with its failures' messages or
  why it was skipped, from `xcresulttool`'s report of the result bundle)
  are kept as long as the lease, by the run's id.
- **One run at a time a lease**: another is refused (409, `busy`). `oss
  machine xctest` ending (Ctrl-C) ends its run: the server stops
  xcodebuild (SIGINT, then ten seconds on SIGKILL for it and what it
  started), and a run asked for meanwhile waits for it.
- **From a container** without the token: `oss grant machine.xctest
  <lease>` on the session's side, then `oss machine xctest --url=<grant>
  --tests=<object> …`, the bundles already in storage (put with a
  `storage.put` grant).

### Self-hosted CI

```yaml
- run: oss machine run macos --config=xcode_27_2 --minutes=90 -- ci/test-in-vm.sh
```

or `oss machine lease linux --exports >> "$GITHUB_ENV"`, then `$OSS_SSH '…'`
in later steps and `oss machine release "$OSS_ID"` in an `if: always()`
step. Either lease is shown as the job's (kind `ci`, its repository,
workflow, run and job, a link to the run) unless `--kind` says otherwise.

A job in a container, on the runner's own Mac (where its folder can be
mounted): `--inside` runs the command in the container, in the runner's
folder (mounted at its own path), its output and exit status passed
through, and the lease released however it ends: a signal goes on to the
command, and SIGTERM (a runner cancelling the job: SIGINT, then SIGTERM,
then SIGKILL) releases the lease at once. A `run` lease is for five
minutes, renewed each minute while it runs, so a job killed outright frees
its lease and volumes within five minutes. A volume named `:keep` (Bazel's
tree, warm from one job to the next) stays when the lease goes; one
without it is deleted with the lease. `--cache=<host>` has its Bazel read this server's
cache there (`~/.bazelrc`, read-only), and `--cache` and `--netrc=<host>`
put the cache's read token in its `~/.netrc` for each host its build names
the server by, so Bazel's cache and downloader (the files served by
SHA-256) take it:

```yaml
- run: >
    oss machine run container --image=<a builder image> --rosetta
    --mount="$PWD:$PWD" --volume=<repo>-ci:/var/cache/bazel:128:keep
    --inside --cache=<this Mac's tailnet name> -- bazel test //...
```

### CI in OS Server's containers (0.14)

OS Server can run a repository's GitHub Actions jobs itself, each in a
container of its own, with no runner to register by hand: it finds the
queued jobs that ask for a label it serves, makes a just-in-time runner
for each (one job, then it exits) in a container lease of kind `ci`, and
deletes the container when the job ends. For now it does so for the
repositories server.json names, beside any runner they have already.

1. **A GitHub App** of the repositories' owner (Settings › Developer
   settings › GitHub Apps): repository permissions Actions read,
   Administration read and write (a just-in-time runner is a repository's
   runner) and Metadata read; no webhook (OS Server has no public address:
   it polls). Install it on the repositories.
2. **Its two files**, on the server's Mac, each mode 600 (OS Server refuses
   one anyone else may read): `~/.config/oss/ci-github-app.json`,
   `{"appId": 123456}` (and, if you like, `"repositories": ["owner/name",
   …]`, the most it may serve, and `"maxConcurrent": N`), and the App's
   private key beside it, `~/.config/oss/ci-github-app.pem`.
3. **server.json**'s `ci`, the repositories it runs jobs for and the label
   each one's jobs ask for (`<name>-ci` where none is given):

   ```json
   {"ci": {"repositories": ["owner/gh_mcp"], "labels": {"owner/gh_mcp": "gh_mcp-oss"}}}
   ```

   Also `maxConcurrent` (jobs at once: by default one for every 8 cores and
   32 GB, at most half the containers it lends: its cap, or as many of a
   job's as the budget holds; at least one), `image` (the jobs' image:
   Visor's agent image), `cpus` and `memoryGigabytes` (each
   job's container: 4 and 8), `pollSeconds` (5), `unclaimedMinutes` (10)
   and `serverURL` (the server as a job's container reaches it: by default
   this Mac's address on the containers' network).
4. OS Server started again. Its log says `ci: running GitHub Actions jobs
   for …`, or why CI is off; `oss ci list` too.

A workflow's job runs there by asking for `self-hosted` and the label, and
nothing else:

```yaml
jobs:
  test:
    runs-on: [self-hosted, gh_mcp-oss]
    steps:
      - uses: actions/checkout@v5
      - run: swift test
      - run: oss machine run macos --config=xcode_27_2 -- ci/test-in-vm.sh   # a VM, leased in the job's name
```

- **How it finds them**: every few seconds, each repository's queued and
  running workflow runs (`GET /repos/{repo}/actions/runs?status=…`) and
  their jobs, each asked again with the last answer's ETag, so an
  unchanged answer costs no rate limit; a failed look waits longer each
  time (what GitHub's rate limit says, else up to five minutes).
- **A runner a job**: `generate-jitconfig` (named `oss-<lease>`, the job's
  labels, the default runner group) in a container leased for it (kind
  `ci`, labelled `oss.ci.repository`, `oss.ci.run` and `oss.ci.job`, linked
  to the job's page), with GitHub's runner for Linux on arm64 (pinned and
  checked by its SHA-256, downloaded once) and `oss` for Linux in it, run
  `run.sh --jitconfig` as the image's user. A job still queued when its
  turn comes gets one; one cancelled, or taken by another runner, meanwhile
  is skipped. A runner no job came to in `unclaimedMinutes` (GitHub gave it
  to another) is given up, its container released and its registration
  deleted; a job still queued after its runner failed gets another, three
  at most. At most `maxConcurrent` at once, across repositories, the rest
  waiting in the order GitHub queued them; one waits too while the server's
  containers are all leased.
- **What a job may do**: its container holds no token or key of the
  server's, nor the App's. Its runner (and so each step) has `OSS_GRANT`, a
  grant's URL in the job's name (`<job>-<run>@ci`), which `oss` there
  uses in place of a key: it leases, uses, renews and releases machines
  (its own alone: another's is 404), puts and gets objects in storage, and
  reads the Bazel cache's token; it makes no grants and reads no keys,
  volumes or status. It works while the job's runner does; the job's
  leases and objects are released when it ends. A container leased from
  the job can't share a folder of the server's Mac (`--mount`): put files
  in with `oss machine upload` or on its standard input. `oss` is on the
  runner's PATH (`~/.local/bin/oss`): a script finds it by `command -v oss`
  where `/Applications/OS Server.app` isn't.
- **`oss` for Linux** is built by OS Server itself from the sources OS
  Server.app carries (`Resources/oss-source`; a checkout's with
  `OSS_REPO`), once for each version of them, in a container of the jobs'
  image, and kept in its folder's `CI/` with GitHub's runner: the first job
  after an update waits a few minutes for it.
- **Seen**: in OS Monitor's CI card (how many runners are in use of how
  many, each job waiting or running and why it waits, the last few that
  ended, each a link to its run), `oss ci list` (`--json`), `GET /v1/ci`
  or `GET /v1/ci/jobs`: each job's repository, workflow, name, page and
  run, state, why it waits, how long it waited and ran, and its lease,
  newest first, for a week. Its leases show in `oss status` and OS
  Monitor as any other `ci` lease.
- **Not yet**: a restart of OS Server ends the jobs running (their runners
  ran in its process's exec; GitHub fails them, and the runners' leases a
  restart leaves are released); jobs on VM runners; OS Server's window.
  Fork pull requests: a public repository's workflows keep them off
  self-hosted runners (`if: github.event.pull_request.head.repo.full_name
  == github.repository`), as with any.

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

**Files by their SHA-256.** The same port serves files as they are (so a
server serves them only with `"cache"` in its settings: `{}` will do), for
pinned Bazel dependencies too big or too private for anywhere else (an
Xcode SDK archive): `GET /files/sha256/<hex>`, read with the read token
and from the same places as the cache. The hash in the URL is the one a
dependency pins, so any server's copy is the same bytes and Bazel checks
them. They're added on the server's Mac only, and never evicted:

```sh
oss files add ~/Downloads/apple-sdks-27.0.tar.gz   # hashed, kept (an APFS clone); prints its URL
oss files list
oss files remove <sha256>                          # no longer served; its bytes go unless a storage lease holds them
```

They share their folder with storage's objects (above): each is held by a
lease of the server's own, its entry beside it (`<sha256>.json`), which
never expires and no holder sees among its own.

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

An application's API key goes in `~/.config/oss/key` (mode 600) or
`OSS_API_KEY`, made on the server's Mac with `oss keys create
<application> | …` (piped: it is shown once); `OSS_CLIENT_ID` says whom
the client acts for (`oss` sends it as `CLIENT_ID`). Through 0.14 the
server's shared token still works in `~/.config/oss/token` (or
`OSS_TOKEN`), as the `user` application. Keep either secret.

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

A program that leases for others says who each lease is for (API 8), as
Visor does for a session's container and its agents' machines:

```swift
let lease = try await client.lease(LeaseRequest(platform: .macos, holder: "visor:\(session)", kind: .agent, label: title))
```

A container's commands (`exec`) go straight to it over its Unix socket
where that is on this computer (the server's Mac), and through the server
from anywhere else:

```swift
let (input, feed) = AsyncStream<ExecFrame>.makeStream()   // .stdin(data), .closeStdin, .signal(15), .resize(...)
let status = try await client.exec(lease, ExecRequest(arguments: ["make", "test"], workingDirectory: "/src"), input: input) { frame in
    if case .stdout(let data) = frame { FileHandle.standardOutput.write(data) }
}
let file = try await client.uploadFile(lease.id, holder: lease.holder, file: binary, to: "/usr/local/bin/server", mode: "755")
try await client.downloadFile(lease.id, holder: lease.holder, path: "/var/log/server.log", to: log)
```

`OSSClient.exec(socket:…)` does the same with the lease's `execSocket`
alone: no server or token, for a process that runs a long command in a
container (an agent's host) and should go on whatever the server does.
`exec(_:holder:…)` always goes through the server.

Storage takes the holder with each call; a grant's URL needs no client
of the server's:

```swift
let put = try await client.putObject(file: ipa, holder: "visor:\(session)", name: "My.ipa")   // HEAD first: no bytes if it's there
let grant = try await client.grant(GrantRequest(verb: "machine.install", lease: lease.id), holder: lease.holder)
let installed = try await OSSGrantClient(url: grant.url).install(object: "My.ipa")           // no token
```

An iOS lease's tests (API 10), from bundles in storage:

```swift
let run = try await client.xctest(lease.id, holder: lease.holder, XCTestRequest(tests: "HelloWorldUITests.zip", host: "HelloWorld.ipa", ui: true)) { frame in
    if case .stdout(let data) = frame { FileHandle.standardOutput.write(data) }   // xcodebuild's output
}
let junit = try await client.xctestJUnit(lease.id, holder: lease.holder, run: run.id)   // run.status: xcodebuild's
```

`OSSPool` leases from several servers as one: from the nearest (this
computer, then the LAN, then the tailnet) that has a base for the machine
and room for it, a container with mounts only from this computer's own. It
returns the lease and the client of the server that lent it:

```swift
let pool = OSSPool(entries: [OSSServerEntry(name: "MacBook Pro", servers: [here], token: { ... }),
                             OSSServerEntry(name: "Mac mini", servers: [minisLAN, minisTailnet], token: { ... })])
let (client, lease) = try await pool.lease(LeaseRequest(platform: .ios), waitForCapacity: true)
```

Requests go through URLSession; pass another `OSSTransport` (one
method: a request in, status, headers and body out; a second, for an
object's body or answer as a file, reads and writes it whole unless the
transport streams it; a third, for an exec's connection, a socket of the
process's own unless the transport makes it) where that can't
reach the server, or to fake the server in tests (macOS lets only Apple's
own tools reach the LAN without the user's leave, so the CLI goes through
`curl`, and an exec to another computer through `nc`). The token can be a closure, asked on every request
(`OSSClient(server:token: { try await secrets.ossToken() })`), and
`timeout` bounds every request but a long poll (its wait and a minute
more). Errors are `OSSError`, with the server's own message.

## The API

Every request but `/v1/hello` and `/v1/capabilities` carries an
application's API key (API 12: in an `API_KEY` header, or as
`Authorization: Bearer <key>`), or the server's shared token as the
bearer, which stands for the `user` application through 0.14. With a key,
`CLIENT_ID` says whom the request acts for within its application (a CI
job, a Visor session): what it leases and stores is
`<CLIENT_ID>@<application>`'s (the holder it names stands in for a client
id it doesn't give; with neither, the application's own), and a lease's
kind follows from it (`…@ci` is `ci`; a Visor's application, `…-visor`,
gives its containers `session` and its other machines `agent`; any other
`manual`). With the token, a `CLIENT_ID` makes the holder
`<CLIENT_ID>@user`. The monitor token (OS
Monitor's, from its connection code) is accepted for `GET /v1/status`,
`/v1/usage`, `/v1/usage/history`, `/v1/volumes` and `/v1/cache` (without
the cache's read token) and refused for everything else. A grant's URL
(`?grant=…`, from `POST /v1/grants`) needs no token, on the one route it
was made for; a CI job's grant (API 13, its container's `OSS_GRANT`) as
its bearer, or as `?grant=`, on the routes a job's scripts use, in the
job's name, while its runner lasts. A storage request names its holder in an `OSS-Holder`
header (a grant's is its own); a holder sees and changes only its own
leases, and another's are 404. So does a request for a container's exec or
files with the token (API 9), and for an iOS lease's tests and their
results (API 10): the lease must be that holder's.
Bodies are JSON; errors are `{"error": "…", "code"?}`. A client says the API level
it speaks in an `OSS-API` header (OSSClient does): one below 6 is shown no
containers, which it couldn't read.

| Method and path | Does |
| --- | --- |
| `GET /v1/hello` | `{"server": "oss"}`: is this an oss server |
| `GET /v1/capabilities` | its version, API level, features and platforms |
| `GET /v1/status` | bases, capacity, leases; from API 14 the limits: `budget` (`memoryBytes`, the budget; `leasedMemoryBytes`, what the leases take; `outsideMemoryBytes`, what isn't theirs; `hostLimitBytes`, the Mac's memory less its reserve; `leasedCPUs`, the leases' CPUs together, shared out; `maxCPUs`, one machine's at most; `waiting`, the line oldest first, each one's `platform`, `config`, `holder`, `size`, `since` and `reason`, its last refusal), and `host`, the Mac by whom (`leases`, each lease's `memoryLimitBytes` as given, `memoryBytes` as used, `cpuPercent`, `diskBytes`; `server`, OS Server itself; `otherVMs`, by `owner` with `machines`, `memoryBytes`, `cpuPercent`, `diskBytes`; `rest` and `restTop`, everything else and its apps using the most; `disk`, the volume's `totalBytes` and `freeBytes`; `outsideMemoryBytes`); and each type's `capacity` its `cap` (absent: none), `used` and `size` (a lease of its default config), and `limit` how many may be held now (its cap, or fewer where the budget has room for fewer more), which a client before API 14 compares `leased` with as before; each lease's `size` (`cpus`, `memoryBytes`) |
| `GET /v1/doctor` | whether the server can drive UTM, simulators and emulators |
| `GET /v1/keys`, `POST /v1/keys` `{"application"}`, `DELETE /v1/keys/<application>` | the applications with keys (`application`, `created`; never a key); a new key for one, replacing its old one (`{"application", "key"}`, shown this once, kept as its SHA-256); its key taken away. On the server's own Mac and as `user` only (API 12) |
| `POST /v1/machines` `{"platform", "config"?, "minutes"?, "holder"?, "sshPublicKey"?, "container"?, "kind"?, "label"?, "link"?, "labels"?, "device"?, "runtime"?, "waitTicket"?, "build"?}` | a lease (state `creating`; poll it until `ready`), if its type's cap and the budget have room (Limits, above): else 409 `busy` naming the full limit, or `tooBig` for one with more memory than the whole budget or more CPUs than `maxCPUs`. `waitTicket` (API 14), the same on every try, keeps a lease waited for in line while it asks again within 45 seconds. `build` (API 14), a layer's name: a place for `oss image build`'s VM, admitted as its platform's lease of its base's (`config`'s) size, with no machine, kind `build`, ready at once, from the server's Mac only; `buildPID`, the building process, which it lasts as long as. A container's `container` is a `ContainerSpec` (`image`, `cpus`, `memoryBytes`, `diskBytes`, `mounts`, `volumes`, `rosetta`, `environment`, `workingDirectory`, `command`); `minutes: 0` holds it until released; only a client on the server's Mac gets one. `kind` is `ci`, `session`, `agent`, `manual` or (API 14) `build` (one a server doesn't know reads as `manual`; without one, the holder's: a `visor:` holder's container `session`, its other machines `agent`, anyone else's `manual`); `label` is kept to one line of at most 200 characters; `link` must be http or https (400 otherwise); `labels` (API 12), at most 32 names (letters, digits, `. _ - /`, at most 100) and one-line values, kept with the lease. An iOS lease's `device` (a device type's name or identifier) and `runtime` (an iOS runtime's name, version or identifier), any case (API 11): its simulator made of them, the config's base's for the one not given; one the server's Xcode hasn't got, or a type the runtime doesn't run, is 400 `noDevice`, naming the close ones; while simctl can't list the server's simulators (Xcode mid-update, CoreSimulator waiting on its first launch), an iOS lease is 400 `noInventory`, saying why, not `no ios base` |
| `GET /v1/machines`, `GET /v1/machines/<id>` | leases (each with its `kind`, `label`, `link` and `labels`; an iOS lease's `device` and `runtime`, by name); one lease: ports, VNC password, UDID, adb port…; a container's forwarded ports (`ports`: `{"port", "host", "hostPort"}`, `host` the server as the asker reached it) |
| `POST /v1/machines/<id>/renew` `{"minutes"?}` | its time set again |
| `DELETE /v1/machines/<id>` | released |
| `PUT /v1/machines/<id>/files/<name>` (raw body) | a file for its commands, as `@<name>` (a `.zip` is unpacked: an `.app`) |
| `POST /v1/machines/<id>/simctl` or `/adb` `{"arguments": [...]}` | `simctl` against the simulator / `adb` against the emulator: `{"status", "output", "error"}` |
| `GET /v1/machines/<id>/screenshot` | a PNG of its screen |
| `POST /v1/machines/<id>/input` `{"action": "tap"\|"swipe"\|"type"\|"key", "x"?, "y"?, "toX"?, "toY"?, "milliseconds"?, "text"?, "key"?}` | a tap, swipe, text or key on its screen, in its screenshot's pixels |
| `GET /v1/usage` | the server's CPU and memory, and each lease's (its processes on the Mac; 100% CPU is one core), against what it was given (and from API 8 its `kind`); from API 5 also OS Server's share (`ours`), everyone else's (`others`), the disk and OS Server's files on it (`disk`), and the other apps using the most (`topProcesses`) |
| `GET /v1/usage/history` | the last day of the server's Mac, a sample a minute: CPU, memory and disk, OS Server's and everyone else's |
| `GET /v1/ci` | CI as a whole (API 15): `maxConcurrent` (runners at most at once), `running` (in use), `repositories` (each `name` and `label`), `jobs` (as `GET /v1/ci/jobs`); 404 `noCI` as below. With the token, a key or the monitor token |
| `GET /v1/ci/jobs` | CI's jobs (API 13), newest first: each one's `id`, `repository`, `workflow`, `name`, `runID`, `url`, `runURL`, `branch`, `commit`, `labels`, `state` (`queued`, `starting`, `listening`, `running`, `completed`, `unclaimed`, `skipped`, `failed`), `queued`, `started`, `ended`, `waited` and `ran` (seconds), `lease`, `runner`, `result` (GitHub's), `error`, `waiting` (API 15: why a queued job waits, every runner in use or the limit that has no room); 404 `noCI`, saying why, from a server that runs none. With the token, a key or the monitor token |
| `GET /v1/volumes`, `DELETE /v1/volumes/<name>` | containers' volumes (size, disk taken, the lease using one and its `kind`); a kept one deleted (from the server's Mac) |
| `GET /v1/cache` | the Bazel cache's port and read token, its size and how many lookups it answered (404 without one) |
| `HEAD /v1/storage/objects/<sha256>` | 200 with its `Content-Length` if the store has it, else 404 |
| `PUT /v1/storage/objects?name=…&ttl=…` (raw body; `OSS-SHA256`?) | the body streamed to a file, hashed as it comes, checked against `OSS-SHA256` if given, kept once; then the holder's lease (`ttl` `90s`, `30m`, `24h`, `7d` or seconds: 24h unless given, at most 7d; `name`: the lease of the holder's that had it is released). 201 `{"object": {"sha256", "size"}, "lease", "existed"}`. With `OSS-SHA256` and no body, a lease on what the store has (404 `noObject` if it hasn't). Past a cap (its length counted as new bytes unless `OSS-SHA256` names what the store has), 413 `quota`, before the body is read |
| `GET /v1/storage/objects/<sha256>` | its bytes, streamed: for a holder with a lease on it, or a served file from where the cache serves them |
| `GET /v1/storage/leases` | the holder's leases (`id`, `holder`, `sha256`, `size`, `name`, `created`, `expires`) |
| `POST /v1/storage/leases/<id>/renew?ttl=…` | its time set again: `ttl` from now |
| `DELETE /v1/storage/leases/<id>` | released; its object goes at the next sweep unless another lease holds it |
| `POST /v1/grants` `{"verb", "lease"?, "object"?, "ttl"?, "name"?, "objectTTL"?}` | 201 `{"verb", "url", "path", "expires"}`: a grant in the holder's name, where the plain API would let it: `storage.put` (with the `name` and `objectTTL` its lease gets), `storage.get` (an object it holds, by sha256 or name), `machine.install` (an iOS lease it holds); from API 8 `machine.exec`, `machine.upload` and `machine.download` (a container lease it holds); from API 10 `machine.xctest` (an iOS lease it holds: its tests run, and their results read). `ttl` 5m unless given, at most 15m. `url` is the server as the asker reached it; `path` is the same for another address. Only with the API's token |
| `POST /v1/machines/<id>/install` `{"object"}` | an .ipa or a zipped .app the lease's holder holds (by sha256 or name) installed on its simulator: `{"object", "app", "bundleIdentifier"}` |
| `POST /v1/machines/<id>/exec` (`Connection: Upgrade`, `Upgrade: oss-exec`; body an `ExecRequest`, with its `Content-Length`) | a command in a container lease, from anywhere (API 8): `101 Switching Protocols`, then the exec socket's frames both ways (below), the server starting the command with the request and relaying the rest; a refusal is an answer as any other (404 another holder's lease, 409 `notReady`, 426 `upgrade` without the upgrade). The token with `OSS-Holder`, or a `machine.exec` grant |
| `PUT /v1/machines/<id>/files?path=…&mode=…` (raw body) | a file put in a container lease (API 9), streamed: at `path` (relative to its working directory, `~/` its home), its folders made, written beside it and moved into place once all of it has come; `mode` octal (else the container's umask's). 201 `{"path", "size"}`, the path absolute. The token with `OSS-Holder`, or a `machine.upload` grant |
| `GET /v1/machines/<id>/files?path=…` | a container lease's file, streamed (its length first); 404 `noFile` if there's none. The token with `OSS-Holder`, or a `machine.download` grant |
| `POST /v1/machines/<id>/xctest` (`Connection: Upgrade`, `Upgrade: oss-exec`; body an `XCTestRequest` `{"tests", "host"?, "ui"?, "onlyTesting"?}`, with its `Content-Length`) | tests on an iOS lease's simulator (API 10): `tests` (the test bundle's zip) and `host` (an .ipa or a zipped .app) are objects the lease's holder holds, by sha256 or name; `ui` a UI test (it needs `host`); `onlyTesting` xcodebuild's `-only-testing`. Made ready first, so a refusal is an answer as any other (400 a bundle that isn't one, 404 an object the holder hasn't got, 409 `busy` while the lease runs another); then `101 Switching Protocols` with the run's id (`OSS-XCTest-Run`), then the exec socket's frames (below): `stdout` xcodebuild's output, `stderr` the server's own notes, last `exit` xcodebuild's status. The connection closing first ends the run (xcodebuild stopped). The token with `OSS-Holder`, or a `machine.xctest` grant |
| `GET /v1/machines/<id>/xctest/<run>/junit`, `…/result` | a run's JUnit (XML, from its result bundle), or its result bundle zipped (`result.xcresult` inside; streamed); 409 `notReady` while it runs, 404 `noFile` if it made none; kept as long as the lease. The token with `OSS-Holder`, or the lease's `machine.xctest` grant |

The two object routes and a container's files stream (an object can be
gigabytes); a put that says `Expect: 100-continue` hears whether it's
refused before it sends a byte.
`Status` carries the store's use (`storage`: its objects and bytes against
its caps, the leases, and the served files).

A container lease's commands go to its Unix socket (`execSocket`), a
stream of frames each way: a kind byte, the payload's length (four bytes,
big-endian), the payload. The client's first is `start` (7, an
`ExecRequest` as JSON: `arguments`, `tty`, `columns`, `rows`,
`environment`, `workingDirectory`), then `stdin` (0), `closeStdin` (1),
`resize` (2, columns and rows as four bytes each), `signal` (6, Linux's
number); the container's are `stdout` (3), `stderr` (4) and last `exit`
(5, the status as four bytes).

From anywhere else (API 9), the same through the server:

```
POST /v1/machines/<id>/exec HTTP/1.1
Host: <server>:7480
Authorization: Bearer <token>          (or ?grant=… in the path, a machine.exec grant's)
OSS-Holder: <the lease's holder>       (with the token)
OSS-API: 8
Connection: Upgrade
Upgrade: oss-exec
Content-Type: application/json
Content-Length: <n>

{"arguments": ["make", "test"], "tty": false, "environment": {"A": "b"}, "workingDirectory": "/src"}
```

answered `HTTP/1.1 101 Switching Protocols` (`Connection: Upgrade`,
`Upgrade: oss-exec`), after which the connection carries the frames above
both ways, but `start`: the server starts the command with the request's
body, then relays the client's `stdin`, `closeStdin`, `resize` and `signal`
and the container's `stdout`, `stderr` and `exit` as they come. The
connection closing before `exit` ends the command, as the socket's does.

An iOS lease's xctest (API 10) is upgraded the same way, its body an
`XCTestRequest`: its `101` carries `OSS-XCTest-Run: <run>`, and then only
the server sends frames (xcodebuild's output as `stdout`, its own notes as
`stderr`, xcodebuild's status as `exit`); the client sends none, and its
connection closing before `exit` ends the run.

The Bazel cache is on a port of its own (7490): `GET`, `HEAD` and `PUT` of
`/ac/<sha256>` and `/cas/<sha256>`, with the read or the write token as
`Authorization: Bearer <token>` or as Basic's password (what Bazel sends
from a `.netrc`).

The machine commands are [Model Context
Protocol](https://modelcontextprotocol.io) tools too: `oss_status`,
`oss_lease`, `oss_container_lease`, `oss_renew`, `oss_release`, `oss_ssh`
(a VM), `oss_exec`, `oss_upload` and `oss_download` (a container's small
files), `oss_simctl`, `oss_adb`, `oss_install`, `oss_storage`,
`oss_grant` (a URL for what is too big for a call), `oss_screenshot`,
`oss_tap`, `oss_swipe`, `oss_type`, `oss_key` and `oss_usage`.

- `oss mcp` serves them on stdio, as this computer's client.
- The server serves them on a port of its own (API 12; `mcpPort` in
  server.json, 7481, 0 for none): Streamable HTTP, JSON-RPC `POST`ed and
  answered as JSON, no stream of its own. Every message carries an
  application's key (`API_KEY`, or as the bearer) and may carry
  `CLIENT_ID`; each call is made with them through the server's API, at
  the host the caller reached the MCP port by (so a grant's URL is one it
  can reach), a VM reached with the server's own key. A caller's files
  come by storage and grants (`oss_grant`), never paths of its own.
  Visor's MCP proxy passes it on to sessions with a Visor's key and
  `CLIENT_ID: $SESSION_ID`.

## Setting it up (the server's Mac)

1. **OS Server**, the app: put `OS Server.app` in /Applications and open
   it (from a checkout, `App/build.sh --install`). It is the server (in its
   own process), and shows what the Mac and each lease use: CPU, memory
   and disk against what each was given, the budget and the capacity per
   platform, the Bazel cache, the server's log, and **Screen** beside a
   VM's lease for its screen, live. Closing its window leaves it in the
   menu bar (no Dock icon). Quitting it keeps every lease: each machine
   runs in a process of its own, taken up again when it starts.
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
{"port": 7480, "limits": {"macos": 2}, "budget": {"memoryGB": 96}, "maxCPUs": 28,
 "sizes": {"ios": {"memoryGB": 2}, "android": {"memoryGB": 4}},
 "defaultMinutes": 60, "maxMinutes": 480, "defaultConfig": {"macos": "vanilla", "ios": "iphone", "android": "phone"},
 "managementKey": "<OS Server's folder>/ssh/id_ed25519"}
```

`limits` are the types' count caps (Limits, above: macOS's two unless
named; `null` takes a cap away, 0 lends none), `budget.memoryGB` the
memory every lease together may take (left out, its default from the
Mac: here a 128 GB Mac), `maxCPUs` the most CPUs one VM or container may
have (left out, the Mac's cores: here 28), `sizes` the memory taken for
the leases nothing measures (simulators, emulators). A server.json from
before 0.14 says `capacity`, read as `limits`: the types it names keep
their caps, and the others are limited by the budget alone.

A Bazel cache (off without `"cache"`; `{}` for these defaults):

```json
{"cache": {"port": 7490, "directory": "<OS Server's folder>/State/bazel-cache", "maxGigabytes": 20,
           "minFreeGigabytes": 30, "lanReads": false, "tailnetReads": true}}
```

Storage's caps (the store is kept without them, at these):

```json
{"storage": {"maxGigabytes": 100, "maxGigabytesPerHolder": 20}}
```

CI's jobs in its containers (off without `"ci"`, or without the GitHub
App's files: "CI in OS Server's containers", above):

```json
{"ci": {"repositories": ["owner/name"], "labels": {"owner/name": "name-oss"}, "maxConcurrent": 2}}
```

The containers' network's subnet (a private /16 to /28, written as its
network's address; the Mac takes its first address, containers the rest):

```json
{"containerSubnet": "192.168.127.0/24"}
```

The default stays clear of Apple's container (192.168.64.0/24) and of the
/24s vmnet takes, one after another from 192.168.64.0 up, for networks
asked for with no subnet; inside 192.168/16, as vmnet's own are, and no
router's usual LAN. Pick another if this Mac already has an interface on
it (the network's owner refuses to start on a subnet in use, and says
whose). A running network keeps the subnet it was made with: a new one
takes effect when its owner next starts (the Mac's restart).

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
"…", "windows": "…"}` (or `"macos/xcode_27_2"` for one config).

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
Its VM takes a place in the running server's limits before it starts, as a
lease does (Limits, above: macOS's cap, the memory budget): with both
macOS places leased it is refused, or with `--wait` waits in line for one,
and while it runs no lease is granted a VM the Mac won't start (a Mac runs
at most two macOS VMs). The place is a lease with no machine, kind `build`,
holder `image-build`, shown in `oss status` like any; it lasts as long as
the build's process (never expiring while it runs, released once it's
gone) and is given back when the build's VM has stopped, however the build
ended. `oss image install` and OS Server's own component installs take
one too. A build that fails deletes its clone (its `.building` folder).
With no server answering on the Mac it builds without a place, as before.
For example, a layer with Homebrew and Git on macOS:

```sh
# tools.sh
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)" && brew install git
```

`oss image build macos tools --from=vanilla --script=tools.sh`, and leases
ask for `--config=tools`. A layer with this Mac's Xcode (Apple's licence
lets it run in a VM on the same Mac) copies it in:
`oss image build macos xcode_27_2 --from=tools --copy=/Applications/Xcode.app:/Applications/Xcode.app --script=xcode.sh`,
where `xcode.sh` accepts the licence and installs the platforms
(`sudo xcodebuild -license accept; sudo xcodebuild -runFirstLaunch; xcodebuild -downloadPlatform iOS`).

### iOS simulators

`oss image build ios <config> [--device="iPhone 17 Pro"] [--runtime=<id>] [--script=PATH]`
makes a simulator named `oss-ios-<config>`, boots it once, runs the
script with its UDID in `OSS_UDID`, and shuts it down. Without a script
it's a vanilla simulator. In a script: `xcrun simctl install "$OSS_UDID"
My.app`, `xcrun simctl privacy "$OSS_UDID" grant photos com.example.app`,
`xcrun simctl addmedia "$OSS_UDID" photo.jpg`. A lease is `simctl clone`
of it (an APFS clone of the device's directory). The script's path is
kept (`Simulators/<config>.json` in OS Server's folder): a lease of
another device type or runtime (`--device`, `--runtime`) is a new
simulator, which the same script sets up after its first boot, so keep it
where it is, and write it for any iPhone or iPad.

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
- **The containers' network has one owner** (`oss-machine network
  <network.json>`, the launchd job `oss.network`, KeepAlive; its files in
  OS Server's folder's `Network/`). It makes one vmnet network in shared
  mode on server.json's `containerSubnet`, DHCP off, and keeps it for its
  life. Its Unix socket (`Network/network.sock`) answers a JSON line with
  one: `network` (the subnet, the gateway and the network's serialization,
  `vmnet_network_copy_serialization`'s XPC object as JSON), `allocate`
  (a container's address and MAC address, kept in `addresses.json`, so its
  helper started again gets the same, and the serialization), `release`,
  `keep` (every address but those named given back: OS Server's start,
  after deleting the containers no lease holds) and `status`. A
  container's helper asks for its address, makes its own reference to the
  network from the serialization (`vmnet_network_create_with_serialization`,
  as Apple's container's runtime does with its network plugin's) and gives
  the container that card. Each network vmnet makes is a bridge of
  macOS's (`bridge100`, `bridge101`…); until 0.14 each container's helper
  made one and took it down when it ended, and macOS, taking one down,
  could take another live network's bridge address and route with it:
  the churn is gone with one network that outlives every lease. Addresses
  go round the subnet rather than lowest first, so one given back goes to
  another container only once the rest have been used (the Mac's ARP
  cache may still hold the old card). `oss-machine network-check` makes
  one, attaches to it from another process and makes containers' cards on
  it, in a folder of its own: CI's macOS VM runs it, as it can't run a
  container.
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
- **A read-only folder can't move to another** on macOS (moving it writes
  its `..`): Bazel leaves its outputs read-only and a zip keeps their modes,
  so an xctest's bundles are made writable before they're moved into place
  (rules_apple's runner `chmod`s them too, for xcodebuild, which writes
  into them).
- **xcresulttool makes no JUnit**: an xctest's comes from its report of the
  result bundle (`xcresulttool get test-results tests`).
- **Emulators** use oss's own adb server port (5137) so they never meet
  another adb on the Mac, and keep running when the server restarts
  (launchd's job leaves its process group alone).

## This repository's CI

`.github/workflows/ci.yml` runs on a self-hosted runner (label `oss-ci`)
on a Mac that runs OS Server, as a user of its own (no sudo, no keychain,
no SSH key of its own; on its PATH, OS Server's command line with a lease
token, bazelisk, Xcode's tools and a python3 with Pillow). Each job leases
what it runs in from that OS Server and gives it back however it ends: a
step that leases execs its script, so the runner's cancel reaches the
script's trap. Every self-hosted job is skipped for a fork's pull request,
and only the publishing jobs may ask for an OIDC token (`id-token: write`).

| Job | Runs for | What it does |
| --- | --- | --- |
| `build-and-test` | pull requests, main | `tools/ci/mac_vm_tests.sh`, in a macOS VM (`xcode_27_2`): `swift build --build-tests`, then `swift test` one test at a time (the forwarder's tests time real sockets) with `OSS_TEST_SIMCTL=1` (real simulators of an iPad and an iPhone, made and deleted in the VM); the App package's `swift build`; OS Monitor's `bazel build` for the Mac and the iPhone's simulator |
| `linux` | pull requests, main | `tools/ci/linux_build.sh`: `swift build --product oss` in a container of Visor's agent image (with Rosetta), the tree on its standard input, through `oss machine run container --inside` (its exec through the server's API: the runner's user can't reach a container's socket) |
| `proof` | by hand only (full): to propose a release (no release without its commit's proof), or on a branch pushed at an earlier commit to bisect; compared with the release before the commit | `tools/ci/proof.sh` (below), uploaded as the `proof` artifact, kept 90 days |
| `beta` | pull requests, main, after `build-and-test` | `tools/ci/mac_vm_package.sh`: OS Server.app (`App/build.sh --zip`, QEMU from Homebrew installed first) and OS Monitor for the Mac built in a macOS VM of their own, OS Monitor's icon checked for its dark appearance; then `tools/ci/publish_from_ci.sh`, which sends each, unsigned, to Applications Server with the job's OIDC token: the server signs them with Developer ID and notarizes them (com.LoganShire.OSS, com.LoganShire.OSMonitor.Mac). OS Server's version is `OSS.version`, its build number the run's |
| `release` | a release published | the same once its tag is on main and is `v` + `OSS.version`: production |

**The proof** (`tools/ci/proof.sh --kind quick|full --proof <dir>`):

1. Builds `tools/ci/snapshot_diff.swift`, `tools/ci/window_shot.swift`
   and `tools/ci/proof_baseline` on the runner, and
   `tools/window_rect.swift` for the VM, and fetches the proof's base
   (below) into the job's shallow checkout.
2. Leases a macOS VM (`xcode_27_2`) with a key of the run's own, which an
   ssh-agent of the run's holds (so `tools/proof.py`'s own `oss machine
   ssh` reaches it); for full, a Linux and a Windows VM meanwhile.
3. Builds OS Server.app and OS Monitor (Mac, and the iPhone's simulator)
   in the VM, and takes them back.
4. Runs `tools/proof.py --held <the VM> --no-build`, against the VM: OS
   Server's window, menu bar panel, Set Up window and menu bar item, light
   and dark; for full, the Linux and Windows guests' Screen windows too.
   It runs as it is: `--held` because its own lease wouldn't wait for a
   free VM, `--no-build` because the app is the VM's build, the agent for
   its SSH, and no sudo outside the leases.
5. OS Monitor's Mac window in the same VM (cut from the screen by its
   frame, its corners cut away as proof.py cuts OS Server's), then its
   four screens on an iPhone simulator leased for it.
6. Gives every lease back, and compares each picture with the one kept
   for it in `Tests/Proof/` at the base (`git show <base>:Tests/Proof/<name>.png`;
   a channel more than 24 apart is a changed pixel).

```
screens/<name>.png   every picture at this commit: server-*, monitor-mac-*, monitor-ios-*
before/<name>.png    each that differs from its picture at the base, as the base kept it (Tests/Proof/<name>.png
                     there); none for a screen the base hasn't got (new, and changed)
diffs/<name>.png     each that differs: the new picture faded to grey, its changed pixels red
proof.json           {"commit", "ref", "kind", "run", "base": {"ref", "commit"},
                      "screens": [{"name", "changed", "changedPixels"}]}
```

The base is what the screens are compared with (`tools/ci/proof_baseline`,
whose choice the package's `ProofBaselineTests` test): a pull request's
base branch as it is (`GITHUB_BASE_REF`), a push's commit before it; CI's
run by hand (`workflow_dispatch`, the proof's only run), the release
before the commit (the highest `v*` tag in its history before it), else
the commit before; by hand outside CI, main (a checkout that isn't
shallow is fetched into without `--depth`). Never this tree's kept pictures: a pull request that changes
a screen replaces its picture, and would show it unchanged. The job's
summary says the base too.

Quick (20 pictures) is everything but the guests' Screen windows, which
need a Linux and a Windows VM; full (24) has them. The job fails when the
apps don't build or a picture doesn't come back; a changed picture is for
review. The kept pictures are a run's screens, looked at first: a change
that means to change a screen replaces its picture in the same pull
request (`screens/<name>.png` from the run's artifact).

Applications Server signs again, with Developer ID, the hardened runtime
and a secure timestamp, every Mach-O in each app, deepest first, each with
its own entitlements: OS Server.app's QEMU (`Contents/Helpers/qemu/bin`,
with its hypervisor entitlement, `App/qemu.entitlements`) and AXe
(`Contents/Helpers/axe/axe`) among them, and has the app notarized.

## License

Apache License 2.0: see [LICENSE](LICENSE).
