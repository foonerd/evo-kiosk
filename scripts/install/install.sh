#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# evo kiosk session layer installer.
#
# Installs helpers, labwc config, systemd unit, the kiosk browser
# binary, and the component privileges declaration
# (kiosk.privileges.toml) that both this installer and the runtime
# preflight consume as the single source of truth for OS dependencies.
#
# Default-enables evo-kiosk.service when DRM is present unless
# KIOSK_FORCE_ENABLE=0. Headless hosts (no /dev/dri/card*) install
# files but do not enable.
#
# User= for the unit is a distribution concern (drop-in). This script
# does not hardcode a service user.
#
# Package list source of truth: layer/kiosk.privileges.toml
# `host_provisioning.debian.apt_packages`. The installer does NOT
# embed a package list of its own; it reads the declaration and
# installs what is named there. The runtime preflight
# (evo-kiosk-preflight) reads the same file and refuses to start the
# unit when a `required_binaries` or `required_system_services` entry
# is absent. Install-side install list and runtime-side enforcement
# list cannot drift because they are the same file.
#
# Never prints mint tokens or bearer material.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAYER_DIR="${REPO_DIR}/layer"
PRIVILEGES_SRC="${LAYER_DIR}/kiosk.privileges.toml"
PRIVILEGES_DST="/etc/evo/kiosk.privileges.toml"
TRUST_ANCHOR_SRC_DEFAULT="${LAYER_DIR}/trust/evo-release-signing-public.pem"
TRUST_ANCHOR_DST_DIR="/etc/evo/trust"
TRUST_ANCHOR_DST="${TRUST_ANCHOR_DST_DIR}/evo-release-signing-public.pem"
VERIFY_TOOL_DST="/usr/local/bin/evo-kiosk-verify"

# 1 (default): enable unit when DRM present. 0: install only.
KIOSK_FORCE_ENABLE="${KIOSK_FORCE_ENABLE:-1}"
# 1 (default): apt-install runtime packages declared in
# `kiosk.privileges.toml`. 0: files-only refresh — the runtime
# preflight will still enforce every declared dependency at unit
# start, so a mismatch surfaces at ExecStartPre with an
# operator-readable failure.
KIOSK_INSTALL_PACKAGES="${KIOSK_INSTALL_PACKAGES:-1}"
# Browser binary source. Default is `signed` — fetch from the
# release plane and verify against the bundled trust anchor
# before placing. Alternatives:
#   layer         Use a locally-staged binary at
#                 layer/binaries/<triple>/evo-kiosk-browser
#                 without signature verification. Intended for
#                 offline install from a physically-trusted
#                 medium.
#   cargo         Build from source in this checkout. Requires
#                 the Rust toolchain and GTK4/WebKit dev
#                 packages. Intended for dev iteration.
#   preinstalled  Require an existing /usr/local/bin/evo-kiosk-
#                 browser. No fetch, no build, no verify.
KIOSK_BROWSER_SOURCE="${KIOSK_BROWSER_SOURCE:-signed}"
# Release channel to consume when KIOSK_BROWSER_SOURCE=signed.
KIOSK_CHANNEL="${KIOSK_CHANNEL:-prod}"
# URL of the artefacts repository (git clone target).
KIOSK_ARTEFACTS_URL="${KIOSK_ARTEFACTS_URL:-https://github.com/foonerd/evo-kiosk-artefacts.git}"
# Override path to the trust anchor PEM. Defaults to the copy
# bundled with this repo at layer/trust/.
KIOSK_TRUST_ANCHOR_SRC="${KIOSK_TRUST_ANCHOR_SRC:-${TRUST_ANCHOR_SRC_DEFAULT}}"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

log() {
  printf '[kiosk-install] %s\n' "$*"
}

warn() {
  printf '[kiosk-install] WARN: %s\n' "$*" >&2
}

fail() {
  printf '[kiosk-install] ERROR: %s\n' "$*" >&2
  exit 1
}

host_rust_triple() {
  case "$(uname -m)" in
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    armv7l|armv6l|armv5tel) echo "armv7-unknown-linux-gnueabihf" ;;
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    *) echo "" ;;
  esac
}

