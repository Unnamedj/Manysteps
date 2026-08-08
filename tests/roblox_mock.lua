--[[
    Mock mínimo de Roblox para poder ejecutar los scripts de UI fuera del
    juego: instancias, eventos, tweens, tipos y HTTP.

    No pretende imitar a Roblox de verdad. Solo lo justo para que el
    script se cargue, para poder disparar los clics a mano y para ver qué
    peticiones manda.
--]]

local mock = {}

----------------------------------------------------------------------
-- tipos
----------------------------------------------------------------------

local enumCache = {}
Enum = setmetatable({}, {
    __index = function(self, category)
        if not enumCache[category] then
            enumCache[category] = setmetatable({}, {
                __index = function(items, item)
                    local value = category .. "." .. item
                    rawset(items, item, value)
                    return value
                end,
            })
            rawset(self, category, enumCache[category])
        end
        return enumCache[category]
    end,
})

UDim = {}
function UDim.new(scale, offset)
    return { Scale = scale or 0, Offset = offset or 0 }
end

UDim2 = {}
function UDim2.new(xScale, xOffset, yScale, yOffset)
    return {
        X = UDim.new(xScale, xOffset),
        Y = UDim.new(yScale, yOffset),
    }
end
function UDim2.fromOffset(x, y)
    return UDim2.new(0, x, 0, y)
end
function UDim2.fromScale(x, y)
    return UDim2.new(x, 0, y, 0)
end

Color3 = {}
function Color3.fromRGB(r, g, b)
    return { R = r / 255, G = g / 255, B = b / 255 }
end

TweenInfo = {}
function TweenInfo.new()
    return {}
end

----------------------------------------------------------------------
-- instancias y eventos
----------------------------------------------------------------------

local EVENT_NAMES = {
    MouseButton1Click = true,
    MouseButton1Down = true,
    MouseEnter = true,
    MouseLeave = true,
    Focused = true,
    FocusLost = true,
    InputBegan = true,
    InputChanged = true,
    InputEnded = true,
    Changed = true,
    Activated = true,
}

mock.instances = {}

local function makeEvent()
    local handlers = {}
    return {
        __handlers = handlers,
        Connect = function(_, callback)
            table.insert(handlers, callback)
            return { Disconnect = function() end }
        end,
    }
end

local function newInstance(className)
    local events = {}
    local propertySignals = {}
    local instance

    local fields = {
        ClassName = className,
        Name = className,
        Text = "",
        Visible = true,
        Parent = nil,
    }

    local proxy = setmetatable({}, {
        __index = function(_, key)
            if fields[key] ~= nil then
                return fields[key]
            end

            if EVENT_NAMES[key] then
                events[key] = events[key] or makeEvent()
                return events[key]
            end

            if key == "Destroy" then
                return function()
                    fields.__destroyed = true
                end
            end

            if key == "GetPropertyChangedSignal" then
                return function(_, property)
                    propertySignals[property] = propertySignals[property] or makeEvent()
                    return propertySignals[property]
                end
            end

            if key == "__events" then
                return events
            end
            if key == "__fields" then
                return fields
            end

            return nil
        end,

        __newindex = function(_, key, value)
            fields[key] = value
            local signal = propertySignals[key]
            if signal then
                for _, callback in ipairs(signal.__handlers) do
                    callback()
                end
            end
        end,
    })

    instance = proxy
    table.insert(mock.instances, proxy)
    return proxy
end

Instance = {}
function Instance.new(className)
    return newInstance(className)
end

--- Dispara un evento sobre una instancia, como haría un clic real.
function mock.fire(instance, eventName, ...)
    local events = instance.__events
    local event = events and events[eventName]
    if not event then
        return false
    end
    for _, callback in ipairs(event.__handlers) do
        callback(...)
    end
    return true
end

--- Busca la primera instancia cuyo texto sea exactamente el dado.
function mock.findByText(text)
    for _, instance in ipairs(mock.instances) do
        if instance.Text == text then
            return instance
        end
    end
    return nil
end

--- Busca por Name. Es lo que hay que usar para los botones: su Text
--- suele estar en una etiqueta hija, no en el botón.
function mock.findByName(name)
    for _, instance in ipairs(mock.instances) do
        if instance.Name == name then
            return instance
        end
    end
    return nil
end

function mock.findAllByName(name)
    local found = {}
    for _, instance in ipairs(mock.instances) do
        if instance.Name == name then
            table.insert(found, instance)
        end
    end
    return found
end

function mock.findAllByClass(className)
    local found = {}
    for _, instance in ipairs(mock.instances) do
        if instance.ClassName == className then
            table.insert(found, instance)
        end
    end
    return found
end

----------------------------------------------------------------------
-- servicios
----------------------------------------------------------------------

local playerGui = newInstance("PlayerGui")

local services = {
    HttpService = {
        JSONEncode = function(_, value)
            _G.__LAST_BODY = value
            return "<json>"
        end,
        JSONDecode = function()
            return _G.__NEXT_RESPONSE
        end,
    },
    Players = {
        LocalPlayer = setmetatable({
            UserId = 7,
            Name = "operador",
            WaitForChild = function()
                return playerGui
            end,
            FindFirstChildOfClass = function()
                return playerGui
            end,
        }, {}),
    },
    TweenService = {
        Create = function()
            return { Play = function() end }
        end,
    },
    UserInputService = newInstance("UserInputService"),
    RunService = newInstance("RunService"),
}

game = {
    PlaceId = 96342491571673,
    -- El Job ID de la partida donde corre el script que se está probando.
    JobId = "17272727-8171",
    GetService = function(_, name)
        if not services[name] then
            error("servicio no mockeado: " .. name)
        end
        return services[name]
    end,
}
mock.services = services
mock.playerGui = playerGui

----------------------------------------------------------------------
-- task
----------------------------------------------------------------------

mock.spawned = {}
mock.waits = 0
mock.maxWaits = 0

task = {
    spawn = function(fn, ...)
        table.insert(mock.spawned, fn)
        -- Los bucles infinitos se cortan solos: task.wait lanza __STOP__
        -- en cuanto se pasa del presupuesto de esperas.
        pcall(fn, ...)
    end,
    wait = function()
        mock.waits = mock.waits + 1
        if mock.waits > mock.maxWaits then
            error("__STOP__", 0)
        end
    end,
    delay = function() end,
}

--- Vuelve a ejecutar una corrutina lanzada con task.spawn (por ejemplo
--- el bucle de sincronización) durante una iteración más.
function mock.runSpawned(index, extraWaits)
    mock.waits = 0
    mock.maxWaits = extraWaits or 0
    pcall(mock.spawned[index])
end

----------------------------------------------------------------------
-- http del executor
----------------------------------------------------------------------

mock.requests = {}

function request(options)
    table.insert(mock.requests, {
        url = options.Url,
        method = options.Method,
        headers = options.Headers,
        body = _G.__LAST_BODY,
    })
    _G.__LAST_BODY = nil

    local status = _G.__NEXT_STATUS or 200
    _G.__NEXT_STATUS = nil
    return { StatusCode = status, Body = "<json>" }
end

function mock.lastRequest()
    return mock.requests[#mock.requests]
end

function mock.reset()
    mock.requests = {}
end

getgenv = function()
    _G.__GENV = _G.__GENV or {}
    return _G.__GENV
end

return mock
