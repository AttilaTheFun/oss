# Windows' first step, pasted into an administrator's PowerShell in the VM's
# window (the only step that needs it): the SSH server, with the lab's
# management key. Everything after runs over SSH (`oss image build`).
# Replace KEY with the server's public key (~/.ssh/id_ed25519.pub on its Mac).
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any
Set-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Value 'KEY'
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notlike '127.*' | Select-Object IPAddress
