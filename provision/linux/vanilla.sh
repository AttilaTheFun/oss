#!/bin/bash
# The vanilla layer on Ubuntu: nothing installed but what the lab needs to
# manage the machine (SSH, QEMU's guest agent; its screen is QEMU's VNC). Run in the guest
# as `runner` over SSH; sudo asks once for the password before the sudoers line.
set -euo pipefail
echo 'runner ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/runner >/dev/null
sudo chmod 440 /etc/sudoers.d/runner
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server qemu-guest-agent >/dev/null
# SSH by key only.
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-keys-only.conf >/dev/null
sudo systemctl reload ssh
# runner logs in at boot.
sudo sed -i -e 's/^#\? *AutomaticLoginEnable *=.*/AutomaticLoginEnable=true/' -e 's/^#\? *AutomaticLogin *=.*/AutomaticLogin=runner/' /etc/gdm3/custom.conf
# Never lock, blank or sleep (system defaults, so every clone has them).
sudo mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
printf 'user-db:user\nsystem-db:local\n' | sudo tee /etc/dconf/profile/user >/dev/null
sudo tee /etc/dconf/db/local.d/00-lease >/dev/null <<'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
DCONF
sudo dconf update
# Updates are taken by the base, never mid-lease: no update notices, no
# background apt runs.
sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq update-notifier unattended-upgrades >/dev/null 2>&1 || true
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
# No first-run welcome on runner's desktop.
mkdir -p ~/.config && echo yes > ~/.config/gnome-initial-setup-done
sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq gnome-initial-setup >/dev/null 2>&1 || true
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
sudo systemctl enable --now qemu-guest-agent
echo "vanilla: $(. /etc/os-release; echo $PRETTY_NAME)"
