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

2. **Configurar el core del stack**  
   Ejecuta `setup_core.sh` desde el administrador para:
   - Actualizar el sistema (`apt update && apt upgrade`).
   - Instalar, habilitar y verificar Nginx.
   - Instalar MariaDB, habilitar el servicio y aplicar endurecimiento equivalente a `mysql_secure_installation`.
   - Solicitar el usuario de referencia y la password que tambien se asignara al usuario `root` de MariaDB. Puedes precargar los valores via variables de entorno (`CORE_MARIADB_USER` y `CORE_MARIADB_PASSWORD`) si quieres automatizarlo.
   - Crear o actualizar el usuario indicado con privilegios globales (`GRANT ALL ... WITH GRANT OPTION`) reutilizando la misma password.
   - Limpiar versiones previas de PHP, agregar el PPA de Ondrej e instalar PHP 8.2 con FPM y modulos comunes, asegurando que el servicio quede activo. Tambien purga Apache si estuviera presente.
   - Solicitar el alias publico para phpMyAdmin (personalizable via `CORE_PHPMYADMIN_ALIAS`), reiniciar `/var/www/html`, descargar phpMyAdmin 5.2.1, generar `blowfish_secret` y dejarlo listo en `/var/www/html/<alias>` con los permisos correctos. Puedes renombrar la carpeta luego para ofuscar la ruta.
   - Preguntar por el dominio (puede quedar vacio para usar solo IP) y escribir `/etc/nginx/conf.d/default.conf` con la configuracion propuesta, validando y recargando Nginx automaticamente.
   - Registrar el avance en `setup_core.log`, marcando cada paso completado o fallido para diagnosticar problemas.

3. **Configurar XFCE**  
   Desde el mismo administrador (opcion 2) ejecuta `configure_xfce.sh` para aplicar la personalizacion del entorno y los paneles empaquetados.

4. **Revisar registros**  
   - `script_runs.log`: historial de scripts ejecutados y su resultado.
   - `setup_desktop.log`: credenciales en texto plano. Eliminalo cuando ya no lo necesites.

## Resetear la copia local

Si quieres limpiar la VPS y volver al estado original del repositorio:

```bash
cd ~
sudo rm -rf ubuntu_sh
git clone https://github.com/otmexa/ubuntu_sh.git
cd ubuntu_sh
```

Esto descarta cambios locales (incluidos los logs) y deja el directorio igual que en GitHub. Ejecuta de nuevo `sudo bash manage_scripts.sh` para recrear los registros.
