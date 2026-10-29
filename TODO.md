# TODO

## 0.14: a primary VM per GUI platform

Apple's licence allows two macOS VMs per Mac, so lending both whole leaves
nothing for the many small jobs (a simulator, an app, a test bundle), and
those run on the host Mac today. In 0.14 each GUI platform gets a
**primary** VM that OS Server keeps for itself and never lends whole, and a
**secondary** that is lent whole only when a lease really needs a whole OS.

- **The macOS primary**: large (on a 512 GB Mac Studio, 128 to 256 GB and
  most of the cores), Xcode installed, a small agent inside it that OS
  Server drives. It does the work leases ask for:
  - `ios` leases are simulators inside it, one per lease, not on the host;
    `xctest`, `install`, screenshots and input go there as they go to the
    host's simulators today.
  - A `macos-app` lease is a slot on it: install a `.app`, launch it,
    screenshot its window, run macOS xctest bundles.
  - Simulators and unit tests run side by side; macOS UI tests and anything
    that needs the screen wait their turn (one desktop).
  - A lease's apps, simulators and processes go when it is released.
- **Health and renewal**: OS Server checks each primary's health (its agent
  answering, free memory and disk, the simulator service and Xcode
  responding, a canary run) and wipes and restarts it, a fresh clone of its
  base: on a schedule, so nothing accumulates, and whenever a check fails.
  It drains first: no new work goes to it, the running leases' work
  finishes (or moves, for simulators), then it is replaced; leases waiting
  meanwhile queue rather than fail.
- **Interrupted work is retried, not lost**: a primary's leases are slots,
  so they outlive its restart; only the work running then fails, with a
  retryable `primaryRestarted` (and when to try again) that `oss` commands
  retry themselves and CI retries as a step. `GET /v1/events` streams a
  lease's "draining", "restarting" and "ready again" to whoever holds it
  (Visor shows its session why).
- **A leak ends one lease's work, not the VM**: macOS caps no process's
  memory, so OS Server watches. It knows each lease's processes (the
  simulator's tree, the app it launched, the xcodebuild run), samples their
  memory every few seconds against the lease's budget, and past it ends that
  tree alone (a simulator shut down and erased, an app or a run killed), the
  work failing with `memoryLimit`. The VM restarts only when the primary
  itself is unwell (the simulator service or the window server stuck, memory
  short with no lease to blame), besides the reset when idle.
- **CI's Mac work on the primary**: CI's runners become containers of their
  own, one a job (no `ci` user on the Mac: "CI runners in containers"
  below), and their Mac steps use the
  primary's slots, not a whole VM: test bundles built on Linux, run with
  `oss machine xctest`, their snapshot pictures brought back as attachments
  or through a files call. Not runners inside the primary: a job runs a pull
  request's code, and the primary, shared by every lease, runs only what OS
  Server asks of it.
- **The secondary** is lent whole as `macos` leases are now, queued
  (`--wait`); AGENTS.md tells agents it is a last resort, for what needs a
  whole OS.
- **Linux and Windows** follow the same pattern: Linux can give each lease a
  display of its own, so its GUI leases run side by side; Windows has one
  desktop, so its GUI work takes turns as the Mac's does.
- Order: the macOS primary with `ios` leases and xctest moved into it, then
  `macos-app` slots, then the secondaries' queue, then Linux and Windows.

## 0.14: CI runners in containers

