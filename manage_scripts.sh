#!/usr/bin/env bash
set -euo pipefail

umask 077

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_LOG="${REPO_DIR}/script_runs.log"
SETUP_LOG="${REPO_DIR}/setup_desktop.log"

declare -a SCRIPTS=(
  "setup_desktop.sh:Provisiona escritorio base (usuario, paquetes, XRDP)"
  "configure_xfce.sh:Personaliza XFCE y carga paneles"
  "setup_core.sh:Actualiza el sistema e instala Nginx"
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

update_repo() {
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    warn "No se detecto repositorio Git; omito la actualizacion automatica."
    return
  fi

  if ! command -v git >/dev/null 2>&1; then
    warn "Git no esta instalado; omito la actualizacion automatica."
    return
  fi

  if [[ -n "$(git -C "${REPO_DIR}" status --porcelain)" ]]; then
    warn "Hay cambios locales pendientes; omito 'git pull' para no sobrescribirlos."
    return
  fi

  if [[ -z "$(git -C "${REPO_DIR}" remote)" ]]; then
    warn "El repositorio no tiene remotos configurados; omito 'git pull'."
    return
  fi

  log "Actualizando repositorio con 'git pull --ff-only'..."
  if ! git -C "${REPO_DIR}" fetch --all --prune; then
    warn "Fallo al ejecutar 'git fetch'. Revisa tu conexion o configuracion remota."
    return
  fi

  if ! git -C "${REPO_DIR}" pull --ff-only; then
    warn "Fallo al ejecutar 'git pull'. Revisa el estado del repositorio."
    return
  fi

  log "Repositorio actualizado correctamente."
}

make_scripts_executable() {
  local adjusted=0
  while IFS= read -r -d '' file; do
    chmod +x "${file}"
    adjusted=1
  done < <(find "${REPO_DIR}" -maxdepth 1 -type f -name '*.sh' ! -perm -111 -print0)

  if [[ "${adjusted}" -eq 1 ]]; then
    log "Se asignaron permisos de ejecucion a los scripts del proyecto."
  else
    log "Los scripts ya contaban con permisos de ejecucion."
  fi
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
  chmod 600 "${STATUS_LOG}"

  update_repo
  make_scripts_executable

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
