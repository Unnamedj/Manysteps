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
```

El panel nunca habla con Roblox directamente: encola comandos y el script
del juego los recoge, ejecuta el remote y devuelve el resultado.

## Qué hace

| Acción | Cómo |
| --- | --- |
| Pausar / reanudar el tiempo | `ToggleAdminTimePause:InvokeServer("pause"\|"resume")` |
| Poner el Job ID | escribe en el cuadro `JobIDBox` del panel **y** `SaveAdminSettings:FireServer("savedJobId", jobId)` |
| Guardar Place ID | `SaveAdminSettings:FireServer("savedPlaceId", placeId)` |
| Enviar teleport | `TeleportSelectedPlayer:FireServer(userId, placeId, jobId)` |
| Listar jugadores | `GetTeleportCandidates:InvokeServer()` |
| Leer los ajustes | `GetAdminSettings:InvokeServer()` |
| Resultado del teleport | `TeleportSelectedPlayerResult.OnClientEvent` |

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
  controller.lua puente: pregunta al panel qué hacer y lo ejecuta
tests/           pruebas de remotes.lua sobre un Roblox mockeado
```

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

Ejecuta `roblox/remotes.lua` dentro de una VM de Lua con `ReplicatedStorage`
mockeado y comprueba que cada función dispara el remote correcto con los
argumentos y tipos exactos (por ejemplo: que el Place ID viaja como texto
`"96342491571673"` en `SaveAdminSettings` pero como número en
`TeleportSelectedPlayer`). No hace falta Studio ni un executor.

## Notas

- El estado vive en memoria: un redeploy borra el log y la lista de
  jugadores, pero el Job ID / Place ID se vuelven a mandar con un botón.
- El bridge usa long-poll de ~15 s. Si tu executor corta las peticiones
  antes, baja `pollWait` en el loader:
  `getgenv().MANYSTEPS_CONFIG = { url = ..., key = ..., pollWait = 8 }`.
- El endpoint `/api/bridge/*` está protegido por `BRIDGE_KEY`; el resto
  del panel, por sesión con cookie.
