#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/reinstall_phpmyadmin.log"
LOG_FILE="${REINSTALL_PHPMYADMIN_LOG_FILE:-${LOG_FILE_DEFAULT}}"

STATE_FILE_DEFAULT="${SCRIPT_DIR}/setup_core.state"
STATE_FILE="${SETUP_CORE_STATE_FILE:-${STATE_FILE_DEFAULT}}"

WWW_ROOT="/var/www/html"
PHPMYADMIN_ALIAS="${REINSTALL_PHPMYADMIN_ALIAS:-${PHPMYADMIN_ALIAS:-}}"
PHPMYADMIN_PATH=""
PHPMYADMIN_VERSION="${REINSTALL_PHPMYADMIN_VERSION:-5.2.1}"
PHPMYADMIN_URL="${REINSTALL_PHPMYADMIN_URL:-https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.zip}"

LOG_OWNER="${REINSTALL_PHPMYADMIN_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${REINSTALL_PHPMYADMIN_LOG_GROUP:-}"

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

load_alias_from_state() {
  if [[ -n "${PHPMYADMIN_ALIAS}" ]]; then
    return
  fi
  if [[ ! -f "${STATE_FILE}" ]]; then
    return
  fi

  local stored
  stored="$(awk -F'=' '/^data:phpmyadmin_alias=/{print $2; exit}' "${STATE_FILE}" | tr -d '\r' || true)"
  if [[ -n "${stored}" ]]; then
    PHPMYADMIN_ALIAS="${stored}"
    log "Alias detectado en ${STATE_FILE}: ${PHPMYADMIN_ALIAS}"
  fi
}

detect_alias_from_fs() {
  if [[ -n "${PHPMYADMIN_ALIAS}" || ! -d "${WWW_ROOT}" ]]; then
    return
  fi

  local candidate=""
  while IFS= read -r -d '' path; do
    if [[ -f "${path}/config.inc.php" ]]; then
      candidate="$(basename "${path}")"
      break
    fi
  done < <(find "${WWW_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  if [[ -n "${candidate}" ]]; then
    PHPMYADMIN_ALIAS="${candidate}"
    log "Alias detectado en ${WWW_ROOT}: ${PHPMYADMIN_ALIAS}"
  fi
}

prompt_phpmyadmin_alias() {
  local default_alias="${PHPMYADMIN_ALIAS:-phpmyadmin}"
  local input=""
  read -r -p "Carpeta publica para phpMyAdmin [${default_alias}]: " input
  if [[ -z "${input}" ]]; then
    input="${default_alias}"
  fi
  PHPMYADMIN_ALIAS="${input}"
}

determine_phpmyadmin_alias() {
  if [[ -n "${PHPMYADMIN_ALIAS}" ]]; then
    log "Usando alias proporcionado: ${PHPMYADMIN_ALIAS}"
    return
  fi
  load_alias_from_state
  detect_alias_from_fs
  if [[ -n "${PHPMYADMIN_ALIAS}" ]]; then
    return
  fi
  prompt_phpmyadmin_alias
}

ensure_www_root() {
  if [[ -d "${WWW_ROOT}" ]]; then
    return
  fi
  log "Creando ${WWW_ROOT}..."
  mkdir -p "${WWW_ROOT}"
  chown www-data:www-data "${WWW_ROOT}" || true
  chmod 755 "${WWW_ROOT}" || true
}

set_phpmyadmin_path() {
  if [[ -z "${PHPMYADMIN_ALIAS}" ]]; then
    error "El alias de phpMyAdmin no puede estar vacio."
    exit 1
  fi
  PHPMYADMIN_PATH="${WWW_ROOT}/${PHPMYADMIN_ALIAS}"
}

reinstall_phpmyadmin() {
  log "Reinstalando phpMyAdmin (${PHPMYADMIN_VERSION}) en /${PHPMYADMIN_ALIAS}..."
  apt-get update >/dev/null 2>&1 || warn "apt-get update fallo; continuando."
  apt-get install -y wget unzip openssl

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  local archive="${tmp_dir}/phpmyadmin.zip"
  if ! wget -qO "${archive}" "${PHPMYADMIN_URL}"; then
    error "No se pudo descargar phpMyAdmin desde ${PHPMYADMIN_URL}."
    exit 1
  fi

  unzip -q "${archive}" -d "${tmp_dir}"
  local extracted
  extracted="$(find "${tmp_dir}" -maxdepth 1 -type d -name 'phpMyAdmin-*-all-languages' | head -n1)"
  if [[ -z "${extracted}" || ! -d "${extracted}" ]]; then
    error "No se pudo extraer phpMyAdmin."
    exit 1
  fi

  if [[ -d "${PHPMYADMIN_PATH}" ]]; then
    rm -rf "${PHPMYADMIN_PATH}"
  fi
  mv "${extracted}" "${PHPMYADMIN_PATH}"

  cp "${PHPMYADMIN_PATH}/config.sample.inc.php" "${PHPMYADMIN_PATH}/config.inc.php"
  local blowfish
  blowfish="$(openssl rand -base64 24)"
  sed -i "s#\$cfg\['blowfish_secret'\] = '';#\$cfg['blowfish_secret'] = '${blowfish}';#" "${PHPMYADMIN_PATH}/config.inc.php"

  chown -R www-data:www-data "${PHPMYADMIN_PATH}"
  chmod -R 775 "${PHPMYADMIN_PATH}"

  rm -rf "${tmp_dir}"
  trap - RETURN

  log "phpMyAdmin reinstalado en /${PHPMYADMIN_ALIAS}."
}

ensure_default_index() {
  local index_file="${WWW_ROOT}/index.php"
  if [[ -f "${index_file}" ]]; then
    return
  fi

  cat <<PHP > "${index_file}"
<?php
http_response_code(200);
echo "Servidor listo. phpMyAdmin disponible en /${PHPMYADMIN_ALIAS}";
PHP

  chown www-data:www-data "${index_file}" || true
  chmod 644 "${index_file}" || true
  log "Archivo index.php generado en ${WWW_ROOT}."
}

update_state_alias() {
  if [[ -z "${STATE_FILE}" || ! -f "${STATE_FILE}" ]]; then
    return
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  local found=0
  local line=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == data:phpmyadmin_alias=* ]]; then
      printf 'data:phpmyadmin_alias=%s\n' "${PHPMYADMIN_ALIAS}" >> "${tmp_file}"
      found=1
    else
      printf '%s\n' "${line}" >> "${tmp_file}"
    fi
  done < "${STATE_FILE}"

  if [[ "${found}" -eq 0 ]]; then
    printf 'data:phpmyadmin_alias=%s\n' "${PHPMYADMIN_ALIAS}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${STATE_FILE}"
  chmod 640 "${STATE_FILE}" || true
  chown "${LOG_OWNER}:${LOG_GROUP}" "${STATE_FILE}" 2>/dev/null || true
}

main() {
  ensure_root
  ensure_www_root
  determine_phpmyadmin_alias
  set_phpmyadmin_path
  reinstall_phpmyadmin
  ensure_default_index
  update_state_alias
  log "Proceso finalizado. Accede a http://<tu-servidor>/${PHPMYADMIN_ALIAS}"
}

main "$@"
