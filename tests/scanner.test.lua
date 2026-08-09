-- Comprueba roblox/scanner.lua sobre un Workspace de mentira: que
-- encuentra los plots, saca el dueño del cartel, ignora la decoración y
-- devuelve solo texto (nada de instancias, que esto acaba en un JSON).

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
-- árbol de mentira
----------------------------------------------------------------------

local Instance_ = {}
Instance_.__index = Instance_

local function inst(className, name, props)
    local self = setmetatable({
        ClassName = className,
        Name = name,
        Children = {},
        Attributes = (props or {}).attributes or {},
        Text = (props or {}).text,
        Value = (props or {}).value,
    }, Instance_)
    return self
end

function Instance_:add(child)
    table.insert(self.Children, child)
    child.Parent = self
    return child
end

function Instance_:GetChildren()
    return self.Children
end

function Instance_:GetAttributes()
    return self.Attributes
end

function Instance_:IsA(className)
    return self.ClassName == className
end

function Instance_:FindFirstChild(name, recursive)
    for _, child in ipairs(self.Children) do
        if child.Name == name then
            return child
        end
    end
    if recursive then
        for _, child in ipairs(self.Children) do
            local found = child:FindFirstChild(name, true)
            if found then
                return found
            end
        end
    end
    return nil
end

function Instance_:FindFirstChildWhichIsA(className, recursive)
    for _, child in ipairs(self.Children) do
        if child:IsA(className) then
            return child
        end
    end
    if recursive then
        for _, child in ipairs(self.Children) do
            local found = child:FindFirstChildWhichIsA(className, true)
            if found then
                return found
            end
        end
    end
    return nil
end

function Instance_:GetDescendants()
    local out = {}
    for _, child in ipairs(self.Children) do
        table.insert(out, child)
        for _, deep in ipairs(child:GetDescendants()) do
            table.insert(out, deep)
        end
    end
    return out
end

----------------------------------------------------------------------
-- el mundo de prueba
----------------------------------------------------------------------

local workspace_ = inst("Workspace", "Workspace")
local plots = workspace_:add(inst("Folder", "Plots"))

-- Plot con cartel y carpeta de objetos.
local plot3 = plots:add(inst("Model", "Plot3"))
local sign = plot3:add(inst("Part", "PlotSign"))
local surface = sign:add(inst("SurfaceGui", "Gui"))
surface:add(inst("TextLabel", "Label", { text = "joseph's Base" }))

local items = plot3:add(inst("Folder", "Items"))
items:add(inst("Model", "Tralalero Tralala", { attributes = { Mutation = "Gold" } }))
items:add(inst("Model", "Bombardiro Crocodilo"))
items:add(inst("Part", "CashPad"))            -- decoración: fuera
items:add(inst("Model", "Collector Base"))    -- decoración: fuera

-- Plot sin carpeta reconocible: se mira lo que cuelga de él.
local plot7 = plots:add(inst("Model", "Plot7"))
local owner = plot7:add(inst("StringValue", "Owner", { value = "maria" }))
owner.ClassName = "StringValue"
plot7:add(inst("Model", "Tung Tung Sahur", { attributes = { __mutation = "Diamond" } }))
plot7:add(inst("Model", "Conveyor"))          -- decoración: fuera

-- Plot vacío y sin dueño.
plots:add(inst("Model", "Plot1"))

----------------------------------------------------------------------
-- el Synchronizer del juego, con sus upvalues de verdad
----------------------------------------------------------------------

-- La tabla de canales es un upvalue real de Get: el escáner tiene que
-- sacarla con debug.getupvalue, igual que hará en el juego.
local channels = {
    Plot3 = {
        CacheTable = {
            Owner = "joseph",
            AnimalList = {
                [1] = { Index = "Tralalero Tralala", Mutation = "Gold", Traits = { "Fast" } },
                [2] = { Index = "Bombardiro Crocodilo" },
            },
        },
    },
    Plot7 = {
        CacheTable = {
            Owner = "maria",
            AnimalList = {
                [4] = { Index = "Tung Tung Sahur", Mutation = "Diamond", Traits = { "Fast", "Lucky" } },
            },
        },
    },
    PlotVacio = {
        CacheTable = { Owner = "nadie", AnimalList = {} },
    },
}

local Synchronizer = {
    Get = function()
        return channels
    end,
}

local AnimalsData = {
    ["Tralalero Tralala"] = { Generation = 100 },
    ["Bombardiro Crocodilo"] = { Generation = 50 },
    ["Tung Tung Sahur"] = { Generation = 200 },
}
local MutationsData = {
    Gold = { Modifier = 1.5 },
    Diamond = { Modifier = 3 },
}
local TraitsData = {
    Fast = { MultiplierModifier = 0.5 },
    Lucky = { MultiplierModifier = 1 },
}

local modulesByName = {
    Synchronizer = Synchronizer,
    Animals = AnimalsData,
    Mutations = MutationsData,
    Traits = TraitsData,
}

