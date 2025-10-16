#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/install_server.log"
LOG_FILE="${INSTALL_SERVER_LOG_FILE:-${LOG_FILE_DEFAULT}}"

LOG_OWNER="${INSTALL_SERVER_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${INSTALL_SERVER_LOG_GROUP:-}"

if [[ -z "${LOG_GROUP}" ]]; then
  if id -gn "${LOG_OWNER}" >/dev/null 2>&1; then
    LOG_GROUP="$(id -gn "${LOG_OWNER}")"
  else
    LOG_GROUP="${LOG_OWNER}"
  fi
fi

STATE_FILE_DEFAULT="${SCRIPT_DIR}/install_server.state"
STATE_FILE="${INSTALL_SERVER_STATE_FILE:-${STATE_FILE_DEFAULT}}"
STATE_RESET="${INSTALL_SERVER_RESET_STATE:-0}"
STATE_ENABLED=1
if [[ "${INSTALL_SERVER_DISABLE_STATE:-0}" -eq 1 ]]; then
  STATE_ENABLED=0
fi

STEP_ORDER=(
  "system_upgrade"
  "install_prerequisites"
  "update_cmake"
  "update_gcc"
  "setup_vcpkg"
  "prepare_crystal_repo"
  "apply_acl_permissions"
  "build_crystal_server"
  "publish_binary"
  "summary"
)

declare -A STEP_INDEX=()
declare -A STEP_DESCRIPTIONS=(
  ["system_upgrade"]="Actualizar paquetes del sistema"
  ["install_prerequisites"]="Instalar herramientas de compilacion"
  ["update_cmake"]="Actualizar CMake via snap"
  ["update_gcc"]="Configurar GCC actualizado"
  ["setup_vcpkg"]="Configurar vcpkg"
  ["prepare_crystal_repo"]="Clonar/actualizar Crystal Server"
  ["apply_acl_permissions"]="Aplicar ACL de www-data"
  ["build_crystal_server"]="Compilar Crystal Server (linux-release)"
  ["publish_binary"]="Publicar binario cristal"
  ["summary"]="Resumen final"
)

TOTAL_STEPS=${#STEP_ORDER[@]}
CURRENT_STEP_INDEX=0
CURRENT_STEP_NAME=""

declare -A STEP_STATUS=()

STATE_DATA_TARGET_USER=""
STATE_DATA_TARGET_HOME=""
STATE_DATA_GCC_VERSION=""

if [[ -n "${LOG_FILE}" ]]; then
  if ! touch "${LOG_FILE}" 2>/dev/null; then
    printf '[WARN] No se pudo inicializar el archivo de log en %s; logging deshabilitado.\n' "${LOG_FILE}" >&2
    LOG_FILE=""
  else
    chmod 640 "${LOG_FILE}"
    chown "${LOG_OWNER}:${LOG_GROUP}" "${LOG_FILE}" 2>/dev/null || true
  fi
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

GCC_VERSION="${INSTALL_SERVER_GCC_VERSION:-12}"
VCPKG_REPO_URL="https://github.com/microsoft/vcpkg"
CRYSTAL_REPO_URL="https://github.com/zimbadev/crystalserver.git"
RUN_AS_USER_OVERRIDE="${INSTALL_SERVER_TARGET_USER:-}"
VCPKG_DIR=""
CRYSTAL_DIR=""
TARGET_USER=""
TARGET_GROUP=""
TARGET_HOME=""

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

initialize_state_tracking() {
  local idx
  for idx in "${!STEP_ORDER[@]}"; do
    STEP_INDEX["${STEP_ORDER[$idx]}"]=$((idx + 1))
  done

  local step
  for step in "${STEP_ORDER[@]}"; do
    STEP_STATUS["${step}"]="pending"
  done

  if [[ "${STATE_ENABLED}" -ne 1 || -z "${STATE_FILE}" ]]; then
    STATE_ENABLED=0
    return
  fi

  if [[ "${STATE_RESET}" -eq 1 && -f "${STATE_FILE}" ]]; then
    rm -f "${STATE_FILE}"
    log "Estado previo reiniciado (INSTALL_SERVER_RESET_STATE=1)."
  fi

  if [[ ! -e "${STATE_FILE}" ]]; then
    return
  fi

  if [[ ! -r "${STATE_FILE}" ]]; then
    warn "No se puede leer ${STATE_FILE}; se deshabilita el modo de reanudacion."
    STATE_ENABLED=0
    return
  fi

  load_state
}

save_state() {
  if [[ "${STATE_ENABLED}" -ne 1 || -z "${STATE_FILE}" ]]; then
    return
  fi

  local tmp_file="${STATE_FILE}.tmp"
  if ! {
    printf '# install_server state (no editar manualmente)\n'
    printf 'version=1\n'
    printf 'data:target_user=%s\n' "${STATE_DATA_TARGET_USER}"
    printf 'data:target_home=%s\n' "${STATE_DATA_TARGET_HOME}"
    printf 'data:gcc_version=%s\n' "${STATE_DATA_GCC_VERSION}"
    local step
    for step in "${STEP_ORDER[@]}"; do
      printf 'step:%s=%s\n' "${step}" "${STEP_STATUS[${step}]}"
    done
  } > "${tmp_file}"; then
    warn "No se pudo escribir el archivo de estado ${tmp_file}; se deshabilita la persistencia."
    STATE_ENABLED=0
    return
  fi

  mv "${tmp_file}" "${STATE_FILE}"
  chmod 640 "${STATE_FILE}"
  if [[ -n "${LOG_OWNER}" ]]; then
    chown "${LOG_OWNER}:${LOG_GROUP:-${LOG_OWNER}}" "${STATE_FILE}" 2>/dev/null || true
  fi
}

load_state() {
  if [[ "${STATE_ENABLED}" -ne 1 || -z "${STATE_FILE}" || ! -r "${STATE_FILE}" ]]; then
    return
  fi

  local resumed=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    case "${key}" in
      step:*)
        local step="${key#step:}"
        if [[ -n "${STEP_INDEX[${step}]:-}" ]]; then
          case "${value}" in
            completed)
              STEP_STATUS["${step}"]="completed"
              resumed=1
              ;;
            in_progress)
              STEP_STATUS["${step}"]="failed"
              ;;
            failed)
              STEP_STATUS["${step}"]="failed"
              ;;
            pending|*)
              STEP_STATUS["${step}"]="pending"
              ;;
          esac
        fi
        ;;
      data:target_user)
        STATE_DATA_TARGET_USER="${value}"
        ;;
      data:target_home)
        STATE_DATA_TARGET_HOME="${value}"
        ;;
      data:gcc_version)
        STATE_DATA_GCC_VERSION="${value}"
        ;;
    esac
  done < "${STATE_FILE}"

  if [[ "${resumed}" -eq 1 ]]; then
    log "Estado previo detectado; se omitiran pasos ya completados."
  fi
}

