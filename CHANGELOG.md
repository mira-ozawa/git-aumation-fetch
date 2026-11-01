# Changelog - Actualizacion de remotes de git

Historial de todo lo que se fue construyendo para actualizar los remotes de los repos locales
despues de cambiar nombres de organizacion y mover repos entre organizaciones en GitHub.

Fecha de trabajo: 2026-11-01

---

## Contexto

- Mas de 15 organizaciones en GitHub, con entre 5 y 200 repos cada una.
- Se renombraron organizaciones y se movieron repos de una org a otra
  (ejemplos reales: `trex-faster` -> `agami-seina`, `rolyqh007` -> `dao088`).
- Los repos locales estan repartidos en carpetas numeradas dentro de `Documents`
  (`1.side-projects` ... `16.malware`), con repos anidados dentro de otros repos.
- Solo existe el disco C:. La terminal usada es PowerShell.
- Total detectado: **86 repos** en 15 carpetas.

El problema: `git remote add origin URL` solo sirve para un repo. Hacerlo a mano en
decenas de repos dispersos no es viable.

---

## [1.4] - Correccion del falso error "set-url fallo"

### Corregido
- Los repos que necesitaban cambio aparecian como `[ERROR] ... set-url fallo` aunque el cambio
  probablemente si se aplicaba.
- Causa: la verificacion posterior leia el remote con `Select-Object -First 1`, que corta el
  comando de git antes de terminar y deja un codigo de salida distinto de 0
  (`$LASTEXITCODE`). El script lo interpretaba como fallo.
- Solucion: se guarda el codigo de salida de `set-url` inmediatamente, y la verificacion compara
  solo el texto de la URL leida, sin depender de `$LASTEXITCODE`.

### Nota
- Los repos marcados como error en la ejecucion anterior no quedaron en `revertir.csv`.
  Su URL original esta en la columna `UrlAntes` de `reporte-completo.csv`.

---

## [1.3] - Lanzadores con doble clic

### Agregado
- `actualizar-repos.bat`: aplica cambios (`-Apply`) y hace fetch de todos.
- `actualizar-repos-rapido.bat`: aplica cambios sin fetch (`-Apply -NoFetch`).
- Ambos deben estar en la misma carpeta que `actualizar-repos.ps1`, ejecutan con
  `-ExecutionPolicy Bypass` y dejan la ventana abierta al terminar.

### Motivo
- Hacer doble clic en un `.ps1` solo lo abre en el Bloc de notas. Un `.bat` evita escribir comandos.

---

## [1.2] - Modo automatico

