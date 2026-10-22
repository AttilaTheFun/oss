#!/bin/bash
# The vanilla layer on macOS: nothing installed, only what the lab needs to
# manage the machine. Run in the guest as `runner` over SSH, with sudo
# (`oss image build` runs it; the first time, sudo asks for the password).
# `runner` and Remote Login come from UTM's provisioning
# (`utmctl start --provision-username runner --provision-ssh …`).
set -euo pipefail
# Throwaway machines: runner's sudo asks nothing.
echo 'runner ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/runner >/dev/null
sudo chmod 440 /etc/sudoers.d/runner
# SSH by key only (this file sorts before Apple's 100-macos.conf, so it wins).
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/100-keys-only.conf >/dev/null
# A clean desktop at every login: no windows brought back from the last session.
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
# Never sleep, blank or lock: a leased desktop stays up.
sudo pmset -a sleep 0 displaysleep 0 disksleep 0
defaults -currentHost write com.apple.screensaver idleTime -int 0
# Screen Sharing (VNC) on, with legacy VNC passwords so any VNC client
# connects; each lease sets its own password.
sudo defaults write /Library/Preferences/com.apple.RemoteManagement.plist VNCLegacyConnectionsEnabled -bool true
# A password-only VNC viewer sees the console (runner's desktop), not a new login window.
sudo defaults write /Library/Preferences/com.apple.RemoteManagement.plist VNCAlwaysStartOnConsole -bool true
sudo launchctl enable system/com.apple.screensharing
sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
echo "vanilla: $(sw_vers -productVersion)"