drm_present() {
  compgen -G '/dev/dri/card*' >/dev/null
}

# ------------------------------- privileges reader -------------------
#
# Reads $PRIVILEGES_SRC and echoes newline-delimited package names.
# Buckets:
#   apt-required            required + first-resolvable of each
#                           required_alternatives group
#   apt-optional            optional entries that resolve in the
#                           apt index
#   apt-build-only          build_only entries (only when the
#                           installer will cargo-build the browser)
#
# `apt-cache show <pkg>` is the resolution primitive so alternative
# groups pick the first name that Debian actually publishes on this
# release.

pkg_in_apt_index() {
  local p="$1"
  [[ -n "${p}" ]] || return 1
  apt-cache show "${p}" >/dev/null 2>&1
}

read_privileges_bucket() {
  local bucket="$1"
  # tomllib is Python 3.11+ stdlib. Debian Trixie ships python3
  # (declared in the privileges file itself under required_binaries).
  # Emitted alternatives are resolved against apt-cache by the caller.
  python3 - "${PRIVILEGES_SRC}" "${bucket}" <<'PY'
import sys, tomllib
path, bucket = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    data = tomllib.load(f)
debian = ((data.get("host_provisioning", {}) or {})
          .get("debian", {}) or {})
apt = debian.get("apt_packages", {}) or {}
if bucket == "apt-required":
    for name in (apt.get("required") or []):
        print(str(name).strip())
    # Alternative groups: emit each group as a tab-joined line so
    # the shell caller can pick the first name that resolves in
    # apt-cache.
    for group in (apt.get("required_alternatives") or []):
        parts = [str(x).strip() for x in group if str(x).strip()]
        if parts:
            print("__alt__\t" + "\t".join(parts))
elif bucket == "apt-optional":
    for name in (apt.get("optional") or []):
        print(str(name).strip())
elif bucket == "apt-build-only":
    for name in (apt.get("build_only") or []):
        print(str(name).strip())
else:
    print("__bad_bucket__", file=sys.stderr)
    sys.exit(2)
PY
}

resolve_apt_list() {
  # Args: bucket name. Emits a newline-delimited resolved list.
  # required + alternative groups: refuses install if any required
  # entry or any alternative group has zero resolvers in the apt
  # index (drift alarm).
  local bucket="$1"
  local -a out=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${line}" == "__alt__	"* ]]; then
      # Alternative group: pick the first that resolves.
      local rest="${line#__alt__	}"
      local picked=""
      # shellcheck disable=SC2001
      # ${rest//$'\t'/ } to convert tabs to spaces for the for-loop.
      local rest_spaces="${rest//$'\t'/ }"
      local cand
      for cand in ${rest_spaces}; do
        if pkg_in_apt_index "${cand}"; then
          picked="${cand}"
          break
        fi
      done
      if [[ -z "${picked}" ]]; then
        if [[ "${bucket}" == "apt-required" ]]; then
          fail "alternative group [${rest_spaces}] has no apt-cache resolver on this release; declared dependency cannot be satisfied"
        fi
        continue
      fi
      out+=("${picked}")
    else
      if pkg_in_apt_index "${line}"; then
        out+=("${line}")
      else
        if [[ "${bucket}" == "apt-required" ]]; then
          fail "required package '${line}' not in apt-cache on this release; declared dependency cannot be satisfied"
        fi
        warn "package '${line}' not in apt index; skipping"
      fi
    fi
  done < <(read_privileges_bucket "${bucket}")
  printf '%s\n' "${out[@]}"
}

