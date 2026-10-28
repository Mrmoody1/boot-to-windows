#!/usr/bin/env bash
#
# boot-to-windows-setup.sh
#
# Dual-boot helper for Linux Mint / Ubuntu / Debian with GRUB on UEFI.
#
#   * Boots straight into Linux with no visible menu (Esc still shows it).
#   * Installs a "Restart to Windows" app + `boot-to-windows` command that
#     reboots into Windows ONCE; the next restart returns to Linux.
#
# Usage:
#   sudo bash boot-to-windows-setup.sh install [options]
#   sudo bash boot-to-windows-setup.sh uninstall
#   sudo bash boot-to-windows-setup.sh status
#
# Run with no arguments or --help for all options.

set -euo pipefail

VERSION="1.0.0"
APP_NAME="boot-to-windows"

GRUB_CFG="${GRUB_CFG:-/boot/grub/grub.cfg}"
DEFAULTS_FILE="/etc/default/grub.d/99_zz-boot-to-windows.cfg"
OVERRIDE_SCRIPT="/etc/grub.d/42_boot-to-windows"
CONF_FILE="/etc/boot-to-windows.conf"
BIN_FILE="/usr/local/bin/boot-to-windows"
DESKTOP_FILE="/usr/share/applications/boot-to-windows.desktop"

# ---------------------------------------------------------------- helpers

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_B=""; C_0=""
fi

info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${APP_NAME} setup v${VERSION}

Boot Linux by default, and reboot into Windows on demand.

Usage:
  sudo bash $0 install [options]
  sudo bash $0 uninstall
  sudo bash $0 status

Install options:
  --entry "NAME"      Use this GRUB menu entry for Windows instead of
                      auto-detecting it (see: sudo $0 status).
  --menu-timeout N    Show the boot menu for N seconds instead of hiding it.
  --fix-clock         Make Linux keep the hardware clock in local time, so
                      the clock isn't an hour out after using Windows.
  --no-desktop-icon   Don't put a "Restart to Windows" icon on the desktop
                      (it is still added to the app menu).

After installing:
  boot-to-windows             Reboot into Windows once (asks for password)
  boot-to-windows --dry-run   Show what would happen without rebooting
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    if [[ -f "$0" ]]; then
      exec sudo bash "$0" "$@"
    fi
    die "Please run this with sudo."
  fi
}

# The regular (non-root) user who ran sudo, used for the desktop icon.
target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "${SUDO_USER}"
  elif [[ -n "${PKEXEC_UID:-}" ]]; then
    id -nu "${PKEXEC_UID}"
  fi
}

# Print Windows GRUB entries as "ID<TAB>TITLE", one per line.
list_windows_entries() {
  [[ -r "${GRUB_CFG}" ]] || return 0
  grep -E "^[[:space:]]*menuentry '[^']*'.*--class windows" "${GRUB_CFG}" \
    | while IFS= read -r line; do
        title=$(sed -E "s/^[[:space:]]*menuentry '([^']*)'.*/\1/" <<<"${line}")
        id=$(sed -nE "s/.*\\\$menuentry_id_option '([^']*)'.*/\1/p" <<<"${line}")
        printf '%s\t%s\n' "${id}" "${title}"
      done
}

check_requirements() {
  [[ -d /sys/firmware/efi ]] \
    || die "This PC isn't booted in UEFI mode. This tool only supports UEFI systems."
  local cmd
  for cmd in update-grub grub-reboot grub-editenv; do
    command -v "${cmd}" >/dev/null 2>&1 \
      || die "'${cmd}' not found. This tool needs GRUB (Linux Mint, Ubuntu or Debian)."
  done
  if ! command -v os-prober >/dev/null 2>&1; then
    info "Installing os-prober (needed to find Windows)..."
    apt-get install -y os-prober >/dev/null || die "Couldn't install os-prober."
  fi
}

