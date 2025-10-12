#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XFCE_PANEL_ARCHIVE="${XFCE_PANEL_ARCHIVE:-${SCRIPT_DIR}/winConfigTemp.bz2}"
XFCE_PANEL_CONFIG_FILE="${XFCE_PANEL_CONFIG_FILE:-config.txt}"

if [[ "$(id -u)" -ne 0 ]]; then
  printf '[ERROR] Run this script as root (use sudo).\n' >&2
  exit 1
fi

TARGET_USER="${TARGET_USER:-${1:-}}"
XFCE_THEME="${XFCE_THEME:-Adwaita-dark}"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-latam}"
KEYBOARD_MODEL="${KEYBOARD_MODEL:-pc105}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT:-}"

log() {
  printf '[INFO] %s\n' "$*"
}

if [[ -z "${TARGET_USER}" ]]; then
  printf 'Usage: %s <target-user>\n' "$(basename "$0")" >&2
  printf '       TARGET_USER=<user> %s\n' "$(basename "$0")" >&2
  exit 1
fi

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
  printf '[ERROR] User %s does not exist.\n' "${TARGET_USER}" >&2
  exit 1
fi

run_xfconf() {
  sudo -u "${TARGET_USER}" dbus-launch --exit-with-session xfconf-query "$@"
}

xfconf_set_string() {
  local property=$1 value=$2 channel=$3
  run_xfconf --channel "${channel}" --property "${property}" --create --type string --set "${value}"
}

xfconf_set_bool() {
  local property=$1 value=$2 channel=$3
  run_xfconf --channel "${channel}" --property "${property}" --create --type bool --set "${value}"
}

xfconf_set_int() {
  local property=$1 value=$2 channel=$3
  run_xfconf --channel "${channel}" --property "${property}" --create --type int --set "${value}"
}

configure_theme() {
  log "Setting XFCE theme to ${XFCE_THEME} for ${TARGET_USER}."
  xfconf_set_string /Net/ThemeName "${XFCE_THEME}" xsettings
}

configure_power() {
  log "Disabling XFCE power-saving features."
  xfconf_set_bool /xfce4-power-manager/dpms-enabled false xfce4-power-manager
  xfconf_set_int /xfce4-power-manager/blank-on-ac 0 xfce4-power-manager
  xfconf_set_int /xfce4-power-manager/blank-on-battery 0 xfce4-power-manager
  xfconf_set_int /xfce4-power-manager/sleep-display-on-ac 0 xfce4-power-manager
  xfconf_set_int /xfce4-power-manager/sleep-display-on-battery 0 xfce4-power-manager
  xfconf_set_bool /xfce4-power-manager/inactivity-on-ac false xfce4-power-manager
  xfconf_set_bool /xfce4-power-manager/inactivity-on-battery false xfce4-power-manager
  run_xfconf --channel xfce4-screensaver --property /saver/enabled --create --type bool --set false
  run_xfconf --channel xfce4-screensaver --property /saver/idle-activation-enabled --create --type bool --set false
  run_xfconf --channel xfce4-screensaver --property /lock/lock-enabled --create --type bool --set false
  run_xfconf --channel xfce4-screensaver --property /lock/lock-delay --create --type uint --set 0
}

configure_keyboard() {
  log "Applying keyboard layout ${KEYBOARD_LAYOUT}${KEYBOARD_VARIANT:+ (${KEYBOARD_VARIANT})}."
  if [[ -n "${KEYBOARD_VARIANT}" ]]; then
    localectl set-x11-keymap "${KEYBOARD_LAYOUT}" "${KEYBOARD_MODEL}" "${KEYBOARD_VARIANT}"
  else
    localectl set-x11-keymap "${KEYBOARD_LAYOUT}" "${KEYBOARD_MODEL}"
  fi

  log "Configuring XFCE keyboard layout list for ${TARGET_USER}."
  run_xfconf --channel keyboard-layout --property /Default/UseSystemDefaults --create --type bool --set false
  run_xfconf --channel keyboard-layout --property /Default/XkbLayout --create --type string --set "${KEYBOARD_LAYOUT}"
  if [[ -n "${KEYBOARD_VARIANT}" ]]; then
    run_xfconf --channel keyboard-layout --property /Default/XkbVariant --create --type string --set "${KEYBOARD_VARIANT}"
  else
    run_xfconf --channel keyboard-layout --property /Default/XkbVariant --create --type string --set ""
  fi
  run_xfconf --channel keyboard-layout --property /Default/LayoutList --create --force-array \
    --type string --set "${KEYBOARD_LAYOUT}"
}

