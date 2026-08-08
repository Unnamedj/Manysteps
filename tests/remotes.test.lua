-- Harness: mockea Roblox y comprueba los argumentos exactos de cada remote.
unpack = unpack or table.unpack

local calls = {}

local function makeRemote(name)
    return {
        _name = name,
        InvokeServer = function(self, ...)
            local args = table.pack(...)
            table.insert(calls, { remote = name, method = "InvokeServer", args = args })
            if name == "GetTeleportCandidates" then
                return _G.__CANDIDATES
            end
            if name == "GetAdminSettings" then
                return _G.__SETTINGS
            end
            if name == "ToggleAdminTimePause" then
                return _G.__TOGGLE_RESULT
            end
            return "server-ok"
        end,
        FireServer = function(self, ...)
            local args = table.pack(...)
            table.insert(calls, { remote = name, method = "FireServer", args = args })
        end,
    }
end

local folder = {
    ToggleAdminTimePause = makeRemote("ToggleAdminTimePause"),
    SaveAdminSettings = makeRemote("SaveAdminSettings"),
    TeleportSelectedPlayer = makeRemote("TeleportSelectedPlayer"),
    TeleportSelectedPlayerResult = makeRemote("TeleportSelectedPlayerResult"),
    GetTeleportCandidates = makeRemote("GetTeleportCandidates"),
    GetAdminSettings = makeRemote("GetAdminSettings"),
}
folder.FindFirstChild = function(self, name) return self[name] end
folder.WaitForChild = function(self, name) return self[name] end

local replicatedStorage = {
    AdminEvents = folder,
    FindFirstChild = function(self, name) return self[name] end,
    WaitForChild = function(self, name) return self[name] end,
}

-- El cuadro Job ID del panel del juego, colgando del PlayerGui.
local jobBox = {
    __instance = true,
    Name = "JobIDBox",
    Text = "",
    IsA = function(self, class) return class == "TextBox" end,
}

local playerGui = {
    __instance = true,
    FindFirstChild = function(self, name, recursive)
        if name == "JobIDBox" and recursive then return _G.__JOB_BOX end
        return nil
    end,
}
_G.__JOB_BOX = jobBox

local localPlayer = {
    UserId = 1,
    Name = "tester",
    FindFirstChildOfClass = function(self, class)
        if class == "PlayerGui" then return playerGui end
        return nil
    end,
}

game = {
    GetService = function(self, name)
        if name == "ReplicatedStorage" then return replicatedStorage end
        if name == "Players" then return { LocalPlayer = localPlayer } end
        error("servicio no mockeado: " .. name)
    end,
}

typeof = function(v)
    if type(v) == "table" and v.__instance then return "Instance" end
    return type(v)
end

----------------------------------------------------------------------

local Remotes = assert(load(REMOTES_SRC, "remotes"))()

local failures = 0
local function check(label, ok, detail)
    if ok then
        print("  ok   " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. "  → " .. tostring(detail))
    end
end