warn_if_windows_first() {
  command -v efibootmgr >/dev/null 2>&1 || return 0
  local first label
  first=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: \([0-9A-Fa-f]\{4\}\).*/\1/p')
  [[ -n "${first}" ]] || return 0
  label=$(efibootmgr 2>/dev/null | sed -n "s/^Boot${first}\*\{0,1\} \(.*\)$/\1/p" | head -n1)
  if grep -qi 'windows' <<<"${label}"; then
    warn "Your firmware boots '${label%%	*}' first, so GRUB never runs."
    warn "Set your Linux entry (e.g. 'ubuntu') as Boot Option #1 in the BIOS."
  fi
}

# ---------------------------------------------------------------- embedded files

write_override_script() {
  # Runs after 30_os-prober. Ubuntu-based systems force the menu to appear
  # whenever another OS is found; this puts our timeout back, except after
  # a failed boot (recordfail) so recovery is still possible.
  local style="$1" timeout="$2"
  cat >"${OVERRIDE_SCRIPT}" <<EOF
#!/bin/sh
# Added by ${APP_NAME}. Remove with: sudo bash boot-to-windows-setup.sh uninstall
cat <<'GRUBEOF'
# ${APP_NAME}: keep menu style/timeout even when other OSes are detected
if [ "\${recordfail}" != 1 ]; then
  set timeout_style=${style}
  set timeout=${timeout}
fi
GRUBEOF
EOF
  chmod 755 "${OVERRIDE_SCRIPT}"
}

write_bin() {
  cat >"${BIN_FILE}" <<'BINEOF'
#!/usr/bin/env bash
# boot-to-windows: reboot into Windows once, then back to Linux by default.
set -euo pipefail

CONF=/etc/boot-to-windows.conf
GRUB_CFG=/boot/grub/grub.cfg
SELF="$(readlink -f "$0")"

confirm=0; dry_run=0
for arg in "$@"; do
  case "${arg}" in
    --confirm) confirm=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help)
      echo "Usage: boot-to-windows [--dry-run] [--confirm]"
      echo "  Reboots into Windows once. The next restart returns to Linux."
      exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

have_gui() { [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }

if [[ ${confirm} -eq 1 && ${EUID} -ne 0 ]] && have_gui && command -v zenity >/dev/null 2>&1; then
  zenity --question --title="Restart to Windows" --icon-name=system-reboot \
    --text="Restart into Windows now?\n\nSave your work first.\nThe next restart will come back to Linux." \
    --ok-label="Restart" --cancel-label="Cancel" 2>/dev/null || exit 0
fi

# Re-run as root: graphical password prompt if possible, otherwise sudo.
if [[ ${EUID} -ne 0 ]]; then
  pass=(); [[ ${dry_run} -eq 1 ]] && pass+=(--dry-run)
  if have_gui && command -v pkexec >/dev/null 2>&1; then
    exec pkexec "${SELF}" "${pass[@]}"
  fi
  exec sudo "${SELF}" "${pass[@]}"
fi

WINDOWS_ENTRY_ID=""; WINDOWS_ENTRY_TITLE=""
# shellcheck disable=SC1090
[[ -r "${CONF}" ]] && . "${CONF}"

entry_exists() { [[ -n "$1" ]] && grep -qF "'$1'" "${GRUB_CFG}"; }

entry=""
if entry_exists "${WINDOWS_ENTRY_ID}"; then
  entry="${WINDOWS_ENTRY_ID}"
elif entry_exists "${WINDOWS_ENTRY_TITLE}"; then
  entry="${WINDOWS_ENTRY_TITLE}"
else
  # Fall back to the first Windows entry GRUB knows about.
  entry=$(grep -E "^[[:space:]]*menuentry '[^']*'.*--class windows" "${GRUB_CFG}" \
            | head -n1 | sed -E "s/^[[:space:]]*menuentry '([^']*)'.*/\1/" || true)
fi

if [[ -z "${entry}" ]]; then
  echo "boot-to-windows: no Windows entry found in ${GRUB_CFG}." >&2
  echo "Run 'sudo update-grub' and check that it says 'Found Windows Boot Manager'." >&2
  exit 1
fi

if [[ ${dry_run} -eq 1 ]]; then
  echo "Dry run: would boot once into GRUB entry: ${entry}"
  exit 0
fi

grub-reboot "${entry}"
systemctl reboot
BINEOF
  chmod 755 "${BIN_FILE}"
}