on_unexpected_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  if [[ -n "${CURRENT_STEP_NAME}" && -n "${STEP_INDEX[${CURRENT_STEP_NAME}]:-}" ]]; then
    STEP_STATUS["${CURRENT_STEP_NAME}"]="failed"
    save_state
  fi
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
  if [[ -n "${RUN_AS_USER_OVERRIDE}" ]]; then
    candidate="${RUN_AS_USER_OVERRIDE}"
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

run_as_target() {
  local command="$1"
  if [[ "${TARGET_USER}" == "root" ]]; then
    bash -lc "${command}"
  else
    runuser -u "${TARGET_USER}" -- bash -lc "${command}"
  fi
}

step_description() {
  local step="$1"
  if [[ -n "${STEP_DESCRIPTIONS[${step}]:-}" ]]; then
    printf '%s' "${STEP_DESCRIPTIONS[${step}]}"
  else
    printf '%s' "${step}"
  fi
}

verify_state_target() {
  if [[ "${STATE_ENABLED}" -ne 1 ]]; then
    return
  fi
  if [[ -n "${STATE_DATA_TARGET_USER}" && "${STATE_DATA_TARGET_USER}" != "${TARGET_USER}" ]]; then
    error "El estado existente pertenece al usuario ${STATE_DATA_TARGET_USER}. Usa INSTALL_SERVER_RESET_STATE=1 o INSTALL_SERVER_TARGET_USER=${STATE_DATA_TARGET_USER}."
    exit 1
  fi
  if [[ -n "${STATE_DATA_TARGET_HOME}" && "${STATE_DATA_TARGET_HOME}" != "${TARGET_HOME}" ]]; then
    error "El estado existente se genero con HOME=${STATE_DATA_TARGET_HOME}. Usa INSTALL_SERVER_RESET_STATE=1 para reiniciar."
    exit 1
  fi
  if [[ -n "${STATE_DATA_GCC_VERSION}" && "${STATE_DATA_GCC_VERSION}" != "${GCC_VERSION}" ]]; then
    warn "Reanudando con GCC ${GCC_VERSION}, diferente al usado anteriormente (${STATE_DATA_GCC_VERSION})."
  fi
}

