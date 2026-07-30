#!/usr/bin/env bash
# Fix wifi on a minimal AlmaLinux/RHEL 10 install (no NetworkManager-wifi plugin),
# and pre-empt the same-subnet dual-homed rp_filter issue if wired + wifi ever
# share a network at the same time (e.g. during provisioning before relocation).
#
# Usage:
#   sudo ./fix-wifi.sh                                  # plugin + rp_filter fix only
#   sudo ./fix-wifi.sh -s "SSID"                         # also connect, prompts for password
#   sudo ./fix-wifi.sh -s "SSID" -p "password"           # also connect, non-interactive
#   sudo ./fix-wifi.sh -s "SSID" -i wlp3s0               # override auto-detected interface
set -euo pipefail

ssid=""
password=""
iface=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--ssid) ssid="$2"; shift 2 ;;
    -p|--password) password="$2"; shift 2 ;;
    -i|--interface) iface="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (sudo)." >&2
  exit 1
fi

echo "== Checking NetworkManager wifi support =="
if rpm -q NetworkManager-wifi &>/dev/null; then
  echo "NetworkManager-wifi already installed."
else
  # Symptom without this package: `nmcli device status` shows the wifi NIC as
  # unmanaged, and `journalctl -u NetworkManager` logs:
  #   "'wifi' plugin not available; creating generic device"
  # NetworkManager then treats the radio as a generic device and can't apply
  # wifi connection profiles to it at all, regardless of rfkill/driver state.
  echo "Installing NetworkManager-wifi and wpa_supplicant..."
  dnf install -y NetworkManager-wifi wpa_supplicant
  echo "Restarting NetworkManager to load the plugin..."
  systemctl restart NetworkManager
  sleep 2
fi

if [[ -z "$iface" ]]; then
  iface=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
fi

if [[ -z "$iface" ]]; then
  echo "No wifi device found (nmcli sees none). Check hardware/rfkill and rerun with -i to override." >&2
  exit 1
fi
echo "Using wifi interface: $iface"

echo "== Loosening reverse-path filtering on $iface =="
# When this interface and another (e.g. wired eno1) end up on the same subnet
# at the same time, strict rp_filter (the RHEL default) silently drops reply
# packets that arrive on this interface but whose "best route back" the
# kernel would otherwise send via the other interface. Loose mode (2) only
# drops a packet if there's no route back through ANY interface, which is
# what you actually want on a machine that may be temporarily dual-homed.
cat > "/etc/sysctl.d/99-${iface}-rp-filter.conf" <<EOF
net.ipv4.conf.${iface}.rp_filter = 2
EOF
sysctl -p "/etc/sysctl.d/99-${iface}-rp-filter.conf"

if [[ -n "$ssid" ]]; then
  echo "== Connecting to '$ssid' =="
  if [[ -z "$password" ]]; then
    read -r -s -p "Password for '$ssid': " password
    echo
  fi
  nmcli device wifi rescan ifname "$iface" || true
  sleep 2
  nmcli device wifi connect "$ssid" password "$password" ifname "$iface"
  nmcli -t -f connection.autoconnect connection show "$ssid" || true
fi

echo "== Done =="
nmcli device status