install_packages() {
  if [[ "${KIOSK_INSTALL_PACKAGES}" != "1" ]]; then
    log "Skipping apt install (KIOSK_INSTALL_PACKAGES=0)."
    log "  Runtime preflight will still enforce every dependency in"
    log "  ${PRIVILEGES_DST} at unit start; missing entries surface as a"
    log "  named ExecStartPre failure."
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    fail "KIOSK_INSTALL_PACKAGES=1 but apt-get not found."
  fi
  if [[ ! -r "${PRIVILEGES_SRC}" ]]; then
    fail "privileges declaration missing at ${PRIVILEGES_SRC}"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    # The privileges declaration lists python3 under required_binaries
    # for exactly this reason. Bootstrap it explicitly here so a
    # minimal image can resolve the file.
    log "python3 absent; bootstrapping via apt before reading privileges declaration."
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    apt-get update
    apt-get install -y --no-install-recommends python3
  fi

  export DEBIAN_FRONTEND=noninteractive
  export APT_LISTCHANGES_FRONTEND=none
  apt-get update
  dpkg --configure -a 2>/dev/null || true
  apt-get -y -f install 2>/dev/null || true

  local -a resolved=()
  mapfile -t resolved < <(resolve_apt_list apt-required)
  local -a optional=()
  mapfile -t optional < <(resolve_apt_list apt-optional)
  if [[ "${#optional[@]}" -gt 0 ]]; then
    resolved+=("${optional[@]}")
  fi

  # Build-only packages: only pulled when the operator has
  # opted into cargo build mode. Every other source mode
  # (signed / layer / preinstalled) places a pre-built binary.
  if [[ "${KIOSK_BROWSER_SOURCE}" == "cargo" ]]; then
    local -a build_only=()
    mapfile -t build_only < <(resolve_apt_list apt-build-only)
    if [[ "${#build_only[@]}" -gt 0 ]]; then
      resolved+=("${build_only[@]}")
      log "Including GTK/WebKit dev packages (KIOSK_BROWSER_SOURCE=cargo): ${build_only[*]}"
    fi
  fi

  log "Installing ${#resolved[@]} package(s) from ${PRIVILEGES_SRC}."
  apt-get install -y --no-install-recommends "${resolved[@]}"
}

install_helper_scripts() {
  local bin
  for bin in evo-kiosk-preflight evo-kiosk-launch evo-kiosk-session evo-kiosk-watch-settings evo-kiosk-osk-theme evo-kiosk-plymouth-handoff; do
    local src="${LAYER_DIR}/bin/${bin}"
    local dst="/usr/local/bin/${bin}"
    [[ -f "${src}" ]] || fail "Missing helper ${src}"
    install -m 0755 "${src}" "${dst}"
    log "Installed ${dst}"
  done

  # sbin helpers (root-side; called by systemd path units).
  local sbin
  for sbin in evo-kiosk-touch-calibrate evo-kiosk-apply-settings; do
    local sbin_src="${LAYER_DIR}/sbin/${sbin}"
    local sbin_dst="/usr/local/sbin/${sbin}"
    [[ -f "${sbin_src}" ]] || fail "Missing helper ${sbin_src}"
    install -m 0755 "${sbin_src}" "${sbin_dst}"
    log "Installed ${sbin_dst}"
  done
}

install_kiosk_apply_units() {
  # Two path-triggered systemd units own the root-side apply.
  # Kiosk session (unprivileged compositor user) + remote plugin
  # (via WSS) both just write overlay files; systemd fires the
  # matching .service (as root) on any overlay write and at boot
  # via evo-kiosk.service's Wants=. No sudoers path from the
  # kiosk user; no NoNewPrivileges conflict.
  local unit
  for unit in \
      evo-kiosk-touch-calibrate.service \
      evo-kiosk-touch-calibrate.path \
      evo-kiosk-apply-settings.service \
      evo-kiosk-apply-settings.path; do
    local src="${LAYER_DIR}/systemd/${unit}"
    local dst="/etc/systemd/system/${unit}"
    [[ -f "${src}" ]] || fail "Missing systemd unit ${src}"
    install -m 0644 "${src}" "${dst}"
    log "Installed ${dst}"
  done
  systemctl daemon-reload
  # Enable both .path units so they start monitoring at boot and
  # pull their matching .service in on any overlay change. The
  # .service units are also transitively started when
  # evo-kiosk.service starts (Wants=).
  systemctl enable evo-kiosk-touch-calibrate.path >/dev/null 2>&1 || true
  systemctl start  evo-kiosk-touch-calibrate.path >/dev/null 2>&1 || true
  systemctl enable evo-kiosk-apply-settings.path   >/dev/null 2>&1 || true
  systemctl start  evo-kiosk-apply-settings.path   >/dev/null 2>&1 || true
  # One-shot apply at install so udev rule + labwc runtime config
  # + backlight sysfs reflect current overlay values right now,
  # not only after the next overlay write / kiosk unit start.
  # PathModified fires on writes, not on path unit activation.
  systemctl start evo-kiosk-touch-calibrate.service >/dev/null 2>&1 || true
  systemctl start evo-kiosk-apply-settings.service  >/dev/null 2>&1 || true
  log "Enabled + started .path units (one-shot apply run for each)"
}

