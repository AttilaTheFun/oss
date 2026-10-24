# Changelog

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
