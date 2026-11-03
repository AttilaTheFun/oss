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

## Then

1. iOS leases move into the primary: its simulators, not the host's (the
   same `ios` lease and verbs; the host's simulators go).
2. The Linux primary (Linux apps, Android emulators) and the Windows one.
3. CI's `ci` kind is refused whole GUI VMs; the repositories' mac_vm.sh
   becomes a slot lease and `machine xctest`.

## Order of work

1. `primary.macos` in server.json and the primary kept running; its lease
   held; OS Monitor shows it.
2. `mac` leases: slot users made and deleted; `machine exec`/`upload`/
   `download` on them.
3. `machine xctest` on a `mac` lease: plain and hosted, and `--gui`.
4. The repositories' Mac tests move (Apple Cross: applications; the Visor
   agent: visor and reviews; Shireworks with it).
