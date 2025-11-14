#!/usr/bin/env bash
set -euo pipefail

umask 077

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_LOG="${REPO_DIR}/script_runs.log"
SETUP_LOG="${REPO_DIR}/setup_desktop.log"

LOG_OWNER="${MANAGER_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${MANAGER_LOG_GROUP:-}"

if [[ -z "${LOG_GROUP}" ]]; then
  if id -gn "${LOG_OWNER}" >/dev/null 2>&1; then
    LOG_GROUP="$(id -gn "${LOG_OWNER}")"
  else
    LOG_GROUP="${LOG_OWNER}"
  fi
fi

declare -a SCRIPTS=(
  "setup_desktop.sh:Provisiona escritorio base (usuario, paquetes, XRDP)"
  "configure_xfce.sh:Personaliza XFCE y carga paneles"
  "setup_core.sh:Actualiza el sistema e instala Nginx"
  "install_web.sh:Despliega MyAAC en Nginx"
  "reinstall_phpmyadmin.sh:Reinstala solo phpMyAdmin en /var/www/html"
  "install_server.sh:Compila Crystal Server (vcpkg)"
  "reapply_crystal_perms.sh:Reaplica permisos de Crystal Server"
  "update_repo.sh:Actualiza este repositorio (git pull)"
  "reboot:Reinicia el servidor tras aplicar los scripts"
)

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
}

record_status() {
  local script="$1"
  local status="$2"
  local duration="$3"
  printf '%s|%s|%s|%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${script}" "${status}" "${duration}" >> "${STATUS_LOG}"
}

get_last_status() {
  local script="$1"
  if [[ ! -f "${STATUS_LOG}" ]]; then
    return 1
  fi

  awk -F'|' -v target="${script}" '$2 == target { status = $3 } END { if (length(status)) print status }' "${STATUS_LOG}"
}

get_last_setup_username() {
  if [[ ! -f "${SETUP_LOG}" ]]; then
    return 1
  fi

  local username
  username="$(awk -F': ' '/^Username: /{ user = $2 } END { if (length(user)) print user }' "${SETUP_LOG}")"
  if [[ -n "${username}" ]]; then
    printf '%s\n' "${username}"
    return 0
  fi

  return 1
}

prompt_target_user() {
  local suggested=""
  suggested="$(get_last_setup_username || true)"

  if [[ -n "${suggested}" ]]; then
    log "Usando usuario ${suggested} detectado en setup_desktop.log." >&2
    printf '%s\n' "${suggested}"
    return 0
  fi

  local input=""
  read -r -p "Usuario destino para configure_xfce.sh: " input
  if [[ -z "${input}" ]]; then
    warn "No se proporciono usuario destino."
    return 1
  fi

  printf '%s\n' "${input}"
  return 0
}

display_menu() {
  printf '\nSelecciona el script a ejecutar:\n'
  local index=1
  local entry script desc status marker display_name
  for entry in "${SCRIPTS[@]}"; do
    IFS=':' read -r script desc <<<"${entry}"
    status="$(get_last_status "${script}" || true)"
    marker=""
    if [[ "${status}" == "success" ]]; then
      marker="*"
    fi
    display_name="${marker}${script}"
    printf ' %d) %s - %s\n' "${index}" "${display_name}" "${desc}"
    ((index++))
  done
  printf ' q) Salir\n'
  printf 'Opcion: '
}