### Agregado
- Parametro `-Silent`: para ejecuciones automaticas. No deja carpetas de reporte en cada pasada.
  Solo escribe en `Documents\reportes-repos\`:
  - `cambios-automaticos.log`: que remote se actualizo y cuando.
  - `ultimo-fallos.csv`: fallos de la ultima pasada (se borra si ya no hay fallos).
- Bloqueo de ejecuciones simultaneas (mutex): si una pasada sigue en curso, la siguiente se cancela.
- Instrucciones para crear la tarea programada `ActualizarRemotesGit` (al iniciar sesion y cada
  30 minutos, con `-Apply -NoFetch -Silent`).

### Limitaciones documentadas
- GitHub no puede avisar a la PC cuando se mueve un repo, asi que "en el acto" no es posible;
  lo mas cercano es una tarea programada con un retraso maximo del intervalo elegido.
- La tarea solo corre con la sesion de Windows iniciada.

---

## [1.1] - Fetch con timeout y avance visible

### Corregido
- El script parecia "colgado" despues de `blog\pocketbase`: solo imprimia repos con cambios o
  fallos, y la barra de progreso estaba desactivada.
- Un `git fetch` podia quedarse esperando sin limite si la conexion no respondia.

### Cambiado
- Una linea de avance por repo: `[14/86] C:\...\ruta`.
- El fetch corre en un job con tiempo limite (`-FetchTimeoutSeg`, 60 s por defecto). Si se pasa,
  se cancela, se registra como fallo con el motivo `Timeout` y sigue con el siguiente repo.

---

## [1.0] - Script completo `actualizar-repos.ps1`

### Agregado
- Busqueda de repos con poda de carpetas (`.git`, `node_modules`, `venv`, `vendor`, etc.) que
  sigue bajando despues de encontrar un repo, para detectar repos anidados.
- Solo recorre las carpetas numeradas de `Documents`. `16.malware` queda excluida por defecto
  (`-IncluirMalware` para incluirla). Se pueden indicar otras carpetas con `-Roots`.
- Consulta a GitHub (`gh api repos/ORG/REPO`) para saber donde vive hoy cada repo. Detecta cambios
  de org, de usuario y de nombre de repo, sin necesidad de un archivo de mapeo.
- Modo prueba por defecto; `-Apply` aplica los cambios; `-NoFetch` omite el fetch.
- `git fetch` por cada remote, sin pedir credenciales (evita bloqueos).
- Todo dentro de `try/catch`: un error en un repo nunca detiene el resto.
- Reportes en `Documents\reportes-repos\<fecha-hora>\`:
  - `reporte-completo.csv`: todos los repos y su estado.
  - `fallos.csv`: solo lo que fallo.
  - `revertir.csv`: para deshacer los cambios aplicados.
  - `log.txt`
- Resumen final en pantalla con conteo por estado y lista de fallos en rojo.
- Codigo de salida `1` si hubo fallos, `0` si no.
- Registro de `safe.directory '*'` para evitar errores de "dubious ownership".

### Estados posibles
`AL DIA`, `POR ACTUALIZAR` (prueba), `ACTUALIZADO`, `NO ENCONTRADO`, `ERROR API`, `NO GITHUB`,
`SIN REMOTE`, `SIN GH`, `ERROR`.

---

## [0.5] - Reporte de todos los repos y alias SSH

### Cambiado
- La regex acepta alias SSH (`git@github-trabajo:org/repo.git`) y no solo `github.com`.
- Se genera un CSV con cada repo encontrado y su estado, para comprobar que ninguno se perdio
  (caso de duda: `1.side-projects\blog-medium\api`, que no aparecia en la lista de cambios por
  estar al dia, sin remote o no ser de GitHub).

---

## [0.4] - Deteccion automatica con GitHub CLI

### Agregado
- Uso de `gh api` para preguntar a GitHub la ubicacion actual de cada repo. Elimina la necesidad
  de indicar a que org fue cada repo.
- Instalacion de GitHub CLI sin `winget`: instalador `.msi`, Scoop o Chocolatey, mas `gh auth login`.

### Aclarado
- La lista `[PRUEBA]` ya es la lista de repos que cambiaron en GitHub pero siguen con el remote
  viejo en local; no hace falta guardar nada en un CSV intermedio.

---

## [0.3] - Busqueda limitada a las carpetas numeradas

### Cambiado
- Solo se buscan carpetas que empiezan con numero (`^\d+\.`) dentro de `Documents`.
- Se excluye `16.malware` por seguridad.
- Recorrido manual con pila en lugar de `-Recurse -Filter ".git"`: mas rapido (no entra a `.git` ni
  `node_modules`) y encuentra repos anidados y repos donde `.git` es un archivo (submodulos, worktrees).
- Se elimino la busqueda en otros discos (solo existe C:).

### Notas
- Documents esta sincronizado con OneDrive; conviene mantener las carpetas "siempre en este
  dispositivo" para que el recorrido no sea lento.

---

## [0.2] - Mapeo de varias organizaciones

### Agregado
- Archivo `mapeo.csv` con reglas `origen,destino`:
  - Por repo: `org/repo,otra-org/repo`.
  - Por organizacion completa: `org-vieja,org-nueva`.
  - Las reglas por repo tienen prioridad sobre las de org completa.
- Version en PowerShell y en Bash (para servers Linux).
- Se revisan todos los remotes (`origin`, `upstream`...), no solo `origin`.

### Reemplazado en 0.4
- Este enfoque se sustituyo por la consulta automatica a GitHub.

---

## [0.1] - Primer enfoque: reemplazo simple

### Agregado
- Bucle que recorre repos y cambia `NOMBRE-VIEJO` por `NOMBRE-NUEVO` en el remote.
- Aclaracion de que el comando correcto es `git remote set-url origin URL`, no
  `git remote add origin URL` (que falla si `origin` ya existe).

---

## Como se usa hoy

1. Instalar GitHub CLI y ejecutar `gh auth login`. Para repos privados: `gh auth setup-git`.
   - Descarga (instalador `.msi` para Windows): https://cli.github.com
   - Todas las versiones (buscar el archivo `gh_*_windows_amd64.msi`): https://github.com/cli/cli/releases/latest
   - Despues de instalar, cerrar y volver a abrir PowerShell y comprobar con `gh --version`.
   - Alternativas sin MSI: Scoop (`scoop install gh`) o Chocolatey (`choco install gh`).
2. Dejar `actualizar-repos.ps1`, `actualizar-repos.bat` y `actualizar-repos-rapido.bat` en la misma carpeta.
3. Primera vez, en modo prueba (PowerShell):

   ```powershell
   cd $env:USERPROFILE\Documents
   powershell -ExecutionPolicy Bypass -File .\actualizar-repos.ps1
   ```

4. Aplicar con doble clic en `actualizar-repos.bat` (o `-Apply` desde PowerShell).
5. Revisar `Documents\reportes-repos\<fecha-hora>\fallos.csv`.

Para deshacer cambios aplicados:

```powershell
Import-Csv "$env:USERPROFILE\Documents\reportes-repos\<fecha-hora>\revertir.csv" | ForEach-Object {
    git -C $_.Repo remote set-url $_.Remote $_.UrlAntes
}
```

---

## Pendiente / problemas conocidos

- **`2.extensions-scripts\ONPE-MONITOR\list-onpe` y `...\extension`**: apuntan a
  `rolyqh007/list-change-elector-onpe`, que GitHub no encuentra (`Repository not found`).
  Hay que ubicar el repo en alguna de las orgs (o confirmar que se borro) y actualizar ambos remotes a mano.
- **Fetch de repos privados**: fallaba con `could not read Username` por falta de credenciales de git.
  Se resuelve con `gh auth setup-git` y autorizando el token para las orgs con SSO.
- **Tarea programada**: documentada pero pendiente de crear si se quiere la actualizacion automatica.
- **Servers Linux**: no cubiertos por el script de PowerShell; falta la version Bash con `gh` y `cron`.
- **Imports de Go**: si algun modulo usa `github.com/ORG-VIEJA/...` en `go.mod` o en los imports,
  hay que cambiarlo a mano. Lo mismo en `.gitmodules`, `package.json`, workflows y webhooks.
- No crear una org o usuario nuevo con un nombre viejo (`trex-faster`, `rolyqh007`): GitHub dejaria
  de redirigir y la deteccion automatica dejaria de funcionar para esos repos.
- El script no se ejecuto en el entorno de desarrollo; las pruebas las hizo el usuario en su PC.