install_privileges_declaration() {
  [[ -f "${PRIVILEGES_SRC}" ]] || fail "Missing privileges declaration ${PRIVILEGES_SRC}"
  mkdir -p "$(dirname "${PRIVILEGES_DST}")"
  install -m 0644 "${PRIVILEGES_SRC}" "${PRIVILEGES_DST}"
  log "Installed ${PRIVILEGES_DST} (single source of truth for install + preflight)"
}

install_labwc_config() {
  local src="${LAYER_DIR}/labwc/rc.xml"
  local dir="/etc/evo/labwc"
  local dst="${dir}/rc.xml"
  [[ -f "${src}" ]] || fail "Missing labwc config ${src}"
  mkdir -p "${dir}"
  install -m 0644 "${src}" "${dst}"
  log "Installed ${dst}"
}

install_unit() {
  local src="${LAYER_DIR}/systemd/evo-kiosk.service"
  local dst="/etc/systemd/system/evo-kiosk.service"
  [[ -f "${src}" ]] || fail "Missing unit ${src}"
  install -m 0644 "${src}" "${dst}"
  log "Installed ${dst}"
  log "User= must come from a distribution drop-in (evo-kiosk.service.d/)."
}

ensure_settings_dir() {
  local dir="/var/lib/evo/settings/kiosk"
  mkdir -p "${dir}"
  log "Ensured ${dir}"
  # Optional OSK theme publish root. Watched by
  # evo-kiosk-watch-settings — inotifywait aborts if any root is
  # missing, so the live-apply daemon dies after its start log.
  local ui_publish="/var/lib/evo/ui"
  mkdir -p "${ui_publish}"
  log "Ensured ${ui_publish}"
}

ensure_etc_kiosk_toml() {
  local dst="/etc/evo/kiosk.toml"
  mkdir -p /etc/evo
  if [[ -f "${dst}" ]]; then
    log "Keeping existing ${dst}"
    return 0
  fi
  cat > "${dst}" <<'EOF'
# evo kiosk runtime config. Overlays under /var/lib/evo/settings/kiosk/
# win over these defaults. See docs/KIOSK.md.
url = "http://127.0.0.1/"
rotation = "0"
cursor = "auto"
osk = "squeekboard"
osk_layout = "us"
osk_force_show = false
auto_rotate = false
zoom = "1.2"
scale = "auto"
xkb_layout = "us"

# Operator-settings defaults consumed by evo-kiosk-apply-settings.
# Overlays under /var/lib/evo/settings/kiosk/ win over these.
brightness = 80
sleep_timeout_seconds = 120
sleep_inhibit_while_playing = true
EOF
  chmod 0644 "${dst}"
  log "Seeded ${dst}"
}

install_trust_anchor() {
  [[ -f "${KIOSK_TRUST_ANCHOR_SRC}" ]] || \
    fail "Trust anchor missing: ${KIOSK_TRUST_ANCHOR_SRC}"
  mkdir -p "${TRUST_ANCHOR_DST_DIR}"
  install -m 0644 "${KIOSK_TRUST_ANCHOR_SRC}" "${TRUST_ANCHOR_DST}"
  log "Installed ${TRUST_ANCHOR_DST} (release trust anchor)"
}

install_verify_tool() {
  local src="${LAYER_DIR}/bin/evo-kiosk-verify"
  [[ -f "${src}" ]] || fail "Missing verify primitive ${src}"
  install -m 0755 "${src}" "${VERIFY_TOOL_DST}"
  log "Installed ${VERIFY_TOOL_DST}"
}

