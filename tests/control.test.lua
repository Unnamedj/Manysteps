-- Comprueba el mando (roblox/control.lua) sobre un Roblox mockeado:
-- que pinta el estado que le llega del panel, que los botones mandan las
-- órdenes correctas y que no pisa lo que estás escribiendo.

local mock = assert(load(MOCK_SRC, "roblox-mock"))()

local failures = 0
local function check(labelText, ok, detail)
    if ok then
        print("  ok   " .. labelText)
    else
        failures = failures + 1
        print("  FAIL " .. labelText .. "  → " .. tostring(detail))
    end
end

----------------------------------------------------------------------
-- estado que devolverá el panel en el primer sync
----------------------------------------------------------------------

local function stateWith(overrides)
    local state = {
        serverTime = 1,
        online = 1,
        bridges = {
            {
                id = "77",
                username = "Zamora",
                online = true,
                panelJobId = "aa11bb22-cc33-dd44-ee55-ff6677889900",
                playerCount = 2,
                access = { status = "active", remainingSeconds = 754, readAt = 1 },
            },
        },
        settings = { placeId = "96342491571673", jobId = "guardado-1234" },
        players = {
            { userId = "156", username = "nova_rex", displayName = "Nova", bridgeId = "77", bridgeName = "Zamora" },
            { userId = "2481", username = "kiro", displayName = "Kiro", bridgeId = "77", bridgeName = "Zamora" },
        },
        pending = 0,
        places = {
            { label = "SAB New Player", placeId = "96342491571673" },
            { label = "SAB Normal", placeId = "109983668079237" },
        },
        log = { { at = 1, level = "ok", message = "Bridge conectado" } },
    }

    for key, value in pairs(overrides or {}) do
        state[key] = value
    end
    return state
end

--- Mismo estado pero con otro acceso en el único bridge.
local function withAccess(access)
    local state = stateWith()
    state.bridges[1].access = access
    return state
end

--- Mismo estado pero con otro Job ID en el cuadro del bridge.
local function withPanelJob(jobId)
    local state = stateWith()
    state.bridges[1].panelJobId = jobId
    return state
end

_G.__NEXT_RESPONSE = stateWith()
getgenv().MANYSTEPS_CONFIG = { url = "https://panel.example/", key = "clave-secreta" }

----------------------------------------------------------------------
-- cargar el mando (hace un sync durante el arranque)
----------------------------------------------------------------------

local chunk = assert(load(CONTROL_SRC, "control"))
local loaded, loadError = pcall(chunk)
check("el script arranca sin errores", loaded, loadError)

local jobBox = mock.findByName("JOBIDBox")
local placeBox = mock.findByName("PLACEIDBox")

----------------------------------------------------------------------
print("conexión con el panel")

local first = mock.requests[1]
check("pide el estado al arrancar",
    first and first.method == "GET" and first.url == "https://panel.example/api/control/state",
    first and (first.method .. " " .. first.url))

check("manda la clave por cabecera",
    first and first.headers["x-control-key"] == "clave-secreta",
    first and first.headers["x-control-key"])

check("la barra quita del final",
    first and not string.find(first.url, "//api"), first and first.url)

----------------------------------------------------------------------
print("pintado del estado")

check("el LED muestra la cuenta del bridge",
    mock.findByText("Zamora") ~= nil)

check("la lista muestra a los dos jugadores",
    mock.findByText("Nova") ~= nil and mock.findByText("Kiro") ~= nil)

check("el contador de la lista dice 2", mock.findByText("2") ~= nil)

check("el Job ID se rellena con el del panel del juego",
    mock.findByText("aa11bb22-cc33-dd44-ee55-ff6677889900") ~= nil)

check("avisa de que ese Job ID está activo",
    mock.findByText("activo en el panel del juego") ~= nil)

check("el Place ID se rellena", mock.findByText("96342491571673") ~= nil)

check("la barra de estado repite el último log",
    mock.findByText("Bridge conectado") ~= nil)

----------------------------------------------------------------------
print("reloj de acceso")

check("muestra cuánto queda, en minutos y segundos",
    mock.findByText("corriendo · 12:34") ~= nil)

_G.__NEXT_RESPONSE = withAccess({ status = "paused", remainingSeconds = 65 })
mock.runSpawned(1)
check("pausado también dice lo que queda", mock.findByText("pausado · 1:05") ~= nil)

_G.__NEXT_RESPONSE = withAccess({ status = "locked", remainingSeconds = 0 })
mock.runSpawned(1)
check("sin acceso lo dice sin reloj", mock.findByText("sin acceso") ~= nil)

