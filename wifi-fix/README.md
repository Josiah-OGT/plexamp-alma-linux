# Wifi fix for minimal AlmaLinux/RHEL 10 installs

Codifies a fix worked out live against a Lenovo ThinkCentre M900 running
AlmaLinux 10.2 (minimal install) — the wifi adapter (Intel Dual Band
Wireless-AC 8260) was hardware-functional but NetworkManager couldn't drive
it, and once connected, replies were being silently dropped due to a routing
conflict with the wired interface. Both issues are generic to minimal
RHEL-family installs, not specific to that one machine.

## Issue 1: wifi device stuck "unmanaged"

**Symptom:**
```
$ nmcli device status
wlp2s0    wifi    unmanaged    --
```
```
$ journalctl -u NetworkManager | grep wlp2s0
NetworkManager[949]: <info> manager: (wlp2s0): 'wifi' plugin not available; creating generic device
```
rfkill shows nothing blocked, the `iwlwifi` kernel driver loads fine, firmware
loads fine — the radio itself works. NetworkManager just can't do anything
wifi-specific with it.

**Root cause:** minimal AlmaLinux/RHEL 10 installs don't include
`NetworkManager-wifi` (the plugin that gives NM wifi scanning/connection
support) or `wpa_supplicant` (which it depends on for WPA auth) by default.
Without the plugin, NM falls back to treating the radio as a bare "generic"
device — no wifi profiles can be applied to it, regardless of driver or
rfkill state.

**Fix:** `dnf install -y NetworkManager-wifi wpa_supplicant`, then
`systemctl restart NetworkManager`.

## Issue 2: connected, but no traffic (dual-homed same subnet)

**Symptom:** wifi shows "connected" with a valid IP, but pings to the gateway
or internet get ~100% packet loss, while a wired interface on the same box
works fine at the same time. `tcpdump` on the wifi interface shows replies
*arriving* — they're just not making it up the stack.

**Root cause:** this only bites when a wired and wireless interface end up on
the **same subnet** at the same time (e.g. testing wifi over SSH while still
plugged into ethernet, before physically relocating a machine). RHEL's
default reverse-path filtering is strict (`rp_filter = 1`): a reply packet
arriving on interface A gets dropped if the kernel's routing table would
prefer to route back to that source via interface B instead — which is
exactly the situation here, since the wired connection typically has a lower
(preferred) route metric.

**Fix:** loosen rp_filter to mode 2 ("loose") on the wifi interface
specifically — it only drops a packet if there's no route back through *any*
interface, rather than requiring it match the specific one:
```
echo 'net.ipv4.conf.<iface>.rp_filter = 2' > /etc/sysctl.d/99-<iface>-rp-filter.conf
sysctl -p /etc/sysctl.d/99-<iface>-rp-filter.conf
```
This is safe to apply even on a machine that's never going to be dual-homed
— it's a no-op there.

## Usage

```bash
sudo ./fix-wifi.sh                                # fix plugin + rp_filter only
sudo ./fix-wifi.sh -s "Your SSID"                 # also connect (prompts for password)
sudo ./fix-wifi.sh -s "Your SSID" -p "password"   # non-interactive
sudo ./fix-wifi.sh -s "Your SSID" -i wlp3s0        # override auto-detected interface name
```

Idempotent — safe to re-run. Auto-detects the wifi interface name via
`nmcli`; only pass `-i` if there's more than one wifi device or detection
picks the wrong one. No credentials are stored in this script or written to
disk anywhere by it, beyond what `nmcli`/NetworkManager itself persists in
`/etc/NetworkManager/system-connections/` when you connect (standard NM
behavior, root-readable only).

## What this doesn't cover

Disabling a wired connection once wifi is confirmed working
(`nmcli connection modify <conn> connection.autoconnect no` +
`nmcli connection down <conn>`) was a separate, deliberate manual step for a
specific machine being relocated off ethernet — not something this script
does automatically, since whether you want that depends on the deployment,
not the wifi bug itself.
