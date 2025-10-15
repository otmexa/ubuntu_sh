#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

LOG_FILE_DEFAULT="${SCRIPT_DIR}/update_repo.log"
LOG_FILE="${UPDATE_REPO_LOG_FILE:-${LOG_FILE_DEFAULT}}"

LOG_OWNER="${UPDATE_REPO_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${UPDATE_REPO_LOG_GROUP:-}"

if [[ -z "${LOG_GROUP}" ]]; then
  if id -gn "${LOG_OWNER}" >/dev/null 2>&1; then
    LOG_GROUP="$(id -gn "${LOG_OWNER}")"
  else
    LOG_GROUP="${LOG_OWNER}"
  fi
fi

if [[ -n "${LOG_FILE}" ]]; then
  if ! touch "${LOG_FILE}" 2>/dev/null; then
    printf '[WARN] No se pudo inicializar el log en %s; logging deshabilitado.\n' "${LOG_FILE}" >&2
    LOG_FILE=""
  else
    chmod 640 "${LOG_FILE}"
    chown "${LOG_OWNER}:${LOG_GROUP}" "${LOG_FILE}" 2>/dev/null || true
  fi
fi

log() {
  local message="$*"
  printf '[INFO] %s\n' "${message}"
  if [[ -n "${LOG_FILE}" ]]; then
    printf '[INFO] %s\n' "${message}" >> "${LOG_FILE}"
  fi
}

warn() {
  local message="$*"
  printf '[WARN] %s\n' "${message}" >&2
  if [[ -n "${LOG_FILE}" ]]; then
    printf '[WARN] %s\n' "${message}" >> "${LOG_FILE}"
  fi
}

error() {
  local message="$*"
  printf '[ERROR] %s\n' "${message}" >&2
  if [[ -n "${LOG_FILE}" ]]; then
    printf '[ERROR] %s\n' "${message}" >> "${LOG_FILE}"
  fi
}

ensure_repo() {
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    error "No se detecto repositorio Git en ${REPO_DIR}."
    exit 1
  fi

  if [[ -n "$(git -C "${REPO_DIR}" status --porcelain)" ]]; then
    warn "El repositorio tiene cambios locales; no se ejecutara git pull."
    exit 1
  fi

  if [[ -z "$(git -C "${REPO_DIR}" remote)" ]]; then
    warn "El repositorio no tiene remotos configurados."
    exit 1
  fi
}

main() {
  ensure_repo

  log "Ejecutando 'git fetch --all --prune'..."
  if ! git -C "${REPO_DIR}" fetch --all --prune; then
    error "Fallo git fetch."
    exit 1
  fi

  log "Ejecutando 'git pull --ff-only'..."
  if ! git -C "${REPO_DIR}" pull --ff-only; then
    error "Fallo git pull."
    exit 1
  fi

  log "Repositorio actualizado correctamente."
}

main "$@"
