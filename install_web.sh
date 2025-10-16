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

CLONED_REPO_PATH=""
SELECTED_REPO=""
SKIP_REPO_PERMS="${INSTALL_WEB_SKIP_REPO_PERMS:-0}"
SKIP_DEPLOY_PERMS="${INSTALL_WEB_SKIP_DEPLOY_PERMS:-0}"
SKIP_GROUP_ASSIGN="${INSTALL_WEB_SKIP_GROUP_ASSIGN:-0}"
SOURCE_BASE=""

ensure_gh_cli() {
  if command -v gh >/dev/null 2>&1; then
    return
  fi

  log "GitHub CLI (gh) no esta instalado; intentando instalarlo automaticamente..."
  if ! apt-get update >/dev/null 2>&1; then
    warn "Fallo 'apt-get update'; se intentara instalar gh de todas formas."
  fi

  if apt-get install -y gh >/dev/null 2>&1; then
    log "GitHub CLI instalado correctamente."
    return
  fi

  error "No se pudo instalar GitHub CLI automaticamente. Instala 'gh' manualmente (sudo apt install gh) e intenta de nuevo."
  exit 1
}

open_device_portal() {
  local url="https://github.com/login/device"
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && -n "${DISPLAY:-}" && -x "$(command -v sudo)" && -x "$(command -v xdg-open)" ]]; then
    if sudo -u "${SUDO_USER}" DISPLAY="${DISPLAY}" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" xdg-open "${url}" >/dev/null 2>&1; then
      log "Se abrio ${url} en la sesion de ${SUDO_USER}. Continua con el codigo que mostrara gh."
      return
    fi
  fi
  warn "Abre manualmente ${url} antes de ingresar el codigo mostrado por gh."
}

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

determine_sources_base() {
  if [[ -n "${INSTALL_WEB_SOURCE_DIR:-}" ]]; then
    SOURCE_BASE="${INSTALL_WEB_SOURCE_DIR}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local user_home
    user_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || true)"
    if [[ -n "${user_home}" && "${user_home}" != "~${SUDO_USER}" ]]; then
      SOURCE_BASE="${user_home}/.cache/ubuntu_sh/web_sources"
      return
    fi
  fi

  SOURCE_BASE="/var/cache/ubuntu_sh/web_sources"
}

prompt_repo_choice() {
  printf '\nSelecciona la web a instalar:\n'
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
            SELECTED_REPO="${REPOS[${idx}]}"
            return 0
          fi
        fi
        warn "Opcion invalida."
        ;;
    esac
  done
}

check_gh_auth() {
  ensure_gh_cli

  if gh auth status >/dev/null 2>&1; then
    log "GitHub CLI ya se encuentra autenticado."
    return 0
  fi

  log "GitHub CLI no autenticado. Iniciando flujo interactivo..."
  open_device_portal
  if gh auth login --hostname github.com --scopes "repo"; then
    log "Autenticacion completada correctamente."
    return 0
  fi

  error "No se pudo completar la autenticacion con GitHub CLI. Ejecuta 'gh auth login --hostname github.com --scopes repo' manualmente y reintenta."
  exit 1
}

