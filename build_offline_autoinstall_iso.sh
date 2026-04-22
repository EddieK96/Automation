#!/usr/bin/env bash
set -euo pipefail

# Build a custom Arch ISO that:
# 1) auto-runs arch_usb_auto_install.sh on boot
# 2) carries an offline package repository in /opt/offline-repo
#
# Run this on an Arch Linux machine (or Arch container/VM), not on Windows.

PROFILE_NAME="archiso-offline-autoinstall"
SCRIPT_SOURCE="${SCRIPT_SOURCE:-./arch_usb_auto_install.sh}"
WORK_ROOT="${WORK_ROOT:-$PWD}"
PROFILE_DIR="${WORK_ROOT}/${PROFILE_NAME}"
WORK_DIR="${WORK_ROOT}/work"
OUT_DIR="${WORK_ROOT}/out"
REPO_DIR="${PROFILE_DIR}/airootfs/opt/offline-repo"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needed for mkarchiso and package cache writes)."
  exit 1
fi

for cmd in mkarchiso repo-add pacman rsync; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing command: ${cmd}"
    echo "Install required tools, e.g. pacman -S --needed archiso pacman-contrib rsync"
    exit 1
  fi
done

if [[ ! -f "${SCRIPT_SOURCE}" ]]; then
  echo "Installer script not found: ${SCRIPT_SOURCE}"
  exit 1
fi

echo "Preparing ArchISO profile..."
rm -rf "${PROFILE_DIR}"
cp -a /usr/share/archiso/configs/releng "${PROFILE_DIR}"

mkdir -p "${PROFILE_DIR}/airootfs/root"
mkdir -p "${PROFILE_DIR}/airootfs/etc/systemd/system/multi-user.target.wants"
mkdir -p "${REPO_DIR}"

cp -f "${SCRIPT_SOURCE}" "${PROFILE_DIR}/airootfs/root/arch_usb_auto_install.sh"
chmod +x "${PROFILE_DIR}/airootfs/root/arch_usb_auto_install.sh"

cat > "${PROFILE_DIR}/airootfs/etc/systemd/system/arch-autoinstall.service" <<'EOF'
[Unit]
Description=Run Arch auto installer
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /root/arch_usb_auto_install.sh
StandardInput=tty
TTYPath=/dev/tty1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ln -sf /etc/systemd/system/arch-autoinstall.service \
  "${PROFILE_DIR}/airootfs/etc/systemd/system/multi-user.target.wants/arch-autoinstall.service"

# Package set needed by the target installation script.
# You can extend this list if you want additional software available offline.
PKGS=(
  base
  linux
  linux-firmware
  nano
  networkmanager
  sudo
  grub
  efibootmgr
  gnome
  gdm
)

echo "Downloading packages and dependencies for offline repo..."
pacman -Syw --noconfirm --cachedir "${REPO_DIR}" "${PKGS[@]}"

shopt -s nullglob
pkg_files=("${REPO_DIR}"/*.pkg.tar.zst)
if (( ${#pkg_files[@]} == 0 )); then
  echo "No package files found in ${REPO_DIR}."
  exit 1
fi

rm -f "${REPO_DIR}/offline.db*" "${REPO_DIR}/offline.files*"
repo-add "${REPO_DIR}/offline.db.tar.gz" "${pkg_files[@]}"

echo "Building ISO..."
rm -rf "${WORK_DIR}" "${OUT_DIR}"
mkarchiso -v -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"

LATEST_LINK_NAME="archlinux-latest-x86_64.iso"
latest_iso="$(ls -1t "${OUT_DIR}"/archlinux-*.iso 2>/dev/null | head -n 1 || true)"
if [[ -n "${latest_iso}" && -f "${latest_iso}" ]]; then
  cp -f "${latest_iso}" "${WORK_ROOT}/${LATEST_LINK_NAME}"
fi

echo "Done. ISO output is in: ${OUT_DIR}"
ls -lh "${OUT_DIR}"
if [[ -f "${WORK_ROOT}/${LATEST_LINK_NAME}" ]]; then
  echo "Latest ISO shortcut updated: ${WORK_ROOT}/${LATEST_LINK_NAME}"
fi
