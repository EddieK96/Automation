#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
  echo "UEFI mode not detected. Boot Arch ISO in UEFI mode."
  exit 1
fi

if ! command -v pacstrap >/dev/null 2>&1; then
  echo "pacstrap not found. Run this from an Arch live environment."
  exit 1
fi

echo ""
echo "Detected block devices:"
lsblk -d -o NAME,SIZE,MODEL,TYPE
echo ""

read -rp "Install disk (default: /dev/nvme0n1): " DISK
DISK="${DISK:-/dev/nvme0n1}"

if [[ ! -b "${DISK}" ]]; then
  echo "Disk ${DISK} does not exist."
  exit 1
fi

read -rp "Hostname (default: arch): " HOSTNAME
HOSTNAME="${HOSTNAME:-arch}"

read -rp "Username (default: ed): " USERNAME
USERNAME="${USERNAME:-ed}"

read -rp "Timezone (default: Europe/Berlin): " TIMEZONE
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

read -rp "Enable GNOME desktop? [Y/n]: " ENABLE_GNOME
ENABLE_GNOME="${ENABLE_GNOME:-Y}"

OFFLINE_REPO_PRIMARY="/opt/offline-repo"
OFFLINE_REPO_SECONDARY="/run/archiso/bootmnt/offline-repo"
OFFLINE_REPO_PATH=""
if [[ -d "${OFFLINE_REPO_PRIMARY}" ]]; then
  OFFLINE_REPO_PATH="${OFFLINE_REPO_PRIMARY}"
elif [[ -d "${OFFLINE_REPO_SECONDARY}" ]]; then
  OFFLINE_REPO_PATH="${OFFLINE_REPO_SECONDARY}"
fi

read -rp "Install mode [auto/offline/online] (default: auto): " INSTALL_MODE
INSTALL_MODE="${INSTALL_MODE:-auto}"

if [[ "${INSTALL_MODE}" == "offline" && -z "${OFFLINE_REPO_PATH}" ]]; then
  echo "Offline mode requested, but no offline repo found at ${OFFLINE_REPO_PRIMARY} or ${OFFLINE_REPO_SECONDARY}."
  exit 1
fi

if [[ "${INSTALL_MODE}" == "auto" ]]; then
  if [[ -n "${OFFLINE_REPO_PATH}" ]]; then
    INSTALL_MODE="offline"
  else
    INSTALL_MODE="online"
  fi
fi

read -rsp "Root password: " ROOT_PASSWORD
echo ""
read -rsp "User password for ${USERNAME}: " USER_PASSWORD
echo ""

echo ""
echo "This will erase ALL data on ${DISK}."
read -rp "Type YES to continue: " CONFIRM
if [[ "${CONFIRM}" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

if mountpoint -q /mnt; then
  echo "/mnt is currently mounted. Unmounting first..."
  umount -R /mnt
fi

if [[ "${DISK}" =~ (nvme|mmcblk) ]]; then
  PSEP="p"
else
  PSEP=""
fi

EFI_PART="${DISK}${PSEP}1"
ROOT_PART="${DISK}${PSEP}2"

echo ""
echo "Partitioning ${DISK} (GPT, 512MiB EFI + remaining root)..."
sgdisk --zap-all "${DISK}"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "${DISK}"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "${DISK}"
partprobe "${DISK}"

echo "Formatting partitions..."
mkfs.fat -F32 "${EFI_PART}"
mkfs.ext4 -F "${ROOT_PART}"

echo "Mounting target filesystem..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART}" /mnt/boot

BASE_PKGS=(base linux linux-firmware nano networkmanager sudo grub efibootmgr)
if [[ "${ENABLE_GNOME}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  BASE_PKGS+=(gnome gdm)
fi

if [[ "${INSTALL_MODE}" == "offline" ]]; then
  echo "Using offline install mode from ${OFFLINE_REPO_PATH}..."
  cat > /tmp/pacman-offline.conf <<EOF
[options]
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[offline]
SigLevel = Never
Server = file://${OFFLINE_REPO_PATH}
EOF
  pacman -Sy --noconfirm -C /tmp/pacman-offline.conf
  echo "Installing base system with pacstrap from offline repository..."
  pacstrap -C /tmp/pacman-offline.conf /mnt "${BASE_PKGS[@]}"
else
  echo "Checking internet connectivity..."
  if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "Network test failed. Configure networking first."
    exit 1
  fi

  echo "Updating mirrorlist with reflector..."
  pacman -Sy --noconfirm reflector
  reflector --country Germany,Netherlands --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  pacman -Syy --noconfirm

  echo "Installing base system with pacstrap..."
  pacstrap /mnt "${BASE_PKGS[@]}"
fi

echo "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab

ROOT_PASSWORD_B64="$(printf '%s' "${ROOT_PASSWORD}" | base64 -w 0)"
USER_PASSWORD_B64="$(printf '%s' "${USER_PASSWORD}" | base64 -w 0)"

cat > /mnt/root/installer.env <<EOF
HOSTNAME=$(printf '%q' "${HOSTNAME}")
USERNAME=$(printf '%q' "${USERNAME}")
TIMEZONE=$(printf '%q' "${TIMEZONE}")
ENABLE_GNOME=$(printf '%q' "${ENABLE_GNOME}")
ROOT_PASSWORD_B64=$(printf '%q' "${ROOT_PASSWORD_B64}")
USER_PASSWORD_B64=$(printf '%q' "${USER_PASSWORD_B64}")
EOF

cat > /mnt/root/post_install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source /root/installer.env

ROOT_PASSWORD="$(printf '%s' "${ROOT_PASSWORD_B64}" | base64 -d)"
USER_PASSWORD="$(printf '%s' "${USER_PASSWORD_B64}" | base64 -d)"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "KEYMAP=de-latin1" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "root:${ROOT_PASSWORD}" | chpasswd

if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager

if [[ "${ENABLE_GNOME}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  systemctl enable gdm
fi

# Run setup hooks if available
echo "Checking for setup hooks..."

HOOKS_MANIFEST="/root/setup-hooks-manifest.txt"
HOOKS_DIR="/root/setup-hooks"

if [[ -f "${HOOKS_MANIFEST}" && -d "${HOOKS_DIR}" ]]; then
  echo "Found embedded setup hooks. Running..."
  while IFS= read -r hook_name; do
    [[ -z "$hook_name" ]] && continue
    hook_path="${HOOKS_DIR}/${hook_name}"
    if [[ -x "$hook_path" ]]; then
      echo "  Executing hook: $hook_name"
      bash "$hook_path" || {
        echo "    Warning: hook $hook_name failed. Continuing..."
      }
    fi
  done < "${HOOKS_MANIFEST}"
fi

rm -f /root/installer.env /root/post_install.sh
EOF

chmod +x /mnt/root/post_install.sh

echo "Running post-install inside chroot..."
arch-chroot /mnt /root/post_install.sh

if [[ -f /tmp/pacman-offline.conf ]]; then
  rm -f /tmp/pacman-offline.conf
fi

echo ""
echo "Install complete."
read -rp "Unmount and reboot now? [Y/n]: " REBOOT_NOW
if [[ "${REBOOT_NOW:-Y}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  umount -R /mnt
  reboot
else
  echo "Leaving /mnt mounted for manual checks."
fi