clone_repo() {
  local repo_name="$1"
  local visibility="$2"
  local label="$3"
  local display="$4"
  local checkout_parent="${SOURCE_BASE}"
  local checkout_dir="${checkout_parent}/${label}"

  mkdir -p "${checkout_parent}"
  if [[ -d "${checkout_dir}" ]]; then
    if [[ ! -d "${checkout_dir}/.git" ]]; then
      warn "El directorio ${checkout_dir} no contiene un repositorio Git valido; se reclonara."
      rm -rf "${checkout_dir}"
    fi
  fi

  if [[ -d "${checkout_dir}" ]]; then
    log "Actualizando repositorio existente en ${checkout_dir}..."
    if git -C "${checkout_dir}" remote get-url origin >/dev/null 2>&1; then
      if ! git -C "${checkout_dir}" fetch --all --prune; then
        warn "Fallo al ejecutar git fetch; se reclonara el repositorio."
        rm -rf "${checkout_dir}"
      else
        if git -C "${checkout_dir}" pull --ff-only; then
          CLONED_REPO_PATH="${checkout_dir}"
          if [[ "${SKIP_REPO_PERMS}" -ne 1 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            chown -R "${SUDO_USER}:${SUDO_USER}" "${checkout_dir}" 2>/dev/null || true
          fi
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

  CLONED_REPO_PATH="${checkout_dir}"

  if [[ "${SKIP_REPO_PERMS}" -ne 1 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${checkout_dir}" 2>/dev/null || true
  fi
}

ensure_www_root() {
  if [[ ! -d "${WWW_ROOT}" ]]; then
    mkdir -p "${WWW_ROOT}"
  fi
}

prepare_symlink_conflicts() {
  local source_dir="$1"
  local target_dir="$2"
  local clean_mode="$3"
  local excludes_var="$4"
  local -n excludes_ref="${excludes_var}"

  local -a symlink_paths=()
  mapfile -d '' -t symlink_paths < <(find "${source_dir}" -type l -print0 2>/dev/null || true)
  local conflict
  for conflict in "${symlink_paths[@]}"; do
    local rel_path="${conflict#${source_dir}/}"
    if [[ -z "${rel_path}" ]]; then
      continue
    fi

    local target_path="${target_dir}/${rel_path}"
    if [[ -e "${target_path}" && ! -L "${target_path}" ]]; then
      if [[ "${clean_mode}" -eq 1 ]]; then
        warn "Eliminando '${target_path}' para permitir crear el enlace simbolico desde la fuente."
        rm -rf -- "${target_path}"
      else
        warn "Omitiendo '${rel_path}' porque existe como directorio en el destino y la fuente usa un enlace simbolico. Ejecuta con INSTALL_WEB_CLEAN_TARGET=1 para reemplazarlo."
        excludes_ref+=("--exclude=${rel_path}")
      fi
    fi
  done
}

synchronize_web_files() {
  local source_dir="$1"
  local target_dir="$2"
  local clean_mode="${INSTALL_WEB_CLEAN_TARGET:-0}"

  log "Copiando archivos hacia ${target_dir}..."
  mkdir -p "${target_dir}"
  if command -v rsync >/dev/null 2>&1; then
    local -a rsync_args=(-a)
    local -a rsync_excludes=()
    if [[ "${clean_mode}" -eq 1 ]]; then
      rsync_args+=(--delete)
    fi
    prepare_symlink_conflicts "${source_dir}" "${target_dir}" "${clean_mode}" rsync_excludes
    if (( ${#rsync_excludes[@]} )); then
      rsync_args+=("${rsync_excludes[@]}")
    fi
    set +e
    rsync "${rsync_args[@]}" "${source_dir}/" "${target_dir}/"
    local rsync_status=$?
    set -e
    if [[ "${rsync_status}" -ne 0 ]]; then
      error "rsync fallo con codigo ${rsync_status}. Intenta revisar permisos en ${source_dir} y ${target_dir} o usa INSTALL_WEB_CLEAN_TARGET=1."
      exit "${rsync_status}"
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
  if [[ "${SKIP_DEPLOY_PERMS}" -eq 1 ]]; then
    log "Omitiendo ajustes de permisos en ${target_dir} (INSTALL_WEB_SKIP_DEPLOY_PERMS=1)."
    return
  fi
  local mode="${INSTALL_WEB_PERMISSIONS_MODE:-${DEFAULT_PERMISSIONS_MODE}}"

  if [[ "${mode}" == "acl" ]]; then
    apply_permissions_acl "${target_dir}"
  else
    apply_permissions_basic "${target_dir}"
  fi
}

ensure_user_in_www_data() {
  if [[ "${SKIP_GROUP_ASSIGN}" -eq 1 ]]; then
    log "Omitiendo incorporacion al grupo www-data (INSTALL_WEB_SKIP_GROUP_ASSIGN=1)."
    return
  fi
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
  determine_sources_base
  mkdir -p "${SOURCE_BASE}"
  log "Repositorio fuente alojado en ${SOURCE_BASE}"

  SELECTED_REPO=""
  prompt_repo_choice
  if [[ -z "${SELECTED_REPO}" ]]; then
    error "No se selecciono ninguna opcion valida."
    exit 1
  fi

  IFS='|' read -r repo_name visibility label display_name <<<"${SELECTED_REPO}"
  local friendly="${display_name:-${repo_name}}"
  log "Opcion seleccionada: ${friendly}"

  CLONED_REPO_PATH=""
  clone_repo "${repo_name}" "${visibility}" "${label}" "${friendly}"
  local checkout_dir="${CLONED_REPO_PATH}"
  if [[ -z "${checkout_dir}" ]]; then
    error "No se pudo determinar la ruta del repositorio clonado."
    exit 1
  fi

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
