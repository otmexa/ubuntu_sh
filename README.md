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
   Desde el mismo administrador (opcion 2) ejecuta `configure_xfce.sh` para aplicar la personalizacion del entorno y los paneles empaquetados.

3. **Revisar registros**  
   - `script_runs.log`: historial de scripts ejecutados y su resultado.
   - `setup_desktop.log`: credenciales en texto plano. Eliminalo cuando ya no lo necesites.
