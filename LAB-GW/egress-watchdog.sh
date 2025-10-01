#!/bin/bash
# egress-watchdog.sh
set -euo pipefail

CLOUD_IP="203.0.113.45"  # <<< replace
CHECK_PORT=443
LAB_NET="10.0.100.0/24"
DROP_RULE="-s ${LAB_NET} -j DROP"
IF_EXT="eth1"

# simple check: try to connect to CLOUD_IP:443 via /dev/tcp using the outgoing interface IP
# find eth1 IP
EXT_IP=$(ip -4 -o addr show dev ${IF_EXT} | awk '{print $4}' | cut -d/ -f1 || true)

check_conn() {
  # use timeout to limit blocking
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${CLOUD_IP}/${CHECK_PORT}" >/dev/null 2>&1 && return 0
  return 1
}

apply_fail_closed() {
  # insert DROP if not present
  if ! iptables -C FORWARD ${DROP_RULE} >/dev/null 2>&1; then
    iptables -I FORWARD 1 -s ${LAB_NET} -j DROP
    logger -t egress-watchdog "Egress check failed — applied fail-closed"
  fi
}

remove_fail_closed() {
  # remove any DROP applied by us
  while iptables -C FORWARD ${DROP_RULE} >/dev/null 2>&1; do
    iptables -D FORWARD -s ${LAB_NET} -j DROP || break
    logger -t egress-watchdog "Egress OK — removed fail-closed"
  done
}

if check_conn; then
  remove_fail_closed
  exit 0
else
  apply_fail_closed
  exit 2
fi