local function last()
    return calls[#calls]
end

local function describeArgs(c)
    local parts = {}
    for i = 1, c.args.n do
        local v = c.args[i]
        parts[#parts + 1] = string.format("%s(%s)", type(v), tostring(v))
    end
    return table.concat(parts, ", ")
end

----------------------------------------------------------------------
print("tiempo")

Remotes.pauseTime()
local c = last()
check("pause → ToggleAdminTimePause:InvokeServer('pause')",
    c.remote == "ToggleAdminTimePause" and c.method == "InvokeServer"
    and c.args.n == 1 and c.args[1] == "pause", describeArgs(c))

Remotes.resumeTime()
c = last()
check("resume → InvokeServer('resume')",
    c.args.n == 1 and c.args[1] == "resume", describeArgs(c))

check("toggleTime rechaza modos raros", not pcall(Remotes.toggleTime, "stop"))

----------------------------------------------------------------------
print("ajustes")

Remotes.saveJobId("7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88")
c = last()
check("jobId → SaveAdminSettings:FireServer('savedJobId', <string>)",
    c.remote == "SaveAdminSettings" and c.method == "FireServer" and c.args.n == 2
    and c.args[1] == "savedJobId" and c.args[2] == "7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88"
    and type(c.args[2]) == "string", describeArgs(c))

Remotes.savePlaceId("96342491571673")
c = last()
check("placeId → FireServer('savedPlaceId', '96342491571673') como string",
    c.args.n == 2 and c.args[1] == "savedPlaceId"
    and c.args[2] == "96342491571673" and type(c.args[2]) == "string", describeArgs(c))

check("savePlaceId rechaza texto no numérico", not pcall(Remotes.savePlaceId, "abc"))

Remotes.savePlaceId(96342491571673)
c = last()
check("placeId numérico tampoco se convierte en notación científica",
    c.args[2] == "96342491571673", describeArgs(c))
check("saveJobId rechaza vacío", not pcall(Remotes.saveJobId, ""))

----------------------------------------------------------------------
print("teleport")

Remotes.teleport("123456789", "96342491571673", "7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88")
c = last()
check("teleport → FireServer(number, number, string)",
    c.remote == "TeleportSelectedPlayer" and c.method == "FireServer" and c.args.n == 3
    and c.args[1] == 123456789 and type(c.args[1]) == "number"
    and c.args[2] == 96342491571673 and type(c.args[2]) == "number"
    and c.args[3] == "7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88" and type(c.args[3]) == "string",
    describeArgs(c))

check("placeId grande sin pérdida de precisión", c.args[2] == 96342491571673,
    string.format("%.0f", c.args[2]))
check("teleport rechaza userId inválido",
    not pcall(Remotes.teleport, "x", "96342491571673", "job"))
check("teleport rechaza jobId vacío",
    not pcall(Remotes.teleport, "1", "2", ""))

----------------------------------------------------------------------
print("cuadro del panel")

Remotes.setPanelJobId("7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88")
check("setPanelJobId escribe en el TextBox del juego",
    jobBox.Text == "7f3a91c2-8b44-4d1e-9a02-5c6e1d0f4b88", jobBox.Text)

jobBox.Text = "  con-espacios  "
check("getPanelJobId recorta espacios", Remotes.getPanelJobId() == "con-espacios",
    Remotes.getPanelJobId())

check("setPanelJobId rechaza vacío", not pcall(Remotes.setPanelJobId, ""))

_G.__JOB_BOX = nil
local boxOk, boxErr = pcall(Remotes.setPanelJobId, "algo")
check("sin cuadro avisa de que el panel no está",
    not boxOk and tostring(boxErr):find("JobIDBox") ~= nil, boxErr)
check("getPanelJobId sin cuadro devuelve nil", Remotes.getPanelJobId() == nil)
_G.__JOB_BOX = jobBox

----------------------------------------------------------------------
print("ajustes del servidor")

_G.__SETTINGS = {
    rememberJobId = true,
    rememberPlaceId = false,
    savedJobId = "abc-123",
    savedPlaceId = 96342491571673,
}
local settings = Remotes.getAdminSettings()
check("getAdminSettings normaliza la tabla del juego",
    settings.rememberJobId == true and settings.rememberPlaceId == false
    and settings.savedJobId == "abc-123" and settings.savedPlaceId == "96342491571673",
    settings.savedPlaceId)

_G.__SETTINGS = nil
check("getAdminSettings tolera respuesta vacía",
    type(Remotes.getAdminSettings()) == "table")

----------------------------------------------------------------------
print("tiempo rechazado por el servidor")

_G.__TOGGLE_RESULT = { success = false, message = "You cannot teleport anyone while paused." }
local pauseOk, pauseErr = pcall(Remotes.pauseTime)
check("un success=false se convierte en error, no en 'hecho'",
    not pauseOk and tostring(pauseErr):find("cannot teleport") ~= nil, pauseErr)

_G.__TOGGLE_RESULT = { success = true }
check("success=true pasa sin ruido", (pcall(Remotes.pauseTime)))
_G.__TOGGLE_RESULT = nil

----------------------------------------------------------------------
print("candidatos")

_G.__CANDIDATES = {
    { UserId = 111, Name = "alfa", DisplayName = "Alfa" },
    { userId = 222, username = "beta" },
    { __instance = true, UserId = 333, Name = "gamma", DisplayName = "Gamma",
      IsA = function(self, class) return class == "Player" end },
    444,
}
local list = Remotes.getCandidates()
local byId = {}
for _, p in ipairs(list) do byId[p.userId] = p end

check("normaliza 4 formatos distintos", #list == 4, "#list=" .. #list)
check("UserId/Name/DisplayName", byId["111"] and byId["111"].username == "alfa"
    and byId["111"].displayName == "Alfa")
check("userId/username sin displayName", byId["222"] and byId["222"].displayName == "beta")
check("instancia Player", byId["333"] and byId["333"].displayName == "Gamma")
check("id suelto", byId["444"] and byId["444"].username == "#444")

_G.__CANDIDATES = { ["555"] = { username = "delta" } }
list = Remotes.getCandidates()
check("tabla indexada por userId", #list == 1 and list[1].userId == "555"
    and list[1].username == "delta")

_G.__CANDIDATES = nil
list = Remotes.getCandidates()
check("respuesta vacía → lista vacía", #list == 0)

----------------------------------------------------------------------
print("errores")

replicatedStorage.AdminEvents = nil
local ok, err = pcall(Remotes.pauseTime)
check("sin AdminEvents da un error legible",
    not ok and tostring(err):find("AdminEvents") ~= nil, err)

print(failures == 0 and "\nTODO OK" or ("\n" .. failures .. " FALLOS"))
if failures > 0 then error("fallos en las pruebas", 0) end
