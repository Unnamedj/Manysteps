--[[
    Manysteps · scanner.lua
    ------------------------------------------------------------------
    Recorre los plots del juego y devuelve qué hay en cada uno y de quién
    es. Nada más: ni ESP, ni billboards, ni bucles de render. El bridge
    manda esa lista al panel y el panel la enseña.

    Solo trabaja en el place indicado en SCAN_PLACE_ID; en cualquier otro
    devuelve nada, porque los nombres de carpetas que busca solo existen
    allí.
--]]

local Workspace = game:GetService("Workspace")

local Scanner = {}
Scanner.VERSION = "1.0.0"

--- El único place donde tiene sentido escanear.
Scanner.PLACE_ID = "78906538690694"

--- Tope de resultados: el panel no necesita más y el JSON tampoco.
local MAX_RESULTS = 400

----------------------------------------------------------------------
-- qué no es un objeto de plot
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

----------------------------------------------------------------------
-- plots y dueños
----------------------------------------------------------------------

local PLOT_CONTAINERS = { "Plots", "Tycoons", "Bases", "PlayerPlots", "PlotFolder" }

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

    -- Sin carpeta conocida, se buscan por nombre en la raíz.
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

----------------------------------------------------------------------
-- escaneo
----------------------------------------------------------------------

local ITEM_FOLDERS = { "Items", "Brainrots", "Displays", "Placed", "Objects", "Podiums", "Animals", "Pets" }

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

--- Devuelve `{ name, plot, owner, mutation }` por cada cosa colocada.
--- Solo texto: nada de instancias, que esto acaba viajando como JSON.
function Scanner.scan()
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
                                mutation = readMutation(child),
                            })
                        end
                    end
                end
            end
        end

        -- Sin carpeta reconocible, se mira lo que cuelga del propio plot.
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
                            mutation = readMutation(descendant),
                        })
                    end
                end
            end
        end
    end

    return results
end

--- ¿Estamos en el juego donde este escaneo significa algo?
function Scanner.isSupportedPlace()
    return string.format("%.0f", game.PlaceId) == Scanner.PLACE_ID
end

return Scanner
