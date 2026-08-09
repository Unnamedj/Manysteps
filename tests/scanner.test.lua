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

game = {
    PlaceId = 78906538690694,
    GetService = function(_, name)
        if name == "Workspace" then
            return workspace_
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
print("escaneo")

local items_ = Scanner.scan()
local byName = {}
for _, entry in ipairs(items_) do
    byName[entry.name] = entry
end

check("encuentra lo colocado en los dos plots", #items_ == 3, "#items=" .. #items_)

check("saca el dueño del cartel",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].owner == "joseph",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].owner)

check("y del StringValue cuando no hay cartel",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].owner == "maria",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].owner)

check("lee la mutación del atributo",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].mutation == "Gold",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].mutation)

check("también con el nombre alternativo del atributo",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].mutation == "Diamond",
    byName["Tung Tung Sahur"] and byName["Tung Tung Sahur"].mutation)

check("sin mutación deja el hueco vacío, no 'None'",
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].mutation == "",
    byName["Bombardiro Crocodilo"] and byName["Bombardiro Crocodilo"].mutation)

check("apunta de qué plot sale cada cosa",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].plot == "Plot3",
    byName["Tralalero Tralala"] and byName["Tralalero Tralala"].plot)

----------------------------------------------------------------------
print("lo que no debe salir")

check("ni los pads de dinero", byName["CashPad"] == nil)
check("ni los colectores", byName["Collector Base"] == nil)
check("ni las cintas", byName["Conveyor"] == nil)

for _, entry in ipairs(items_) do
    check("solo texto: " .. entry.name,
        type(entry.name) == "string" and type(entry.owner) == "string"
        and type(entry.plot) == "string" and type(entry.mutation) == "string"
        and entry.Model == nil)
end

----------------------------------------------------------------------
print("sin plots")

workspace_.Children = {}
check("un mundo sin plots devuelve lista vacía", #Scanner.scan() == 0)

----------------------------------------------------------------------

print(failures == 0 and "\nTODO OK" or ("\n" .. failures .. " FALLOS"))
if failures > 0 then
    error("fallos en las pruebas del escáner", 0)
end
