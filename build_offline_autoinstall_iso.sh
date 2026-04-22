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
MIN_FREE_GB="${MIN_FREE_GB:-30}"
INSTALL_PROFILE="${INSTALL_PROFILE:-generic}"
INSTALL_PROFILE="${INSTALL_PROFILE,,}"
INSTALL_PROFILE="${INSTALL_PROFILE//[[:space:]]/}"

if [[ "${INSTALL_PROFILE}" != "generic" && "${INSTALL_PROFILE}" != "hyperv" ]]; then
  echo "Unsupported INSTALL_PROFILE='${INSTALL_PROFILE}'. Use 'generic' or 'hyperv'."
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needed for mkarchiso and package cache writes)."
  exit 1
fi

for cmd in mkarchiso repo-add pacman rsync git; do
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

if ! command -v findmnt >/dev/null 2>&1; then
  echo "Missing command: findmnt"
  echo "Install util-linux, then retry."
  exit 1
fi

fs_info="$(findmnt -no TARGET,SOURCE,FSTYPE,AVAIL -T "${WORK_ROOT}" 2>/dev/null || true)"
if [[ -z "${fs_info}" ]]; then
  echo "Could not determine filesystem info for ${WORK_ROOT}."
  exit 1
fi

echo "Build target filesystem: ${fs_info}"
fs_type="$(awk '{print $3}' <<< "${fs_info}")"
if [[ "${fs_type}" == "overlay" || "${fs_type}" == "tmpfs" || "${fs_type}" == "squashfs" ]]; then
  echo "WORK_ROOT (${WORK_ROOT}) is on ${fs_type}, which is not suitable for large ISO builds."
  echo "Mount persistent disk storage (e.g. /mnt/build) and run the script from there."
  exit 1
fi

min_required_kb=$(( MIN_FREE_GB * 1024 * 1024 ))
available_kb="$(df -Pk "${WORK_ROOT}" | awk 'NR==2 {print $4}')"
if [[ -z "${available_kb}" || "${available_kb}" -lt "${min_required_kb}" ]]; then
  echo "Not enough free space under ${WORK_ROOT}. Need at least ${MIN_FREE_GB} GiB free for package cache + ISO build."
  df -h "${WORK_ROOT}"
  exit 1
fi

# Quick write test so write-destination failures are detected before long downloads.
mkdir -p "${WORK_ROOT}/.build-write-test"
if ! dd if=/dev/zero of="${WORK_ROOT}/.build-write-test/probe.bin" bs=1M count=64 conv=fsync status=none; then
  echo "Write test failed on ${WORK_ROOT}. Check guest disk health and host free space."
  rm -rf "${WORK_ROOT}/.build-write-test"
  exit 1
fi
rm -rf "${WORK_ROOT}/.build-write-test"

echo "Preparing ArchISO profile..."
rm -rf "${PROFILE_DIR}"
cp -a /usr/share/archiso/configs/releng "${PROFILE_DIR}"

PROFILE_PKGS_FILE="${PROFILE_DIR}/packages.x86_64"
if [[ ! -f "${PROFILE_PKGS_FILE}" ]]; then
  echo "ArchISO profile package list not found: ${PROFILE_PKGS_FILE}"
  exit 1
fi

if [[ "${INSTALL_PROFILE}" == "hyperv" ]]; then
  tmp_pkgs_file="${PROFILE_PKGS_FILE}.tmp"
  grep -vE '^linux-firmware([[:space:]]|$)' "${PROFILE_PKGS_FILE}" > "${tmp_pkgs_file}"
  mv "${tmp_pkgs_file}" "${PROFILE_PKGS_FILE}"
  echo "INSTALL_PROFILE=hyperv -> removed linux-firmware from ArchISO live profile package list."
fi

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
StandardInput=tty-force
StandardOutput=journal+console
StandardError=journal+console
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
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
  nano
  networkmanager
  sudo
  grub
  efibootmgr
  gnome
  gdm
)

OPTIONAL_PKGS=()

if [[ "${INSTALL_PROFILE}" != "hyperv" ]]; then
  OPTIONAL_PKGS+=(linux-firmware)
else
  echo "INSTALL_PROFILE=hyperv -> omitting linux-firmware from offline package set."
fi

