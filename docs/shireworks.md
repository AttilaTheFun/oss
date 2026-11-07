# OS Server becomes Shireworks (0.14)

The owner's decisions (2026-11-01/02 and 2026-11-07): OS Server and OS
Monitor become one app, **Shireworks**, released as 0.14 (there is no "OS
Server 0.14"). The repository becomes `shireworks`, private. This is the
plan, in the order it lands.

## What changes, and what keeps its name

The rule: what a person sees, and the app's identity, change. Names that
running machines, saved state, other repositories' CI or Visor's MCP proxy
depend on keep their names, or take a new one beside the old, so that nothing
is orphaned by the upgrade.

| | Becomes | Kept or aliased |
| --- | --- | --- |
| The app | `Shireworks.app`, bundle id `com.LoganShire.Shireworks`, executable `Shireworks`, the anvil icon (`App/Icon/Shireworks.icon`), `BuildVariant` (Alpha, AdHoc, Beta, Production) in its Info.plist | `OS Server.app` and `OS Monitor.app` retired from /Applications on both Macs once Shireworks runs |
| Its window | OS Monitor's dashboard (OSSMonitorKit: the servers, each one's machines, CI and usage); the menu bar item stays as it is | The machines' screens, Settings and setup as today |
| The iPhone app | Shireworks for iPhone, the same client (OSSMonitorKit) under `com.LoganShire.Shireworks`, scheme `shireworks://` | `osmonitor://connect?code=…` still accepted; connection codes keep their format |
| The command | `sw`, in the app's `Contents/Helpers` and `~/.local/bin` | `oss`, the same binary, beside it in both places and in CI's containers, until every script has moved |
| The server's folder | `~/Library/Application Support/Shireworks` | The folder is renamed, not copied, and `…/OS Server` left as a symlink to it: running helpers' open files, their launchd jobs' absolute paths and `server.json`'s paths keep working |
| Its log | `~/Library/Logs/Shireworks.log` | |
| The machines' helpers | Their launchd jobs rewritten to `Shireworks.app/Contents/Helpers/oss-machine` when Shireworks first starts (a running helper keeps running; its next start uses the new path) | The helper keeps the name `oss-machine` (OS Server's accounting finds it by name) and its jobs keep their labels (`oss.machine.*`, `oss.container.*`, `oss.network`) |
| Published packages | `Shireworks.zip`, registered with Applications Server before the first build; production promoted from the release commit's Alpha (`promote_from_ci.sh`), never rebuilt | `OS-Server.zip` and `OS-Monitor.zip` stop |

Kept as they are in 0.14 (internal, or a coordinated rename of its own later):

- **Machines and users**: `oss-lease-*`, `oss-primary-*`, `oss-<platform>-<config>` bases, `oss-<lease>` slot users, holders `primary@oss`, container labels `oss.ci.*`. `leases.json` stores them, and machines are found by these prefixes.
- **The API**: headers `OSS-API`, `OSS-Holder` and the rest, the `oss-exec` upgrade, `/v1/hello`'s `"server": "oss"` (clients check it), API levels.
- **Client files and environment**: `~/.config/oss/{client.json,token,key}`, `~/.local/state/oss`, and every `OSS_*` variable. Other Macs, CI containers and scripts in other repositories read them.
- **Swift modules and types**: `OSSClient`, `OSSServer`, `OSSMonitorKit`, `OSS`. Only this repository builds them now; renaming them is churn with no user-visible effect.
- **MCP**: the tool names (`oss_lease`, …), the server name and port 7481. Visor's proxy passes them to sessions as `oss__…`; renaming them is a separate step with the Visor session, after 0.14.
- **CI's labels**: `oss-jit`.

## Steps

1. **The app's identity**: Info.plist, `App/build.sh` (bundle name,
   executable, `Helpers/sw` beside `Helpers/oss`, `--identifier`s),
   `BuildVariant`, the icon, the window titles and menu text ("Quit
   Shireworks", …), the proof's window titles and `pkill` names.
2. **The folder and log**: `Paths.support` to `…/Shireworks`; at start, a
   server whose new folder is missing and old one present renames it and
   leaves the symlink (as 0.7's `Paths.migrate()` moved `~/.config/oss`);
   launchd jobs rewritten to the new helper path; the log's new name. Tested
   with a temporary home holding an old layout and a job plist.
3. **OS Monitor folded in**: the app's window becomes OSSMonitorKit's
   dashboard with the servers list (this Mac's server added by itself, with
   its monitor token); OS Monitor's Mac servers imported once from its
   defaults (`com.LoganShire.OSMonitor.Mac`, `servers`), their tokens
   re-entered from their connection codes (the old Keychain items aren't
   readable from a new bundle id); `Open OS Monitor` and `Copy OS Monitor
   Connection Code` become the window's own. The iPhone app's bundle id,
   name, scheme and icon change in `Monitor/BUILD.bazel` (its sources move
   with it later).
4. **Publishing**: `mac_vm_package.sh` builds `Shireworks.zip`;
   `Shireworks` registered with Applications Server (the Applications
   session, before the first build); the release job uses
   `promote_from_ci.sh`.
5. **Docs**: README, AGENTS.md, App/README.md, Monitor/README.md, CHANGELOG's
   0.14 entry, `oss` → `sw` in examples (`oss` noted as the alias).
6. **The proof**, then **the release**: 0.14's proof and its review; the owner
   publishes; Container Helper installs Shireworks, and removes OS
   Server.app and OS Monitor.app.
7. **The repository**: `AttilaTheFun/oss` renamed `shireworks` and made
   private; Applications Server's entry renamed (`applications-server repo
   AttilaTheFun/shireworks …`, then `… oss off`); `~/Developer/oss` moved to
   `~/Developer/shireworks` with a symlink; `~/Developer/AGENTS.md` (both
   Macs) and Visor's `tools/oss/README.md` updated. GitHub redirects the old
   URL meanwhile.

After 0.14: the MCP endpoint's name (with Visor), `SW_*` beside `OSS_*`, and
the `oss` alias retired once nothing calls it.
