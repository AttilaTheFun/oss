# Primary VMs and their slots (design, 2026-11-02)

The owner (2026-10-31, 2026-11-01): the host Mac runs no tests and no
simulators of its own; apps and tests run in **primary VMs**, one a
platform, which OS Server keeps running; CI builds in its job's Linux
container and leases only **the ability to run** tests or apps, a **slot**
on a primary, never a whole GUI VM; agents lease a whole VM only when they
need one. And (2026-11-02): reviews, applications, visor and Shireworks
build their Mac and iPhone apps and tests in Linux containers and run the
tests in leases on the primary Mac VM.

Today a `macos` lease is a whole VM (two at most, Apple's limit, 16 GB
each), an `ios` lease a simulator on the host Mac, and CI's Mac tests take a
whole `xcode_27_2` VM each (tools/ci/mac_vm.sh in each repository).

## The primary macOS VM

- **One, OS Server's own**: a clone of a configured base (`primary.macos`
  in server.json: its config, `xcode_27_2`, and its size, 8 CPUs and 24 GB
  by default), started when the server starts and kept running: made again
  if it stops or stops answering, replaced (drained, as a restart is) when
  its base changes. It is one of the two macOS VMs Apple allows, so one is
  left for agents' `macos` leases.
- **Its memory is the budget's**, held as a lease of the server's own
  (holder `primary@oss`, kind `primary`), never released through the API.
  OS Monitor shows it, and its slots inside it.
- **Not leasable whole.** Its slots are.

## Slots

A slot is a lease of a new platform, `mac`: a part of the primary, for a
holder, released as any lease is (its time, or `release`, or its runner's
end for CI).

