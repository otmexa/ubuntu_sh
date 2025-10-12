#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  printf '[ERROR] Run this script as root (use sudo).\n' >&2
  exit 1
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
DEFAULT_USERNAME="${DEFAULT_USERNAME:-}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
TMP_WORKDIR=""
USERNAME=""
PASSWORD=""

log() {
  printf '[INFO] %s\n' "$*"
}

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
      printf '[WARN] Username cannot be empty.\n'
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
      printf '[WARN] Password cannot be empty.\n'
      continue
    fi

    if [[ "${PASSWORD}" != "${password_confirm}" ]]; then
      printf '[WARN] Passwords do not match.\n'
      PASSWORD=""
      password_confirm=""
      continue
    fi

    break
  done
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
  TMP_WORKDIR="$(mktemp -d)"
  trap cleanup EXIT

  prompt_credentials
  ensure_user
  install_packages
  install_deb_packages

  log "Setup finished. Reboot if you want to log in with XFCE."
}

main "$@"