_G.__NEXT_RESPONSE = withAccess({ status = "active", remainingSeconds = 7265 })
mock.runSpawned(1)
check("más de una hora sale con horas", mock.findByText("corriendo · 2:01:05") ~= nil)

_G.__NEXT_RESPONSE = stateWith()
mock.runSpawned(1)

----------------------------------------------------------------------
print("destinos del juego")

local newPlayer = mock.findByName("Place_96342491571673")
local normal = mock.findByName("Place_109983668079237")
check("hay un atajo por cada destino del juego",
    newPlayer ~= nil and normal ~= nil)
check("con la etiqueta sin el prefijo SAB",
    newPlayer and newPlayer.Text == "New Player", newPlayer and newPlayer.Text)

mock.reset()
mock.fire(normal, "MouseButton1Click")
local picked = mock.lastRequest()
check("al pulsar uno manda ese Place ID",
    picked and picked.body.type == "settings.placeId"
    and picked.body.payload.placeId == "109983668079237",
    picked and tostring(picked.body.payload and picked.body.payload.placeId))
check("y lo deja escrito en el campo",
    placeBox.Text == "109983668079237", placeBox.Text)

-- Devolvemos el destino a como estaba.
_G.__NEXT_RESPONSE = stateWith()
mock.runSpawned(1)
placeBox.Text = "96342491571673"

----------------------------------------------------------------------
print("botones de tiempo")

mock.reset()
mock.fire(mock.findByName("PauseButton"), "MouseButton1Click")

local paused = mock.lastRequest()
check("Pausar manda time.pause a /api/command",
    paused and paused.method == "POST"
    and paused.url == "https://panel.example/api/command"
    and paused.body.type == "time.pause",
    paused and (paused.url .. " " .. tostring(paused.body and paused.body.type)))

mock.reset()
mock.fire(mock.findByName("ResumeButton"), "MouseButton1Click")
check("Reanudar manda time.resume",
    mock.lastRequest().body.type == "time.resume",
    mock.lastRequest().body.type)

----------------------------------------------------------------------
print("campos de destino")

check("hay un cuadro para el Job ID y otro para el Place ID",
    jobBox ~= nil and placeBox ~= nil)

mock.reset()
jobBox.Text = "  nuevo-job-id  "
mock.fire(jobBox, "FocusLost", true)

local saved = mock.lastRequest()
check("al pulsar Enter manda settings.jobId ya recortado",
    saved and saved.body.type == "settings.jobId"
    and saved.body.payload.jobId == "nuevo-job-id",
    saved and tostring(saved.body.payload and saved.body.payload.jobId))

-- Escribir marca el campo como tuyo: el siguiente refresco no debe pisarlo.
jobBox.Text = "estoy-escribiendo-esto"
_G.__NEXT_RESPONSE = stateWith()
mock.runSpawned(1)
check("un refresco no pisa lo que estás escribiendo",
    jobBox.Text == "estoy-escribiendo-esto", jobBox.Text)

-- Lo enviado se queda hasta que el juego lo confirme: el bridge tarda en
-- releer el cuadro, y hasta entonces el panel devuelve el valor viejo.
jobBox.Text = "job-recien-mandado"
mock.fire(jobBox, "FocusLost", true)

_G.__NEXT_RESPONSE = stateWith()  -- el panel sigue con el Job ID de antes
mock.runSpawned(1)
check("el valor recién mandado no lo pisa el estado viejo",
    jobBox.Text == "job-recien-mandado", jobBox.Text)
check("y mientras tanto avisa de que está guardando",
    mock.findByText("guardando…") ~= nil)

_G.__NEXT_RESPONSE = withPanelJob("job-recien-mandado")
mock.runSpawned(1)
check("cuando el juego lo confirma, deja de estar pendiente",
    mock.findByText("activo en el panel del juego") ~= nil)

-- Y a partir de ahí el campo vuelve a seguir al juego.
_G.__NEXT_RESPONSE = withPanelJob("cambiado-desde-la-web")
mock.runSpawned(1)
check("un cambio hecho desde la web llega al mando",
    jobBox.Text == "cambiado-desde-la-web", jobBox.Text)

----------------------------------------------------------------------
print("mandar el Job ID de esta partida")

mock.reset()
mock.fire(mock.findByName("UseMyJobButton"), "MouseButton1Click")

local mine = mock.lastRequest()
check("manda el Job ID de la partida donde está el mando",
    mine and mine.body.type == "settings.jobId"
    and mine.body.payload.jobId == "17272727-8171",
    mine and tostring(mine.body.payload and mine.body.payload.jobId))

