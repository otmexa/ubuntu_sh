#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/install_web.log"
LOG_FILE="${INSTALL_WEB_LOG_FILE:-${LOG_FILE_DEFAULT}}"

LOG_OWNER="${INSTALL_WEB_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${INSTALL_WEB_LOG_GROUP:-}"

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

WWW_ROOT="/var/www/html"
DEFAULT_TARGET_DIR=""
DEFAULT_PERMISSIONS_MODE="acl"
MODIFIABLE_DIRS=(outfits system images plugins tools cache)

REPOS=(
  "otmexa/myaac_noxusot|privado|noxus|Noxus MyAAC (privado)"
  "zimbadev/crystalserver-myacc|publico|crystal|Crystal MyAAC (publico)"
)

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
    printf '%s\n' "${line}" >>"${LOG_FILE}"
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

prompt_repo_choice() {
  log "Selecciona la web a instalar:"
  local index=1
  local choice=""
  for entry in "${REPOS[@]}"; do
    IFS='|' read -r name visibility _ display <<<"${entry}"
    printf ' %d) %s\n' "${index}" "${display:-${name}}"
    ((index++))
  done
  printf ' q) Cancelar\n'

  while :; do
    read -r -p "Opcion: " choice
    case "${choice}" in
      q|Q)
        log "Instalacion cancelada por el usuario."
        exit 0
        ;;
      '')
        continue
        ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]]; then
          local idx=$((choice - 1))
          if (( idx >= 0 && idx < ${#REPOS[@]} )); then
            printf '%s\n' "${REPOS[${idx}]}"
            return 0
          fi
        fi
        warn "Opcion invalida."
        ;;
    esac
  done
}

check_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    error "GitHub CLI (gh) no esta instalado. Instala con 'sudo apt install gh' y vuelve a intentar."
    exit 1
  fi

  if gh auth status >/dev/null 2>&1; then
    log "GitHub CLI ya se encuentra autenticado."
    return 0
  fi

  log "GitHub CLI no autenticado. Iniciando flujo via device code..."
  if gh auth login --git-protocol https --scopes "repo"; then
    log "Autenticacion completada correctamente."
    return 0
  fi

  error "No se pudo completar la autenticacion con GitHub CLI."
  exit 1
}

clone_repo() {
  local repo_name="$1"
  local visibility="$2"
  local label="$3"
  local display="$4"
  local checkout_parent="${SCRIPT_DIR}/web_sources"
  local checkout_dir="${checkout_parent}/${label}"

  mkdir -p "${checkout_parent}"
  if [[ -d "${checkout_dir}" ]]; then
    log "Actualizando repositorio existente en ${checkout_dir}..."
    if git -C "${checkout_dir}" remote get-url origin >/dev/null 2>&1; then
      if ! git -C "${checkout_dir}" fetch --all --prune; then
        warn "Fallo al ejecutar git fetch; se reclonara el repositorio."
        rm -rf "${checkout_dir}"
      else
        if git -C "${checkout_dir}" pull --ff-only; then
          printf '%s\n' "${checkout_dir}"
          return 0
        fi
        warn "Fallo al aplicar git pull; se reclonara el repositorio."
        rm -rf "${checkout_dir}"
      fi
    else
      rm -rf "${checkout_dir}"
    fi
  fi

  local friendly="${display:-${repo_name}}"
  log "Clonando ${friendly} (${repo_name})..."
  if [[ "${visibility}" == "privado" ]]; then
    check_gh_auth
    if ! gh repo clone "${repo_name}" "${checkout_dir}"; then
      error "No se pudo clonar el repositorio privado ${repo_name}."
      exit 1
    fi
  else
    if ! git clone "https://github.com/${repo_name}.git" "${checkout_dir}"; then
      error "No se pudo clonar el repositorio ${repo_name}."
      exit 1
    fi
  fi

  printf '%s\n' "${checkout_dir}"
}

ensure_www_root() {
  if [[ ! -d "${WWW_ROOT}" ]]; then
    mkdir -p "${WWW_ROOT}"
  fi
}

synchronize_web_files() {
  local source_dir="$1"
  local target_dir="$2"
  local clean_mode="${INSTALL_WEB_CLEAN_TARGET:-0}"

  log "Copiando archivos hacia ${target_dir}..."
  mkdir -p "${target_dir}"
  if command -v rsync >/dev/null 2>&1; then
    if [[ "${clean_mode}" -eq 1 ]]; then
      rsync -a --delete "${source_dir}/" "${target_dir}/"
    else
      rsync -a "${source_dir}/" "${target_dir}/"
    fi
  else
    if [[ "${clean_mode}" -eq 1 ]]; then
      find "${target_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    cp -a "${source_dir}/." "${target_dir}/"
  fi
}

apply_permissions_basic() {
  local target_dir="$1"
  log "Aplicando permisos basicos en ${target_dir}..."
  chown -R www-data:www-data "${target_dir}"
  chmod -R 755 "${target_dir}"
  local dir
  for dir in "${MODIFIABLE_DIRS[@]}"; do
    if [[ -d "${target_dir}/${dir}" ]]; then
      chmod -R 777 "${target_dir}/${dir}"
    fi
  done
}

apply_permissions_acl() {
  local target_dir="$1"
  if ! command -v setfacl >/dev/null 2>&1; then
    warn "setfacl no esta disponible; se usan permisos basicos."
    apply_permissions_basic "${target_dir}"
    return
  fi

  log "Aplicando permisos ACL en ${target_dir}..."
  chown -R www-data:www-data "${target_dir}"
  chmod -R 775 "${target_dir}"
  setfacl -R -m g:www-data:rwx "${target_dir}"
  setfacl -dR -m g:www-data:rwx "${target_dir}"

  local dir
  for dir in "${MODIFIABLE_DIRS[@]}"; do
    if [[ -d "${target_dir}/${dir}" ]]; then
      chmod -R 777 "${target_dir}/${dir}"
    fi
  done
}

apply_permissions() {
  local target_dir="$1"
  local mode="${INSTALL_WEB_PERMISSIONS_MODE:-${DEFAULT_PERMISSIONS_MODE}}"

  if [[ "${mode}" == "acl" ]]; then
    apply_permissions_acl "${target_dir}"
  else
    apply_permissions_basic "${target_dir}"
  fi
}

ensure_user_in_www_data() {
  if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    return
  fi

  if id -nG "${SUDO_USER}" | tr ' ' '\n' | grep -qx "www-data"; then
    return
  fi

  if usermod -a -G www-data "${SUDO_USER}"; then
    log "Usuario ${SUDO_USER} agregado al grupo www-data (requerira nueva sesion para tomar efecto)."
  else
    warn "No se pudo agregar a ${SUDO_USER} al grupo www-data; verifica manualmente."
  fi
}

main() {
  ensure_root
  ensure_www_root
  ensure_user_in_www_data

  local selection
  selection="$(prompt_repo_choice)"
  IFS='|' read -r repo_name visibility label display_name <<<"${selection}"
  local friendly="${display_name:-${repo_name}}"
  log "Opcion seleccionada: ${friendly}"

  local checkout_dir
  checkout_dir="$(clone_repo "${repo_name}" "${visibility}" "${label}" "${friendly}")"

  local target_subdir="${INSTALL_WEB_TARGET_DIR:-${DEFAULT_TARGET_DIR}}"
  local target_dir="${WWW_ROOT}"
  if [[ -n "${target_subdir}" ]]; then
    target_dir="${WWW_ROOT}/${target_subdir}"
  fi
  synchronize_web_files "${checkout_dir}" "${target_dir}"
  apply_permissions "${target_dir}"

  log "Instalacion completada."
  log "Archivos desplegados en ${target_dir}"
  log "Abre http://<tu-servidor>/install para finalizar el asistente de MyAAC."
}

main "$@"
