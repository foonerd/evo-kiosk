# evo kiosk (eng)

Kiosk browser + boot integration + hardware acceptance surface for `v0.1.13`.

## Process shape

```text
non-headless boot
  -> Plymouth (evo-device-boot)
  -> handoff (this repo / unit)
  -> evo-kiosk-preflight
       -> DRM probe
       -> wait for /run/evo/kiosk.sock (readiness only)
  -> evo-kiosk-launch
       -> resolve /etc/evo/kiosk.toml + overlays
       -> exec labwc --session evo-kiosk-session
  -> evo-kiosk-session
       -> scale / rotation / OSK / cursor
       -> exec evo-kiosk-browser
  -> evo-kiosk-browser
       -> mint on /run/evo/kiosk.sock
       -> inject bearer into localStorage.evoBearer (Start-time user script)
       -> navigate to local UI URL
```

## Paths

| Role | Path |
| --- | --- |
| TOML defaults | `/etc/evo/kiosk.toml` |
| Runtime overlays | `/var/lib/evo/settings/kiosk/<key>` |
| labwc config | `/etc/evo/labwc/rc.xml` |
| Helpers | `/usr/local/bin/evo-kiosk-{preflight,launch,session,browser}` |
| Mint socket | `/run/evo/kiosk.sock` (override: `EVO_KIOSK_SOCK`) |
| Unit | `evo-kiosk.service` |
| Runtime dir | `/run/evo-kiosk` (systemd `RuntimeDirectory`) |

## Mint ownership

The **browser binary** owns `mint_local_kiosk_session` and bearer inject against `/run/evo/kiosk.sock` only (never `/run/evo/evo.sock`). Inject path is `localStorage.evoBearer` (matches evo-ui `storedBearer`); the bearer never appears in systemd `Environment=` or world-readable files. Session/launch scripts may wait for socket readiness; they must not mint, carry, or log the bearer. Silent renewal and WebProcess-crash remint stay in the browser process.

## Environment variables

| Variable | Default | Who reads | Notes |
| --- | --- | --- | --- |
| `KIOSK_URL` | `http://127.0.0.1/` | launch → session → browser | Overridden by TOML `url` |
| `KIOSK_TOML` | `/etc/evo/kiosk.toml` | launch | |
| `KIOSK_SETTINGS_DIR` | `/var/lib/evo/settings/kiosk` | launch | Overlay files win over TOML |
| `KIOSK_OUTPUT` | empty (first) | launch | Optional wlroots output name |
| `EVO_KIOSK_SOCK` | `/run/evo/kiosk.sock` | preflight (+ browser) | Existence check only in preflight |
| `EVO_KIOSK_SOCK_WAIT_SECS` | `30` | preflight | |
| `KIOSK_ZOOM` | from overlay/TOML | session → browser | |
| `KIOSK_SCALE` | from overlay/TOML | session | `auto` skips wlr-randr scale |
| `KIOSK_ROT` | from launch | session | Applied with scale in one wlr-randr call |
| `KIOSK_CURSOR` | from overlay/TOML | session | `hide` fires F24 HideCursor |
| `OSK` / `OSK_FORCE_SHOW` / `KIOSK_OSK_LAYOUT` | from overlay/TOML | session | |

Never put bearer tokens in systemd `Environment=` or world-readable files.

## Overlay / TOML keys

Overlays are single-line files under `/var/lib/evo/settings/kiosk/`. Overlay wins over TOML; empty overlay falls through.

| Key | Values | Notes |
| --- | --- | --- |
| `url` | URL string | Default loopback UI |
| `rotation` | `0` / `90` / `180` / `270` (or `normal`) | |
| `cursor` | `auto` / `show` / `hide` | |
| `osk` | `squeekboard` / `wvkbd` / `none` | |
| `osk_layout` | XKB code (`us`, `gb`, …) | |
| `osk_force_show` | `true` / `false` | Debug only |
| `auto_rotate` | `true` / `false` | Reserved; session does not drive accel yet |
| `zoom` | float or `auto` | WebKit page zoom |
| `scale` | float or `auto` | wlroots output scale via wlr-randr |
| `xkb_layout` | XKB code | Passed as `WLR_XKB_LAYOUT` |

## Autostart

Default enabled when DRM/display is present (`ConditionPathExistsGlob=/dev/dri/card*` + `systemctl enable` from install). Headless installs files but does not enable. Operator Settings toggle can disable/enable. `User=` is a distribution drop-in, not hardcoded in the unit.