check("y lo deja escrito en el campo", jobBox.Text == "17272727-8171", jobBox.Text)

-- El mismo place que el destino configurado: nada que advertir.
check("sin aviso si el place coincide",
    mock.findByText("mandando tu Job ID: 17272727-8171") ~= nil)

-- El campo aguanta hasta que el juego confirme, igual que al escribirlo.
_G.__NEXT_RESPONSE = stateWith()
mock.runSpawned(1)
check("mientras el juego no lo confirme, sigue guardando",
    mock.findByText("guardando…") ~= nil)
check("y el campo no vuelve atrás", jobBox.Text == "17272727-8171", jobBox.Text)

-- Con otro place, el Job ID no le sirve al bridge y hay que decirlo.
placeBox.Text = "111222333"
mock.reset()
mock.fire(mock.findByName("UseMyJobButton"), "MouseButton1Click")
check("avisa si estás en otro place distinto del destino",
    mock.findByText("ojo: estás en el place 96342491571673, no en 111222333") ~= nil)

-- Volvemos a dejar el campo como estaba para lo que viene.
placeBox.Text = "96342491571673"
_G.__NEXT_RESPONSE = withPanelJob("17272727-8171")
mock.runSpawned(1)

----------------------------------------------------------------------
print("teleport por tanda")

mock.reset()
mock.fire(mock.findByName("SendButton"), "MouseButton1Click")
check("sin selección no manda nada", mock.lastRequest() == nil)
check("y lo dice en la barra de estado",
    mock.findByText("no hay nadie seleccionado") ~= nil)

