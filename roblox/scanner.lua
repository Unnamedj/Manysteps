--[[
    Manysteps · scanner.lua
    ------------------------------------------------------------------
    Lee qué hay en cada plot y de quién es. Nada más: ni ESP, ni
    billboards, ni bucles de render. El bridge manda la lista al panel y
    el panel la enseña.

    La fuente buena es el paquete Synchronizer del propio juego: dentro
    de los upvalues de su `Get` está la tabla de canales, y cada canal
    lleva su CacheTable con el dueño del plot y su AnimalList. De ahí
    salen el slot, el animal, la mutación, los traits y la generación
    calculada con los datos del juego — bastante más de lo que se puede
    deducir mirando modelos sueltos en el Workspace.

    Si ese paquete no está (otro juego, otra versión), se cae al barrido
    del Workspace, que da menos pero algo da.

    Solo trabaja en el place indicado en Scanner.PLACE_ID.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Scanner = {}
Scanner.VERSION = "2.0.0"

--- El único place donde tiene sentido escanear.
Scanner.PLACE_ID = "78906538690694"

--- Tope de resultados: el panel no necesita más y el JSON tampoco.
local MAX_RESULTS = 400

----------------------------------------------------------------------
-- módulos del juego
----------------------------------------------------------------------

local function safeRequire(instance)
    if not instance then
        return nil
    end
    local ok, result = pcall(require, instance)
    return ok and result or nil
end

local function findChild(parent, name)
    if not parent then
        return nil
    end
    return parent:FindFirstChild(name)
end

--- Todo lo que hace falta para leer y valorar la caché.
local function loadGameModules()
    local packages = findChild(ReplicatedStorage, "Packages")
    local datas = findChild(ReplicatedStorage, "Datas")

    return {
        sync = safeRequire(findChild(packages, "Synchronizer")),
        animals = safeRequire(findChild(datas, "Animals")),
        mutations = safeRequire(findChild(datas, "Mutations")),
        traits = safeRequire(findChild(datas, "Traits")),
    }
end

----------------------------------------------------------------------
-- la tabla de canales, escondida en los upvalues de Get
----------------------------------------------------------------------

local function readUpvalues(fn)
    local reader = getupvalues or (debug and debug.getupvalues)
    if reader then
        local ok, values = pcall(reader, fn)
        if ok and type(values) == "table" then
            return values
        end
    end

    -- Sin lector de golpe, se van sacando de uno en uno.
    if not (debug and debug.getupvalue) then
        return nil
    end

    local values = {}
    for index = 1, 128 do
        local ok, _, value = pcall(debug.getupvalue, fn, index)
        if not ok or value == nil then
            break
        end
        values[index] = value
    end
    return values
end

local function looksLikeChannels(candidate)
    if type(candidate) ~= "table" then
        return false
    end
    for _, value in next, candidate do
        if type(value) == "table" and rawget(value, "CacheTable") then
            return true
        end
    end
    return false
end

--- Busca la tabla de canales entre los upvalues, y un nivel más abajo.
local function findChannels(sync)
    if type(sync) ~= "table" or type(sync.Get) ~= "function" then
        return nil
    end

    local upvalues = readUpvalues(sync.Get)
    if type(upvalues) ~= "table" then
        return nil
    end

    local found = nil
    pcall(function()
        for _, upvalue in next, upvalues do
            if type(upvalue) == "table" then
                if looksLikeChannels(upvalue) then
                    found = upvalue
                    return
                end

                for _, nested in next, upvalue do
                    if looksLikeChannels(nested) then
                        found = nested
                        return
                    end
                end
            end
        end
    end)

    return found
end

----------------------------------------------------------------------
-- cuánto genera cada bicho
----------------------------------------------------------------------

--- Base del animal por su multiplicador de mutación y traits, igual que
--- lo calcula el juego.
local function generationOf(entry, modules)
    local index = rawget(entry, "Index")
    if not index then
        return 0
    end

    local animal = modules.animals and modules.animals[index]
    local base = animal and rawget(animal, "Generation") or 0
    local multiplier = 1

    local mutationName = rawget(entry, "Mutation")
    if mutationName and modules.mutations then
        local mutation = modules.mutations[mutationName]
        if mutation then
            multiplier = multiplier + (rawget(mutation, "Modifier") or 0)
        end
    end

    local traits = rawget(entry, "Traits")
    if type(traits) == "table" and modules.traits then
        for _, traitName in next, traits do
            local trait = modules.traits[traitName]
            if trait then
                multiplier = multiplier + (rawget(trait, "MultiplierModifier") or 0)
            end
        end
    end

    return base * multiplier
end

local function traitNames(entry)
    local traits = rawget(entry, "Traits")
    if type(traits) ~= "table" then
        return {}
    end

    local names = {}
    for _, value in next, traits do
        table.insert(names, tostring(value))
    end
    return names
end

----------------------------------------------------------------------
-- lectura desde el Synchronizer
----------------------------------------------------------------------

local function scanFromSynchronizer(modules)
    local channels = findChannels(modules.sync)
    if not channels then
        return nil
    end

    local results = {}

    for channelName, channelData in next, channels do
        if type(channelData) == "table" and #results < MAX_RESULTS then
            local cache = rawget(channelData, "CacheTable")
            local animals = type(cache) == "table" and rawget(cache, "AnimalList") or nil

            if type(animals) == "table" then
                local owner = tostring(rawget(cache, "Owner") or "Unclaimed")

                for slot, entry in next, animals do
                    if type(entry) == "table" and rawget(entry, "Index") and #results < MAX_RESULTS then
                        local mutation = rawget(entry, "Mutation")

                        table.insert(results, {
                            name = tostring(rawget(entry, "Index")),
                            plot = tostring(channelName),
                            owner = owner,
                            slot = tonumber(slot) or 0,
                            mutation = mutation and tostring(mutation) or "",
                            traits = traitNames(entry),
                            generation = generationOf(entry, modules),
                        })
                    end
                end
            end
        end
    end

    return results
end

----------------------------------------------------------------------
-- respaldo: barrido del Workspace
----------------------------------------------------------------------

local BLACKLIST = {
    "cashpad", "cash", "collector", "collect", "dropper", "upgrader", "dispenser",
    "atm", "pad", "button", "giver", "money", "rebirth", "floor", "wall", "door",
    "roof", "base", "baseplate", "spawn", "claim", "sign", "plotsign", "plotowner",
    "barrier", "grid", "border", "texture", "part", "light", "wedge", "truss",
    "hitbox", "collider", "purchased", "conveyor", "prompt", "proximity", "sell", "buy",
}

local function isBlacklisted(name)
    local lowered = string.gsub(string.lower(name), "%s+", "")
    for _, word in ipairs(BLACKLIST) do
        if string.find(lowered, word, 1, true) then
            return true
        end
    end
    return false
end

local PLOT_CONTAINERS = { "Plots", "Tycoons", "Bases", "PlayerPlots", "PlotFolder" }
local ITEM_FOLDERS = { "Items", "Brainrots", "Displays", "Placed", "Objects", "Podiums", "Animals", "Pets" }

local function getPlots()
    local plots = {}

    for _, name in ipairs(PLOT_CONTAINERS) do
        local folder = Workspace:FindFirstChild(name)
        if folder then
            for _, child in ipairs(folder:GetChildren()) do
                table.insert(plots, child)
            end
        end
    end

    if #plots == 0 then
        for _, child in ipairs(Workspace:GetChildren()) do
            local lowered = string.lower(child.Name)
            if string.find(lowered, "plot") or string.find(lowered, "tycoon") or string.find(lowered, "base") then
                table.insert(plots, child)
            end
        end
    end

    return plots
end

local function getPlotOwner(plot)
    local sign = plot:FindFirstChild("PlotSign") or plot:FindFirstChild("Sign")
    if sign then
        local gui = sign:FindFirstChildWhichIsA("SurfaceGui", true)
        if gui then
            local textLabel = gui:FindFirstChildWhichIsA("TextLabel", true)
            local text = textLabel and textLabel.Text or nil
            if text and text ~= "" and not string.find(string.lower(text), "empty") then
                return string.match(text, "^(.+)'s Base$")
                    or string.match(text, "^(.+)'s Plot$")
                    or text
            end
        end
    end

    local ownerValue = plot:FindFirstChild("Owner")
        or plot:FindFirstChild("PlotOwner")
        or plot:FindFirstChild("Player")

    if ownerValue then
        if ownerValue:IsA("StringValue") and ownerValue.Value ~= "" then
            return ownerValue.Value
        elseif ownerValue:IsA("ObjectValue") and ownerValue.Value then
            return ownerValue.Value.Name
        end
    end

    return "Unclaimed"
end

local function readMutation(instance)
    local ok, attributes = pcall(instance.GetAttributes, instance)
    if not ok or type(attributes) ~= "table" then
        return ""
    end

    local mutation = attributes.Mutation or attributes.__mutation
    if mutation == nil or mutation == "None" or mutation == "" then
        return ""
    end
    return tostring(mutation)
end

local function scanFromWorkspace()
    local results = {}

    for _, plot in ipairs(getPlots()) do
        local ownerOk, owner = pcall(getPlotOwner, plot)
        if not ownerOk then
            owner = "Unclaimed"
        end

        local foundInFolder = false

        for _, folderName in ipairs(ITEM_FOLDERS) do
            local folder = plot:FindFirstChild(folderName, true)
            if folder then
                for _, child in ipairs(folder:GetChildren()) do
                    local isItem = child:IsA("Model") or child:IsA("BasePart") or child:IsA("Tool")
                    if isItem and not isBlacklisted(child.Name) then
                        foundInFolder = true
                        if #results < MAX_RESULTS then
                            table.insert(results, {
                                name = child.Name,
                                plot = plot.Name,
                                owner = owner,
                                slot = 0,
                                mutation = readMutation(child),
                                traits = {},
                                generation = 0,
                            })
                        end
                    end
                end
            end
        end

        if not foundInFolder then
            for _, descendant in ipairs(plot:GetDescendants()) do
                local isItem = descendant:IsA("Model") or descendant:IsA("Tool")
                local parent = descendant.Parent
                local directChild = parent == plot or (parent and parent:IsA("Folder"))

                if isItem and directChild and not isBlacklisted(descendant.Name) then
                    if #results < MAX_RESULTS then
                        table.insert(results, {
                            name = descendant.Name,
                            plot = plot.Name,
                            owner = owner,
                            slot = 0,
                            mutation = readMutation(descendant),
                            traits = {},
                            generation = 0,
                        })
                    end
                end
            end
        end
    end

    return results
end

----------------------------------------------------------------------
-- API
----------------------------------------------------------------------

--- Devuelve `items, fuente`. Solo texto y números: nada de instancias,
--- que esto acaba viajando como JSON.
function Scanner.scan()
    local modules = loadGameModules()

    local fromSync = scanFromSynchronizer(modules)
    if fromSync and #fromSync > 0 then
        return fromSync, "synchronizer"
    end

    return scanFromWorkspace(), "workspace"
end

--- ¿Estamos en el juego donde este escaneo significa algo?
function Scanner.isSupportedPlace()
    return string.format("%.0f", game.PlaceId) == Scanner.PLACE_ID
end

return Scanner
