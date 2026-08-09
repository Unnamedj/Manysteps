--[[
    Manysteps · controller.lua
    ------------------------------------------------------------------
    Puente entre el panel web y remotes.lua.

    No toca ningún remote por su cuenta: pregunta al servidor qué hay que
    hacer (long-poll), llama a la función correspondiente de remotes.lua y
    devuelve el resultado. También publica la lista de jugadores.

    Config (la inyecta /script/loader.lua):
        getgenv().MANYSTEPS_CONFIG = { url = "https://...", key = "..." }
--]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------

local config = getgenv and getgenv().MANYSTEPS_CONFIG or _G.MANYSTEPS_CONFIG
if type(config) ~= "table" or type(config.url) ~= "string" or config.url == "" then
    error("[Manysteps] Falta getgenv().MANYSTEPS_CONFIG = { url = ..., key = ... }", 0)
end

local BASE_URL = string.gsub(config.url, "/+$", "")
local BRIDGE_KEY = tostring(config.key or "")
local POLL_WAIT = tonumber(config.pollWait) or 15 -- segundos que el server retiene el poll
local PLAYER_SYNC_SECONDS = tonumber(config.playerSync) or 20
local REMOTES_URL = config.remotesUrl or "@@REMOTES_URL@@"
local SCANNER_URL = config.scannerUrl or "@@SCANNER_URL@@"
local SCAN_SECONDS = tonumber(config.scanEvery) or 20

----------------------------------------------------------------------
-- una sola instancia
----------------------------------------------------------------------

if getgenv and type(getgenv().MANYSTEPS_STOP) == "function" then
    pcall(getgenv().MANYSTEPS_STOP)
end

local running = true
local session = {}
if getgenv then
    getgenv().MANYSTEPS_SESSION = session
    getgenv().MANYSTEPS_STOP = function()
        running = false
        session.running = false
    end
end
session.running = true

local function alive()
    return running and session.running
end

local function print_(...)
    print("[Manysteps]", ...)
end

----------------------------------------------------------------------
-- http
----------------------------------------------------------------------

local httpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or request
    or (fluxus and fluxus.request)

if type(httpRequest) ~= "function" then
    error("[Manysteps] Tu executor no expone una función request/http_request", 0)
end

local function statusOf(response)
    if type(response) ~= "table" then
        return 0
    end
    return response.StatusCode or response.Status or response.status_code or 0
end

--- Petición JSON. Devuelve ok, tabla|mensajeDeError.
-- Con varios bridges conectados a la vez, el panel necesita saber cuál
-- habla en cada petición: la cuenta que ejecuta el script es la
-- identidad, así que reejecutarlo no deja un fantasma en la lista.
local BRIDGE_ID = (function()
    local player = Players.LocalPlayer
    if player and player.UserId then
        return string.format("%.0f", player.UserId)
    end
    return "anon-" .. tostring(math.random(100000, 999999))
end)()

local function httpJson(method, pathname, body, timeoutHint)
    local options = {
        Url = BASE_URL .. pathname,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["x-bridge-key"] = BRIDGE_KEY,
            ["x-bridge-id"] = BRIDGE_ID,
        },
        Timeout = timeoutHint or 30,
    }

    if body ~= nil then
        local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, body)
        if not encodeOk then
            return false, "no se pudo codificar el cuerpo: " .. tostring(encoded)
        end
        options.Body = encoded
    end

    local ok, response = pcall(httpRequest, options)
    if not ok then
        return false, tostring(response)
    end

    local status = statusOf(response)
    if status < 200 or status >= 300 then
        return false, ("HTTP %s — %s"):format(tostring(status), tostring(response.Body or ""):sub(1, 160))
    end

    local rawBody = response.Body
    if type(rawBody) ~= "string" or rawBody == "" then
        return true, {}
    end

    local decoded, parsed = pcall(HttpService.JSONDecode, HttpService, rawBody)
    if not decoded then
        return false, "respuesta no era JSON"
    end
    return true, parsed
end

local function report(level, message)
    task.spawn(httpJson, "POST", "/api/bridge/log", { level = level, message = message })
end

----------------------------------------------------------------------
-- remotes
----------------------------------------------------------------------

local Remotes
if getgenv and type(getgenv().MANYSTEPS_REMOTES) == "table" then
    Remotes = getgenv().MANYSTEPS_REMOTES
else
    local fetched, source = pcall(game.HttpGet, game, REMOTES_URL)
    if not fetched then
        error("[Manysteps] No se pudo descargar remotes.lua: " .. tostring(source), 0)
    end
    local chunk, compileError = loadstring(source, "manysteps-remotes")
    if not chunk then
        error("[Manysteps] remotes.lua no compila: " .. tostring(compileError), 0)
    end
    Remotes = chunk()
end

if type(Remotes) ~= "table" or type(Remotes.pauseTime) ~= "function" then
    error("[Manysteps] remotes.lua no devolvió el módulo esperado", 0)
end

if getgenv then
    getgenv().MANYSTEPS_REMOTES = Remotes
end

----------------------------------------------------------------------
-- escáner de plots (opcional)
----------------------------------------------------------------------

