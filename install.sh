#!/bin/bash
# Builds oss, signs it with this Mac's Apple Development identity (so
# macOS's permissions for it, Automation of UTM, survive rebuilds), and
# installs it as ~/.local/bin/oss.
#
#   ./install.sh            the command, for any Mac that leases machines
#   ./install.sh --service  and the server, under launchd (the Mac with UTM)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/oss ~/.local/bin/oss.new
# The first Apple Development identity, by its SHA-1: two certificates can
# share a name (a renewed one), and codesign refuses an ambiguous name.
identity="${OSS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -v REVOKED | awk '/"Apple Development: / {print $2; exit}')}"
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" --identifier oss ~/.local/bin/oss.new
else
  echo "install.sh: no Apple Development identity; signed ad hoc (macOS asks again after each rebuild)" >&2
  codesign --force --sign - --identifier oss ~/.local/bin/oss.new
fi
mv ~/.local/bin/oss.new ~/.local/bin/oss
echo "installed ~/.local/bin/oss"

if [ "${1:-}" = "--service" ]; then
  plist=~/Library/LaunchAgents/oss.server.plist
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>oss.server</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/oss</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    <key>OSS_REPO</key><string>$PWD</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Emulators the server starts keep running when it restarts. -->
  <key>AbandonProcessGroup</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/oss.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/oss.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/oss.server" 2>/dev/null || true
  # bootout returns before the old server is gone; bootstrap fails (5) until it is.
  for _ in $(seq 1 30); do launchctl print "gui/$(id -u)/oss.server" >/dev/null 2>&1 || break; sleep 1; done
  for _ in 1 2 3; do launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break; sleep 2; done
  launchctl print "gui/$(id -u)/oss.server" >/dev/null 2>&1 || { echo "install.sh: the server didn't load" >&2; exit 1; }
  echo "oss serve is running under launchd (log: ~/Library/Logs/oss.log)"
fi