local moduleScripts = {}
local function moduleScript(name)
    if not moduleScripts[name] then
        local m = inst("ModuleScript", name)
        m.__module = modulesByName[name]
        moduleScripts[name] = m
    end
    return moduleScripts[name]
end

local replicated = inst("ReplicatedStorage", "ReplicatedStorage")
local packages = replicated:add(inst("Folder", "Packages"))
packages:add(moduleScript("Synchronizer"))
local datas = replicated:add(inst("Folder", "Datas"))
datas:add(moduleScript("Animals"))
datas:add(moduleScript("Mutations"))
datas:add(moduleScript("Traits"))

-- require de mentira: devuelve lo que cuelga del ModuleScript.
local realRequire = require
require = function(target)
    if type(target) == "table" and target.__module ~= nil then
        return target.__module
    end
    return realRequire(target)
end

game = {
    PlaceId = 78906538690694,
    GetService = function(_, name)
        if name == "Workspace" then
            return workspace_
        end
        if name == "ReplicatedStorage" then
            return replicated
        end
        error("servicio no mockeado: " .. name)
    end,
}

----------------------------------------------------------------------

local Scanner = assert(load(SCANNER_SRC, "scanner"))()

print("place")
check("reconoce el place del escáner", Scanner.isSupportedPlace())

game.PlaceId = 101017811878308
check("y descarta cualquier otro", not Scanner.isSupportedPlace())
game.PlaceId = 78906538690694

----------------------------------------------------------------------
print("escaneo por el Synchronizer")

local items_, source = Scanner.scan()
check("usa la caché del juego, no el barrido", source == "synchronizer", source)
local byName = {}
for _, entry in ipairs(items_) do
    byName[entry.name] = entry
end

check("encuentra lo colocado en los dos plots", #items_ == 3, "#items=" .. #items_)

check("saca el dueño de la caché",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].owner == "joseph",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].owner)

check("y el de cada canal por separado",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].owner == "maria",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].owner)

check("lee la mutación",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].mutation == "Gold",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].mutation)

check("sin mutación deja el hueco vacío",
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].mutation == "",
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].mutation)

check("apunta el plot y el slot",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].plot == "Plot7"
    and byName["Tung Tung Sahur"].slot == 4,
    byName["Tung Tung Sahur"] and (byName["Tung Tung Sahur"].plot .. "/" .. tostring(byName["Tung Tung Sahur"].slot)))

check("trae los traits",
    byName["Tung Tung Sahur"] and #byName["Tung Tung Sahur"].traits == 2,
    byName["Tung Tung Sahur"] and #byName["Tung Tung Sahur"].traits)

check("un plot vacío no aparece", byName["nadie"] == nil)

----------------------------------------------------------------------
print("generación")

-- Tralalero: 100 base × (1 + 1.5 de Gold + 0.5 de Fast) = 300
check("base por mutación y traits",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].generation == 300,
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].generation)

-- Bombardiro: 50 base, sin nada = 50
check("sin mutación ni traits es la base",
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].generation == 50,
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].generation)

-- Tung Tung: 200 × (1 + 3 de Diamond + 0.5 de Fast + 1 de Lucky) = 1100
check("suma todos los traits",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].generation == 1100,
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].generation)

----------------------------------------------------------------------
print("solo datos")

for _, entry in ipairs(items_) do
    check("nada de instancias en " .. entry.name,
        type(entry.name) == "string" and type(entry.owner) == "string"
        and type(entry.plot) == "string" and type(entry.mutation) == "string"
        and type(entry.generation) == "number" and type(entry.traits) == "table"
        and entry.Model == nil and entry.Instance == nil)
end

----------------------------------------------------------------------
print("respaldo sin Synchronizer")

-- Sin canales que leer (otra versión del juego, o el paquete cambiado)
-- se cae al barrido del Workspace.
for key in next, channels do
    channels[key] = nil
end

local fallback, fallbackSource = Scanner.scan()
check("avisa de que va por el respaldo", fallbackSource == "workspace", fallbackSource)

local byNameFallback = {}
for _, entry in ipairs(fallback) do
    byNameFallback[entry.name] = entry
end

check("y aun así encuentra lo del Workspace",
    byNameFallback["Tralalero Tralala"] ~= nil and byNameFallback["Tung Tung Sahur"] ~= nil)
check("con el dueño del cartel",
    byNameFallback["Tralalero Tralala"] and byNameFallback["Tralalero Tralala"].owner == "joseph",
    byNameFallback["Tralalero Tralala"] and byNameFallback["Tralalero Tralala"].owner)
check("descartando la decoración", byNameFallback["CashPad"] == nil
    and byNameFallback["Collector Base"] == nil and byNameFallback["Conveyor"] == nil)

----------------------------------------------------------------------
print("sin nada que leer")

workspace_.Children = {}
check("sin plots ni caché devuelve lista vacía", #Scanner.scan() == 0)

----------------------------------------------------------------------

print(failures == 0 and "\nTODO OK" or ("\n" .. failures .. " FALLOS"))
if failures > 0 then
    error("fallos en las pruebas del escáner", 0)
end
