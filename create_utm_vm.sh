#!/usr/bin/env bash
# create_utm_vm.sh
# Usage:
#   ./create_utm_vm.sh <vm-name> <disk-size-gb> <ssh-key-file> <cloud-init-packages-csv>
#
# Example:
#   ./create_utm_vm.sh LAB-GW 4 ~/.ssh/id_rsa.pub "wireguard,iptables"
#
set -euo pipefail

VM_NAME="$1"
DISK_GB="${2:-4}"
SSH_KEY_FILE="${3:-}"
CLOUD_PKGS="${4:-}"   # comma separated packages for cloud-init install

find_docs_dir() {
  local candidates=(
    "$HOME/Library/Group Containers/group.com.utmapp.UTM/Documents"
    "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done

  return 1
}

UTM_DOCS="$(find_docs_dir || true)"

if [[ -z "$UTM_DOCS" ]]; then
  echo "UTM documents directory not found in either '~/Library/Group Containers/group.com.utmapp.UTM/Documents' or '~/Library/Containers/com.utmapp.UTM/Data/Documents'. Launch UTM once to initialize it." >&2
  exit 1
fi

VM_DIR="${UTM_DOCS}/${VM_NAME}.utm"
DATA_DIR="${VM_DIR}/Data"
DISK_FILE="${DATA_DIR}/${VM_NAME}.qcow2"
CLOUD_ISO="${DATA_DIR}/seed.iso"
CONFIG_PLIST="${VM_DIR}/config.plist"

mkdir -p "${DATA_DIR}"

echo "Creating qcow2 disk (${DISK_GB}G) at ${DISK_FILE}..."
qemu-img create -f qcow2 "${DISK_FILE}" "${DISK_GB}G"

# Create cloud-init user-data + meta-data if SSH key provided or packages listed
if [[ -n "${SSH_KEY_FILE}" || -n "${CLOUD_PKGS}" ]]; then
  echo "Generating cloud-init ISO..."
  cat > "${DATA_DIR}/user-data" <<EOF
#cloud-config
users:
  - name: labuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
EOF
  if [[ -n "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}" ]]; then
    cat "${SSH_KEY_FILE}" >> "${DATA_DIR}/user-data"
  fi

  if [[ -n "${CLOUD_PKGS}" ]]; then
    echo "packages:" >> "${DATA_DIR}/user-data"
    IFS=',' read -ra PKGS <<< "${CLOUD_PKGS}"
    for p in "${PKGS[@]}"; do
      echo "  - ${p}" >> "${DATA_DIR}/user-data"
    done
  fi

  cat > "${DATA_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

  # Create ISO using genisoimage if available; fallback to hdiutil
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "${CLOUD_ISO}" -volid cidata -joliet -rock "${DATA_DIR}/user-data" "${DATA_DIR}/meta-data"
  else
    # Use hdiutil on macOS
    (cd "${DATA_DIR}" && hdiutil makehybrid -o seed.iso -hfs -joliet -iso -default-volume-name cidata user-data meta-data)
  fi
  echo "Cloud-init seed generated at ${CLOUD_ISO}"
fi

# Generate a minimal config.plist
# NOTE: This plist is intentionally minimal. UTM may require tweaks in the GUI for display, QEMU args, or other options.
cat > "${CONFIG_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>name</key>
  <string>__VMNAME__</string>
  <key>arch</key>
  <string>aarch64</string>
  <key>system</key>
  <dict>
    <key>type</key>
    <string>qemu</string>
  </dict>
  <key>drives</key>
  <array>
    <dict>
      <key>ImagePath</key>
      <string>Data/__DISKFILE__</string>
      <key>Interface</key>
      <string>virtio</string>
      <key>ImageType</key>
      <string>qcow2</string>
    </dict>
PLIST

# if cloud-init iso exists, add it as CD drive entry
if [[ -f "${CLOUD_ISO}" ]]; then
  cat >> "${CONFIG_PLIST}" <<PLIST
    <dict>
      <key>ImagePath</key>
      <string>Data/seed.iso</string>
      <key>Interface</key>
      <string>ide</string>
      <key>ImageType</key>
      <string>iso</string>
    </dict>
PLIST
fi

cat >> "${CONFIG_PLIST}" <<'PLIST'
  </array>
  <key>networks</key>
  <array>
    <dict>
      <key>NetworkType</key>
      <string>bridged</string>
      <key>DeviceType</key>
      <string>net</string>
    </dict>
  </array>
  <key>qemu</key>
  <dict>
    <key>cpu</key>
    <dict>
      <key>cores</key>
      <integer>1</integer>
    </dict>
    <key>memory</key>
    <integer>512</integer>
  </dict>
</dict>
</plist>
PLIST

# replace placeholders
sed -i '' "s|__VMNAME__|${VM_NAME}|g" "${CONFIG_PLIST}"
sed -i '' "s|__DISKFILE__|${VM_NAME}.qcow2|g" "${CONFIG_PLIST}"

echo "Created UTM package at ${VM_DIR}"
echo "You can now open UTM — the VM ${VM_NAME} should appear. Adjust network mode to host-only if required in the GUI."