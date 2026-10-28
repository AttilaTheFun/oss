# TODO

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
target of the package. (#30 meant to add this note.)

## A macOS lease's window server

A Mac app's snapshot test in a macOS lease draws a sidebar's list blank
(an `NSSplitView` sidebar, captured with `cacheDisplay`), where a Mac's own
login session draws its rows: over SSH and from a launch agent in the
user's session alike, so a VM's display, not the session, seems to be why.
Until a lease draws them, a repository records its Mac pictures on CI's
Mac. Find what the window server lacks (a display attached, its scale, the
compositor) and give macOS leases it.
