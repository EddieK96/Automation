# Arch Linux Installation Cheat Sheet (UEFI + GNOME)

## 0. Boot Installer
- Boot from Arch ISO (USB)
- Ensure UEFI mode (not legacy BIOS)

Check:
```
ls /sys/firmware/efi
```

## 1. Identify Disk
```
lsblk
```

## 2. Partition Disk (GPT)
```
fdisk /dev/nvme0n1
```
Inside:
```
g
n → +512MiB
t → 1
n
w
```

## 3. Format Partitions
```
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.ext4 /dev/nvme0n1p2
```

## 4. Mount
```
mount /dev/nvme0n1p2 /mnt
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
```

## 5. Network
```
ping archlinux.org
```

## 6. Mirrors
```
pacman -Sy reflector
reflector --country Germany,Netherlands --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy
```

## 7. Install Base
```
pacstrap /mnt base linux linux-firmware nano networkmanager
```

## 8. fstab
```
genfstab -U /mnt >> /mnt/etc/fstab
```

## 9. Chroot
```
arch-chroot /mnt
```

## 10. Time
```
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
```

## 11. Locale
Edit /etc/locale.gen and uncomment:
```
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
```
Then:
```
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

## 12. Keyboard
```
echo "KEYMAP=de-latin1" > /etc/vconsole.conf
localectl set-x11-keymap de
```

## 13. Hostname
```
echo arch > /etc/hostname
```

## 14. Root Password
```
passwd
```

## 15. User
```
useradd -m -G wheel -s /bin/bash ed
passwd ed
EDITOR=nano visudo
```
Uncomment:
```
%wheel ALL=(ALL:ALL) ALL
```

## 16. Bootloader
```
pacman -S grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

## 17. GNOME
```
pacman -S gnome
systemctl enable gdm
```

## 18. Network
```
systemctl enable NetworkManager
```

## 19. Finish
```
exit
umount -R /mnt
reboot
```

Remove USB.

## Notes
- Verify disk before formatting
- Use normal user, not root
- Ensure /boot is mounted before GRUB install

## Automated Installer Script

Use the script `arch_usb_auto_install.sh` to automate this process from Arch live media.

### Run From a Second USB

1. Plug in your script USB after booting Arch ISO.
2. Mount it (replace device/path as needed):

```bash
mkdir -p /mnt/usb
mount /dev/sdb1 /mnt/usb
chmod +x /mnt/usb/arch_usb_auto_install.sh
/mnt/usb/arch_usb_auto_install.sh
```

### Place in ISO and Auto-Run (Fully Offline)

Use `build_offline_autoinstall_iso.sh` to generate a custom ISO that:
- embeds `arch_usb_auto_install.sh`
- auto-runs it at boot via systemd
- includes an offline package repository with base + GNOME + bootloader packages

1. On an Arch Linux machine (or Arch VM/container), copy this project folder.
2. Install build requirements:

```bash
sudo pacman -S --needed archiso pacman-contrib rsync
```

3. Build the custom offline ISO:

```bash
cd /path/to/Automation
sudo chmod +x ./build_offline_autoinstall_iso.sh
sudo ./build_offline_autoinstall_iso.sh
```

4. Output ISO is created in:

```text
./out/
```

5. Boot from that ISO. The installer starts automatically.

Notes:
- Installer install mode defaults to `auto`: if `/opt/offline-repo` exists, it uses offline mode automatically.
- No internet is required during install if the ISO was built successfully.
- You can still force modes in the installer prompt: `offline` or `online`.

### Important Safety Note

The script wipes the selected target disk completely after a typed confirmation (`YES`). Always double-check the selected disk.

## Desktop VM Setup (Windows Hyper-V)

For a desktop-usable Arch VM on Windows, use the helper script in this folder.

1. Open PowerShell as Administrator.
2. Run:

```powershell
Set-Location "c:\Users\eddik\Documents\GitHub\Automation"
.\setup_arch_vm_hyperv.ps1 -StartVm
```

This now starts the VM and opens the Hyper-V VMConnect window automatically.

The VM script now auto-picks the ISO in this order:
- `archlinux-latest-x86_64.iso` in the repo root
- `out/archlinux-latest-x86_64.iso`
- newest `archlinux-*.iso` in repo root or `out/`
- if none exist, it downloads from `-OfficialIsoUrl` and stores it as `archlinux-latest-x86_64.iso`

`build_offline_autoinstall_iso.sh` updates `archlinux-latest-x86_64.iso` automatically after a successful build.

