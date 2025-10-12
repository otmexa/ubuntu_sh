# ubuntu_sh

Colección de scripts para provisionar un escritorio Ubuntu con XFCE, XRDP y ajustes personalizados.

## Orden de ejecución recomendado

1. **Administrador interactivo**  
   Ejecuta el manejador para sincronizar el repositorio, asegurar permisos y lanzar los scripts en orden:
   ```bash
   sudo bash manage_scripts.sh
   ```
   - El menú mostrará los scripts disponibles; elige primero `setup_desktop.sh`.
   - Si termina bien se marcará con `*` en ejecuciones posteriores.

2. **Configurar XFCE**  
   Desde el mismo manejador (opción 2) ejecuta `configure_xfce.sh` para aplicar la personalización del entorno y los paneles empaquetados.

3. **Revisar registros**  
   - `script_runs.log`: historial de qué se ejecutó y su resultado.
   - `setup_desktop.log`: credenciales en texto plano (elimínalo cuando ya no lo necesites).
