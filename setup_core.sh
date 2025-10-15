#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE_DEFAULT="${SCRIPT_DIR}/setup_core.log"
LOG_FILE="${SETUP_CORE_LOG_FILE:-${LOG_FILE_DEFAULT}}"
TOTAL_STEPS=6
CURRENT_STEP=0

LOG_OWNER="${SETUP_CORE_LOG_OWNER:-${SUDO_USER:-root}}"
LOG_GROUP="${SETUP_CORE_LOG_GROUP:-}"

if [[ -z "${LOG_GROUP}" ]]; then
  if id -gn "${LOG_OWNER}" >/dev/null 2>&1; then
    LOG_GROUP="$(id -gn "${LOG_OWNER}")"
  else
    LOG_GROUP="${LOG_OWNER}"
  fi
fi

if [[ -n "${LOG_FILE}" ]]; then
  if ! touch "${LOG_FILE}" 2>/dev/null; then
    printf '[WARN] No se pudo inicializar el archivo de log en %s; continuando sin log persistente.\n' "${LOG_FILE}" >&2
    LOG_FILE=""
  else
    chmod 640 "${LOG_FILE}"
    chown "${LOG_OWNER}:${LOG_GROUP}" "${LOG_FILE}" 2>/dev/null || printf '[WARN] No se pudo ajustar propietario de %s a %s:%s; continuando con permisos actuales.\n' "${LOG_FILE}" "${LOG_OWNER}" "${LOG_GROUP}" >&2
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

