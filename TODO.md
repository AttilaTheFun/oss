# TODO

## Storage

- **xctest from storage**: `oss machine xctest <ios lease> <object>`, a
  zipped test bundle (or an `.xctestrun` with its products) from the store
  run on the lease's simulator, its result bundle put back in the store;
  and its grant, `machine.xctest` (reserved: `GrantKey.later`).
- **`machine.exec` and `machine.upload` grants** (reserved too): a
  container's exec and a VM's upload through a grant's URL.
- **Android installs from the store**: `oss machine install` takes iOS
  leases only; an emulator's would be `adb install` of an `.apk` object.
- **OS Server's window and OS Monitor show storage's use**: `Status.storage`
  carries it; both draw leases from `Status`, and their proofs' canned
  servers would need a value too.
- **`oss mcp`**: tools for storage and grants beside the machines'.
- **A free-space floor for the store**, as the Bazel cache keeps one
  (`minFreeGigabytes`): today only its caps bound it.
- **One writer in `Files/sha256/`**: `oss files add` and `remove` write the
  folder from their own process while the server sweeps it. Entries are
  written before bytes, so a file being added is never swept, but adding
  bytes that a holder's lease has just let go can race the sweep that
  deletes them. Adding and removing through the server (a route for its own
  Mac only) would close that.

## Tools in Swift, not Python

The two proofs (`tools/proof.py`, `tools/monitor_proof.py`) and the QEMU
bundler (`tools/bundle_qemu.py`) are Python; each can be an executable
target of the package. (#30 meant to add this note.)
