#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/reapply_crystal_perms.log"
LOG_FILE="${REAPPLY_CRYSTAL_PERMS_LOG_FILE:-${LOG_FILE_DEFAULT}}"

LOG_OWNER="${REAPPLY_CRYSTAL_PERMS_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${REAPPLY_CRYSTAL_PERMS_LOG_GROUP:-}"

if [[ -z "${LOG_GROUP}" ]]; then
  if id -gn "${LOG_OWNER}" >/dev/null 2>&1; then
    LOG_GROUP="$(id -gn "${LOG_OWNER}")"
  else
    LOG_GROUP="${LOG_OWNER}"
  fi
fi

if [[ -n "${LOG_FILE}" ]]; then
  if ! touch "${LOG_FILE}" 2>/dev/null; then
    printf '[WARN] No se pudo inicializar el archivo de log en %s; logging deshabilitado.\n' "${LOG_FILE}" >&2
    LOG_FILE=""
  else
    chmod 640 "${LOG_FILE}"
    chown "${LOG_OWNER}:${LOG_GROUP}" "${LOG_FILE}" 2>/dev/null || true
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

on_unexpected_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  error "Fallo inesperado (codigo ${exit_code}) en linea ${line}: ${cmd}"
  exit "${exit_code}"
}

trap 'on_unexpected_error' ERR

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "Ejecuta este script como root (usa sudo)."
    exit 1
  fi
}

determine_target_user() {
  local candidate=""
  if [[ -n "${REAPPLY_CRYSTAL_TARGET_USER:-}" ]]; then
    candidate="${REAPPLY_CRYSTAL_TARGET_USER}"
  elif [[ -n "${INSTALL_SERVER_TARGET_USER:-}" ]]; then
    candidate="${INSTALL_SERVER_TARGET_USER}"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    candidate="${SUDO_USER}"
  else
    candidate="root"
  fi

  if ! id "${candidate}" >/dev/null 2>&1; then
    error "El usuario objetivo '${candidate}' no existe."
    exit 1
  fi

  TARGET_USER="${candidate}"
  TARGET_GROUP="$(id -gn "${TARGET_USER}")"
  TARGET_HOME="$(eval echo "~${TARGET_USER}" 2>/dev/null || true)"
  if [[ -z "${TARGET_HOME}" || "${TARGET_HOME}" == "~${TARGET_USER}" ]]; then
    error "No se pudo determinar el directorio home de ${TARGET_USER}."
    exit 1
  fi
}

ensure_directories() {
  local base_dir="$1"
  local -a dirs=(
    ""
    "system"
    "plugins"
    "tools"
    "build"
    "build/linux-release"
    "build/linux-release/bin"
  )

  local subdir
  for subdir in "${dirs[@]}"; do
    local current="${base_dir}"
    if [[ -n "${subdir}" ]]; then
      current="${base_dir}/${subdir}"
    fi
    mkdir -p "${current}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${current}"
  done
}

apply_permissions() {
  local crystal_dir="$1"

  log "Ajustando propietario de ${crystal_dir} a ${TARGET_USER}:${TARGET_GROUP}..."
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "${crystal_dir}"

  log "Aplicando permisos 775 en ${crystal_dir}..."
  chmod -R 775 "${crystal_dir}"

  if command -v setfacl >/dev/null 2>&1; then
    log "Aplicando ACL para www-data en ${TARGET_HOME} y ${crystal_dir}..."
    setfacl -R -m g:www-data:rx "${TARGET_HOME}"
    setfacl -R -m g:www-data:rx "${crystal_dir}"
  else
    warn "setfacl no esta disponible; omitiendo configuracion ACL para www-data."
  fi
}

main() {
  ensure_root
  determine_target_user

  local crystal_dir="${TARGET_HOME}/crystalserver"
  if [[ ! -d "${crystal_dir}" ]]; then
    warn "No se encontro ${crystal_dir}; no se realizaron cambios."
    return 0
  fi

  log "Reaplicando permisos de Crystal Server para el usuario ${TARGET_USER}."
  ensure_directories "${crystal_dir}"
  apply_permissions "${crystal_dir}"

  log "Permisos reaplicados correctamente en ${crystal_dir}."
}

main "$@"