3. In Hyper-V Manager, connect to the VM and run the Arch installer script inside the VM:

```bash
chmod +x /root/arch_usb_auto_install.sh
/root/arch_usb_auto_install.sh
```

Optional custom size:

```powershell
.\setup_arch_vm_hyperv.ps1 -VmName "ArchGNOME" -CpuCount 6 -MemoryGB 12 -DiskGB 120 -StartVm
```

Optional explicit ISO path:

```powershell
.\setup_arch_vm_hyperv.ps1 -IsoPath ".\archlinux-2026.04.01-x86_64.iso" -StartVm
```

Optional custom mirror URL (used when no local ISO is found):

```powershell
.\setup_arch_vm_hyperv.ps1 -OfficialIsoUrl "https://fastly.mirror.pkgbuild.com/iso/2026.04.01/archlinux-2026.04.01-x86_64.iso" -StartVm
```

Optional: skip auto-opening the VMConnect window:

```powershell
.\setup_arch_vm_hyperv.ps1 -StartVm -NoConsole
```

## Setup Hooks (Post-Install Scripts)

You can configure custom setup scripts to run automatically after the Arch installation completes. These scripts are stored in GitHub repos and can be embedded in the offline ISO or pulled at install time.

### Configuration

Edit `setup-hooks.conf` in the project root:

```bash
# Format: GITHUB_REPO_URL SCRIPT_RELATIVE_PATH [SCRIPT_RELATIVE_PATH ...]
https://github.com/your-user/your-repo.git setup/init.sh setup/configure.sh
https://github.com/other-user/dotfiles.git dotfiles/install.sh
```

### How It Works

- **Offline mode** (ISO build): Scripts are embedded in the ISO and run locally without internet.
- **Online mode** (direct install): Scripts are cloned fresh at install time if they're available.

### Example Workflow

1. Add your setup repos to `setup-hooks.conf`:

```
https://github.com/EddieK96/Automation.git post-install/setup.sh
```

2. Build the ISO (scripts are embedded):

```bash
sudo ./build_offline_autoinstall_iso.sh
```

3. Boot and install. After the base system is installed, your setup hooks run automatically.

## Build Custom Installer From Arch Live Medium (Inside VM)

Use this flow when you boot a VM from the official Arch ISO and want to build the custom installer from GitHub.

1. Verify networking:

```bash
ping -c 1 archlinux.org
```

2. Prepare persistent build storage (example uses `/dev/sda` and wipes it):
   - `1MiB` below is the partition start offset for alignment, not the partition size.
   - `100%` means the partition grows to the end of the disk.

```bash
wipefs -a /dev/sda
parted -s /dev/sda mklabel gpt
parted -s /dev/sda mkpart primary ext4 1MiB 100%
partprobe /dev/sda
mkfs.ext4 -F /dev/sda1
mkdir -p /mnt/build
mount /dev/sda1 /mnt/build
```

3. Install tooling needed to clone and build:

```bash
pacman -Sy --noconfirm git archiso pacman-contrib rsync
```

4. Clone your repository from GitHub and run the build:

```bash
cd /mnt/build
git clone https://github.com/EddieK96/Automation.git Automation
cd Automation
chmod +x ./build_offline_autoinstall_iso.sh
INSTALL_PROFILE=hyperv ./build_offline_autoinstall_iso.sh
```

For Hyper-V VM targets, `INSTALL_PROFILE=hyperv` skips `linux-firmware`, which reduces download size and avoids unnecessary firmware packages in the offline ISO.

5. Verify output:

```bash
ls -lh ./out
ls -lh ./archlinux-latest-x86_64.iso
```

6. Transfer the built custom ISO back to Windows:
   - Copy `./archlinux-latest-x86_64.iso` or `./out/archlinux-*.iso` to your Windows host.
   - Place it in the Automation folder on Windows, or specify the path when running the VM setup script.

7. On Windows, use that custom ISO with your VM setup:

```powershell
.\setup_arch_vm_hyperv.ps1 -IsoPath ".\archlinux-latest-x86_64.iso" -StartVm
```

If package download fails during ISO build with mirror errors (firmware/package retrieval):

```bash
cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF
rm -f ./archiso-offline-autoinstall/airootfs/opt/offline-repo/*.part
./build_offline_autoinstall_iso.sh
```

Optional: if you also want the official ISO for comparison/testing inside the live environment:

```bash
curl -L "https://fastly.mirror.pkgbuild.com/iso/2026.04.01/archlinux-2026.04.01-x86_64.iso" -o /mnt/build/archlinux-2026.04.01-x86_64.iso
```