echo "Effective INSTALL_PROFILE: ${INSTALL_PROFILE}"
echo "Offline required package set: ${PKGS[*]}"
if (( ${#OPTIONAL_PKGS[@]} > 0 )); then
  echo "Offline optional package set: ${OPTIONAL_PKGS[*]}"
fi

echo "Downloading packages and dependencies for offline repo..."

PACMAN_DL_CONF="${WORK_ROOT}/pacman-offline-build.conf"
cat > "${PACMAN_DL_CONF}" <<'EOF'
[options]
Architecture = auto
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 1

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

download_pkgs() {
  pacman -Syy --noconfirm --config "${PACMAN_DL_CONF}" >/dev/null
  pacman -Sw --noconfirm --cachedir "${REPO_DIR}" --config "${PACMAN_DL_CONF}" "${PKGS[@]}"
}

if ! download_pkgs; then
  echo "First package download attempt failed. Cleaning partial files and retrying once..."
  find "${REPO_DIR}" -type f \( -name '*.part' -o -name '*.db.part' -o -name '*.sig.part' \) -delete
  download_pkgs
fi

if (( ${#OPTIONAL_PKGS[@]} > 0 )); then
  echo "Downloading optional packages (non-fatal): ${OPTIONAL_PKGS[*]}"
  if ! pacman -Sw --noconfirm --cachedir "${REPO_DIR}" --config "${PACMAN_DL_CONF}" "${OPTIONAL_PKGS[@]}"; then
    echo "Optional package download failed. Continuing without optional packages."
    find "${REPO_DIR}" -type f \( -name '*.part' -o -name '*.db.part' -o -name '*.sig.part' \) -delete
  fi
fi

shopt -s nullglob
pkg_files=("${REPO_DIR}"/*.pkg.tar.zst)
if (( ${#pkg_files[@]} == 0 )); then
  echo "No package files found in ${REPO_DIR}."
  exit 1
fi

rm -f "${REPO_DIR}/offline.db*" "${REPO_DIR}/offline.files*"
repo-add "${REPO_DIR}/offline.db.tar.gz" "${pkg_files[@]}"

# Process setup hooks from repos (embed scripts in ISO for offline execution)
HOOKS_DIR="${PROFILE_DIR}/airootfs/root/setup-hooks"
HOOKS_MANIFEST="${PROFILE_DIR}/airootfs/root/setup-hooks-manifest.txt"
SETUP_HOOKS_CONF="${WORK_ROOT}/setup-hooks.conf"

if [[ -f "${SETUP_HOOKS_CONF}" ]]; then
  mkdir -p "${HOOKS_DIR}"
  > "${HOOKS_MANIFEST}"

  echo "Processing setup hooks from ${SETUP_HOOKS_CONF}..."
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Parse: REPO_URL SCRIPT1 SCRIPT2 ...
    read -r repo_url scripts_str <<< "$line"
    
    if [[ -z "$repo_url" ]]; then
      continue
    fi

    echo "  Cloning $repo_url..."
    temp_clone="/tmp/setup-hooks-$$-$(basename "$repo_url" .git)"
    git clone --depth 1 "$repo_url" "$temp_clone" 2>/dev/null || {
      echo "    Warning: failed to clone $repo_url. Skipping."
      continue
    }

    # Copy each specified script
    if [[ -z "$scripts_str" ]]; then
      scripts_str="setup.sh post-install.sh"
    fi

    for script in $scripts_str; do
      script_path="${temp_clone}/${script}"
      if [[ -f "$script_path" ]]; then
        script_name=$(basename "$script" .sh)_$(echo "$repo_url" | md5sum | cut -d' ' -f1 | cut -c1-8)
        hook_dest="${HOOKS_DIR}/${script_name}.sh"
        cp -f "$script_path" "$hook_dest"
        chmod +x "$hook_dest"
        echo "${script_name}.sh" >> "${HOOKS_MANIFEST}"
        echo "    Embedded: $script"
      fi
    done

    rm -rf "$temp_clone"
  done < "${SETUP_HOOKS_CONF}"

  if [[ -f "${HOOKS_MANIFEST}" && -s "${HOOKS_MANIFEST}" ]]; then
    echo "Setup hooks manifest created with $(wc -l < "${HOOKS_MANIFEST}") hooks."
  fi
else
  echo "No setup-hooks.conf found. Skipping hooks processing."
fi

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