write_desktop_entry() {
  cat >"${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Type=Application
Name=Restart to Windows
Comment=Reboot into Windows once, then back to Linux next time
Exec=${BIN_FILE} --confirm
Icon=system-reboot
Terminal=false
Categories=System;
Keywords=windows;reboot;dual;boot;
EOF
  chmod 644 "${DESKTOP_FILE}"
}

install_desktop_icon() {
  local user home desktop
  user=$(target_user) || true
  [[ -n "${user}" ]] || { warn "Couldn't tell which user to add the desktop icon for; skipped."; return 0; }
  home=$(getent passwd "${user}" | cut -d: -f6)
  desktop=$(sudo -u "${user}" xdg-user-dir DESKTOP 2>/dev/null || true)
  [[ -n "${desktop}" && "${desktop}" != "${home}" ]] || desktop="${home}/Desktop"
  [[ -d "${desktop}" ]] || { warn "No Desktop folder for ${user}; icon is in the app menu only."; return 0; }

  install -m 755 -o "${user}" -g "$(id -gn "${user}")" "${DESKTOP_FILE}" "${desktop}/boot-to-windows.desktop"
  # Mark as trusted so it launches without the "Allow Launching" step (Cinnamon/GNOME).
  sudo -u "${user}" gio set "${desktop}/boot-to-windows.desktop" metadata::trusted true 2>/dev/null || true
  ok "Desktop icon added: ${desktop}/boot-to-windows.desktop"
}

# ---------------------------------------------------------------- commands

cmd_install() {
  local entry_override="" menu_timeout="" fix_clock=0 desktop_icon=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --entry)          entry_override="${2:?--entry needs a value}"; shift 2 ;;
      --menu-timeout)   menu_timeout="${2:?--menu-timeout needs a number}"; shift 2 ;;
      --fix-clock)      fix_clock=1; shift ;;
      --no-desktop-icon) desktop_icon=0; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
  if [[ -n "${menu_timeout}" && ! "${menu_timeout}" =~ ^[0-9]+$ ]]; then
    die "--menu-timeout must be a whole number of seconds."
  fi

  info "Checking system"
  check_requirements
  ok "UEFI + GRUB found"

  local style="hidden" timeout=0
  if [[ -n "${menu_timeout}" ]]; then style="menu"; timeout="${menu_timeout}"; fi

  info "Configuring GRUB (Linux by default, menu ${style}${menu_timeout:+, ${timeout}s})"
  mkdir -p "$(dirname "${DEFAULTS_FILE}")"
  cat >"${DEFAULTS_FILE}" <<EOF
# Added by ${APP_NAME}. Remove with: sudo bash boot-to-windows-setup.sh uninstall
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT_STYLE=${style}
GRUB_TIMEOUT=${timeout}
GRUB_RECORDFAIL_TIMEOUT=10
GRUB_DISABLE_OS_PROBER=false
EOF
  write_override_script "${style}" "${timeout}"
  # Make sure no old one-time boot is pending.
  grub-editenv - unset next_entry 2>/dev/null || true
  grub-editenv - unset saved_entry 2>/dev/null || true

  info "Regenerating GRUB menu (this can take a moment)"
  update-grub 2>&1 | sed 's/^/    /'

  info "Finding Windows"
  local entries id title
  entries=$(list_windows_entries)
  if [[ -n "${entry_override}" ]]; then
    title="${entry_override}"; id=""
    grep -qF "'${title}'" "${GRUB_CFG}" || warn "Entry '${title}' isn't in ${GRUB_CFG} right now."
  elif [[ -n "${entries}" ]]; then
    id=$(head -n1 <<<"${entries}" | cut -f1)
    title=$(head -n1 <<<"${entries}" | cut -f2)
    if [[ $(wc -l <<<"${entries}") -gt 1 ]]; then
      warn "More than one Windows entry found; using the first:"
      cut -f2 <<<"${entries}" | sed 's/^/      /' >&2
      warn "Pick another with: sudo bash $0 install --entry \"NAME\""
    fi
  else
    id=""; title=""
    warn "Windows wasn't found in the GRUB menu."
    warn "Check Windows is installed, Fast Startup is OFF in Windows, then re-run install."
  fi
  [[ -n "${title}" ]] && ok "Windows entry: ${title}"

  cat >"${CONF_FILE}" <<EOF
