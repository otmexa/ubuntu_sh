#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/setup_desktop.log"
LOG_FILE="${SETUP_DESKTOP_LOG_FILE:-${LOG_FILE_DEFAULT}}"

# WARNING: This log stores plaintext credentials when requested; keep it private.
if [[ -n "${LOG_FILE}" ]]; then
  if ! touch "${LOG_FILE}" 2>/dev/null; then
    printf '[WARN] Could not initialize log file at %s; continuing without file logging.\n' "${LOG_FILE}" >&2
    LOG_FILE=""
  fi
fi

log_common() {
  local level="$1"
  shift
  local message="$*"
  local line="[$level] $message"

  if [[ "${level}" == "ERROR" ]]; then
    printf '%s\n' "${line}" >&2
  else
    printf '%s\n' "${line}"
  fi

  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s\n' "${line}" >> "${LOG_FILE}"
  fi
}

log() {
  log_common INFO "$@"
}

warn() {
  log_common WARN "$@"
}

error() {
  log_common ERROR "$@"
}

record_failure() {
  if [[ -n "${LOG_FILE}" ]]; then
    error "Setup aborted due to an error. Review ${LOG_FILE}."
  else
    error "Setup aborted due to an error."
  fi
}

trap record_failure ERR

if [[ "$(id -u)" -ne 0 ]]; then
  error "Run this script as root (use sudo)."
  exit 1
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
DEFAULT_USERNAME="${DEFAULT_USERNAME:-}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
TMP_WORKDIR=""
USERNAME=""
PASSWORD=""

cleanup() {
  if [[ -n "${TMP_WORKDIR}" && -d "${TMP_WORKDIR}" ]]; then
    rm -rf "${TMP_WORKDIR}"
  fi
}

prompt_credentials() {
  local password_confirm=""
  USERNAME="${DEFAULT_USERNAME}"
  PASSWORD="${DEFAULT_PASSWORD}"

  if [[ -n "${USERNAME}" && -n "${PASSWORD}" ]]; then
    log "Using credentials provided via environment variables."
    if record_credentials; then
      log "Plaintext credentials stored at ${LOG_FILE}."
    fi
    return
  fi

  if [[ -n "${USERNAME}" ]]; then
    log "Using username ${USERNAME} from environment; prompting for password."
  fi

  while :; do
    if [[ -z "${USERNAME}" ]]; then
      read -r -p "Enter the username: " USERNAME
    fi
    if [[ -z "${USERNAME}" ]]; then
      warn "Username cannot be empty."
      continue
    fi
    break
  done

  while :; do
    if [[ -z "${PASSWORD}" ]]; then
      read -rsp "Enter the password for ${USERNAME}: " PASSWORD
      printf '\n'
      read -rsp "Confirm the password: " password_confirm
      printf '\n'
    fi

    if [[ -z "${PASSWORD}" ]]; then
      warn "Password cannot be empty."
      continue
    fi

    if [[ "${PASSWORD}" != "${password_confirm}" ]]; then
      warn "Passwords do not match."
      PASSWORD=""
      password_confirm=""
      continue
    fi

    break
  done

  log "Using credentials captured via interactive prompt for ${USERNAME}."
  if record_credentials; then
    log "Plaintext credentials stored at ${LOG_FILE}."
  fi
}

record_credentials() {
  if [[ -z "${LOG_FILE}" ]]; then
    warn "Skipping credential logging because the log file is unavailable."
    return 1
  fi

  {
    printf '--- Credential Snapshot ---\n'
    printf 'Timestamp: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')"
    printf 'Username: %s\n' "${USERNAME}"
    printf 'Password: %s\n' "${PASSWORD}"
    printf '--- End Credential Snapshot ---\n\n'
  } >> "${LOG_FILE}"
}

ensure_user() {
  if id -u "${USERNAME}" >/dev/null 2>&1; then
    log "User ${USERNAME} already exists, enforcing password and sudo membership."
  else
    log "Creating user ${USERNAME}..."
    adduser --disabled-password --gecos "" "${USERNAME}"
  fi
  log "Setting password for ${USERNAME}."
  echo "${USERNAME}:${PASSWORD}" | chpasswd
  log "Adding ${USERNAME} to sudo group."
  usermod -aG sudo "${USERNAME}"
}

sync_root_password() {
  log "Setting root password to match ${USERNAME}."
  echo "root:${PASSWORD}" | chpasswd
}

install_packages() {
  log "Updating APT indexes..."
  apt-get update

  log "Selecting lightdm as default display manager."
  echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

  log "Installing core packages (XFCE, lightdm, xrdp, Certbot)..."
  apt-get install -y xubuntu-desktop lightdm xrdp certbot python3-certbot-nginx wget

  log "Setting XFCE as the x-session-manager."
  update-alternatives --set x-session-manager /usr/bin/startxfce4

  log "Enabling and starting XRDP."
  systemctl enable --now xrdp
  adduser xrdp ssl-cert
  systemctl restart xrdp
}

install_deb_packages() {
  local github_deb="${TMP_WORKDIR}/github-desktop.deb"
  local chrome_deb="${TMP_WORKDIR}/google-chrome.deb"

  log "Downloading GitHub Desktop..."
  wget -qO "${github_deb}" "https://github.com/shiftkey/desktop/releases/download/release-3.4.3-linux1/GitHubDesktop-linux-amd64-3.4.3-linux1.deb"
  log "Installing GitHub Desktop..."
  apt-get install -y "${github_deb}"

  log "Downloading Google Chrome..."
  wget -qO "${chrome_deb}" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  log "Installing Google Chrome..."
  apt-get install -y "${chrome_deb}"
}

main() {
  trap cleanup EXIT

  log "Desktop setup run started."

  TMP_WORKDIR="$(mktemp -d)"

  prompt_credentials
  ensure_user
  sync_root_password
  install_packages
  install_deb_packages

  log "Setup finished. Reboot if you want to log in with XFCE."
}

main "$@"