install_kiosk_browser_signed() {
  local dst="/usr/local/bin/evo-kiosk-browser"
  local triple
  triple="$(host_rust_triple)"
  [[ -n "${triple}" ]] || \
    fail "cannot resolve host target triple (uname -m: $(uname -m))"

  command -v git >/dev/null 2>&1 || \
    fail "git not on PATH; required for signed-fetch mode. Install git or set KIOSK_BROWSER_SOURCE=layer/cargo/preinstalled."
  command -v openssl >/dev/null 2>&1 || \
    fail "openssl not on PATH; required for signed-fetch mode."

  local artefacts_dir
  artefacts_dir="$(mktemp -d -t evo-kiosk-artefacts.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '${artefacts_dir}'" EXIT INT TERM

  log "Fetching release plane: ${KIOSK_ARTEFACTS_URL} (channel ${KIOSK_CHANNEL})"
  if ! git clone --depth 1 --quiet "${KIOSK_ARTEFACTS_URL}" "${artefacts_dir}"; then
    fail "git clone failed: ${KIOSK_ARTEFACTS_URL}"
  fi
  local pointer_commit
  pointer_commit="$(git -C "${artefacts_dir}" rev-parse --short HEAD)"
  log "Release plane at commit ${pointer_commit}"

  log "Verifying release plane against trust anchor ${KIOSK_TRUST_ANCHOR_SRC}"
  local evidence
  if ! evidence="$(EVO_KIOSK_TRUST_ANCHOR="${KIOSK_TRUST_ANCHOR_SRC}" \
      "${LAYER_DIR}/bin/evo-kiosk-verify" \
        --artefacts-dir "${artefacts_dir}" \
        --channel "${KIOSK_CHANNEL}" \
        --target "${triple}")"; then
    fail "release plane verification failed — refusing to place unverified binary"
  fi
  log "${evidence}"

  local verified="${artefacts_dir}/binaries/${triple}/evo-kiosk-browser"
  install -m 0755 "${verified}" "${dst}"
  log "Installed verified ${dst}"
}

install_kiosk_browser_layer() {
  local dst="/usr/local/bin/evo-kiosk-browser"
  local triple
  triple="$(host_rust_triple)"
  [[ -n "${triple}" ]] || \
    fail "cannot resolve host target triple (uname -m: $(uname -m))"
  local prebuilt="${LAYER_DIR}/binaries/${triple}/evo-kiosk-browser"
  [[ -x "${prebuilt}" ]] || \
    fail "KIOSK_BROWSER_SOURCE=layer but staged binary missing at ${prebuilt}"
  warn "installing UNVERIFIED binary from ${prebuilt} (layer mode)"
  install -m 0755 "${prebuilt}" "${dst}"
  log "Installed ${dst} (unverified layer-staged binary)"
}

install_kiosk_browser_cargo() {
  local dst="/usr/local/bin/evo-kiosk-browser"
  local cargo_bin=""
  if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
  elif [[ -x /usr/local/cargo/bin/cargo ]]; then
    cargo_bin="/usr/local/cargo/bin/cargo"
  fi
  [[ -n "${cargo_bin}" ]] || \
    fail "KIOSK_BROWSER_SOURCE=cargo but cargo not found on PATH or /usr/local/cargo/bin/."
  [[ -f "${REPO_DIR}/crates/kiosk-browser/Cargo.toml" ]] || \
    fail "crates/kiosk-browser/Cargo.toml missing in ${REPO_DIR}."

  warn "building UNVERIFIED binary from source (cargo mode)"
  log "Building kiosk-browser: cargo build -p evo-kiosk-browser --release --features webkit"
  (
    cd "${REPO_DIR}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
    export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
    export PATH="${CARGO_HOME}/bin:${PATH}"
    "${cargo_bin}" build -p evo-kiosk-browser --release --features webkit
  )
  local built="${REPO_DIR}/target/release/evo-kiosk-browser"
  [[ -x "${built}" ]] || fail "cargo build succeeded but ${built} is missing."
  install -m 0755 "${built}" "${dst}"
  log "Installed ${dst} (unverified cargo build)"
}

install_kiosk_browser_preinstalled() {
  local dst="/usr/local/bin/evo-kiosk-browser"
  [[ -x "${dst}" ]] || \
    fail "KIOSK_BROWSER_SOURCE=preinstalled but ${dst} is missing."
  log "Reusing existing ${dst} (preinstalled mode)"
}

