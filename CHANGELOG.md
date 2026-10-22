# Changelog

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
