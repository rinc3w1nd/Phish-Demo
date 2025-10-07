#!/bin/bash
# create_utm_network.sh
# Usage: ./create_utm_network.sh <network-name> <type>
# Type must be: host | shared | bridged

set -euo pipefail

NET_NAME="${1:-lab-net}"
NET_TYPE="${2:-host}"   # default to host-only

find_pref_dir() {
  local candidates=(
    "$HOME/Library/Group Containers/group.com.utmapp.UTM/Library/Preferences/UTM"
    "$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/UTM"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  done

  return 1
}

PREF_DIR="$(find_pref_dir || true)"

if [[ -z "$PREF_DIR" ]]; then
  echo "UTM preferences dir not found in either '~/Library/Group Containers/group.com.utmapp.UTM/Library/Preferences/UTM' or '~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/UTM'. Did you run UTM once?"
  exit 1
fi

PREF_FILE="${PREF_DIR}/networks.plist"

case "$NET_TYPE" in
  host|shared|bridged) ;;
  *) echo "Invalid type. Must be 'host', 'shared', or 'bridged'." ; exit 1 ;;
esac

UUID=$(uuidgen)

TMP_PLIST=$(mktemp)
cat > "$TMP_PLIST" <<EOF
<dict>
  <key>Enabled</key>
  <true/>
  <key>Name</key>
  <string>${NET_NAME}</string>
  <key>Type</key>
  <string>${NET_TYPE}</string>
  <key>UUID</key>
  <string>${UUID}</string>
</dict>
EOF

# Initialize networks.plist if missing
if [[ ! -f "$PREF_FILE" ]]; then
  cat > "$PREF_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
</array>
</plist>
EOF
fi

# Append new entry at end of array
/usr/libexec/PlistBuddy -c "Add : dict" "$PREF_FILE"
/usr/libexec/PlistBuddy -c "Merge $TMP_PLIST :$(( $(/usr/libexec/PlistBuddy -c 'Print :' "$PREF_FILE" | grep -c '^    Dict {') - 1 ))" "$PREF_FILE"

rm "$TMP_PLIST"

echo "Created UTM network '${NET_NAME}' of type '${NET_TYPE}' with UUID ${UUID}"
echo "Restart UTM to see it in the GUI."