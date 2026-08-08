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
        bridge = { online = true, username = "Zamora", jobId = "bridge-job" },
        time = { status = "paused" },
        settings = { placeId = "96342491571673", jobId = "guardado-1234" },
        game = { panelJobId = "aa11bb22-cc33-dd44-ee55-ff6677889900" },
        players = {
            { userId = "156", username = "nova_rex", displayName = "Nova" },
            { userId = "2481", username = "kiro", displayName = "Kiro" },
        },
        pending = 0,
        log = { { at = 1, level = "ok", message = "Bridge conectado" } },
    }

    for key, value in pairs(overrides or {}) do
        state[key] = value
    end
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

-- El TextBox del Job ID es el que tiene el placeholder del Job ID.
local jobBox = mock.findByName("JOBIDBox")
local placeBox = mock.findByName("PLACEIDBox")
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

check("y con el Job ID que hay escrito",
    batch and batch.body.jobId == "estoy-escribiendo-esto", batch and batch.body.jobId)

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