-- Solo sirve en un place concreto; en el resto ni se carga.
local Scanner = nil
do
    local fetched, source = pcall(game.HttpGet, game, SCANNER_URL)
    if fetched then
        local chunk = loadstring(source, "manysteps-scanner")
        if chunk then
            local built, module = pcall(chunk)
            if built and type(module) == "table" and type(module.scan) == "function" then
                Scanner = module
            end
        end
    end

    if Scanner and not Scanner.isSupportedPlace() then
        Scanner = nil
    end
end

local hasRemotes = Remotes.hasAdminEvents()

if Scanner then
    print_("escáner activo en este place")
end
if not hasRemotes then
    print_("sin AdminEvents en este place: este bridge no ejecuta remotes")
end

----------------------------------------------------------------------
-- ritmo de los remotes
----------------------------------------------------------------------

-- Cuando el panel manda varias cosas de golpe, los remotes salen uno
-- detrás de otro con milisegundos de diferencia. Muchos juegos ponen
-- cooldown a los remotes de admin y descartan el segundo sin avisar,
-- que es justo lo que parecía pasar al guardar Place ID y Job ID
-- seguidos. Aquí se les da aire.
local REMOTE_GAP = tonumber(config.remoteGap) or 0.7
local lastCallAt = {}

local function pace(remoteName)
    local previous = lastCallAt[remoteName]
    if previous then
        local elapsed = os.clock() - previous
        if elapsed < REMOTE_GAP then
            task.wait(REMOTE_GAP - elapsed)
        end
    end
    lastCallAt[remoteName] = os.clock()
end

----------------------------------------------------------------------
-- jugadores
----------------------------------------------------------------------

-- Lo que el juego tiene ahora mismo, para que el panel muestre la
-- realidad en vez de lo último que creímos haber mandado.
local function readGameState()
    local state = {}
    state.scanner = Scanner ~= nil
    state.hasRemotes = hasRemotes

    if not hasRemotes then
        return state
    end

    local boxOk, boxValue = pcall(Remotes.getPanelJobId)
    state.panelJobId = boxOk and boxValue or nil

    pace("GetAdminSettings")
    local settingsOk, settings = pcall(Remotes.getAdminSettings)
    if settingsOk and type(settings) == "table" then
        state.savedJobId = settings.savedJobId
        state.savedPlaceId = settings.savedPlaceId
        state.rememberJobId = settings.rememberJobId
        state.rememberPlaceId = settings.rememberPlaceId
    end

    pace("GetAccessStatus")
    local accessOk, access = pcall(Remotes.getAccessStatus)
    if accessOk and type(access) == "table" then
        state.access = access
    end

    return state
end

-- Tras cambiar un ajuste hay que contarlo ya: si esperásemos al refresco
-- periódico, el panel seguiría enseñando el valor viejo casi medio
-- minuto y pisaría lo que acabas de escribir.
local function publishGameState()
    httpJson("POST", "/api/bridge/players", { game = readGameState() })
end

local function pushPlayers()
    -- Un bridge que solo escanea no tiene remotes que llamar.
    if not hasRemotes then
        httpJson("POST", "/api/bridge/players", { players = {}, game = readGameState() })
        return true, {}
    end

    pace("GetTeleportCandidates")
    local ok, list = pcall(Remotes.getCandidates)
    if not ok then
        report("error", "GetTeleportCandidates falló: " .. tostring(list))
        return false, tostring(list)
    end
    httpJson("POST", "/api/bridge/players", { players = list, game = readGameState() })
    return true, list
end

--- Manda lo que hay en los plots. Solo datos: el panel los enseña, en el
--- juego no se dibuja nada.
local function pushScan()
    if not Scanner then
        return false
    end

    local ok, items = pcall(Scanner.scan)
    if not ok then
        report("error", "escaneo falló: " .. tostring(items))
        return false
    end

    httpJson("POST", "/api/bridge/scan", { items = items })
    return true, items
end

----------------------------------------------------------------------
-- comandos
----------------------------------------------------------------------

