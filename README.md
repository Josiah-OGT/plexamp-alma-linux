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
mpd-upnp.yml          # optional second playbook: Navidrome/Symfonium endpoint (see below)
caldera-music.yml     # optional: Caldera Music, a second Plex player (see below)
audioctl.yml          # optional: TUI to start/stop engines and route DACs (see below)
inventory.ini         # target host(s) — edit before running
requirements.yml      # ansible.posix collection (needed for the firewalld module)
roles/plexamp_headless/
roles/mpd_upnp/
roles/caldera_music/
roles/audioctl/
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

## Second role: `mpd_upnp` — the same endpoint for Navidrome/Symfonium

If your library also lives in [Navidrome](https://www.navidrome.org/) (or any
Subsonic-compatible server) and you drive it from
[Symfonium](https://symfonium.app/), `mpd-upnp.yml` turns the same box into a
**UPnP/OpenHome renderer**: MPD as the playback engine, fronted by
[upmpdcli](https://www.lesbonscomptes.com/upmpdcli/). Symfonium casts to it,
the box pulls the FLAC straight from Navidrome, and MPD plays it out the DAC
with no resampling.

**It cannot share a DAC with Plexamp.** Headless Plexamp opens its ALSA
output device at service start and holds it open for as long as it runs,
idle or not — so with both services enabled, whichever one starts first
wins the DAC and the other fails every track with `Failed to open ALSA
device ...: Device or resource busy`. Pick one per DAC:
`sudo systemctl disable --now plexamp` to hand the device to MPD (and
`enable --now` to hand it back). Both can stay installed; only one can run.

Neither MPD nor upmpdcli is packaged anywhere for EL10 (EPEL 10, RPM Fusion
EL10, COPR and upstream were all checked — nothing), so the role builds a
small **Debian container** where both are first-class packages (upmpdcli from
its developer's own apt repo — it isn't in Debian's archive either) and runs
it as two podman quadlet services sharing the host network: `mpd.service`
(bound to 127.0.0.1 only) and `upmpdcli.service` (UPnP control on TCP 49152 +
SSDP, firewalled to your LAN CIDR). The container gets `/dev/snd` directly,
so the bit-perfect path is identical to native.

```bash
# edit mpd_upnp_lan_cidr in mpd-upnp.yml first, same rules as plexamp_lan_cidr
ansible-playbook mpd-upnp.yml -i inventory.ini
```

Two defaults you'll want to override in `mpd-upnp.yml` for real hardware:
- `mpd_upnp_alsa_device` — defaults to `"default"` (safe everywhere, but
  that's dmix, which **resamples**). Set your DAC's raw device **by name**,
  e.g. `"hw:CARD=AUDIO"` — the id is the bracketed name in
  `/proc/asound/cards`. Avoid `"hw:0,0"`-style numbers: they're USB
  enumeration order, and a boot where the DAC and onboard audio swap
  places would silently send playback to the wrong output.
- `mpd_upnp_friendly_name` — the name Symfonium's cast menu shows.

**More than one DAC:** set `mpd_upnp_alsa_outputs` instead of
`mpd_upnp_alsa_device` and the one renderer plays out of all of them at
once, each opened bit-perfect at the source rate:

```yaml
mpd_upnp_alsa_outputs:
  - { name: "Hifi DAC", device: "hw:CARD=AUDIO" }
  - { name: "Mesh DAC", device: "hw:CARD=Card" }
```

Each DAC runs on its own clock, so the outputs aren't sample-locked — fine
for separate rooms or speakers + headphones, but expect a slight offset if
both feed speakers in the same room. Turn one off without redeploying with
`sudo podman exec mpd mpc disable 2` (`mpc outputs` lists them; the state
survives restarts). A DAC that's unplugged just drops out — MPD keeps
playing to the others. For a DAC that isn't in the list (say one you plug
in later), `sudo audioctl route <DAC> mpd` adds an output without a
redeploy — see the audioctl section.

In Symfonium, pick the **OpenHome** entry of the renderer (it appears twice):
that keeps the queue on the box itself, with proper gapless, and playback
survives the phone sleeping. Verify bit-perfect output the same way as
Plexamp: `hw_params` while two tracks of different sample rates play.
Volume is intentionally not in the audio path (`mixer_type "none"`) — use
your amp, or set `mpd_upnp_mixer_type: "hardware"` if your DAC has a real
hardware mixer.

## Third role: `caldera_music` — another Plex player

Caldera Music is a headless Plex player you cast to
from Plex/Plexamp on your phone, like headless Plexamp. `caldera-music.yml`
installs it for a dedicated `caldera` account and runs it the way its own
installer intends — as that account's systemd *user* unit, so Caldera's
built-in self-updater keeps working — with lingering on so it runs without
anyone logged in.

```bash
# set caldera_music_lan_cidr in caldera-music.yml first, same rules as the others
ansible-playbook caldera-music.yml -i inventory.ini
```

The role only installs on the first run; after that Caldera updates itself
(`caldera_music_channel: stable` or `beta`). On every run it enforces:
- **Bit-perfect preferences.** Caldera's defaults resample everything to
  44.1 kHz, attenuate with software volume at 20%, and apply loudness
  leveling and crossfades. The role sets source-rate output, volume 100 and
  turns leveling and sweet fades off (`caldera_music_bitperfect_prefs`).
- **Companion port 32501, not 32500.** Caldera defaults to the same port as
  headless Plexamp; on one box they couldn't both run.

It never starts, stops or boot-enables Caldera — that's audioctl's job (it
won't let an engine start, or start at boot, without a DAC routed to it):

```bash
sudo audioctl caldera-login --player-name "Den"   # plex.tv/link PIN, one-time
sudo audioctl route Card caldera
sudo audioctl start caldera && sudo audioctl enable caldera
```

## Managing it: `audioctl`

`audioctl.yml` installs a small TUI (single stdlib-Python script, no extra
packages) for the day-to-day: starting/stopping each engine (Plexamp,
Caldera, MPD/UPnP — whichever are installed), whether it starts at boot,
and which DAC goes to which engine.

```bash
ansible-playbook audioctl.yml -i inventory.ini
ssh mini-pc.local -t sudo audioctl
```

```
── Engines ─────────────────────────────────────────────
 ▶  Plexamp    ● running   boot: off  DAC: Card
    MPD/UPnP   ● running   boot: on   DAC: AUDIO
── DACs ────────────────────────────────────────────────
    DAC     Routed to       Now                          Description
    AUDIO   MPD             playing  44.1 kHz S32_LE  mpd   SUCA HIFI USB AUDIO
    Card    Plexamp         closed                          Schiit Audio Mesh Card
```

Enter opens a menu for the selected row; `?` lists the hotkeys. Every
action also exists as a command, for scripts or a quick change over SSH:

| | |
|---|---|
| `audioctl status [--json]` | engines, routing, what each DAC is playing right now (rate/format) |
| `audioctl start\|stop\|restart plexamp\|caldera\|mpd` | run state |
| `audioctl enable\|disable plexamp\|caldera\|mpd` | start at boot |
| `audioctl route <dac> mpd\|plexamp\|caldera\|off` | `<dac>` = card id (`AUDIO`), number, or MPD output name |
| `audioctl caldera-login [--player-name N]` | Caldera's one-time Plex login |
| `audioctl only <dac>` / `audioctl all` | MPD plays to one DAC / all of them |
| `audioctl mpd-forget <dac>` | remove an MPD output audioctl added (works with the DAC unplugged) |

A DAC is routed to **one engine at a time**, because an engine with a DAC
open makes it busy for the others (Plexamp holds its DAC for as long as it
runs). Routing a DAC to one engine takes it from whichever had it — out of
MPD's outputs, or stopping Plexamp/Caldera if they were on it — so the
engines can all run at once, each on its own DAC. Plexamp and Caldera each
drive a single DAC; MPD drives any number.

**Plugging in another DAC.** It shows up in audioctl as soon as the kernel
sees it, by its card id, and can be routed to Plexamp or Caldera straight
away. Routing it to MPD the first time adds an MPD output for it, because
MPD only knows the DACs in `mpd_upnp_alsa_outputs`:
- audioctl keeps those extra outputs in `/var/lib/audioctl/state.json` and
  writes them to `/opt/mpd-upnp/etc/mpd.d/audioctl-outputs.conf`, which
  `mpd.conf` includes. A drop-in rewrites the file before every MPD start.
- MPD can't add an output while running, and the container only sees DACs
  that existed when it started, so **adding one restarts MPD**. Whatever
  MPD is playing on its other DACs stops, and may need play pressing again
  (a stream from the phone often can't be resumed).
- The output is named after the DAC's description, and `audioctl all`
  includes it from then on. `sudo audioctl mpd-forget <DAC>` removes it
  (also a restart); `audioctl status` points at it if the DAC is unplugged.
- Adding the same DAC to `mpd_upnp_alsa_outputs` later is fine: at the next
  MPD start audioctl drops its own output for it, so it never gets two.

Details worth knowing:
- **Plexamp's DAC is now owned by audioctl** once you route one to it. Plexamp
  stores the device as a card *number*, which can change between boots, so
  a drop-in re-pins it from the stable card id before every Plexamp start.
  A device picked later in Plexamp's web UI gets overwritten on the next
  start — use audioctl instead.
- **MPD "disable at boot" masks the units.** Quadlet units are generated and
  can't be `systemctl disable`d; audioctl masks them instead (and briefly
  unmasks to start one that's boot-disabled). `mpd-upnp.yml` skips starting
  masked units rather than undoing the choice.
- **`plexamp.yml` re-enables and starts Plexamp** every run, as before. If
  Plexamp is meant to be off, rerun `audioctl disable plexamp` / `stop
  plexamp` afterwards.