run_step() {
  local description="$1"
  shift || true
  local fn="$1"
  shift || true

  if [[ -z "${fn}" ]]; then
    error "No se proporciono funcion para ejecutar en el paso: ${description}."
    exit 1
  fi

  ((CURRENT_STEP++))
  log "----- Paso ${CURRENT_STEP}/${TOTAL_STEPS}: ${description} (iniciando)"

  set +e
  "${fn}" "$@"
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    log "----- Paso ${CURRENT_STEP}/${TOTAL_STEPS}: ${description} (completado)"
    return 0
  fi

  error "----- Paso ${CURRENT_STEP}/${TOTAL_STEPS}: ${description} (fallo)"
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  error "Ejecuta este script como root (usa sudo)."
  exit 1
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

MARIADB_APP_USER=""
MARIADB_APP_PASSWORD=""
MARIADB_ROOT_PASSWORD=""
PHPMYADMIN_ALIAS=""
PHPMYADMIN_PATH=""
NGINX_SERVER_NAME="_"
NGINX_IS_DEFAULT=1

escape_sql_string() {
  printf '%s' "$1" | sed "s/'/''/g"
}

update_system() {
  log "Actualizando indices de APT..."
  apt-get update

  log "Aplicando actualizaciones del sistema..."
  apt-get upgrade -y
}

install_helper_tools() {
  log "Instalando utilidades basicas (nano)..."
  apt-get install -y nano
}

purge_existing_php() {
  log "Buscando instalaciones previas de PHP..."
  local packages=()
  local package_list=""

  # dpkg -l devuelve estado distinto de cero cuando no hay coincidencias; se ignora para evitar detener el script
  package_list="$(dpkg -l 'php*' 2>/dev/null || true)"

  if [[ -n "${package_list}" ]]; then
    while IFS= read -r pkg; do
      if [[ -n "${pkg}" ]]; then
        packages+=("${pkg}")
      fi
    done < <(printf '%s\n' "${package_list}" | awk '/^ii/ { print $2 }')
  fi

  if (( ${#packages[@]} )); then
    log "Eliminando paquetes PHP existentes..."
    if ! apt-get remove -y "${packages[@]}"; then
      warn "Fallo al remover algunos paquetes PHP; verifica manualmente si persisten."
    fi
  else
    log "No se detectaron paquetes PHP instalados previamente."
  fi
}

install_nginx() {
  log "Instalando Nginx..."
  apt-get install -y nginx
}

enable_and_check_nginx() {
  log "Habilitando Nginx para iniciar automaticamente..."
  systemctl enable nginx

  log "Iniciando Nginx..."
  systemctl start nginx

  if systemctl is-active --quiet nginx; then
    log "Nginx esta en ejecucion. Mostrando estado:"
    systemctl status --no-pager nginx || true
  else
    systemctl status --no-pager nginx || true
    error "Nginx no pudo iniciar correctamente."
    exit 1
  fi
}

install_mariadb() {
  log "Instalando MariaDB server y client..."
  apt-get install -y mariadb-server mariadb-client
}

enable_and_check_mariadb() {
  log "Habilitando MariaDB para iniciar automaticamente..."
  systemctl enable mariadb

  log "Iniciando MariaDB..."
  systemctl start mariadb

  if systemctl is-active --quiet mariadb; then
    log "MariaDB esta en ejecucion. Mostrando estado:"
    systemctl status --no-pager mariadb || true
  else
    systemctl status --no-pager mariadb || true
    error "MariaDB no pudo iniciar correctamente."
    exit 1
  fi
}

prompt_mariadb_credentials() {
  local default_user="${CORE_MARIADB_USER:-app_user}"
  local user_input=""
  local password_input=""
  local password_confirm=""

  while :; do
    read -r -p "Usuario de MariaDB que se configurara (tambien se usara para futuros pasos) [${default_user}]: " user_input
    user_input="${user_input:-${default_user}}"
    if [[ "${user_input}" =~ ^[A-Za-z0-9_]+$ ]]; then
      MARIADB_APP_USER="${user_input}"
      break
    fi
    warn "El usuario solo puede contener letras, numeros y guion bajo."
  done

  if [[ -n "${CORE_MARIADB_PASSWORD:-}" ]]; then
    MARIADB_APP_PASSWORD="${CORE_MARIADB_PASSWORD}"
    log "Usando password de MariaDB proporcionada via CORE_MARIADB_PASSWORD."
  else
    while :; do
      read -rsp "Password para ${MARIADB_APP_USER} (tambien se asignara a root): " password_input
      printf '\n'
      if [[ -z "${password_input}" ]]; then
        warn "La password no puede estar vacia."
        continue
      fi
      read -rsp "Confirma la password: " password_confirm
      printf '\n'
      if [[ "${password_input}" != "${password_confirm}" ]]; then
        warn "Las passwords no coinciden."
        continue
      fi
      MARIADB_APP_PASSWORD="${password_input}"
      break
    done
  fi

  MARIADB_ROOT_PASSWORD="${MARIADB_APP_PASSWORD}"
  log "La password capturada se aplicara tanto al usuario ${MARIADB_APP_USER} como a root."
}

run_mariadb_sql() {
  local client_args=(--batch --silent --raw)
  if mariadb --user root --password="${MARIADB_ROOT_PASSWORD}" --batch -e "SELECT 1" >/dev/null 2>&1; then
    client_args+=(--user root "--password=${MARIADB_ROOT_PASSWORD}")
  else
    client_args+=(--user root)
  fi
  mariadb "${client_args[@]}"
}

secure_mariadb() {
  log "Aplicando endurecimiento inicial de MariaDB (equivalente a mysql_secure_installation)..."
  local escaped_pass
  escaped_pass="$(escape_sql_string "${MARIADB_ROOT_PASSWORD}")"

  run_mariadb_sql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_pass}';
UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='root' AND Host='localhost';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

  log "Password configurada para root y eliminados usuarios/recursos inseguros."
}

create_mariadb_app_user() {
  log "Creando/actualizando usuario ${MARIADB_APP_USER} con privilegios globales..."
  local escaped_pass
  escaped_pass="$(escape_sql_string "${MARIADB_APP_PASSWORD}")"

  run_mariadb_sql <<SQL
CREATE USER IF NOT EXISTS '${MARIADB_APP_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${MARIADB_APP_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${MARIADB_APP_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  log "Usuario ${MARIADB_APP_USER} listo para administracion local."
}

test_mariadb_connection() {
  log "Probando autenticacion de MariaDB con la nueva password..."
  if mariadb --user root --password="${MARIADB_ROOT_PASSWORD}" --batch -e "SELECT VERSION();" >/dev/null 2>&1; then
    log "Conexion como root exitosa."
  else
    error "No se pudo autenticar en MariaDB con la password configurada."
    exit 1
  fi
}

test_app_user_connection() {
  log "Probando autenticacion con ${MARIADB_APP_USER}..."
  if mariadb --user "${MARIADB_APP_USER}" --password="${MARIADB_APP_PASSWORD}" --batch -e "SELECT VERSION();" >/dev/null 2>&1; then
    log "Conexion como ${MARIADB_APP_USER} exitosa."
  else
    error "No se pudo autenticar en MariaDB como ${MARIADB_APP_USER}. Revisa la password."
    exit 1
  fi
}

prompt_phpmyadmin_alias() {
  local default_alias="${CORE_PHPMYADMIN_ALIAS:-phpmyadmin}"
  local input=""

  while :; do
    if [[ -n "${CORE_PHPMYADMIN_ALIAS:-}" ]]; then
      log "Usando alias de phpMyAdmin proporcionado via CORE_PHPMYADMIN_ALIAS."
      input="${CORE_PHPMYADMIN_ALIAS}"
    else
      read -r -p "Carpeta publica para phpMyAdmin [${default_alias}]: " input
      input="${input:-${default_alias}}"
    fi

    input="${input#/}"
    input="${input%/}"

    if [[ -z "${input}" ]]; then
      warn "La carpeta no puede quedar vacia."
      if [[ -n "${CORE_PHPMYADMIN_ALIAS:-}" ]]; then
        error "Valor de CORE_PHPMYADMIN_ALIAS invalido."
        exit 1
      fi
      continue
    fi

    if [[ ! "${input}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "Solo se permiten letras, numeros, guion y guion bajo."
      if [[ -n "${CORE_PHPMYADMIN_ALIAS:-}" ]]; then
        error "Valor de CORE_PHPMYADMIN_ALIAS invalido."
        exit 1
      fi
      continue
    fi

    PHPMYADMIN_ALIAS="${input}"
    PHPMYADMIN_PATH="/var/www/html/${PHPMYADMIN_ALIAS}"
    log "phpMyAdmin se desplegara en ${PHPMYADMIN_PATH} (URL: /${PHPMYADMIN_ALIAS})."
    break
  done
}

prepare_web_root() {
  log "Reiniciando estructura de /var/www/html..."
  if [[ -d /var/www/html ]]; then
    rm -rf /var/www/html
  fi
  mkdir -p /var/www/html
  chown www-data:www-data /var/www/html
  chmod 755 /var/www/html
}

install_phpmyadmin() {
  log "Desplegando phpMyAdmin 5.2.1..."
  apt-get install -y wget unzip openssl

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  local archive="${tmp_dir}/phpmyadmin.zip"
  wget -qO "${archive}" "https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip"

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

  log "phpMyAdmin disponible en /${PHPMYADMIN_ALIAS}."
}

create_default_index() {
  local index_file="/var/www/html/index.php"
  if [[ -f "${index_file}" ]]; then
    return
  fi

  cat <<PHP > "${index_file}"
<?php
http_response_code(200);
echo "Servidor listo. phpMyAdmin disponible en /${PHPMYADMIN_ALIAS}";
PHP

  chown www-data:www-data "${index_file}"
  chmod 644 "${index_file}"
  log "Archivo index.php de bienvenida generado en /var/www/html."
}

prompt_nginx_server_name() {
  local input=""
  if [[ -n "${CORE_SERVER_NAME:-}" ]]; then
    input="${CORE_SERVER_NAME}"
    log "Usando server_name proporcionado via CORE_SERVER_NAME."
  else
    read -r -p "Dominio para Nginx (deja vacio para usar la IP): " input
  fi

  input="${input//[[:space:]]/}"

  if [[ -z "${input}" ]]; then
    NGINX_SERVER_NAME="_"
    NGINX_IS_DEFAULT=1
    log "Configurando Nginx como default_server, accesible por IP."
    return
  fi

  if [[ ! "${input}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    error "El dominio proporcionado contiene caracteres invalidos."
    exit 1
  fi

  NGINX_SERVER_NAME="${input}"
  NGINX_IS_DEFAULT=0
  log "Nginx se configurara para el dominio ${NGINX_SERVER_NAME}."
}

configure_nginx_server() {
  log "Aplicando configuracion personalizada de Nginx..."
  local conf_dir="/etc/nginx/conf.d"
  local conf_file="${conf_dir}/default.conf"

  mkdir -p "${conf_dir}"
  rm -f /etc/nginx/sites-enabled/default

  local listen_ipv4="listen 80;"
  local listen_ipv6="listen [::]:80;"
  if [[ "${NGINX_IS_DEFAULT}" -eq 1 ]]; then
    listen_ipv4="listen 80 default_server;"
    listen_ipv6="listen [::]:80 default_server;"
  fi

  cat <<EOF > "${conf_file}"
server {
    ${listen_ipv4}
    ${listen_ipv6}
    server_name ${NGINX_SERVER_NAME};

    root /var/www/html;
    index index.php;

    # Allow larger uploads
    client_max_body_size 10M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP execution
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 240;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Deny access to internal/system folders
    location ~ ^/(system|vendor|storage|tests|\.env) {
        deny all;
    }

    # Deny access to dotfiles and version control
    location ~* /\.(?:ht|git|svn|env)\$ {
        deny all;
    }

    # Deny access to backups, docs, dumps, etc.
    location ~* \.(?:md|json|dist|sql|bak|old|backup|tpl|twig|log)\$ {
        deny all;
    }

    # Additional security headers
    add_header X-Frame-Options        "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection       "1; mode=block";
}
EOF

  nginx -t
  systemctl reload nginx
  log "Configuracion de Nginx aplicada y servicio recargado."
}

install_php_dependencies() {
  log "Instalando dependencias previas para el PPA de PHP..."
  apt-get install -y python3-launchpadlib
  apt-get install -y software-properties-common apt-transport-https
}

add_php_repository() {
  log "Agregando PPA de Ondrej para PHP..."
  add-apt-repository -y ppa:ondrej/php
  log "Actualizando indices de APT tras agregar el PPA..."
  apt-get update
}

install_php_stack() {
  log "Instalando PHP 8.2 y modulos requeridos..."
  apt-get install -y php8.2 php8.2-cli php8.2-curl php8.2-fpm php8.2-gd php8.2-mysql php8.2-xml php8.2-zip php8.2-bcmath php8.2-mbstring php8.2-calendar

  local php_version_output=""
  if php_version_output="$(php8.2 -v 2>/dev/null | head -n1)"; then
    log "Version de PHP instalada: ${php_version_output}"
  else
    warn "No se pudo obtener la version de PHP 8.2."
  fi
}

configure_php_service() {
  log "Habilitando e iniciando php8.2-fpm..."
  systemctl enable --now php8.2-fpm
  systemctl status --no-pager php8.2-fpm || true

  if systemctl is-active --quiet php8.2-fpm; then
    log "php8.2-fpm esta activo."
  else
    error "php8.2-fpm no se encuentra activo."
    exit 1
  fi
}

remove_apache() {
  log "Eliminando Apache si estuviera instalado..."
  if dpkg -l | grep -E '^ii\s+apache2' >/dev/null 2>&1; then
    if ! apt-get purge -y 'apache2*'; then
      warn "Fallo al purgar paquetes de Apache; revisa manualmente."
    fi
  else
    log "No se detectaron paquetes de Apache instalados."
  fi

  apt-get autoremove -y

  if [[ -d /etc/apache2 ]]; then
    log "Eliminando directorio /etc/apache2..."
    rm -rf /etc/apache2
  fi
}

step_system_prepare() {
  update_system
  install_helper_tools
  purge_existing_php
}

step_nginx_setup() {
  install_nginx
  enable_and_check_nginx
  prompt_nginx_server_name
  configure_nginx_server
}

step_mariadb_setup() {
  install_mariadb
  enable_and_check_mariadb
  prompt_mariadb_credentials
  secure_mariadb
  test_mariadb_connection
  create_mariadb_app_user
  test_app_user_connection
}

step_php_setup() {
  install_php_dependencies
  add_php_repository
  install_php_stack
  configure_php_service
  remove_apache
}

step_phpmyadmin_setup() {
  prompt_phpmyadmin_alias
  prepare_web_root
  install_phpmyadmin
  create_default_index
}

step_summary() {
  print_summary
}

print_summary() {
  cat <<EOF

========================================
Setup core completado.
  - Sistema actualizado (apt update/upgrade)
  - Nginx instalado y habilitado
  - Nginx configurado con server_name ${NGINX_SERVER_NAME}
  - MariaDB instalado, asegurado y con password para root
  - Usuario de referencia para MariaDB: ${MARIADB_APP_USER}
  - Privilegios globales asignados a ${MARIADB_APP_USER}
  - PHP 8.2 instalado desde el PPA de Ondrej y listo con php-fpm
  - phpMyAdmin desplegado en /var/www/html/${PHPMYADMIN_ALIAS}
  - Registro del proceso: ${LOG_FILE:-no disponible}
========================================

Accede via: http://<tu-servidor>/${PHPMYADMIN_ALIAS}
Para restringir el acceso, renombra /var/www/html/${PHPMYADMIN_ALIAS} a un nombre secreto.

La password asignada a root es la misma que ingresaste para ${MARIADB_APP_USER}; guardala de forma segura.
Puedes verificar acceso ejecutando: sudo mariadb -u root -p
EOF
}

main() {
  run_step "Preparar sistema base" step_system_prepare
  run_step "Instalar y configurar Nginx" step_nginx_setup
  run_step "Instalar y configurar MariaDB" step_mariadb_setup
  run_step "Instalar y configurar PHP 8.2" step_php_setup
  run_step "Desplegar phpMyAdmin" step_phpmyadmin_setup
  run_step "Mostrar resumen final" step_summary
}

main "$@"