## Install

```bash
sudo ./scripts/install/install.sh
# optional runtime apt packages:
sudo KIOSK_INSTALL_PACKAGES=1 ./scripts/install/install.sh
# install files but do not enable:
sudo KIOSK_FORCE_ENABLE=0 ./scripts/install/install.sh
```

## OSK theming

Stock squeekboard chrome follows the UI-committed `ui.theme`. The UI workspace ships derived GTK-CSS packs with each UI release; the kiosk consumes them. There is no theme-id space owned by the framework — the five ids below come from the UI's approved theme set and change only when the UI workspace ships new packs.

**UI contract.** Both sides agree on exactly this surface; changes require a joint update to this section and the matching UI handoff.

| Surface | Value |
| --- | --- |
| Allowed theme ids | `evo-default`, `night-sky`, `sunrise`, `air`, `liquid` |
| Pack location | `/opt/evo/ui/current/osk/gtk/<id>.css` (owned by UI release) |
| Active CSS target | `$HOME/.config/gtk-3.0/gtk.css` (kiosk service user) |
| Authoritative trigger | `/opt/evo/ui/data/settings.json` → `.settings["ui.theme"]` (runtime rewrites this atomically on every committed Apply) |
| Publish record (optional override, persistent) | `/var/lib/evo/ui/osk_theme` — one line, theme id |
| Publish record (optional override, ephemeral) | `/run/evo/ui-osk-theme` — one line, theme id |
| Fallback id | `evo-default` |
| `GTK_THEME` base — dark | `Adwaita:dark` for `evo-default`, `night-sky`, `sunrise`, `liquid` |
| `GTK_THEME` base — light | `Adwaita` for `air` |

**Resolution priority** (kiosk-side, in [layer/bin/evo-kiosk-osk-theme](layer/bin/evo-kiosk-osk-theme)): persistent record → ephemeral record → `settings.json` `ui.theme` → `evo-default`. First hit wins; unknown ids are rejected and collapsed to the fallback. Publish records are optional operator overrides — the runtime does not write them today; they exist so an operator or a follow-on tool can force a specific id without touching `settings.json`.

**Boot apply.** `evo-kiosk-session`'s `start_squeekboard` delegates to `/usr/local/bin/evo-kiosk-osk-theme`. The helper resolves the id, copies the matching pack to `~/.config/gtk-3.0/gtk.css`, computes the `GTK_THEME` base, and spawns squeekboard with that env. Pidfile at `$XDG_RUNTIME_DIR/evo-kiosk-squeekboard.pid` tracks the child so live refresh can restart it cleanly.

**Live refresh.** `evo-kiosk-watch-settings` watches `/opt/evo/ui/data` (the runtime-owned settings dir), plus both publish-record dirs, via inotify (polling fallback covers the same paths). The trigger event is `moved_to` — the runtime rewrites `settings.json` via tempfile + `rename(2)`, so a watch on the file inode alone would silently miss subsequent Applys (the same class of miss as the earlier `udevadm --action=change` touch-calibration bug). On any qualifying event the watcher re-invokes the helper. The helper short-circuits to a no-op when the resolved theme is unchanged AND the tracked squeekboard is still alive — an unrelated Apply (volume step, network mode, timezone) that rewrites `settings.json` does not cycle the OSK. When the theme actually changes, the helper kills the tracked squeekboard and spawns a fresh one with the new pack and `GTK_THEME`. labwc, the browser, and the `evo-kiosk` unit are not touched.

**Degraded behaviour.** Missing pack for the selected id → fall back to `evo-default` pack; if that too is missing → leave `gtk.css` unchanged and start stock squeekboard. Each fallback step emits one `WARN` line in the kiosk journal. The session never fails to start over a theme problem.

**Not in scope.** The kiosk does not generate CSS from the UI's `styles.css`, does not maintain a parallel dark/light catalog, does not compile custom wvkbd themes for branding, and does not start `gnome-session` to silence the benign `Could not register to session manager … org.gnome.SessionManager` line seen under labwc.

## Stack locks

- labwc + GTK4 + webkit2gtk 6
- maximize (not fullscreen) for OSK / layer-shell
- browser owns mint + cookie inject on `/run/evo/kiosk.sock` only
- default-on when non-headless