CI's self-hosted runners are long-lived processes on the Mac today, one a
repository, each registered by hand with a token and an administrator's
`sudo` (a hidden `ci` user's LaunchDaemons), running one job at a time and
seen in OS Server only through the leases their jobs take. In 0.14 OS
Server runs CI itself: a container for each job, made when GitHub queues
it and deleted when it ends.

- **One GitHub App for every repository.** The owner makes one App (Actions
  read, Administration read and write, Metadata read; no webhook) and
  installs it on all their repositories; OS Server keeps its private key
  and client id (`~/.config/oss/ci-github-app.{pem,json}`, mode 600) and
  mints installation tokens from them. Nothing of the App reaches a job.
- **Jobs found by polling, not webhooks**: OS Server has no public address,
  so it asks each installed repository for its queued runs every few
  seconds (`GET /repos/{repo}/actions/runs?status=queued`, conditional on
  the last answer's ETag, so an unchanged answer costs no rate limit), and
  for each queued job whose labels it serves (`self-hosted` and
  `<repo>-ci`, the labels workflows use today, so none change) it makes a
  runner for that job alone.
- **A runner a job**: a just-in-time runner
  (`POST /repos/{repo}/actions/runners/generate-jitconfig`, the job's
  labels) in a container leased with kind `ci`, from an image with the
  runner and what CI's jobs need (the agent image plus actions/runner),
  started `run.sh --jitconfig`: it takes one job, runs it, exits, and the
  container is deleted. Its registration is GitHub's to clean up; a
  container whose job never came (GitHub gave the job to another runner) is
  deleted after a few minutes.
- **Concurrent jobs**: up to N at once (a setting; by default from the
  Mac's cores and memory), each container with its own CPU and memory
  limits, the rest queued in the order GitHub queued them, across
  repositories.
- **What a job may do**: it holds no OS Server token. OS Server gives its
  container a grant scoped to its own lease: leasing machines beneath it
  (released with it), storage, and the Bazel cache read; the cache's write
  only for a push to the default branch. GitHub's own secrets and its OIDC
  token reach the job as on any runner, so Applications Server's signing
  stays as it is. A public repository's workflows keep fork pull requests
  off self-hosted runners.
- **Seen in OS Server**: a CI view (in the app, `oss ci list`,
  `GET /v1/ci/jobs`) of every job: its repository, workflow, job, branch or
  pull request, commit, how long it waited and ran, its container's CPU,
  memory and disk over time, the leases it holds, and a link to its run on
  GitHub; running jobs first, the last week's after.
- **Onboarding a repository** is installing the App on it (already: all
  repositories) and a workflow asking for `<repo>-ci`: no token, no `sudo`,
  nothing on the Mac.
- **Then retire** the runners on the Mac: the `ci` user's LaunchDaemons
  (`com.<owner>.ci-runner.<repo>`), `/Users/Shared/ci`, the `ci` user
  itself, and the runners that run as a login user; one `sudo` script, the
  last.
- Order: before the primary VMs (it needs no new Mac): the poller and JIT
  runners for one repository beside its old runner (a label of its own),
  then every repository, the CI view, then retiring the old runners.

## Storage

- **A VM's files through the server**: `machine.upload` and
  `machine.download` (and their routes) take container leases; a VM's go by
  scp, which needs its SSH port and the holder's key.
- **Android installs from the store**: `oss machine install` takes iOS
  leases only; an emulator's would be `adb install` of an `.apk` object.
- **OS Server's window and OS Monitor show storage's use**: `Status.storage`
  carries it; both draw leases from `Status`, and their proofs' canned
  servers would need a value too.
- **`oss mcp`**: tools for storage and grants beside the machines'.
- **Kinds for storage's leases**: a machine lease says who it's for
  (`kind`, `label`, `link`, API 8) and a storage lease doesn't. Its holder
  could be taken the same way (`LeaseOrigin`: a `visor:` holder's objects
  are a session's), so `oss storage ls` and the store's use in `oss status`
  could say how much CI, sessions and people keep.
- **A free-space floor for the store**, as the Bazel cache keeps one
  (`minFreeGigabytes`): today only its caps bound it.
- **One writer in `Files/sha256/`**: `oss files add` and `remove` write the
  folder from their own process while the server sweeps it. Entries are
  written before bytes, so a file being added is never swept, but adding
  bytes that a holder's lease has just let go can race the sweep that
  deletes them. Adding and removing through the server (a route for its own
  Mac only) would close that.

## Containers from anywhere

- **A kept volume deleted from anywhere**: `DELETE /v1/volumes/<name>` is
  still the server's Mac's only, so an agent elsewhere that kept one can't
  delete it; volumes would need holders, as leases have.
- **A container's stdin held back**: the helper takes stdin frames into an
  unbounded stream, so a fast upload (or exec's stdin) into a container
  slower to read it is held in the helper's memory; its writes to the
  command should wait as its output's do.
- **Folders through the server**: a file at a time; a folder goes as a tar
  through exec, which needs `tar` in the image. The files route could take
  an archive and unpack it.
- **UDP ports**: `--port` forwards TCP alone, as VMs' forwards do.
- **A container's CPUs as it counts them**: one leased with `--cpus=6`
  sees 7 (`nproc`, `/proc/cpuinfo`), while its cgroup's `cpu.max` (`600000
  100000`) holds it to 6. It's Containerization's: `LinuxContainer` gives
  the VM one CPU more than the container's (`cpuOverhead`, 1 by default:
  "a core for the guest agent outside of the container"), and limits the
  container by a CFS quota alone, no cpuset, so it sees every CPU the VM
  has. A tool that sizes its work by the CPUs it sees (`make -j$(nproc)`)
  runs one job more than its quota; one that reads the cgroup counts what
  was asked. Ask upstream for a cpuset of the container's own CPUs, or set
  `cpuOverhead` to 0 in the helper (`Helper.boot`), the guest agent then
  sharing the container's CPUs.

## iOS tests

- **Test diagnostics on request**: runs pass `-collect-test-diagnostics
  never`, as xcodebuild's `simctl diagnose` of a failing run took its whole
  ten minutes in a macOS VM (and outlived xcodebuild). An `XCTestRequest`
  could ask for them, with a shorter timeout.
- **What rules_apple's runner takes and xctest doesn't**: a test's
  environment (`env`) and arguments (`command_line_args`), random order,
  coverage, a screen capture format, and attachments' lifetime: the
  runner's default, `keepNever`, so a failing UI test's screenshots aren't
  in its result bundle. An `XCTestRequest` could carry each.
- **Runs held by the lease alone**: a run's folder (its bundles, result
  bundle and derived data) stays until its lease ends, counted against no
  cap; a lease running many large UI tests fills the disk with them.
- **macOS tests**: `macos_unit_test` bundles could run on a macOS lease the
  same way, xcodebuild in the VM.
- **`oss mcp`**: an xctest tool.

## Tools in Swift, not Python

The two proofs (`tools/proof.py`, `tools/monitor_proof.py`) and the QEMU
bundler (`tools/bundle_qemu.py`) are Python; each can be an executable
target of the package. (#30 meant to add this note.) CI's proof
(`tools/ci/proof.sh`) runs proof.py as it is and does OS Monitor's part in
shell, cutting windows with `tools/ci/window_shot.swift`: a Swift proof
would take both, and CI's runner would need no Pillow.

## OS Server.app's beta from CI

`beta` builds OS Server.app and sends it to Applications Server, whose
Signer signs again only the executables directly in `Contents/MacOS` and
`Contents/Helpers` (and every bundle and dylib): QEMU's
`Helpers/qemu/bin/{qemu-system-aarch64,qemu-img}` and AXe's
`Helpers/axe/axe` keep the build's ad hoc signature, and notarization
refuses the app. Once the Signer signs every Mach-O executable in a bundle
(each with its own entitlements: QEMU's `com.apple.security.hypervisor`),
make OS Server.app's publish fatal again in ci.yml.

## A macOS lease's window server

A Mac app's snapshot test in a macOS lease draws a sidebar's list blank
(an `NSSplitView` sidebar, captured with `cacheDisplay`), where a Mac's own
login session draws its rows: over SSH and from a launch agent in the
user's session alike, so a VM's display, not the session, seems to be why.
Until a lease draws them, a repository records its Mac pictures on CI's
Mac. Find what the window server lacks (a display attached, its scale, the
compositor) and give macOS leases it.
