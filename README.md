# Manysteps · consola de operaciones remotas

Panel web (desplegable en Railway) que controla los remotes de
`ReplicatedStorage.AdminEvents` desde un script ejecutado dentro de Roblox.

```
   navegador                Railway                     Roblox
  ┌──────────┐   HTTPS   ┌────────────┐  long-poll  ┌──────────────┐
  │  panel   │ ────────► │  servidor  │ ◄────────── │ controller.lua│
  │  (web)   │ ◄──────── │  (cola +   │ ──────────► │      ↓        │
  └──────────┘   websock │   estado)  │   comandos  │  remotes.lua  │
                         └────────────┘             └──────────────┘
  ┌──────────┐              ▲     │                        ↓
  │ control  │ ─────────────┘     └──────────────►  AdminEvents
  │  (mando) │   mismas órdenes, desde dentro del juego
  └──────────┘
```

El panel nunca habla con Roblox directamente: encola comandos y el script
del juego los recoge, ejecuta el remote y devuelve el resultado.

Hay dos formas de mandar: **el panel web** y **el mando**, una ventana
dentro de Roblox que hace lo mismo sin salir del juego. Los dos hablan
con el mismo servidor, así que se ven el uno al otro en tiempo real.

## Qué hace

| Acción | Cómo |
| --- | --- |
| Pausar / reanudar el tiempo | `ToggleAdminTimePause:InvokeServer("pause"\|"resume")` |
| Poner el Job ID | escribe en el cuadro `JobIDBox` del panel **y** `SaveAdminSettings:FireServer("savedJobId", jobId)` |
| Guardar Place ID | `SaveAdminSettings:FireServer("savedPlaceId", placeId)` |
| Enviar teleport | `TeleportSelectedPlayer:FireServer(userId, placeId, jobId)` |
| Listar jugadores | `GetTeleportCandidates:InvokeServer()` |
| Leer los ajustes | `GetAdminSettings:InvokeServer()` |
| Estado del acceso | `GetAccessStatus:InvokeServer()` |
| Resultado del teleport | `TeleportSelectedPlayerResult.OnClientEvent` |

El panel y el mando muestran el **tiempo de acceso que queda**, tal y
como lo cuenta el servidor del juego (`GetAccessStatus`), y no lo que
dedujimos del último botón pulsado. La cuenta atrás corre en el cliente
entre lecturas.

Los **destinos** del propio panel del juego (`SAB New Player` y
`SAB Normal`) están como atajos junto al Place ID, para no tener que
recordar los números.

Los teleports se pueden mandar a varios jugadores de una tanda: se
seleccionan en la lista y se encola un comando por cada uno.

### Por qué el Job ID son dos pasos

En el juego, el Job ID que se usa de verdad es **el texto del cuadro
`JobIDBox`** del panel: su botón de teleport manda
`TeleportSelectedPlayer:FireServer(userId, placeId, JobIDBox.Text)`.

`savedJobId` es solo persistencia. El juego lo escribe en el cuadro al
abrir el panel, y únicamente si el ajuste `rememberJobId` está activado:

```lua
if settings.rememberJobId then JobIDBox.Text = settings.savedJobId end
```

Por eso mandar solo `SaveAdminSettings` no cambia nada a la vista. El
bridge hace las dos cosas: escribe en el cuadro (efecto inmediato) y
guarda el ajuste (para cuando se reabra el panel). Si quieres que
persista entre sesiones, activa **Remember Job ID** dentro del juego.

El panel web muestra en todo momento lo que hay en el cuadro, leído del
juego — no lo último que se mandó.

## Estructura

```
server/          backend Node (Express + WebSocket)
  index.js       rutas del panel y del bridge, entrega de los .lua
  store.js       estado, cola de comandos, log, long-poll
  auth.js        sesiones del panel y clave del bridge
public/          panel web (sin build, sin dependencias externas)
roblox/
  remotes.lua    capa de remotes — solo llama a AdminEvents
  controller.lua bridge: pregunta al panel qué hacer y lo ejecuta
  control.lua    mando: la consola dibujada dentro de Roblox
tests/           pruebas de los scripts sobre un Roblox mockeado
```

Los tres scripts de Roblox se sirven desde el propio servidor, así que se
actualizan solos al hacer redeploy: basta con volver a pegar el loader.

## Desplegar en Railway

1. Crea un proyecto nuevo apuntando a este repositorio.
2. En **Variables** añade:
   - `PANEL_PASSWORD` — la contraseña para entrar al panel.
   - `BRIDGE_KEY` — una clave larga y aleatoria para el script.
3. Genera un dominio público (**Settings → Networking → Generate Domain**).
4. Railway detecta Node con Nixpacks y arranca con `npm start`.

