--[[
    Manysteps · remotes.lua
    ------------------------------------------------------------------
    Capa de acceso a ReplicatedStorage.AdminEvents.

    Este archivo NO habla con la web: solo envuelve cada remote en una
    función con nombre, valida los argumentos y normaliza lo que devuelve
    el servidor. El puente (controller.lua) es quien decide cuándo llamar.

    Uso suelto (sin panel):
        local Remotes = loadstring(game:HttpGet(URL .. "/script/remotes.lua"))()
        Remotes.pauseTime()
        Remotes.saveJobId("....")
        Remotes.teleport(123456, 96342491571673, "....")
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
Remotes.VERSION = "1.0.0"

local FOLDER_NAME = "AdminEvents"
local WAIT_TIMEOUT = 10

local REMOTE_NAMES = {
    togglePause = "ToggleAdminTimePause",
    saveSettings = "SaveAdminSettings",
    teleport = "TeleportSelectedPlayer",
    candidates = "GetTeleportCandidates",
}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function getFolder()
    local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
    if not folder then
        folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
    end
    if not folder then
        error("No se encontró ReplicatedStorage." .. FOLDER_NAME, 0)
    end
    return folder
end

local function getRemote(name)
    local folder = getFolder()
    local remote = folder:FindFirstChild(name)
    if not remote then
        remote = folder:WaitForChild(name, WAIT_TIMEOUT)
    end
    if not remote then
        error("No se encontró el remote " .. FOLDER_NAME .. "." .. name, 0)
    end
    return remote
end

-- Los IDs llegan como texto desde la web; el juego los espera numéricos.
local function toId(value, label)
    local number = tonumber(value)
    if not number then
        error(("%s inválido: %s"):format(label, tostring(value)), 0)
    end
    return number
end

-- Y al revés: SaveAdminSettings guarda los IDs como texto. Nada de pasar
-- por tonumber y volver, que un ID de 14 cifras acaba en "9.6342e+13".
local function idToText(value, label)
    local text
    if type(value) == "number" then
        text = string.format("%.0f", value)
    else
        text = tostring(value)
    end

    if not string.match(text, "^%d+$") then
        error(("%s inválido: %s"):format(label, tostring(value)), 0)
    end
    return text
end

local function assertString(value, label)
    if type(value) ~= "string" or value == "" then
        error(("%s inválido: %s"):format(label, tostring(value)), 0)
    end
    return value
end

----------------------------------------------------------------------
-- tiempo
----------------------------------------------------------------------

--- Cambia el estado del reloj administrativo. `mode` es "pause" o "resume".
function Remotes.toggleTime(mode)
    if mode ~= "pause" and mode ~= "resume" then
        error('toggleTime espera "pause" o "resume"', 0)
    end

    local args = {
        [1] = mode,
        n = 1,
    }
    return getRemote(REMOTE_NAMES.togglePause):InvokeServer(unpack(args, 1, args.n or #args))
end

function Remotes.pauseTime()
    return Remotes.toggleTime("pause")
end

function Remotes.resumeTime()
    return Remotes.toggleTime("resume")
end

----------------------------------------------------------------------
-- ajustes guardados
----------------------------------------------------------------------

--- Guarda un ajuste arbitrario del panel de admin.
function Remotes.saveSetting(key, value)
    assertString(key, "key")

    local args = {
        [1] = key,
        [2] = value,
        n = 2,
    }
    getRemote(REMOTE_NAMES.saveSettings):FireServer(unpack(args, 1, args.n or #args))
    return true
end

--- El juego guarda el Job ID como texto.
function Remotes.saveJobId(jobId)
    return Remotes.saveSetting("savedJobId", assertString(jobId, "jobId"))
end

--- El Place ID también viaja como texto en SaveAdminSettings.
function Remotes.savePlaceId(placeId)
    return Remotes.saveSetting("savedPlaceId", idToText(placeId, "placeId"))
end

----------------------------------------------------------------------
-- teleport
----------------------------------------------------------------------

--- Manda a un jugador al place/servidor indicado.
function Remotes.teleport(userId, placeId, jobId)
    local args = {
        [1] = toId(userId, "userId"),
        [2] = toId(placeId, "placeId"),
        [3] = assertString(jobId, "jobId"),
        n = 3,
    }
    getRemote(REMOTE_NAMES.teleport):FireServer(unpack(args, 1, args.n or #args))
    return true
end

----------------------------------------------------------------------
-- candidatos
----------------------------------------------------------------------

local function readCandidate(entry)
    -- El remote puede devolver instancias Player, tablas, o IDs sueltos.
    if typeof(entry) == "Instance" and entry:IsA("Player") then
        return {
            userId = tostring(entry.UserId),
            username = entry.Name,
            displayName = entry.DisplayName,
        }
    end

    if type(entry) == "table" then
        local userId = entry.userId or entry.UserId or entry.id or entry.Id
        local username = entry.username or entry.Name or entry.name or entry.Username
        local displayName = entry.displayName or entry.DisplayName or username
        if userId == nil and username == nil then
            return nil
        end
        return {
            userId = userId ~= nil and tostring(userId) or "",
            username = username ~= nil and tostring(username) or tostring(userId),
            displayName = displayName ~= nil and tostring(displayName) or tostring(username),
        }
    end

    if type(entry) == "number" then
        return { userId = tostring(entry), username = "#" .. tostring(entry), displayName = "#" .. tostring(entry) }
    end

    return nil
end

--- Devuelve la lista de jugadores a los que se puede teletransportar,
--- ya aplanada a { userId, username, displayName }.
function Remotes.getCandidates()
    local raw = getRemote(REMOTE_NAMES.candidates):InvokeServer()
    local list = {}

    if type(raw) == "table" then
        -- Formato { [userId] = info } o { info, info, ... }: cubrimos ambos.
        for key, entry in pairs(raw) do
            local candidate = readCandidate(entry)
            if candidate then
                if candidate.userId == "" and type(key) ~= "number" then
                    candidate.userId = tostring(key)
                end
                if candidate.userId ~= "" then
                    table.insert(list, candidate)
                end
            end
        end
    end

    return list, raw
end

return Remotes