run_step() {
  local step="$1"
  local func="$step"
  local status="${STEP_STATUS[${step}]:-pending}"
  local index="${STEP_INDEX[${step}]:-0}"
  local description
  description="$(step_description "${step}")"

  if [[ -z "${index}" || "${index}" -eq 0 ]]; then
    error "Paso desconocido: ${step}"
    exit 1
  fi

  if [[ "${status}" == "completed" ]]; then
    log "Paso ${index}/${TOTAL_STEPS} ya completado: ${description}. Se omite."
    return
  fi

  if ! declare -f "${func}" >/dev/null 2>&1; then
    error "No se encontro la funcion para el paso ${step}."
    exit 1
  fi

  log "Paso ${index}/${TOTAL_STEPS}: ${description}"
  CURRENT_STEP_NAME="${step}"
  STEP_STATUS["${step}"]="in_progress"
  save_state

  if "${func}"; then
    STEP_STATUS["${step}"]="completed"
    CURRENT_STEP_NAME=""
    save_state
    log "Paso ${index}/${TOTAL_STEPS} completado."
  else
    local exit_code=$?
    STEP_STATUS["${step}"]="failed"
    CURRENT_STEP_NAME=""
    save_state
    error "Paso ${description} fallo con codigo ${exit_code}."
    exit "${exit_code}"
  fi
}

system_upgrade() {
  log "Actualizando paquetes del sistema..."
  apt-get update >/dev/null
  apt-get dist-upgrade -y
}

install_prerequisites() {
  log "Instalando dependencias base (compilador, herramientas de build)..."
  local kernel_headers="linux-headers-$(uname -r)"
  local -a packages=(
    git
    cmake
    build-essential
    autoconf
    libtool
    ca-certificates
    curl
    zip
    unzip
    tar
    pkg-config
    ninja-build
    ccache
    "${kernel_headers}"
  )
  apt-get install -y "${packages[@]}"
}

update_cmake() {
  log "Instalando CMake desde snap..."
  if dpkg-query -W -f='${Status}' cmake 2>/dev/null | grep -q "install ok installed"; then
    apt-get remove --purge -y cmake
  fi
  hash -r 2>/dev/null || true
  apt-get install -y snapd
  if snap list cmake >/dev/null 2>&1; then
    snap refresh cmake
  else
    snap install cmake --classic
  fi
  cmake --version
}

update_gcc() {
  log "Instalando GCC ${GCC_VERSION}..."
  apt-get update >/dev/null
  apt-get install -y "gcc-${GCC_VERSION}" "g++-${GCC_VERSION}"
  update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-${GCC_VERSION}" 100 \
    --slave /usr/bin/g++ g++ "/usr/bin/g++-${GCC_VERSION}" \
    --slave /usr/bin/gcov gcov "/usr/bin/gcov-${GCC_VERSION}"
  update-alternatives --set gcc "/usr/bin/gcc-${GCC_VERSION}"
  gcc-"${GCC_VERSION}" --version
  g++-"${GCC_VERSION}" --version
}

setup_vcpkg() {
  log "Configurando vcpkg para ${TARGET_USER}..."
  apt-get install -y acl
  if [[ -z "${VCPKG_DIR}" ]]; then
    error "VCPKG_DIR no esta definido."
    exit 1
  fi

  local force_vcpkg="${INSTALL_SERVER_FORCE_VCPKG:-0}"
  if [[ "${force_vcpkg}" -ne 1 && -x "${VCPKG_DIR}/vcpkg" && -d "${VCPKG_DIR}/.git" ]]; then
    log "vcpkg ya se encuentra instalado en ${VCPKG_DIR}; se omite la reinstalacion. Usa INSTALL_SERVER_FORCE_VCPKG=1 para forzar."
    return 0
  fi

  if [[ -d "${VCPKG_DIR}/.git" ]]; then
    log "Actualizando repositorio existente de vcpkg..."
    if ! run_as_target "cd '${VCPKG_DIR}' && git pull --ff-only"; then
      warn "No se pudo actualizar vcpkg (git pull). Se continuara con la version existente."
    fi
  else
    if [[ -d "${VCPKG_DIR}" ]]; then
      local backup="${VCPKG_DIR}.backup.$(date +%s)"
      warn "El directorio ${VCPKG_DIR} existe pero no contiene vcpkg; se renombra a ${backup}."
      mv "${VCPKG_DIR}" "${backup}"
      chown -R "${TARGET_USER}:${TARGET_GROUP}" "${backup}" || true
    fi
    run_as_target "git clone '${VCPKG_REPO_URL}' '${VCPKG_DIR}'"
  fi
  run_as_target "cd '${VCPKG_DIR}' && ./bootstrap-vcpkg.sh"
  run_as_target "cd '${VCPKG_DIR}' && ./vcpkg install --triplet x64-linux-release"
}