# ${APP_NAME} configuration
WINDOWS_ENTRY_ID=$(printf '%q' "${id}")
WINDOWS_ENTRY_TITLE=$(printf '%q' "${title}")
EOF
  chmod 644 "${CONF_FILE}"

  info "Installing the 'boot-to-windows' command and app"
  write_bin
  write_desktop_entry
  ok "Command: ${BIN_FILE}"
  ok "App menu: Restart to Windows"
  [[ ${desktop_icon} -eq 1 ]] && install_desktop_icon

  if [[ ${fix_clock} -eq 1 ]]; then
    timedatectl set-local-rtc 1 --adjust-system-clock
    ok "Clock set to local time (matches Windows)"
  fi

  warn_if_windows_first

  echo
  info "Done."
  echo "    • Turning the PC on now goes straight into Linux."
  echo "    • To use Windows: click 'Restart to Windows' or run: boot-to-windows"
  echo "    • To see the boot menu anyway: tap Esc just after the BIOS logo."
}

cmd_uninstall() {
  info "Removing ${APP_NAME}"
  rm -f "${DEFAULTS_FILE}" "${OVERRIDE_SCRIPT}" "${CONF_FILE}" "${BIN_FILE}" "${DESKTOP_FILE}"
  local user home f
  user=$(target_user) || true
  if [[ -n "${user}" ]]; then
    home=$(getent passwd "${user}" | cut -d: -f6)
    for f in "${home}"/Desktop/boot-to-windows.desktop "${home}"/*/boot-to-windows.desktop; do
      [[ -e "${f}" ]] && rm -f "${f}"
    done
  fi
  grub-editenv - unset next_entry 2>/dev/null || true
  info "Regenerating GRUB menu"
  update-grub 2>&1 | sed 's/^/    /'
  ok "Removed. GRUB is back to your system's own settings."
  echo "    (If you used --fix-clock, undo it with: sudo timedatectl set-local-rtc 0)"
}

cmd_status() {
  echo "${C_B}${APP_NAME} v${VERSION}${C_0}"
  if [[ -f "${CONF_FILE}" ]]; then
    echo "Installed: yes"
    sed -n 's/^WINDOWS_ENTRY_TITLE=/Windows entry: /p' "${CONF_FILE}"
  else
    echo "Installed: no"
  fi
  echo
  echo "Windows entries in ${GRUB_CFG}:"
  local entries
  entries=$(list_windows_entries)
  if [[ -n "${entries}" ]]; then
    cut -f2 <<<"${entries}" | sed 's/^/  /'
  else
    echo "  (none found)"
  fi
  echo
  echo "Pending one-time boot: $(grub-editenv list 2>/dev/null | sed -n 's/^next_entry=//p' | grep . || echo none)"
  if command -v efibootmgr >/dev/null 2>&1; then
    echo
    echo "Firmware boot order:"
    efibootmgr 2>/dev/null | grep -E '^(BootOrder|Boot[0-9A-Fa-f]{4})' | cut -c1-70 | sed 's/^/  /'
  fi
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    install)   shift; require_root install "$@"; cmd_install "$@" ;;
    uninstall) shift; require_root uninstall;    cmd_uninstall ;;
    status)    shift; require_root status;       cmd_status ;;
    -v|--version) echo "${VERSION}" ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

# BTW_TEST lets the test suite load the functions without running main.
[[ -n "${BTW_TEST:-}" ]] || main "$@"
