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

PROMPT_TTY=""
if [[ -t 0 ]]; then
  PROMPT_TTY="/dev/tty"
elif [[ -r /dev/tty1 && -w /dev/tty1 ]]; then
  PROMPT_TTY="/dev/tty1"
elif [[ -r /dev/tty && -w /dev/tty ]]; then
  PROMPT_TTY="/dev/tty"
else
  echo "Interactive TTY is not available (/dev/tty or /dev/tty1)."
  echo "Run this script from the local VM console so prompts can accept input."
  exit 1
fi
echo "Using prompt TTY: ${PROMPT_TTY}"

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  printf "%s" "${prompt}" > "${PROMPT_TTY}"
  if ! IFS= read -r value < "${PROMPT_TTY}"; then
    echo "Input aborted."
    exit 1
  fi

  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi

  printf "%s" "${value}"
}

prompt_required() {
  local prompt="$1"
  local value=""

  while true; do
    printf "%s" "${prompt}" > "${PROMPT_TTY}"
    if ! IFS= read -r value < "${PROMPT_TTY}"; then
      echo "Input aborted."
      exit 1
    fi

    if [[ -n "${value}" ]]; then
      printf "%s" "${value}"
      return
    fi

    printf "Please provide a value.\n" > "${PROMPT_TTY}"
  done
}

prompt_secret_required() {
  local prompt="$1"
  local value=""

  while true; do
    printf "%s" "${prompt}" > "${PROMPT_TTY}"
    if ! IFS= read -rs value < "${PROMPT_TTY}"; then
      echo "Input aborted."
      exit 1
    fi
    printf "\n" > "${PROMPT_TTY}"

    if [[ -n "${value}" ]]; then
      printf "%s" "${value}"
      return
    fi

    printf "Value cannot be empty.\n" > "${PROMPT_TTY}"
  done
}

echo ""
echo "Detected block devices:"
lsblk -d -o NAME,SIZE,MODEL,TYPE
echo ""

DISK="$(prompt_default "Install disk (default: /dev/nvme0n1): " "/dev/nvme0n1")"

if [[ ! -b "${DISK}" ]]; then
  echo "Disk ${DISK} does not exist."
  exit 1
fi

HOSTNAME="$(prompt_default "Hostname (default: arch): " "arch")"

USERNAME="$(prompt_default "Username (default: ed): " "ed")"

TIMEZONE="$(prompt_default "Timezone (default: Europe/Berlin): " "Europe/Berlin")"

INSTALL_PROFILE="$(prompt_default "Install profile [generic/hyperv] (default: generic): " "generic")"
INSTALL_PROFILE="${INSTALL_PROFILE,,}"
INSTALL_PROFILE="${INSTALL_PROFILE//[[:space:]]/}"
if [[ "${INSTALL_PROFILE}" != "generic" && "${INSTALL_PROFILE}" != "hyperv" ]]; then
  echo "Unsupported install profile: ${INSTALL_PROFILE}"
  exit 1
fi

ENABLE_GNOME="$(prompt_default "Enable GNOME desktop? [Y/n]: " "Y")"

OFFLINE_REPO_PRIMARY="/opt/offline-repo"
OFFLINE_REPO_SECONDARY="/run/archiso/bootmnt/offline-repo"
OFFLINE_REPO_PATH=""
if [[ -d "${OFFLINE_REPO_PRIMARY}" ]]; then
  OFFLINE_REPO_PATH="${OFFLINE_REPO_PRIMARY}"
elif [[ -d "${OFFLINE_REPO_SECONDARY}" ]]; then
  OFFLINE_REPO_PATH="${OFFLINE_REPO_SECONDARY}"
fi

INSTALL_MODE="$(prompt_default "Install mode [auto/offline/online] (default: auto): " "auto")"
INSTALL_MODE="${INSTALL_MODE,,}"
INSTALL_MODE="${INSTALL_MODE//[[:space:]]/}"

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

ROOT_PASSWORD="$(prompt_secret_required "Root password: ")"
USER_PASSWORD="$(prompt_secret_required "User password for ${USERNAME}: ")"

echo ""
echo "This will erase ALL data on ${DISK}."
CONFIRM="$(prompt_required "Type YES to continue: ")"
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

BASE_PKGS=(base linux nano networkmanager sudo grub efibootmgr)
if [[ "${INSTALL_PROFILE}" != "hyperv" ]]; then
  BASE_PKGS+=(linux-firmware)
else
  echo "Install profile is hyperv: skipping linux-firmware package."
fi
if [[ "${ENABLE_GNOME}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  BASE_PKGS+=(gnome gdm)
fi

install_base_with_fallback() {
  local pacstrap_args=("$@")
  if pacstrap "${pacstrap_args[@]}" /mnt "${BASE_PKGS[@]}"; then
    return 0
  fi

  if [[ " ${BASE_PKGS[*]} " == *" linux-firmware "* ]]; then
    echo "Base install failed; retrying once without linux-firmware..."
    local reduced_pkgs=()
    local p
    for p in "${BASE_PKGS[@]}"; do
      if [[ "${p}" != "linux-firmware" ]]; then
        reduced_pkgs+=("${p}")
      fi
    done
    BASE_PKGS=("${reduced_pkgs[@]}")
    pacstrap "${pacstrap_args[@]}" /mnt "${BASE_PKGS[@]}"
    return 0
  fi

  return 1
}

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
  pacman -Sy --noconfirm --config /tmp/pacman-offline.conf
  echo "Installing base system with pacstrap from offline repository..."
  install_base_with_fallback -C /tmp/pacman-offline.conf
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
  install_base_with_fallback
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
INSTALL_PROFILE=$(printf '%q' "${INSTALL_PROFILE}")
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
REBOOT_NOW="$(prompt_default "Unmount and reboot now? [Y/n]: " "Y")"
if [[ "${REBOOT_NOW}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  umount -R /mnt
  reboot
else
  echo "Leaving /mnt mounted for manual checks."
fi
