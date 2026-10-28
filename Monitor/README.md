# OS Monitor

OS Server's client, as Visor is Visor Server's: an iPhone, iPad and Mac app
that watches your OS Servers from wherever you are. For each server it
shows:
- what its Mac's CPU, memory and disk go to: OS Server and the machines it
  lends, every other process, what's free;
- the last minutes of CPU and memory;
- what's running (each lease, its kind: CI, Session, Agent or Manual, its
  holder and label, what it uses, its time left);
- the other apps using the most;
- OS Server's files on disk, its capacity per platform, and its Bazel cache.

It reads, and can do nothing else: a server's code carries its monitor
token, which the server accepts for status, usage and its cache alone.

- **Adding a server:** OS Server's Settings › OS Monitor shows its code as
  a QR code (an iPhone's or iPad's camera opens OS Monitor with it) and
  Copy Code (paste it into Add Server). A server run without the app gives
  it with `oss monitor code | pbcopy`. The code holds the server's
  addresses (its LAN's, its tailnet's, its .local name), tried in order.
  **New Code** in OS Server stops every Monitor given the old one.
- **Where things are:**
  - `Sources/` is the app: its servers (names and addresses in its defaults,
    tokens in the Keychain), the list and Add Server;
  - `../Sources/OSSMonitorKit` is what it shows of a server (`ServerMonitor`,
    `ServerDashboard`), which OS Server's window shows too;
  - `Icon/OSMonitor.icon` is its icon (Icon Composer).
- **Building** (Bazel, from the repository's root):
  - `bazel build //Monitor:os_monitor_macos`;
  - `bazel build //Monitor:os_monitor_ios --ios_multi_cpus=sim_arm64`, for the
    simulator;
  - for an iPhone, `--ios_multi_cpus=arm64`, with the team in `.bazelrc.user`
    (tools/signing).
  - Its version is in `Info.ios.plist` and `Info.mac.plist`, the same as
    OSSClient's `OSS.version`.
- **The canned servers** (`-fixture YES`, `-fixture.open YES` to open the
  first, `-appearance light|dark`) are the proof's screens:
  `tools/monitor_proof.py --review <dir> [--publish <host>]`.
- **Plain HTTP:** an OS Server's API is plain HTTP, so OS Monitor allows
  it on the local network and on `ts.net` (the tailnet, encrypted
  underneath) only.