install_kiosk_browser() {
  case "${KIOSK_BROWSER_SOURCE}" in
    signed)       install_kiosk_browser_signed ;;
    layer)        install_kiosk_browser_layer ;;
    cargo)        install_kiosk_browser_cargo ;;
    preinstalled) install_kiosk_browser_preinstalled ;;
    *) fail "Invalid KIOSK_BROWSER_SOURCE=${KIOSK_BROWSER_SOURCE} (expected signed|layer|cargo|preinstalled)" ;;
  esac
}

enable_unit_if_appropriate() {
  systemctl daemon-reload

  if [[ "${KIOSK_FORCE_ENABLE}" == "0" ]]; then
    log "KIOSK_FORCE_ENABLE=0: unit installed but not enabled."
    return 0
  fi

  # Default-on is a FIRST-INSTALL convenience only. On a re-install (unit was
  # already present before this run) the operator's kiosk-mode toggle owns the
  # enablement - re-enabling here would clobber an operator who turned Kiosk
  # mode OFF (a real regression: a redeploy silently brought the kiosk back on
  # a headless / deliberately-disabled player). Respect their current choice.
  if [[ "${KIOSK_UNIT_PREEXISTED}" == "1" ]]; then
    log "Re-install: leaving evo-kiosk.service enablement as-is ($(systemctl is-enabled evo-kiosk.service 2>/dev/null || echo unknown)) - operator's Kiosk-mode toggle owns it."
    return 0
  fi

  if ! drm_present; then
    warn "No DRM device (/dev/dri/card*); installing files but not enabling evo-kiosk.service."
    return 0
  fi

  log "First install + DRM present: enabling evo-kiosk.service (default-on non-headless)."
  systemctl enable evo-kiosk.service
}

main() {
  need_root

  log "Starting evo kiosk install from ${REPO_DIR}"

  # Capture whether the unit already exists BEFORE install_unit overwrites it.
  # enable_unit_if_appropriate uses this to default-enable ONLY on a genuine
  # first install; a re-install must never touch enablement (the operator's
  # Kiosk-mode toggle owns it).
  if [[ -f /etc/systemd/system/evo-kiosk.service ]]; then
    KIOSK_UNIT_PREEXISTED=1
  else
    KIOSK_UNIT_PREEXISTED=0
  fi

  install_privileges_declaration
  install_trust_anchor
  install_verify_tool
  install_packages
  install_helper_scripts
  install_kiosk_apply_units
  install_labwc_config
  install_unit
  ensure_settings_dir
  ensure_etc_kiosk_toml
  install_kiosk_browser
  enable_unit_if_appropriate

  log "Summary:"
  log "  privileges (src) : ${PRIVILEGES_DST} (single source of truth)"
  log "  trust anchor     : ${TRUST_ANCHOR_DST}"
  log "  verify tool      : ${VERIFY_TOOL_DST}"
  log "  helpers          : /usr/local/bin/evo-kiosk-{preflight,launch,session,watch-settings}"
  log "  touch calibrate  : /usr/local/sbin/evo-kiosk-touch-calibrate + evo-kiosk-touch-calibrate.{path,service}"
  log "  apply settings   : /usr/local/sbin/evo-kiosk-apply-settings + evo-kiosk-apply-settings.{path,service} (brightness + sleep timeout + inhibit-while-playing)"
  log "  browser          : /usr/local/bin/evo-kiosk-browser (source: ${KIOSK_BROWSER_SOURCE}, channel: ${KIOSK_CHANNEL})"
  log "  labwc config     : /etc/evo/labwc/rc.xml"
  log "  unit             : /etc/systemd/system/evo-kiosk.service"
  log "  config           : /etc/evo/kiosk.toml"
  log "  overlays         : /var/lib/evo/settings/kiosk/"
  log "  mint socket      : /run/evo/kiosk.sock (readiness only in preflight; browser owns mint)"
  if drm_present; then
    log "  DRM              : yes"
  else
    log "  DRM              : no"
  fi
  log "  logs             : journalctl -u evo-kiosk -n 100 --no-pager"
  log "Install complete."
}

main "$@"
