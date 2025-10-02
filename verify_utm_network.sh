#!/usr/bin/env bash
# verify_utm_network.sh
# Verify a UTM network exists and print the backing interface + subnet (host/shared).
# Usage: ./verify_utm_network.sh <network-name> [timeout-seconds]
# Example: ./verify_utm_network.sh lab-net 30

set -euo pipefail

NET_NAME="${1:-}"
TIMEOUT="${2:-30}"

if [[ -z "$NET_NAME" ]]; then
  echo "Usage: $0 <network-name> [timeout-seconds]" >&2
  exit 1
fi

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

UTM_PREF_DIR="$(find_pref_dir || true)"

if [[ -z "$UTM_PREF_DIR" ]]; then
  echo "UTM preferences dir not found in either '~/Library/Group Containers/group.com.utmapp.UTM/Library/Preferences/UTM' or '~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/UTM'. Open UTM once to initialize preferences." >&2
  exit 1
fi

UTM_NETS_PLIST="${UTM_PREF_DIR}/networks.plist"
VMNET_SYS_PLIST="/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist"

if [[ ! -f "$UTM_NETS_PLIST" ]]; then
  echo "UTM networks.plist not found under ${UTM_PREF_DIR}. Open UTM once and create a network (or use your create script)." >&2
  exit 1
fi

# Find matching network dict index by Name
INDEX=$(/usr/libexec/PlistBuddy -c 'Print :' "$UTM_NETS_PLIST" \
  | awk -v name="$NET_NAME" '
     $0 ~ /Dict {/ {i++}
     $0 ~ /Name/ && getline && $0 ~ name {print i-1; exit}
  ')

if [[ -z "${INDEX:-}" ]]; then
  echo "No UTM network named '$NET_NAME' found in $UTM_NETS_PLIST" >&2
  exit 1
fi

TYPE=$(/usr/libexec/PlistBuddy -c "Print :$INDEX:Type" "$UTM_NETS_PLIST" 2>/dev/null || echo "unknown")
UUID=$(/usr/libexec/PlistBuddy -c "Print :$INDEX:UUID" "$UTM_NETS_PLIST" 2>/dev/null || echo "n/a")

echo "UTM network:"
echo "  Name : $NET_NAME"
echo "  Type : $TYPE   (host=host-only, shared=NAT, bridged=bridge)"
echo "  UUID : $UUID"
echo

if [[ "$TYPE" == "bridged" ]]; then
  echo "Bridged networks do not have a vmnet-managed subnet. Attach VMs and check the bridged NIC in macOS Network." 
  exit 0
fi

# We’ll read vmnet's system plist for assigned service addresses.
if [[ ! -r "$VMNET_SYS_PLIST" ]]; then
  echo "Need read access to $VMNET_SYS_PLIST (try: sudo). Re-run with sudo if required." >&2
  exit 1
fi

# Collect candidate gateway IPs for shared/host
readarray -t HOSTONLY_GWS < <(/usr/libexec/PlistBuddy -c 'Print :HostOnly_Net_Address' "$VMNET_SYS_PLIST" 2>/dev/null | awk '/=/{print $3}')
readarray -t SHARED_GWS   < <(/usr/libexec/PlistBuddy -c 'Print :Shared_Net_Address'   "$VMNET_SYS_PLIST" 2>/dev/null | awk '/=/{print $3}')

# Pick the set to match based on type
declare -a CANDIDATES=()
if [[ "$TYPE" == "host" ]]; then
  CANDIDATES=("${HOSTONLY_GWS[@]}")
elif [[ "$TYPE" == "shared" ]]; then
  CANDIDATES=("${SHARED_GWS[@]}")
else
  echo "Unknown Type '$TYPE' in networks.plist. Cannot verify." >&2
  exit 1
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No vmnet addresses found yet. Make sure UTM is running and the network is enabled." >&2
fi

# Poll for an interface whose inet matches one of the vmnet gateway IPs
deadline=$(( $(date +%s) + TIMEOUT ))
FOUND_IF=""
FOUND_IP=""

while [[ $(date +%s) -le $deadline ]]; do
  for ip in "${CANDIDATES[@]}"; do
    [[ -z "$ip" ]] && continue
    IFACE=$(ifconfig -l | tr ' ' '\n' | while read -r i; do
      if ifconfig "$i" 2>/dev/null | grep -qw "inet $ip"; then echo "$i"; break; fi
    done)
    if [[ -n "$IFACE" ]]; then
      FOUND_IF="$IFACE"
      FOUND_IP="$ip"
      break 2
    fi
  done
  sleep 1
done

if [[ -z "$FOUND_IF" ]]; then
  echo "Timed out waiting ($TIMEOUT s) for a vmnet interface. Ensure UTM is open and the network '$NET_NAME' is enabled." >&2
  echo "Tip: Open UTM → Preferences → Networks to confirm. Then re-run this script."
  exit 2
fi

# Derive /24 subnet from gateway IP (most vmnet nets are /24; adjust if you use custom masks)
SUBNET="$(echo "$FOUND_IP" | awk -F. '{printf "%d.%d.%d.0/24", $1,$2,$3}')"

echo "Backed by interface: $FOUND_IF"
echo "Gateway IP (host side): $FOUND_IP"
echo "Assumed subnet: $SUBNET"
echo
echo "Routes:"
netstat -nr | egrep "Destination|$SUBNET" || true

exit 0