local handlers = {
    ["time.pause"] = function()
        pace("ToggleAdminTimePause")
        return { state = Remotes.pauseTime() }
    end,

    ["time.resume"] = function()
        pace("ToggleAdminTimePause")
        return { state = Remotes.resumeTime() }
    end,

    -- Dos pasos, y el orden importa: primero el cuadro del panel, que es
    -- lo que se ve y lo que lee el botón Teleport del juego, y después
    -- el ajuste guardado, que solo se relee al reabrir el panel.
    ["settings.jobId"] = function(payload)
        local jobId = tostring(payload.jobId)

        local wroteBox, boxError = pcall(Remotes.setPanelJobId, jobId)
        if wroteBox then
            report("ok", ("Job ID del panel → %s"):format(jobId))
        else
            report("warn", "No se pudo escribir en el panel: " .. tostring(boxError))
        end

        pace("SaveAdminSettings")
        Remotes.saveJobId(jobId)

        if not wroteBox then
            -- Sin el cuadro, lo guardado no llega a aplicarse solo.
            error(tostring(boxError), 0)
        end

        publishGameState()
        return { jobId = jobId, panel = Remotes.getPanelJobId() }
    end,

    ["settings.placeId"] = function(payload)
        local placeId = tostring(payload.placeId)
        pace("SaveAdminSettings")
        Remotes.savePlaceId(placeId)
        publishGameState()
        return { placeId = placeId }
    end,

    ["teleport.send"] = function(payload)
        pace("TeleportSelectedPlayer")
        Remotes.teleport(payload.userId, payload.placeId, payload.jobId)
        return { userId = payload.userId }
    end,

    -- Mover el propio bridge. Al hacerlo se va del servidor actual, así
    -- que el panel lo verá caer y volver: es lo esperado.
    ["bridge.teleport"] = function(payload)
        local placeId = tostring(payload.placeId)
        report("info", "moviendo este bridge al place " .. placeId)
        return Remotes.moveSelf(placeId, payload.jobId)
    end,

    ["scan.refresh"] = function()
        if not Scanner then
            error("este bridge no escanea (no está en el place del escáner)", 0)
        end
        local ok, items = pushScan()
        if not ok then
            error("el escaneo falló", 0)
        end
        return { count = #items }
    end,

    ["players.refresh"] = function()
        pace("GetTeleportCandidates")
        local ok, list = pcall(Remotes.getCandidates)
        if not ok then
            error(tostring(list), 0)
        end
        return { players = list }
    end,
}

local function runCommand(command)
    local handler = handlers[command.type]
    if not handler then
        return { id = command.id, ok = false, error = "comando desconocido: " .. tostring(command.type) }
    end

    local ok, result = pcall(handler, command.payload or {})
    if not ok then
        print_("comando falló:", command.type, result)
        return { id = command.id, ok = false, error = tostring(result) }
    end
    return { id = command.id, ok = true, data = result }
end

----------------------------------------------------------------------
-- arranque
----------------------------------------------------------------------

local localPlayer = Players.LocalPlayer

local function hello()
    return httpJson("POST", "/api/bridge/hello", {
        executor = (identifyexecutor and select(1, identifyexecutor())) or "desconocido",
        placeId = tostring(game.PlaceId),
        jobId = tostring(game.JobId),
        userId = localPlayer and tostring(localPlayer.UserId) or nil,
        username = localPlayer and localPlayer.Name or nil,
        version = Remotes.VERSION,
    })
end

local ok, greeting = hello()
if not ok then
    error("[Manysteps] No se pudo contactar el panel: " .. tostring(greeting), 0)
end
print_("conectado a " .. BASE_URL)
report("ok", "Bridge listo en JobId " .. tostring(game.JobId))

-- El juego contesta a cada teleport por su cuenta. Sin escucharlo, el
-- panel diría "hecho" con solo haber disparado el remote.
local listening, listenError = pcall(Remotes.onTeleportResult, function(result)
    if result.success then
        report("ok", ("Teleport de %s aceptado%s"):format(
            result.userId,
            result.message ~= "" and (": " .. result.message) or ""
        ))
    else
        report("error", ("Teleport de %s rechazado: %s"):format(
            result.userId,
            result.message ~= "" and result.message or "sin motivo"
        ))
    end
end)

if not listening then
    report("warn", "Sin resultados de teleport: " .. tostring(listenError))
end

----------------------------------------------------------------------
-- bucles
----------------------------------------------------------------------

-- 1) Long-poll: pide trabajo, lo ejecuta y confirma.
task.spawn(function()
    local backoff = 1
    while alive() do
        local query = ("/api/bridge/poll?wait=%d&placeId=%s&jobId=%s"):format(
            POLL_WAIT,
            tostring(game.PlaceId),
            tostring(game.JobId)
        )

        local pollOk, payload = httpJson("GET", query, nil, POLL_WAIT + 15)
        if not alive() then
            break
        end

        if not pollOk then
            print_("poll falló:", payload)
            task.wait(backoff)
            backoff = math.min(backoff * 2, 30)
        else
            backoff = 1
            local commands = payload.commands or {}
            -- Un ack por comando, no uno al final: con lotes largos (y
            -- los remotes van espaciados) el servidor nos daría por
            -- caídos antes de terminar. Además el panel va marcando cada
            -- orden conforme se cumple.
            for _, command in ipairs(commands) do
                httpJson("POST", "/api/bridge/ack", { results = { runCommand(command) } })
            end
            task.wait(0.1)
        end
    end
    print_("poll detenido")
end)

-- 2) Escaneo de plots, si este place lo admite.
if Scanner then
    task.spawn(function()
        while alive() do
            pushScan()
            for _ = 1, SCAN_SECONDS do
                if not alive() then
                    break
                end
                task.wait(1)
            end
        end
    end)
end

-- 3) Heartbeat + refresco periódico de la lista de jugadores.
task.spawn(function()
    while alive() do
        pushPlayers()
        for _ = 1, PLAYER_SYNC_SECONDS do
            if not alive() then
                break
            end
            task.wait(1)
        end
    end
end)

print_("controlador activo — usa getgenv().MANYSTEPS_STOP() para detenerlo")
