# plexamp_headless — Ansible role for a bit-perfect Plex audio endpoint

Deploys headless [Plexamp](https://plexamp.com) to a minimal **AlmaLinux 10**
box as a bit-perfect audio endpoint: pins Node.js to the version its native
audio bindings actually require, sets up the systemd service, opens only
what's needed in `firewalld` scoped to your LAN, and gets wifi working on
installs that don't ship it by default.

## Why x86?

Nearly every headless-Plexamp guide out there targets ARM boards — a
Raspberry Pi, in particular. This project exists for the opposite case:
you've got a spare **x86_64** box (an old mini PC, a NUC, a repurposed
desktop) and want to run the same bit-perfect setup on it. The Node.js
version pinning, package sourcing, and native-binding concerns this role
handles are specific to x86_64 AlmaLinux 10 — don't expect it to work
unmodified on an ARM target.

## Layout

```
plexamp.yml          # the playbook — edit plexamp_lan_cidr here before running
inventory.ini         # target host(s) — edit before running
requirements.yml      # ansible.posix collection (needed for the firewalld module)
roles/plexamp_headless/
```

## Prerequisites

**On whichever machine runs `ansible-playbook`** (a separate control machine,
or the target itself — see "Running locally" below):
- `ansible-core` (`sudo dnf install ansible-core` on EL, or your distro's
  equivalent)
- The `ansible.posix` collection: `ansible-galaxy collection install -r requirements.yml`

**On the target:**
- AlmaLinux 10 (or compatible EL10 derivative), minimal install is fine
- SSH access with a sudo-capable user, if running remotely
- A Plex Pass — headless Plexamp won't run without one
- A USB DAC, if you actually want bit-perfect audio out of this (the role
  runs fine without one, but there's nothing useful to point
  `Settings > Playback > Audio Output` at)

## Before running, edit two things

1. **`inventory.ini`** — replace `mini-pc.local ansible_user=youruser` with
   the real target.
2. **`plexamp.yml`** — set `plexamp_lan_cidr` to the target's *actual* LAN
   subnet (e.g. `10.100.0.0/24`), not a placeholder. The role hard-fails via
   an `assert` if this is left unset, but it can't tell a wrong-but-set CIDR
   from a correct one — get this wrong and firewalld will silently block the
   web UI and phone casting while the service itself looks perfectly healthy.

## Running it over SSH (normal case)

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook plexamp.yml -i inventory.ini
```

## Running it locally (no separate control machine)

If you're sitting at the target box's own console/terminal with no other
machine to SSH in from, install Ansible **on the target itself** and point
it at `localhost` instead of over SSH:

```bash
sudo dnf install -y ansible-core
ansible-galaxy collection install -r requirements.yml
```

Change `inventory.ini` to:
```ini
[plexamp_endpoint]
localhost ansible_connection=local
```

Then run as root (simplest — no `become` password prompt needed since
you're already privileged), or as a sudo-capable user with `--ask-become-pass`:
```bash
sudo ansible-playbook plexamp.yml -i inventory.ini
# or, as a non-root user:
ansible-playbook plexamp.yml -i inventory.ini --ask-become-pass
```
Everything else about the run is identical to the remote case — same
idempotency, same firewall/CIDR caveat above.

## Upgrades

Re-run the playbook. With `plexamp_version` left empty it tracks Plex's
latest published headless release; the role only re-downloads when the
version actually changed, then restarts the service. App files are replaced
wholesale, but runtime state under the install directory (`.local` — which
holds the claim and all web-UI settings — `.cache`, `Library`) is preserved,
so upgrades never require re-claiming or reconfiguring. Pin
`plexamp_version` in `plexamp.yml` if you'd rather upgrades only happen when
you choose.

## After it runs

The playbook prints exact next steps at the end (claiming — which needs a
one-off interactive foreground run, since it can't be done through systemd —
audio device selection, and the "Sample Rate Matching" setting that actually
controls bit-perfect output). Read that output; it's specific to the version
that just installed. The short version, if you've done this before:
- `Settings > Playback > Audio Output > Audio Device` → your DAC, not onboard audio
- `Settings > Playback > Audio Output > Sample Rate Matching` → **Strict** (defaults to Disabled, which silently resamples everything)
- `Settings > Remote Control > Enable Remote Control` → on
- Verify with `cat /proc/asound/card*/pcm*/sub0/hw_params` while something's playing