disable_release_upgrades() {
  local cfg="/etc/update-manager/release-upgrades"
  log "Disabling release upgrade prompts system-wide."
  if [[ -f "${cfg}" ]]; then
    if grep -q '^Prompt=' "${cfg}"; then
      sed -i 's/^Prompt=.*/Prompt=never/' "${cfg}"
    else
      printf '\nPrompt=never\n' >> "${cfg}"
    fi
  else
    cat <<'EOF' > "${cfg}"
[DEFAULT]
Prompt=never
EOF
  fi

  if command -v gsettings >/dev/null 2>&1; then
    log "Setting per-user release-upgrade-mode to never."
    sudo -u "${TARGET_USER}" dbus-launch gsettings set com.ubuntu.update-notifier release-upgrade-mode never || true
  fi

  local autostart="/etc/xdg/autostart/update-notifier.desktop"
  if [[ -f "${autostart}" ]]; then
    log "Renaming update-notifier autostart entry to stop upgrade prompts."
    mv -f "${autostart}" "${autostart}.disabled"
  fi
}

disable_screen_lock() {
  log "Disabling XFCE session lock for ${TARGET_USER}."
  run_xfconf --channel xfce4-session --property /general/LockCommand --create --type string --set ""
  run_xfconf --channel xfce4-session --property /general/LockOnSuspend --create --type bool --set false
  run_xfconf --channel xfce4-session --property /shutdown/LockScreen --create --type bool --set false

  local light_locker="/etc/xdg/autostart/light-locker.desktop"
  if [[ -f "${light_locker}" ]]; then
    log "Disabling light-locker autostart."
    mv -f "${light_locker}" "${light_locker}.disabled"
  fi

  local xfce_saver="/etc/xdg/autostart/xfce4-screensaver.desktop"
  if [[ -f "${xfce_saver}" ]]; then
    log "Disabling xfce4-screensaver autostart."
    mv -f "${xfce_saver}" "${xfce_saver}.disabled"
  fi
}

apply_panel_configuration() {
  local archive="${XFCE_PANEL_ARCHIVE}"
  if [[ ! -f "${archive}" ]]; then
    log "Panel archive ${archive} not found; skipping panel import."
    return
  fi

  log "Applying XFCE panel configuration from ${archive}."

  local temp_dir
  temp_dir="$(mktemp -d)"

  if ! tar -xf "${archive}" -C "${temp_dir}"; then
    log "Failed to extract panel archive; skipping panel import."
    rm -rf "${temp_dir}"
    return
  fi

  local config_path="${temp_dir}/${XFCE_PANEL_CONFIG_FILE}"
  if [[ ! -f "${config_path}" ]]; then
    log "Panel config file ${XFCE_PANEL_CONFIG_FILE} missing inside archive; skipping panel import."
    rm -rf "${temp_dir}"
    return
  fi

  local target_home
  target_home="$(eval echo "~${TARGET_USER}")"
  if [[ -z "${target_home}" || ! -d "${target_home}" ]]; then
    log "Unable to resolve home directory for ${TARGET_USER}; skipping panel import."
    rm -rf "${temp_dir}"
    return
  fi

  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  local panel_dir="${target_home}/.config/xfce4/panel"
  install -d -m 755 "${panel_dir}"

  # Copy launcher directories if present to preserve custom shortcuts.
  local copied_launchers=0
  while IFS= read -r -d '' launcher_dir; do
    local launcher_name
    launcher_name="$(basename "${launcher_dir}")"
    rm -rf "${panel_dir}/${launcher_name}"
    cp -a "${launcher_dir}" "${panel_dir}/"
    copied_launchers=1
  done < <(find "${temp_dir}" -maxdepth 1 -type d -name 'launcher-*' -print0)

  if [[ "${copied_launchers}" -eq 0 ]]; then
    log "No launcher directories found in archive; continuing without launcher import."
  fi

  chown -R "${TARGET_USER}:${target_group}" "${panel_dir}"

  # Ensure the target user can read the config file during import.
  chown "${TARGET_USER}:${target_group}" "${config_path}"
  chmod 600 "${config_path}"

  if run_xfconf --channel xfce4-panel --from-file "${config_path}"; then
    log "Panel configuration imported for ${TARGET_USER}."
  else
    log "Failed to import panel configuration for ${TARGET_USER}."
  fi

  rm -rf "${temp_dir}"
}

main() {
  disable_release_upgrades
  disable_screen_lock
  configure_theme
  configure_power
  configure_keyboard
  apply_panel_configuration
  log "XFCE adjustments completed. Log out and back in to see theme changes."
}

main "$@"