prepare_crystal_repo() {
  log "Preparando Crystal Server en el home de ${TARGET_USER}..."
  if [[ -z "${CRYSTAL_DIR}" ]]; then
    error "CRYSTAL_DIR no esta definido."
    exit 1
  fi
  if [[ -d "${CRYSTAL_DIR}/.git" ]]; then
    log "Actualizando repositorio existente de Crystal Server..."
    run_as_target "cd '${CRYSTAL_DIR}' && git pull --ff-only"
  elif [[ -d "${CRYSTAL_DIR}" ]]; then
    warn "El directorio ${CRYSTAL_DIR} existe pero no es un repositorio Git; se renombra a crystalserver.backup.$(date +%s)."
    local backup="${CRYSTAL_DIR}.backup.$(date +%s)"
    mv "${CRYSTAL_DIR}" "${backup}"
    chown -R "${TARGET_USER}:${TARGET_GROUP}" "${backup}" || true
    run_as_target "git clone --depth 1 '${CRYSTAL_REPO_URL}' '${CRYSTAL_DIR}'"
  else
    run_as_target "git clone --depth 1 '${CRYSTAL_REPO_URL}' '${CRYSTAL_DIR}'"
  fi

  run_as_target "cd '${CRYSTAL_DIR}' && if [[ ! -f config.lua && -f config.lua.dist ]]; then cp config.lua.dist config.lua; fi"
  chmod -R 775 "${CRYSTAL_DIR}"
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "${CRYSTAL_DIR}"
}

apply_acl_permissions() {
  if ! command -v setfacl >/dev/null 2>&1; then
    warn "setfacl no esta disponible; omitiendo configuracion ACL para www-data."
    return
  fi

  if [[ -z "${TARGET_HOME}" || -z "${CRYSTAL_DIR}" ]]; then
    error "Variables TARGET_HOME o CRYSTAL_DIR no definidas para aplicar ACL."
    exit 1
  fi

  log "Asignando permisos de lectura para www-data en el home de ${TARGET_USER}..."
  setfacl -R -m g:www-data:rx "${TARGET_HOME}"
  setfacl -R -m g:www-data:rx "${CRYSTAL_DIR}"
}

build_crystal_server() {
  log "Generando build linux-release de Crystal Server..."
  if [[ -z "${CRYSTAL_DIR}" || -z "${VCPKG_DIR}" ]]; then
    error "CRYSTAL_DIR o VCPKG_DIR no estan definidos."
    exit 1
  fi
  local env_prefix="VCPKG_ROOT='${VCPKG_DIR}'"
  run_as_target "cd '${CRYSTAL_DIR}' && mkdir -p build"
  run_as_target "cd '${CRYSTAL_DIR}' && ${env_prefix} cmake --preset linux-release"
  run_as_target "cd '${CRYSTAL_DIR}' && ${env_prefix} cmake --build --preset linux-release"
}

publish_binary() {
  if [[ -z "${CRYSTAL_DIR}" ]]; then
    error "CRYSTAL_DIR no esta definido."
    exit 1
  fi
  local binary_src="${CRYSTAL_DIR}/build/linux-release/bin/crystalserver"
  local binary_dst="${CRYSTAL_DIR}/crystalserver"
  if [[ ! -f "${binary_src}" ]]; then
    warn "No se encontro el binario ${binary_src}; verifica la compilacion."
    return
  fi

  log "Copiando binario compilado a ${binary_dst}..."
  cp -f "${binary_src}" "${binary_dst}"
  chown "${TARGET_USER}:${TARGET_GROUP}" "${binary_dst}"
  chmod +x "${binary_dst}"
}

summary() {
  local final_vcpkg="${VCPKG_DIR:-${TARGET_HOME}/vcpkg}"
  local final_crystal="${CRYSTAL_DIR:-${TARGET_HOME}/crystalserver}"

  log "Instalacion completada."
  log "vcpkg instalado en ${final_vcpkg}"
  log "Crystal Server disponible en ${final_crystal}"
  log "Presets de build generados en ${final_crystal}/build/linux-release"
}

main() {
  ensure_root
  initialize_state_tracking
  determine_target_user
  verify_state_target

  VCPKG_DIR="${TARGET_HOME}/vcpkg"
  CRYSTAL_DIR="${TARGET_HOME}/crystalserver"

  STATE_DATA_TARGET_USER="${TARGET_USER}"
  STATE_DATA_TARGET_HOME="${TARGET_HOME}"
  STATE_DATA_GCC_VERSION="${GCC_VERSION}"
  save_state

  log "Ejecutando instalacion para el usuario ${TARGET_USER} (home: ${TARGET_HOME})."

  local step
  for step in "${STEP_ORDER[@]}"; do
    run_step "${step}"
  done
}

main "$@"