run_script() {
  local script="$1"
  local script_path="${REPO_DIR}/${script}"
  local log_hint=""

  if [[ ! -f "${script_path}" ]]; then
    error "El script ${script} no se encontro."
    return 1
  fi

  local target_user=""
  if [[ "${script}" == "configure_xfce.sh" ]]; then
    target_user="$(prompt_target_user)" || return 1
    log "Ejecutando ${script} para el usuario ${target_user}..."
  else
    log "Ejecutando ${script}..."
  fi

  case "${script}" in
    setup_desktop.sh)
      export SETUP_DESKTOP_LOG_FILE="${REPO_DIR}/setup_desktop.log"
      log_hint="${SETUP_DESKTOP_LOG_FILE}"
      ;;
    setup_core.sh)
      export SETUP_CORE_LOG_FILE="${REPO_DIR}/setup_core.log"
      log_hint="${SETUP_CORE_LOG_FILE}"
      ;;
    install_web.sh)
      export INSTALL_WEB_LOG_FILE="${REPO_DIR}/install_web.log"
      log_hint="${INSTALL_WEB_LOG_FILE}"
      ;;
    reinstall_phpmyadmin.sh)
      export REINSTALL_PHPMYADMIN_LOG_FILE="${REPO_DIR}/reinstall_phpmyadmin.log"
      log_hint="${REINSTALL_PHPMYADMIN_LOG_FILE}"
      ;;
    install_server.sh)
      export INSTALL_SERVER_LOG_FILE="${REPO_DIR}/install_server.log"
      log_hint="${INSTALL_SERVER_LOG_FILE}"
      ;;
    reapply_crystal_perms.sh)
      export REAPPLY_CRYSTAL_PERMS_LOG_FILE="${REPO_DIR}/reapply_crystal_perms.log"
      log_hint="${REAPPLY_CRYSTAL_PERMS_LOG_FILE}"
      ;;
    update_repo.sh)
      export UPDATE_REPO_LOG_FILE="${REPO_DIR}/update_repo.log"
      log_hint="${UPDATE_REPO_LOG_FILE}"
      ;;
  esac

  local start end
  start=$(date +%s)

  local exit_code=0
  if [[ "${script}" == "configure_xfce.sh" ]]; then
    if TARGET_USER="${target_user}" bash "${script_path}"; then
      exit_code=0
    else
      exit_code=$?
    fi
  else
    if bash "${script_path}"; then
      exit_code=0
    else
      exit_code=$?
    fi
  fi

  end=$(date +%s)

  if [[ "${exit_code}" -eq 0 ]]; then
    record_status "${script}" "success" "$((end - start))"
    log "Script ${script} finalizado correctamente."
    return 0
  fi

  record_status "${script}" "failed" "$((end - start))"
  error "Script ${script} termino con errores."
  if [[ -n "${log_hint}" ]]; then
    if [[ -r "${log_hint}" ]]; then
      error "Ultimas 20 lineas de ${log_hint}:"
      if ! tail -n 20 "${log_hint}" 2>/dev/null | sed 's/^/[LOG] /'; then
        warn "No se pudo leer ${log_hint} pese a existir."
      fi
    else
      warn "No se encontro log para ${script} en ${log_hint}."
    fi
  fi
  return "${exit_code}"
}

ask_continue() {
  local choice
  read -r -p "Deseas ejecutar otro script? [y/N]: " choice
  case "${choice}" in
    [Yy]*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "Ejecuta este administrador como root para evitar fallos en los scripts gestionados."
    exit 1
  fi

  touch "${STATUS_LOG}"
  chmod 640 "${STATUS_LOG}"
  if ! chown "${LOG_OWNER}:${LOG_GROUP}" "${STATUS_LOG}" 2>/dev/null; then
    warn "No se pudo asignar propietario ${LOG_OWNER}:${LOG_GROUP} a ${STATUS_LOG}; se mantienen los permisos actuales."
  fi

  while true; do
    display_menu
    read -r selection

    case "${selection}" in
      q|Q)
        log "Saliendo del administrador."
        break
        ;;
      '')
        continue
        ;;
      *)
        if [[ "${selection}" =~ ^[0-9]+$ ]]; then
          local idx=$((selection - 1))
          local total=${#SCRIPTS[@]}
          if (( idx >= 0 && idx < total )); then
            IFS=':' read -r script desc <<<"${SCRIPTS[${idx}]}"
            if [[ "${script}" == "reboot" ]]; then
              log "Reiniciando el sistema..."
              reboot
              break
            else
              run_script "${script}"
            fi
            if ask_continue; then
              continue
            else
              log "Saliendo del administrador."
              break
            fi
          else
            warn "Opcion fuera de rango."
          fi
        else
          warn "Entrada no valida."
        fi
        ;;
    esac
  done
}

main "$@"
