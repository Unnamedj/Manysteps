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
local Players = game:GetService("Players")

local Remotes = {}
Remotes.VERSION = "1.1.0"

local FOLDER_NAME = "AdminEvents"
local WAIT_TIMEOUT = 10

-- El cuadro de texto del panel del juego. Es la fuente de la verdad del
-- teleport: el botón del propio panel manda JobIDBox.Text, mientras que
-- savedJobId solo se relee al abrir el panel.
local JOB_BOX_NAME = "JobIDBox"

local REMOTE_NAMES = {
    togglePause = "ToggleAdminTimePause",
    saveSettings = "SaveAdminSettings",
    teleport = "TeleportSelectedPlayer",
    teleportResult = "TeleportSelectedPlayerResult",
    candidates = "GetTeleportCandidates",
    getSettings = "GetAdminSettings",
    accessStatus = "GetAccessStatus",
}

-- Los destinos que el propio panel del juego ofrece.
Remotes.PLACES = {
    { label = "SAB New Player", placeId = "96342491571673" },
    { label = "SAB Normal", placeId = "109983668079237" },
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
    local result = getRemote(REMOTE_NAMES.togglePause):InvokeServer(unpack(args, 1, args.n or #args))

    -- El juego responde { success = bool, message = string }. Sin esto
    -- daríamos por hecho un cambio que el servidor acaba de rechazar.
    if type(result) == "table" and result.success == false then
        error(tostring(result.message or "el servidor rechazó el cambio de tiempo"), 0)
    end
    return result
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
-- el cuadro Job ID del panel del juego
----------------------------------------------------------------------

local function findJobBox()
    local player = Players.LocalPlayer
    if not player then
        return nil
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return nil
    end

    local box = playerGui:FindFirstChild(JOB_BOX_NAME, true)
    if box and box:IsA("TextBox") then
        return box
    end
    return nil
end

--- Escribe el Job ID en el cuadro del panel del juego.
--- Esto es lo que hace que el cambio se vea y que el botón Teleport del
--- propio panel use ese destino; saveJobId() solo guarda el ajuste.
function Remotes.setPanelJobId(jobId)
    assertString(jobId, "jobId")

    local box = findJobBox()
    if not box then
        error("no se encontró el cuadro " .. JOB_BOX_NAME .. " — ¿está abierto el panel?", 0)
    end

    box.Text = jobId
    return true
end

--- Lee lo que hay ahora mismo en el cuadro del panel.
function Remotes.getPanelJobId()
    local box = findJobBox()
    if not box then
        return nil
    end
    return (string.match(box.Text, "^%s*(.-)%s*$"))
end

----------------------------------------------------------------------
-- ajustes guardados en el servidor
----------------------------------------------------------------------

--- Devuelve la tabla de ajustes tal y como los tiene el juego
--- (rememberJobId, savedJobId, savedPlaceId, …).
function Remotes.getAdminSettings()
    local raw = getRemote(REMOTE_NAMES.getSettings):InvokeServer()
    if type(raw) ~= "table" then
        return {}
    end

    -- Ojo con tostring() a secas: si el juego devuelve el Place ID como
    -- número, un tostring() normal puede escupir notación científica.
    local function text(value)
        if type(value) == "number" then
            return string.format("%.0f", value)
        end
        return tostring(value or "")
    end

    return {
        rememberPlaceId = raw.rememberPlaceId == true,
        rememberJobId = raw.rememberJobId == true,
        savedPlaceId = text(raw.savedPlaceId),
        savedJobId = text(raw.savedJobId),
    }
end

----------------------------------------------------------------------
-- estado del acceso
----------------------------------------------------------------------

--- Estado real del reloj de admin, tal y como lo cuenta el servidor:
--- `{ status, remainingSeconds, paused, whitelisted, blacklisted }`.
--- Mucho mejor que deducir si está pausado por el último botón pulsado.
function Remotes.getAccessStatus()
    local raw = getRemote(REMOTE_NAMES.accessStatus):InvokeServer()
    if type(raw) ~= "table" then
        return nil
    end

    local remaining = math.max(0, tonumber(raw.remainingSeconds) or 0)
    local permanent = raw.permanentlyWhitelisted == true or raw.whitelisted == true
    local blacklisted = raw.blacklisted == true
    local paused = raw.paused == true

    -- El mismo orden de prioridades que usa el panel del juego.
    local status
    if blacklisted then
        status = "blacklisted"
    elseif permanent then
        status = "permanent"
    elseif paused and remaining > 0 then
        status = "paused"
    elseif remaining > 0 then
        status = "active"
    else
        status = "locked"
    end

    return {
        status = status,
        remainingSeconds = remaining,
        paused = paused,
        permanent = permanent,
        blacklisted = blacklisted,
    }
end

----------------------------------------------------------------------
-- teleport
----------------------------------------------------------------------

--- Avisa de cómo acabó cada teleport. El juego responde por
--- TeleportSelectedPlayerResult(userId, success, message).
function Remotes.onTeleportResult(callback)
    local remote = getRemote(REMOTE_NAMES.teleportResult)
    return remote.OnClientEvent:Connect(function(userId, success, message)
        callback({
            userId = tostring(userId or ""),
            success = success == true,
            message = tostring(message or ""),
        })
    end)
end

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