Si no defines las variables, el servidor genera valores temporales y los
imprime en los logs del deploy — pero cambian en cada redeploy, así que
para uso real conviene fijarlas.

## Usar el panel

1. Abre el dominio y entra con `PANEL_PASSWORD`.
2. Pulsa **Loader** arriba a la derecha y copia la línea que aparece.
3. Pégala en tu executor con el juego abierto. Debería aparecer
   `[Manysteps] conectado a …` en la consola y el chip **Bridge** ponerse
   en verde.
4. A partir de ahí el panel manda y el script obedece.

El loader tiene esta forma:

```lua
loadstring(game:HttpGet("https://TU-APP.up.railway.app/script/loader.lua?key=TU_BRIDGE_KEY"))()
```

Para detener el bridge sin cerrar Roblox: `getgenv().MANYSTEPS_STOP()`.

## El mando (opcional)

Si prefieres mandar sin salir del juego, el botón **Loader** trae una
segunda línea, la del mando:

```lua
loadstring(game:HttpGet("https://TU-APP.up.railway.app/script/loader.lua?key=TU_BRIDGE_KEY&mode=control"))()
```

Abre una ventana dentro de Roblox con lo mismo que el panel web: pausar y
reanudar, Place ID y Job ID, la lista de jugadores con selección múltiple
y el envío por tanda. No toca ningún remote — manda las órdenes al panel,
igual que el navegador, y el bridge las ejecuta.

Por eso puede correr donde quieras: en otra cuenta, en otro servidor o en
otro juego. Solo necesita alcanzar el panel.

### Traer gente a tu partida

El botón **MI JOB ID**, junto al campo, coge el `game.JobId` del servidor
donde está corriendo *el mando* y lo manda como destino de un tirón.

Sirve para lo de siempre: tú estás en una partida, el bridge está en
otra, y quieres que la gente venga contigo. Le das y el bridge empieza a
teletransportar a tu servidor.

Un Job ID solo vale dentro de su propio juego, así que si el Place ID
configurado es otro, el mando te avisa en la barra de estado en vez de
dejarte mandar gente a un sitio que no existe.

- `RightControl` muestra u oculta la ventana.
- La barra de título la arrastra; el `_` la pliega.
- `getgenv().MANYSTEPS_CONTROL_STOP()` la cierra del todo.

Si en tu pantalla se ve grande, cárgalo a mano con una escala:

```lua
getgenv().MANYSTEPS_CONFIG = {
    url = "https://TU-APP.up.railway.app",
    key = "TU_BRIDGE_KEY",
    scale = 0.8,
}
loadstring(game:HttpGet("https://TU-APP.up.railway.app/script/control.lua"))()
```

Puedes ejecutar el bridge y el mando en la misma sesión: son
independientes y no se pisan.

## Usar los remotes sin panel

`remotes.lua` funciona por su cuenta:

```lua
local Remotes = loadstring(game:HttpGet("https://TU-APP.up.railway.app/script/remotes.lua"))()

Remotes.pauseTime()
Remotes.savePlaceId("96342491571673")
Remotes.saveJobId("00000000-0000-0000-0000-000000000000")
Remotes.teleport(123456789, 96342491571673, "00000000-0000-0000-0000-000000000000")

for _, player in ipairs(Remotes.getCandidates()) do
    print(player.userId, player.username)
end
```

## Desarrollo local

```bash
npm install
PANEL_PASSWORD=test BRIDGE_KEY=test npm run dev
# http://localhost:3000
```

## Pruebas

```bash
npm test
```

Dos suites, las dos sobre una VM de Lua con Roblox mockeado. No hace
falta Studio ni un executor.

- **remotes.lua** — comprueba que cada función dispara el remote correcto
  con los argumentos y tipos exactos. Por ejemplo: que el Place ID viaja
  como texto `"96342491571673"` en `SaveAdminSettings` pero como número
  en `TeleportSelectedPlayer`.
- **control.lua** — carga el mando entero con instancias, eventos y HTTP
  simulados, dispara los clics y mira qué manda al panel: que Pausar
  encola `time.pause`, que el envío por tanda lleva los jugadores
  marcados, que un refresco no pisa lo que estás escribiendo.

## Notas

- El estado vive en memoria: un redeploy borra el log y la lista de
  jugadores, pero el Job ID / Place ID se vuelven a mandar con un botón.
- El bridge usa long-poll de ~15 s. Si tu executor corta las peticiones
  antes, baja `pollWait` en el loader:
  `getgenv().MANYSTEPS_CONFIG = { url = ..., key = ..., pollWait = 8 }`.
- El endpoint `/api/bridge/*` está protegido por `BRIDGE_KEY`; el resto
  del panel, por sesión con cookie.
