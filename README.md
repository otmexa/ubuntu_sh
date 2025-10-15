# ubuntu_sh

Coleccion de scripts para provisionar un escritorio Ubuntu con XFCE, XRDP y ajustes personalizados.

## Orden de ejecucion recomendado

1. **Preparar el entorno y lanzar el administrador**  
   Clona el repositorio (es publico, no requiere credenciales) y ejecuta el manejador:
   ```bash
   sudo apt-get update
   sudo apt-get install -y git
   git clone https://github.com/otmexa/ubuntu_sh.git
   cd ubuntu_sh
   sudo bash manage_scripts.sh
   ```  
   El menu mostrara los scripts disponibles; selecciona primero `setup_desktop.sh`. Si termina bien se marcara con `*` cuando vuelvas a abrir el administrador.

2. **Configurar XFCE**  
   Con el administrador abierto selecciona `configure_xfce.sh` (opcion 2) para aplicar la personalizacion del entorno, cargar los paneles predefinidos y dejar listo el escritorio para el usuario objetivo.

3. **Configurar el core del stack**  
   Ejecuta `setup_core.sh` (opcion 3) para:
   - Actualizar el sistema (`apt update && apt upgrade`).
   - Instalar, habilitar y verificar Nginx.
   - Instalar MariaDB, habilitar el servicio y aplicar endurecimiento equivalente a `mysql_secure_installation`.
   - Solicitar el usuario de referencia y la password que tambien se asignara al usuario `root` de MariaDB. Puedes precargar los valores via variables de entorno (`CORE_MARIADB_USER` y `CORE_MARIADB_PASSWORD`) si quieres automatizarlo.
   - Crear o actualizar el usuario indicado con privilegios globales (`GRANT ALL ... WITH GRANT OPTION`) reutilizando la misma password.
   - Limpiar versiones previas de PHP, agregar el PPA de Ondrej e instalar PHP 8.2 con FPM y modulos comunes, asegurando que el servicio quede activo. Tambien purga Apache si estuviera presente.
   - Solicitar el alias publico para phpMyAdmin (personalizable via `CORE_PHPMYADMIN_ALIAS`), reiniciar `/var/www/html`, descargar phpMyAdmin 5.2.1, generar `blowfish_secret` y dejarlo listo en `/var/www/html/<alias>` con los permisos correctos. Puedes renombrar la carpeta luego para ofuscar la ruta.
   - Preguntar por el dominio (puede quedar vacio para usar solo IP) y escribir `/etc/nginx/conf.d/default.conf` con la configuracion propuesta, validando y recargando Nginx automaticamente.
   - Garantizar que UFW quede instalado, habilitado y con los puertos requeridos abiertos (`22`, `80`, `443`, `3389`, `3800`, `7171`, `7172`, `8245`). Puedes añadir otros via `CORE_FIREWALL_EXTRA_PORTS` (lista separada por comas).
   - Registrar el avance en `setup_core.log`, marcando cada paso completado o fallido para diagnosticar problemas.

4. **Instalar la web (MyAAC)**  
   Ejecuta `install_web.sh` (opcion 4) para:
   - Elegir entre la version publica (`zimbadev/crystalserver-myacc`) o la privada (`otmexa/myaac_noxusot`). Si seleccionas la privada, el script verificara/instalara `gh`, intentara abrir `https://github.com/login/device` en tu sesion y lanzara `gh auth login`. Si aun asi falla la autenticacion, ejecuta manualmente `gh auth login --hostname github.com --scopes repo` y vuelve a correr la opcion.
   - Clonar la web en `~/.cache/ubuntu_sh/web_sources/<repo>` (cambia la ruta con `INSTALL_WEB_SOURCE_DIR`) y sincronizarla hacia `/var/www/html/`. Usa `INSTALL_WEB_CLEAN_TARGET=1` si quieres que se eliminen archivos previos del destino.
   - Ajustar permisos: por defecto deja la carpeta bajo `www-data:www-data`, aplica ACL (si hay `setfacl`) y abre los directorios que requieren escritura (`outfits`, `system`, `images`, `plugins`, `tools`, `cache`). Puedes omitir estos ajustes con `INSTALL_WEB_SKIP_DEPLOY_PERMS=1`.
   - Agregar automaticamente al usuario que lanzo el script (`benny`, etc.) al grupo `www-data` (omite este paso con `INSTALL_WEB_SKIP_GROUP_ASSIGN=1`). Deberas cerrar y reabrir sesion para que surta efecto.
   - Registrar el proceso en `install_web.log`.

5. **Actualizar el repositorio (opcional)**  
   Ejecuta `update_repo.sh` (opcion 5) cuando quieras sincronizar esta copia local con el origen (`git pull`). El comando se omitira si detecta cambios locales pendientes o si no hay remoto configurado.

6. **Revisar registros**  
   - `script_runs.log`: historial de scripts ejecutados y su resultado.
   - `setup_desktop.log`: credenciales en texto plano. Eliminalo cuando ya no lo necesites.
   - `setup_core.state`: estado de cada paso del core para reanudar sin repetir etapas. Bórralo (o ejecuta con `SETUP_CORE_RESET_STATE=1`) si quieres forzar que todos los pasos vuelvan a correr.

## Resetear la copia local

Si quieres limpiar la VPS y volver al estado original del repositorio:

```bash
cd ~
sudo rm -rf ubuntu_sh
git clone https://github.com/otmexa/ubuntu_sh.git
cd ubuntu_sh
```

Esto descarta cambios locales (incluidos los logs) y deja el directorio igual que en GitHub. Ejecuta de nuevo `sudo bash manage_scripts.sh` para recrear los registros.
