# The vanilla layer on Windows: nothing installed but what the lab needs to
# manage the machine. Run over SSH as runner (an administrator: the session
# is elevated) after bootstrap.ps1. runner's password, which auto-login
# stores, comes on standard input (oss image build sends
# OSS_GUEST_PASSWORD there).
$ErrorActionPreference = 'Stop'
$password = [Console]::In.ReadLine()
if (-not $password) { throw 'runner''s password is needed on standard input (OSS_GUEST_PASSWORD)' }
# SSH by key only; PowerShell as its shell.
$config = 'C:\ProgramData\ssh\sshd_config'
$text = Get-Content $config -Raw
$text = $text -replace '(?m)^#?PasswordAuthentication .*', 'PasswordAuthentication no'
$text = $text -replace '(?m)^#?PubkeyAuthentication .*', 'PubkeyAuthentication yes'
if ($text -notmatch '(?m)^KbdInteractiveAuthentication') { $text = $text -replace '(?m)^PasswordAuthentication no', "PasswordAuthentication no`r`nKbdInteractiveAuthentication no" }
Set-Content -Path $config -Value $text -NoNewline -Encoding ascii
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
# runner logs in at boot.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value 'runner'
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $password
$passwordless = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
if (-not (Test-Path $passwordless)) { New-Item -Path $passwordless -Force | Out-Null }
Set-ItemProperty -Path $passwordless -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
# Never sleep or blank; updates are taken by the golden image, never mid-lease.
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
Set-ItemProperty -Path $au -Name AUOptions -Value 2 -Type DWord
# QEMU's clock is UTC; Windows takes a machine's clock for local time unless
# told (its time was off by the zone's hours).
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name RealTimeIsUniversal -Value 1 -Type QWord
# A screen that holds still: no widgets (the taskbar's live weather) and no
# Spotlight (a new wallpaper every day), Windows' own wallpaper instead.
$dsh = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
New-Item -Path $dsh -Force | Out-Null
Set-ItemProperty -Path $dsh -Name AllowNewsAndInterests -Value 0 -Type DWord
$cloud = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
New-Item -Path $cloud -Force | Out-Null
Set-ItemProperty -Path $cloud -Name DisableWindowsSpotlightFeatures -Value 1 -Type DWord
Set-ItemProperty -Path $cloud -Name DisableSpotlightCollectionOnDesktop -Value 1 -Type DWord
$wallpaper = 'C:\Windows\Web\Wallpaper\Windows\img0.jpg'
if (Test-Path $wallpaper) {
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
    $wallpapers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    New-Item -Path $wallpapers -Force | Out-Null
    Set-ItemProperty -Path $wallpapers -Name BackgroundType -Value 0 -Type DWord
}
# No OneDrive (its "Turn On Windows Backup" toast comes a while after
# logon) and no apps' toasts at all.
$onedrive = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
New-Item -Path $onedrive -Force | Out-Null
Set-ItemProperty -Path $onedrive -Name DisableFileSyncNGSC -Value 1 -Type DWord
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDrive -ErrorAction SilentlyContinue
$toasts = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'
New-Item -Path $toasts -Force | Out-Null
Set-ItemProperty -Path $toasts -Name NoToastApplicationNotification -Value 1 -Type DWord
# The screen is QEMU's VNC (the server sets it up per lease): nothing to install for it.
"vanilla: " + (Get-CimInstance Win32_OperatingSystem).Caption
