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
local function httpJson(method, pathname, body, timeoutHint)
    local options = {
        Url = BASE_URL .. pathname,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["x-bridge-key"] = BRIDGE_KEY,
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
-- jugadores
----------------------------------------------------------------------

local function pushPlayers()
    local ok, list = pcall(Remotes.getCandidates)
    if not ok then
        report("error", "GetTeleportCandidates falló: " .. tostring(list))
        return false, tostring(list)
    end
    httpJson("POST", "/api/bridge/players", { players = list })
    return true, list
end

----------------------------------------------------------------------
-- comandos
----------------------------------------------------------------------

local handlers = {
    ["time.pause"] = function()
        return { state = Remotes.pauseTime() }
    end,

    ["time.resume"] = function()
        return { state = Remotes.resumeTime() }
    end,

    ["settings.jobId"] = function(payload)
        Remotes.saveJobId(payload.jobId)
        return { jobId = payload.jobId }
    end,

    ["settings.placeId"] = function(payload)
        Remotes.savePlaceId(payload.placeId)
        return { placeId = payload.placeId }
    end,

    ["teleport.send"] = function(payload)
        Remotes.teleport(payload.userId, payload.placeId, payload.jobId)
        return { userId = payload.userId }
    end,

    ["players.refresh"] = function()
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
            if #commands > 0 then
                local results = {}
                for _, command in ipairs(commands) do
                    table.insert(results, runCommand(command))
                    task.wait(0.05) -- respiro entre remotes seguidos
                end
                httpJson("POST", "/api/bridge/ack", { results = results })
            end
            task.wait(0.1)
        end
    end
    print_("poll detenido")
end)

-- 2) Heartbeat + refresco periódico de la lista de jugadores.
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