- **What it is**: a macOS user of its own on the primary (`oss-<lease>`,
  made at lease, its home empty; deleted with its files at release), reached
  through the API only (no SSH, no VNC: those are a whole VM's).
- **How many**: `primary.macos.slots` (4 by default) at once; a slot's
  memory is the primary's, so slots count against no budget beyond it; a
  slot asked for when all are held waits in line as any lease does
  (`--wait`).
- **Ready in**: about a second (a user made).
- **Its keychain**: a user that never logs in has no login keychain, and
  tests that keep a token (pipeline_app's Keychain.swift) need one. A slot's
  user gets `login.keychain-db` made at lease, with a password only the
  server keeps, set as its default and unlocked before each run (and
  deleted with the user). A `--gui` run, in the console user's session,
  gets the slot's keychain as its default for the run, not the console
  user's.

### Tests on a slot: `oss machine xctest <mac lease>`

The same verb, request and results as an `ios` lease's (API 10), for
rules_apple's macOS tests built on Linux (rules_applecross) or a Mac:

```sh
oss machine lease mac
oss machine xctest <id> --tests=bazel-bin/app/AppLogicTests.zip                 # no host: xcrun xctest
oss machine xctest <id> --tests=bazel-bin/app/AppTests.zip --host=bazel-bin/app/App.zip   # hosted
```

- **No host**: `xcrun xctest <bundle>.xctest`, as the slot's user, in the
  run's folder.
- **A host** (`--host`, the app zipped as rules_apple's macOS app is):
  `xcodebuild test-without-building` with an .xctestrun made as
  rules_apple's template makes one (TestHostPath the app's executable,
  TestBundlePath the .xctest in its PlugIns).
- **Not rules_apple's own runner**, whose run stops silently with exit 0
  without bazel's test environment (TEST_PREMATURE_EXIT_FILE,
  TEST_UNDECLARED_OUTPUTS_DIR, …).
- **Back**: xcodebuild's or xctest's output as it comes and its status; the
  JUnit and the result bundle (a hosted run's; a plain xctest's JUnit from
  its output) by the run's id, as long as the lease.
- **One run at a time a slot**; Ctrl-C ends it.
- **Windows drawn** (`--gui`): a test that draws a window, even one never
  shown (reviews' and releases' Mac picture tests, through
  pipeline_snapshots' MacSnapshotHost: an NSWindow with an
  NSHostingController), needs a WindowServer connection, so a GUI session.
  A run with `--gui` runs in the primary's console session (its logged-in
  user, `launchctl asuser`), one such run at a time on the primary, the
  others waiting their turn; its files are still the slot's. Without
  `--gui` a run is the slot's user's outside any login session, which logic
  tests and hosted tests that open no window need (checked by Apple Cross
  over SSH, 2026-11-02; visor's four Mac bundles are such). A session of
  each slot's own can come later if `--gui` runs queue.

### Apps on a slot (done, API 18)

`oss machine exec <mac lease> -- <command>` (as the slot's user) and
`upload`/`download` to and from its home, with grants (`machine.exec`,
`machine.upload`, `machine.download`) as for containers: running a Mac app
or tool that needs a Mac but not a whole VM. The same routes, frames and
MCP tools as a container's (`POST /v1/machines/<id>/exec`, `PUT`/`GET
…/files`; Sources/OSSServer/SlotAPI.swift):

- **exec**: `/usr/bin/ssh` to the primary, whose command line is
  `cd / && sudo -u oss-<id> -H /bin/bash -lc <wrapper> oss-exec <pid file>
  <dir> [NAME=VALUE]… -- <program> [arguments]…; exit $?`, every word
  single-quoted: the request's arguments, environment and directory reach
  the wrapper as positional parameters, never as script text. The wrapper
  exports the environment, enters the directory (the home, or one under
  it or /tmp), writes its pid to `/tmp/oss-exec-<id>-<run>.pid` and execs
  the program in a process group of its own (Perl's setpgrp). stdin,
  stdout, stderr and the status are relayed as a container's.
- **Signals**: a signal frame, or the client going (TERM, then KILL ten
  seconds on), is `kill -s <SIG> -- -<pgid>` on the primary, as the
  command's own user (`sudo -u`), so it reaches nothing else.
- **`--gui`** (`ExecRequest.gui`): the same as the primary's console user
  in its session (`sudo launchctl asuser $(id -u <console>) sudo -u
  <console> -H …`), one at a time, sharing `xctest --gui`'s turn.
- **No terminal** (`--tty`) yet: refused, saying so.
- **Files**: ContainerAPI's own script (`/bin/sh -c`, written beside its
  path and moved into place), over SSH as the slot's user; paths under its
  home (relative, `~/…` or absolute) or /tmp, no `..`.

## Pictures and recordings (2026-11-03)

The owner (2026-11-03): iOS, macOS and Android run in slots, and slots run
tests and take screenshots and screen recordings. Windows and Ubuntu wait
for their primaries, which wait for the Mac Studio's memory.

Every lease that shows something gets the same three verbs, whatever is
behind them:

```sh
oss machine screenshot <id> shot.png [--window=<app>]   # a PNG, now
oss machine record <id> start [--window=<app>]          # a recording begins
oss machine record <id> stop clip.mp4                   # it ends; an H.264 MP4 comes back
```

(`GET /v1/machines/<id>/screenshot?window=`, `POST …/record` `{window?}`
and `POST …/record/stop`, which answers the MP4; MCP `oss_screenshot` with
`window`, and `oss_record`, which keeps the MP4 in the caller's storage;
grants `machine.screenshot` and `machine.record` for CI's containers; API
19, #97.) One recording at a time a lease (409 `busy`), an hour at most;
one left running ends with the lease, its file discarded. A slot without
the GUI turn answers 409 `noGUI`, an app with no window on screen 404
`noWindow`. Recordings and window crops need a Mac server.

### macOS: a slot's GUI runs

A slot's apps that draw run in the primary's console session (`exec
--gui`, `xctest --gui`), one at a time on the primary. What is seen is
that session's screen:

- **Screenshot**: the server's own VNC capture of the primary (as a whole
  VM lease's is: RFB, no permission asked in the guest), cropped to the
  app's window when `--window` names it (its frame read in the session by
  a small helper over CGWindowList: window bounds need no Screen Recording
  permission). Only while the slot holds the GUI turn, so a picture is
  never another slot's.
- **Recording**: the same VNC frames at 30 per second, encoded on the
  server's Mac (VideoToolbox's H.264), cropped as a screenshot is.
- The proof's Mac part (isomer's tools/proof/proof.py) moves to a slot:
  the app run by `exec --gui`, its windows pictured by `screenshot
  --window`.

### iOS: simulators in the primary (opt-in)

`ios` leases move from the server's Mac into the primary where
server.json's `primary.macos.simulators` is above 0 (0, the default,
keeps the Mac's): the same lease, verbs, grants and MCP tools (`simctl`,
`install`, `xctest` plain and `--ui`, `screenshot`, `tap`/`swipe`/`type`/
`key`, `record`), a simulator of the primary's own Xcode, run by its guest
user (`runner`) over SSH, booted headless: simctl needs no GUI session
there for create, boot, install, launch, `io screenshot`, `io
recordVideo`, status_bar or AXe's input (checked on an `xcode_27_2` clone,
2026-11-03).

- **Room**: at most `simulators` at once (the `ios` cap), taking nothing
  of the budget: the primary grows by 2 GB a simulator (24 + 4 × 2 = 32
  GB). Still one of the two macOS VMs. A primary whose size or base no
  longer matches server.json lends nothing new (slots or simulators) and
  is replaced once what lives in it has ended.
- **A lease**: a new simulator there, `oss-lease-ios-<id>`, of the device
  asked for or `primary.macos.simulatorDevice` (`iPhone 17 Pro`, the
  server's own base's type until now) on the newest runtime that runs it;
  about 45 s (no bases to clone). Its files (uploads a command names, apps
  to install, test runs) are copied into `/Users/Shared/oss-ios/<id>` there
  by tar over SSH; it and its folder are deleted at release. Its own
  files (API 20: `oss machine upload <lease> <file> <path>`, the files
  routes a container's take) go straight into its `files/` there, as its
  guest user, by ContainerAPI's script over SSH; `@<path>` in a simctl
  argument or environment value is that file's path there.
- **Environment**: `launch` and `spawn` take one (API 20), each name the
  app's through simctl's `SIMCTL_CHILD_<name>`: `env NAME=value… xcrun
  simctl …` on SSH's command line, every word single-quoted.
- **Screenshot**: `xcrun simctl io <udid> screenshot --mask=black` there,
  its bytes back over SSH, with the status bar held still as on the Mac
  (the primary's clock is in the server's time zone).
- **Recording**: `xcrun simctl io <udid> recordVideo --codec=h264` there,
  ended by `pkill -INT` matching its file, the file brought back.
- **Input**: AXe, OS Server.app's own copy, sent to the primary's
  `~/.oss/axe` at its first use (and again when the server's changes).
- **xctest**: the run's folder made ready on the server's Mac (its
  .xctestrun naming the primary's Xcode and folder), copied there, a UI
  test's runner made there from the primary's Xcode, `xcodebuild
  test-without-building` there against the lease's simulator, the result
  bundle copied back for JUnit.
- **Restarts**: an `ios` lease in the primary is kept, and released with
  the primary if it didn't come back; one shut down (the primary started
  again from its disk) is booted again; simulators there named as a lease's
  that no lease holds are deleted, each minute's check.
- Leases already on the Mac when it is turned on stay there until they
  end. Once every server's simulators are in the primary, the Mac's path
  (its bases, `oss image build ios`) can go.

### Android: emulators on the server's Mac until the Linux primary

The Android emulator needs the hypervisor, and macOS gives a macOS guest
no nested virtualization (only Linux guests, on newer chips): so Android
can't run in the Mac primary. Its emulators stay on the server's Mac,
leased as now, with the same verbs as a slot's:

- **Screenshot**: `adb exec-out screencap -p` (as now).
- **Recording**: `adb shell screenrecord` (H.264; `--time-limit 0` where
  the device takes it, else three minutes a part, the parts joined on the
  server's Mac by ffmpeg when it has it, else AVFoundation).
- They move into the Linux primary when it comes, the API unchanged.

### Windows and Ubuntu

Held until the Mac Studio (the owner, 2026-11-03: not enough memory now).
Their primaries take the same shape: users of their own on one VM for
slots, the console session for GUI runs, VNC for pictures and
recordings.

## Then

1. Screenshots and recordings on every lease that shows something: done
   (API 19, #97).
2. iOS leases move into the primary: done, opt-in (above); the host's
   simulators go once it is on everywhere.
3. The Linux primary (Linux apps, Android emulators) and the Windows one,
   with the Mac Studio.
4. CI's `ci` kind is refused whole GUI VMs: done in practice for oss,
   visor and reviews (their mac_vm.sh leases a slot); isomer's proof next.

## Order of work

1. `primary.macos` in server.json and the primary kept running; its lease
   held; OS Monitor shows it.
2. `mac` leases: slot users made and deleted; `machine exec`/`upload`/
   `download` on them.
3. `machine xctest` on a `mac` lease: plain and hosted, and `--gui`.
4. The repositories' Mac tests move (Apple Cross: applications; the Visor
   agent: visor and reviews; Shireworks with it).