-- Seleccionar a Nova: su fila es el TextButton que contiene la etiqueta.
local rows = mock.findAllByName("PlayerRow")
check("las filas de jugadores son pulsables", #rows >= 2, "#rows=" .. #rows)

mock.reset()
mock.fire(rows[1], "MouseButton1Click")
check("al marcar uno lo cuenta", mock.findByText("1 seleccionado") ~= nil)

_G.__NEXT_RESPONSE = { accepted = { "id-1" }, rejected = {} }
mock.fire(mock.findByName("SendButton"), "MouseButton1Click")

local batch = mock.lastRequest()
check("manda la tanda a /api/teleport/batch",
    batch and batch.url == "https://panel.example/api/teleport/batch"
    and batch.method == "POST", batch and batch.url)

check("con el jugador marcado dentro",
    batch and batch.body.targets and #batch.body.targets == 1
    and batch.body.targets[1].userId ~= nil,
    batch and batch.body.targets and batch.body.targets[1]
    and batch.body.targets[1].userId)

check("y con el Job ID que hay en el cuadro en ese momento",
    batch and batch.body.jobId == "17272727-8171", batch and batch.body.jobId)

check("tras enviarlos se limpia la selección",
    mock.findByText("0 seleccionados") ~= nil)

----------------------------------------------------------------------
print("el panel caído")

mock.reset()
_G.__NEXT_STATUS = 500
_G.__NEXT_RESPONSE = { error = "boom" }
mock.runSpawned(1)

check("un error del panel se ve en el LED", mock.findByText("sin panel") ~= nil)
check("y el motivo en la barra de estado",
    mock.findByText("no se pudo hablar con el panel: boom") ~= nil)

----------------------------------------------------------------------
print("varios bridges")

--- Tres operadores en partidas distintas, cada uno con sus jugadores.
local function multiState(overrides)
    local state = stateWith()
    state.online = 3
    state.bridges = {
        {
            id = "1001", username = "opA", online = true, playerCount = 2,
            panelJobId = "job-de-opA",
            access = { status = "active", remainingSeconds = 900 },
        },
        {
            id = "1002", username = "opB", online = true, playerCount = 1,
            panelJobId = "job-de-opB",
            access = { status = "paused", remainingSeconds = 120 },
        },
        {
            id = "1003", username = "opC", online = true, playerCount = 1,
            panelJobId = "job-de-opC",
            access = { status = "locked", remainingSeconds = 0 },
        },
    }
    state.players = {
        { userId = "5001", username = "nova", displayName = "Nova", bridgeId = "1001", bridgeName = "opA" },
        { userId = "5002", username = "kiro", displayName = "Kiro", bridgeId = "1001", bridgeName = "opA" },
        { userId = "5003", username = "lumen", displayName = "Lumen", bridgeId = "1002", bridgeName = "opB" },
        { userId = "5004", username = "vexel", displayName = "Vexel", bridgeId = "1003", bridgeName = "opC" },
    }
    for key, value in pairs(overrides or {}) do
        state[key] = value
    end
    return state
end

_G.__NEXT_RESPONSE = multiState()
mock.runSpawned(1)

check("el LED cuenta los bridges", mock.findByText("3 bridges") ~= nil)
check("hay una fila por bridge más la de todos",
    mock.findByName("BridgeRow_all") ~= nil
    and mock.findByName("BridgeRow_1001") ~= nil
    and mock.findByName("BridgeRow_1002") ~= nil
    and mock.findByName("BridgeRow_1003") ~= nil)

check("cada fila resume sus jugadores y su reloj",
    mock.findByText("2j · 15:00") ~= nil and mock.findByText("1j · 2:00") ~= nil,
    "no están los detalles")
check("un bridge sin acceso lo dice", mock.findByText("1j · sin acceso") ~= nil)

check("sin filtro salen los cuatro jugadores",
    mock.findByText("Nova") ~= nil and mock.findByText("Lumen") ~= nil
    and mock.findByText("Vexel") ~= nil)

check("el reloj de arriba es el del que peor está",
    mock.findByText("pausado · 2:00") ~= nil)

-- Elegir opA filtra la lista y dirige las órdenes.
mock.fire(mock.findByName("BridgeRow_1001"), "MouseButton1Click")

check("al elegir uno lo dice", mock.findByText("las órdenes van solo a opA") ~= nil)
check("la lista se queda con los suyos",
    mock.findByText("Nova") ~= nil and mock.findByText("Lumen") == nil,
    "Lumen no debería estar")
check("y el reloj pasa a ser el suyo", mock.findByText("corriendo · 15:00") ~= nil)

mock.reset()
mock.fire(mock.findByName("PauseButton"), "MouseButton1Click")
local directed = mock.lastRequest()
check("las órdenes llevan ese bridge como destino",
    directed and directed.body.target == "1001", directed and directed.body.target)

-- El teleport sigue yendo por el bridge que ve a cada jugador.
mock.reset()
local rowNova
for _, row in ipairs(mock.findAllByName("PlayerRow")) do
    rowNova = rowNova or row
end
mock.fire(rowNova, "MouseButton1Click")
_G.__NEXT_RESPONSE = { accepted = { "x" }, rejected = {} }
mock.fire(mock.findByName("SendButton"), "MouseButton1Click")

local sent = mock.lastRequest()
check("cada teleport indica por qué bridge va",
    sent and sent.body.targets and sent.body.targets[1]
    and sent.body.targets[1].bridgeId == "1001",
    sent and sent.body.targets and sent.body.targets[1]
    and tostring(sent.body.targets[1].bridgeId))

-- Si el bridge elegido se cae, se vuelve a mandar a todos.
_G.__NEXT_RESPONSE = multiState({
    online = 2,
    bridges = {
        { id = "1002", username = "opB", online = true, playerCount = 1,
          access = { status = "paused", remainingSeconds = 120 } },
        { id = "1003", username = "opC", online = true, playerCount = 1,
          access = { status = "active", remainingSeconds = 600 } },
    },
})
mock.runSpawned(1)

check("si el bridge elegido desaparece, vuelve a todos",
    mock.findByText("las órdenes van a todos") ~= nil)

mock.reset()
mock.fire(mock.findByName("PauseButton"), "MouseButton1Click")
check("y las órdenes vuelven a ir a todos",
    mock.lastRequest().body.target == "all", mock.lastRequest().body.target)

-- Sin ningún bridge conectado la lista lo dice en vez de quedarse en cero.
_G.__NEXT_RESPONSE = multiState({ online = 0, bridges = {}, players = {} })
mock.runSpawned(1)
check("sin bridges lo dice en la lista", mock.findByText("ninguno conectado") ~= nil)
check("y el LED también", mock.findByText("sin bridges") ~= nil)

----------------------------------------------------------------------
print("cierre")

check("deja MANYSTEPS_CONTROL_STOP para poder cerrarlo",
    type(getgenv().MANYSTEPS_CONTROL_STOP) == "function")

getgenv().MANYSTEPS_CONTROL_STOP()
check("al cerrar se borra el gancho", getgenv().MANYSTEPS_CONTROL_STOP == nil)

----------------------------------------------------------------------

print(failures == 0 and "\nTODO OK" or ("\n" .. failures .. " FALLOS"))
if failures > 0 then
    error("fallos en las pruebas del mando", 0)
end
