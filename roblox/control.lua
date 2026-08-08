--[[
    Manysteps · control.lua
    ------------------------------------------------------------------
    El mando: la misma consola del panel web, pero dibujada dentro de
    Roblox. No toca ningún remote — manda las órdenes al panel, y el
    panel se las pasa al bridge, que es quien las ejecuta en el juego.

        control.lua  →  panel web  →  controller.lua  →  remotes.lua

    Por eso puede correr en cualquier sitio: en otra cuenta, en otro
    servidor o en otro juego. Lo único que necesita es alcanzar el panel.

    Config (la inyecta /script/loader.lua?mode=control):
        getgenv().MANYSTEPS_CONFIG = { url = "https://...", key = "..." }

    Atajos:
        RightControl   muestra u oculta la ventana
        getgenv().MANYSTEPS_CONTROL_STOP()   la cierra del todo
--]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------

local config = getgenv and getgenv().MANYSTEPS_CONFIG or _G.MANYSTEPS_CONFIG
if type(config) ~= "table" or type(config.url) ~= "string" or config.url == "" then
    error("[Manysteps] Falta getgenv().MANYSTEPS_CONFIG = { url = ..., key = ... }", 0)
end

local BASE_URL = string.gsub(config.url, "/+$", "")
local CONTROL_KEY = tostring(config.key or "")
local SYNC_SECONDS = tonumber(config.syncEvery) or 1.5

----------------------------------------------------------------------
-- una sola instancia
----------------------------------------------------------------------

if getgenv and type(getgenv().MANYSTEPS_CONTROL_STOP) == "function" then
    pcall(getgenv().MANYSTEPS_CONTROL_STOP)
end

local running = true

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

local function httpJson(method, pathname, body)
    local options = {
        Url = BASE_URL .. pathname,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["x-control-key"] = CONTROL_KEY,
        },
    }

    if body ~= nil then
        local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, body)
        if not encodeOk then
            return false, "no se pudo codificar el cuerpo"
        end
        options.Body = encoded
    end

    local ok, response = pcall(httpRequest, options)
    if not ok then
        return false, tostring(response)
    end

    local status = (type(response) == "table" and (response.StatusCode or response.Status)) or 0
    local raw = type(response) == "table" and response.Body or ""

    local decoded, parsed = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decoded then
        parsed = {}
    end

    if status < 200 or status >= 300 then
        local message = type(parsed) == "table" and parsed.error or nil
        return false, message or ("HTTP " .. tostring(status))
    end
    return true, parsed
end

----------------------------------------------------------------------
-- aspecto
----------------------------------------------------------------------

local THEME = {
    bg = Color3.fromRGB(12, 14, 16),
    surface = Color3.fromRGB(18, 21, 24),
    surfaceAlt = Color3.fromRGB(23, 27, 31),
    line = Color3.fromRGB(34, 38, 43),
    lineSoft = Color3.fromRGB(28, 32, 37),
    text = Color3.fromRGB(232, 235, 237),
    dim = Color3.fromRGB(141, 149, 158),
    faint = Color3.fromRGB(90, 98, 107),
    acid = Color3.fromRGB(198, 242, 78),
    acidDim = Color3.fromRGB(143, 178, 55),
    acidInk = Color3.fromRGB(11, 15, 4),
    amber = Color3.fromRGB(255, 181, 69),
    red = Color3.fromRGB(255, 95, 87),
    blue = Color3.fromRGB(111, 179, 255),
}

local FAST = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function new(className, props, children)
    local instance = Instance.new(className)
    local parent = nil

    for key, value in pairs(props or {}) do
        if key == "Parent" then
            parent = value
        else
            instance[key] = value
        end
    end

    for _, child in ipairs(children or {}) do
        child.Parent = instance
    end

    instance.Parent = parent
    return instance
end

local function corner(radius, parent)
    return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(color, thickness, parent)
    return new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function label(props)
    return new("TextLabel", {
        BackgroundTransparency = 1,
        Font = props.Font or Enum.Font.Gotham,
        TextSize = props.TextSize or 13,
        TextColor3 = props.TextColor3 or THEME.text,
        TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
        TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center,
        Text = props.Text or "",
        Size = props.Size,
        Position = props.Position,
        Name = props.Name or "Label",
        TextTruncate = props.TextTruncate or Enum.TextTruncate.AtEnd,
        Parent = props.Parent,
    })
end

--- Etiqueta pequeña en mayúsculas, como los títulos del panel web.
local function caption(text, position, size, parent)
    return label({
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.faint,
        Position = position,
        Size = size,
        Parent = parent,
    })
end

----------------------------------------------------------------------
-- ventana
----------------------------------------------------------------------

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screen = new("ScreenGui", {
    Name = "ManystepsControl",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
    AutoLocalize = false,
    Parent = playerGui,
})

pcall(function()
    screen.IgnoreGuiInset = true
end)

local window = new("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(586, 424),
    Position = UDim2.new(0.5, -293, 0.5, -212),
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
    -- Sin esto, al plegar la ventana el contenido se queda flotando
    -- fuera de ella: encoger el marco no recorta a los hijos.
    ClipsDescendants = true,
    -- Y sin esto Roblox traduce los textos por su cuenta ("JOB ID" pasa
    -- a "ID DE TRABAJO") y se comen el sitio de lo que tienen al lado.
    AutoLocalize = false,
    Parent = screen,
})
corner(10, window)
stroke(THEME.line, 1, window)

-- En pantallas pequeñas 586x424 se come medio monitor. Con
-- scale = 0.8 en la config del loader se encoge sin tocar el diseño.
local UI_SCALE = tonumber(config.scale) or 1
if UI_SCALE ~= 1 then
    new("UIScale", { Scale = UI_SCALE, Parent = window })
end

-- Marca de esquina: el mismo guiño que los paneles de la web.
new("Frame", {
    Size = UDim2.fromOffset(10, 2),
    Position = UDim2.fromOffset(14, 14),
    BackgroundColor3 = THEME.acid,
    BorderSizePixel = 0,
    Parent = window,
})
new("Frame", {
    Size = UDim2.fromOffset(2, 10),
    Position = UDim2.fromOffset(14, 14),
    BackgroundColor3 = THEME.acid,
    BorderSizePixel = 0,
    Parent = window,
})

----------------------------------------------------------------------
-- barra de título
----------------------------------------------------------------------

local titleBar = new("Frame", {
    Name = "TitleBar",
    Size = UDim2.new(1, 0, 0, 46),
    BackgroundTransparency = 1,
    Parent = window,
})

label({
    Text = "MANYSTEPS",
    Font = Enum.Font.Code,
    TextSize = 14,
    Position = UDim2.fromOffset(32, 10),
    Size = UDim2.fromOffset(160, 15),
    Parent = titleBar,
})

label({
    Text = "REMOTE OPS",
    Font = Enum.Font.Code,
    TextSize = 9,
    TextColor3 = THEME.faint,
    Position = UDim2.fromOffset(32, 25),
    Size = UDim2.fromOffset(160, 12),
    Parent = titleBar,
})

-- Indicador del bridge: LED + texto, igual que el chip de la web.
local ledHolder = new("Frame", {
    Size = UDim2.fromOffset(152, 26),
    Position = UDim2.new(1, -236, 0, 10),
    BackgroundColor3 = THEME.surface,
    BorderSizePixel = 0,
    Parent = titleBar,
})
corner(6, ledHolder)
stroke(THEME.lineSoft, 1, ledHolder)

local led = new("Frame", {
    Size = UDim2.fromOffset(7, 7),
    Position = UDim2.fromOffset(10, 10),
    BackgroundColor3 = THEME.red,
    BorderSizePixel = 0,
    Parent = ledHolder,
})
corner(4, led)

local ledText = label({
    Text = "sin bridge",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = THEME.red,
    Position = UDim2.fromOffset(25, 0),
    Size = UDim2.new(1, -32, 1, 0),
    Parent = ledHolder,
})

-- Reloj de acceso: lo que queda de tiempo, según el propio servidor.
local clockText = label({
    Name = "ClockLabel",
    Text = "",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = THEME.faint,
    TextXAlignment = Enum.TextXAlignment.Right,
    Position = UDim2.new(1, -374, 0, 10),
    Size = UDim2.fromOffset(130, 26),
    Parent = titleBar,
})

local function iconButton(text, offsetX, parent)
    local button = new("TextButton", {
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = THEME.dim,
        BackgroundColor3 = THEME.surface,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.new(1, offsetX, 0, 10),
        Parent = parent,
    })
    corner(6, button)
    stroke(THEME.lineSoft, 1, button)

    button.MouseEnter:Connect(function()
        TweenService:Create(button, FAST, { BackgroundColor3 = THEME.surfaceAlt }):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, FAST, { BackgroundColor3 = THEME.surface }):Play()
    end)
    return button
end

local minimizeButton = iconButton("_", -72, titleBar)
local closeButton = iconButton("X", -40, titleBar)

new("Frame", {
    Size = UDim2.new(1, -28, 0, 1),
    Position = UDim2.fromOffset(14, 46),
    BackgroundColor3 = THEME.lineSoft,
    BorderSizePixel = 0,
    Parent = window,
})

----------------------------------------------------------------------
-- columna izquierda: tiempo y destino
----------------------------------------------------------------------

caption("CONTROL DE TIEMPO", UDim2.fromOffset(18, 58), UDim2.fromOffset(200, 12), window)

local function bigButton(name, text, subtitle, accent, positionY)
    local button = new("TextButton", {
        Name = name,
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = THEME.surface,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(228, 48),
        Position = UDim2.fromOffset(18, positionY),
        Parent = window,
    })
    corner(8, button)
    local border = stroke(THEME.line, 1, button)

    new("Frame", {
        Size = UDim2.fromOffset(3, 30),
        Position = UDim2.fromOffset(0, 9),
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Parent = button,
    })

    label({
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        Position = UDim2.fromOffset(16, 8),
        Size = UDim2.fromOffset(180, 16),
        Parent = button,
    })

    label({
        Text = subtitle,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = THEME.faint,
        Position = UDim2.fromOffset(16, 25),
        Size = UDim2.fromOffset(190, 14),
        Parent = button,
    })

    button.MouseEnter:Connect(function()
        TweenService:Create(button, FAST, { BackgroundColor3 = THEME.surfaceAlt }):Play()
        TweenService:Create(border, FAST, { Color = accent }):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, FAST, { BackgroundColor3 = THEME.surface }):Play()
        TweenService:Create(border, FAST, { Color = THEME.line }):Play()
    end)

    return button, border
end

local pauseButton, pauseBorder = bigButton("PauseButton", "Pausar", "congela el reloj", THEME.amber, 76)
local resumeButton, resumeBorder = bigButton("ResumeButton", "Reanudar", "vuelve a correr", THEME.acid, 132)

caption("DESTINO", UDim2.fromOffset(18, 196), UDim2.fromOffset(200, 12), window)

--- Campo de texto a todo el ancho, con su botón de guardar arriba a la
--- derecha. Un Job ID son 36 caracteres: cada píxel del cuadro cuenta,
--- así que el botón no puede robarle sitio al valor.
local function field(labelText, placeholder, positionY, onSubmit)
    caption(labelText, UDim2.fromOffset(18, positionY), UDim2.fromOffset(120, 12), window)

    local box = new("TextBox", {
        Name = labelText:gsub("%s", "") .. "Box",
        Text = "",
        PlaceholderText = placeholder,
        PlaceholderColor3 = Color3.fromRGB(69, 77, 85),
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundColor3 = THEME.bg,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Size = UDim2.fromOffset(228, 30),
        Position = UDim2.fromOffset(18, positionY + 16),
        Parent = window,
    })
    corner(6, box)
    local border = stroke(THEME.line, 1, box)
    new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8), Parent = box })

    box.Focused:Connect(function()
        TweenService:Create(border, FAST, { Color = THEME.acid }):Play()
    end)
    box.FocusLost:Connect(function(enterPressed)
        TweenService:Create(border, FAST, { Color = THEME.line }):Play()
        if enterPressed then
            onSubmit(box.Text)
        end
    end)

    local save = new("TextButton", {
        Name = labelText:gsub("%s", "") .. "Save",
        Text = "GUARDAR",
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = THEME.acidDim,
        TextXAlignment = Enum.TextXAlignment.Right,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Size = UDim2.fromOffset(110, 12),
        Position = UDim2.fromOffset(136, positionY),
        Parent = window,
    })

    save.MouseEnter:Connect(function()
        save.TextColor3 = THEME.acid
    end)
    save.MouseLeave:Connect(function()
        save.TextColor3 = THEME.acidDim
    end)
    save.MouseButton1Click:Connect(function()
        onSubmit(box.Text)
    end)

    local hint = label({
        Text = "",
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = THEME.faint,
        Position = UDim2.fromOffset(18, positionY + 50),
        Size = UDim2.fromOffset(228, 12),
        Parent = window,
    })

    return box, hint, save
end

----------------------------------------------------------------------
-- columna derecha: jugadores
----------------------------------------------------------------------

caption("JUGADORES", UDim2.fromOffset(268, 58), UDim2.fromOffset(120, 12), window)

local rosterCount = label({
    Text = "0",
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = THEME.faint,
    TextXAlignment = Enum.TextXAlignment.Right,
    Position = UDim2.new(1, -104, 0, 58),
    Size = UDim2.fromOffset(40, 12),
    Parent = window,
})

-- Nada de glifos vistosos en los botones: Roblox no trae "✕" ni "↻" en
-- sus fuentes y salen como cuadros vacíos.
local refreshButton = new("TextButton", {
    Name = "RefreshButton",
    Text = "SYNC",
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = THEME.dim,
    TextXAlignment = Enum.TextXAlignment.Right,
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Size = UDim2.fromOffset(40, 14),
    Position = UDim2.new(1, -58, 0, 57),
    Parent = window,
})

refreshButton.MouseEnter:Connect(function()
    refreshButton.TextColor3 = THEME.acid
end)
refreshButton.MouseLeave:Connect(function()
    refreshButton.TextColor3 = THEME.dim
end)

local roster = new("ScrollingFrame", {
    Name = "Roster",
    Size = UDim2.fromOffset(300, 250),
    Position = UDim2.fromOffset(268, 76),
    BackgroundColor3 = THEME.surface,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = THEME.line,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = window,
})
corner(8, roster)
stroke(THEME.lineSoft, 1, roster)

new("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = roster,
})
new("UIPadding", {
    PaddingTop = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 6),
    PaddingRight = UDim.new(0, 6),
    PaddingBottom = UDim.new(0, 6),
    Parent = roster,
})

local emptyNote = label({
    Text = "esperando al bridge…",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = THEME.faint,
    TextXAlignment = Enum.TextXAlignment.Center,
    Position = UDim2.fromOffset(268, 160),
    Size = UDim2.fromOffset(300, 20),
    Parent = window,
})

local selectionLabel = label({
    Text = "0 seleccionados",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = THEME.dim,
    Position = UDim2.fromOffset(268, 336),
    Size = UDim2.fromOffset(150, 16),
    Parent = window,
})

local sendButton = new("TextButton", {
    Name = "SendButton",
    Text = "ENVIAR TELEPORT",
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextColor3 = THEME.acidInk,
    BackgroundColor3 = THEME.acid,
    AutoButtonColor = false,
    BorderSizePixel = 0,
    Size = UDim2.fromOffset(160, 32),
    Position = UDim2.fromOffset(408, 330),
    Parent = window,
})
corner(8, sendButton)

----------------------------------------------------------------------
-- barra de estado
----------------------------------------------------------------------

new("Frame", {
    Size = UDim2.new(1, -28, 0, 1),
    Position = UDim2.fromOffset(14, 376),
    BackgroundColor3 = THEME.lineSoft,
    BorderSizePixel = 0,
    Parent = window,
})

local statusDot = new("Frame", {
    Size = UDim2.fromOffset(5, 5),
    Position = UDim2.fromOffset(18, 394),
    BackgroundColor3 = THEME.faint,
    BorderSizePixel = 0,
    Parent = window,
})
corner(3, statusDot)

local statusLabel = label({
    Text = "conectando con el panel…",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = THEME.dim,
    Position = UDim2.fromOffset(32, 386),
    Size = UDim2.fromOffset(536, 20),
    Parent = window,
})

local LEVEL_COLORS = {
    ok = THEME.acid,
    cmd = THEME.blue,
    info = THEME.dim,
    warn = THEME.amber,
    error = THEME.red,
}

local function setStatus(message, level)
    statusLabel.Text = message
    local color = LEVEL_COLORS[level or "info"] or THEME.dim
    statusLabel.TextColor3 = level == "error" and THEME.red or THEME.dim
    statusDot.BackgroundColor3 = color
end

----------------------------------------------------------------------
-- estado local
----------------------------------------------------------------------

local placeBox, placeHint
local jobBox, jobHint

local selected = {}
local playerBridge = {}
local rosterRows = {}
local rosterSignature = ""
local latest = nil
local jobDirty = false
local placeDirty = false

-- Escribir en un TextBox dispara su Changed igual que si teclearas, así
-- que sin esto el primer refresco marcaría los campos como editados y ya
-- no volverían a actualizarse solos.
local applyingState = false

-- Lo que acabamos de mandar y el juego todavía no confirma. El campo se
-- queda con ello: si lo soltáramos al enviar, el siguiente refresco lo
-- repondría al valor viejo, porque el bridge tarda en releer el juego.
local pendingJobId = nil
local pendingPlaceId = nil

-- Último GetAccessStatus que nos pasó el panel, y cuándo lo recibimos:
-- el tiempo restante se descuenta aquí entre lecturas.
local access = nil
local accessReadAt = 0
local placeButtons = {}
local placesSignature = ""

local function selectionCount()
    local count = 0
    for _ in pairs(selected) do
        count = count + 1
    end
    return count
end

local function refreshSelectionUi()
    local count = selectionCount()
    selectionLabel.Text = count == 1 and "1 seleccionado" or (count .. " seleccionados")

    local enabled = count > 0 and latest and (tonumber(latest.online) or 0) > 0
    sendButton.BackgroundColor3 = enabled and THEME.acid or THEME.surfaceAlt
    sendButton.TextColor3 = enabled and THEME.acidInk or THEME.faint
end

----------------------------------------------------------------------
-- acciones
----------------------------------------------------------------------

local function sendCommand(commandType, payload, describeOk)
    task.spawn(function()
        local ok, result = httpJson("POST", "/api/command", {
            type = commandType,
            payload = payload or {},
        })
        if ok then
            setStatus(describeOk or "orden enviada", "cmd")
        else
            setStatus(tostring(result), "error")
        end
    end)
end

pauseButton.MouseButton1Click:Connect(function()
    sendCommand("time.pause", {}, "pausa enviada")
end)

resumeButton.MouseButton1Click:Connect(function()
    sendCommand("time.resume", {}, "reanudación enviada")
end)

refreshButton.MouseButton1Click:Connect(function()
    sendCommand("players.refresh", {}, "refrescando jugadores")
end)

sendButton.MouseButton1Click:Connect(function()
    -- Cada jugador va por el bridge que lo tiene delante en su partida.
    local targets = {}
    for userId in pairs(selected) do
        table.insert(targets, { userId = userId, bridgeId = playerBridge[userId] })
    end
    if #targets == 0 then
        setStatus("no hay nadie seleccionado", "warn")
        return
    end

    local jobId = jobBox.Text:match("^%s*(.-)%s*$")
    local placeId = placeBox.Text:match("^%s*(.-)%s*$")

    task.spawn(function()
        local ok, result = httpJson("POST", "/api/teleport/batch", {
            targets = targets,
            jobId = jobId ~= "" and jobId or nil,
            placeId = placeId ~= "" and placeId or nil,
        })
        if ok then
            local count = type(result.accepted) == "table" and #result.accepted or #targets
            setStatus(count .. " teleport(s) en cola", "ok")
            selected = {}
            for _, row in pairs(rosterRows) do
                row.setSelected(false)
            end
            refreshSelectionUi()
        else
            setStatus(tostring(result), "error")
        end
    end)
end)

placeBox, placeHint = field("PLACE ID", "96342491571673", 218, function(value)
    local placeId = value:match("^%s*(.-)%s*$")
    pendingPlaceId = placeId
    sendCommand("settings.placeId", { placeId = placeId }, "place id enviado")
end)

local jobSave
jobBox, jobHint, jobSave = field("JOB ID", "pega aquí el Job ID", 292, function(value)
    local jobId = value:match("^%s*(.-)%s*$")
    pendingJobId = jobId
    sendCommand("settings.jobId", { jobId = jobId }, "job id enviado")
end)

-- Sitio para el botón de al lado.
jobSave.Position = UDim2.fromOffset(170, 292)
jobSave.Size = UDim2.fromOffset(76, 12)

--- Manda como destino el servidor en el que está este mando. Es el gesto
--- de "traedme a la gente aquí": el bridge está en otra partida y ahora
--- teletransportará a este Job ID.
local useMyJob = new("TextButton", {
    Name = "UseMyJobButton",
    Text = "MI JOB ID",
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = THEME.blue,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Size = UDim2.fromOffset(84, 12),
    Position = UDim2.fromOffset(80, 292),
    Parent = window,
})

useMyJob.MouseEnter:Connect(function()
    useMyJob.TextColor3 = THEME.text
end)
useMyJob.MouseLeave:Connect(function()
    useMyJob.TextColor3 = THEME.blue
end)

useMyJob.MouseButton1Click:Connect(function()
    local myJobId = tostring(game.JobId or "")
    if myJobId == "" then
        setStatus("esta partida no tiene Job ID (¿estás en Studio?)", "warn")
        return
    end

    applyingState = true
    jobBox.Text = myJobId
    applyingState = false

    pendingJobId = myJobId
    sendCommand("settings.jobId", { jobId = myJobId }, "mandando tu Job ID: " .. myJobId)

    -- Un Job ID solo vale dentro de su propio juego: si el destino
    -- configurado es otro place, este Job ID no le sirve al bridge.
    -- (%.0f y no tostring: un Place ID de 14 cifras acaba en "9.6342e+13".)
    local myPlaceId = string.format("%.0f", game.PlaceId)
    local targetPlaceId = placeBox.Text:match("^%s*(.-)%s*$")
    if targetPlaceId ~= "" and targetPlaceId ~= myPlaceId then
        setStatus("ojo: estás en el place " .. myPlaceId .. ", no en " .. targetPlaceId, "warn")
    end
end)

placeBox:GetPropertyChangedSignal("Text"):Connect(function()
    if not applyingState then
        placeDirty = true
    end
end)
jobBox:GetPropertyChangedSignal("Text"):Connect(function()
    if not applyingState then
        jobDirty = true
    end
end)

----------------------------------------------------------------------
-- lista de jugadores
----------------------------------------------------------------------

local function makeRow(entry, order)
    local row = new("TextButton", {
        Name = "PlayerRow",
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = THEME.surface,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 40),
        LayoutOrder = order,
        Parent = roster,
    })
    corner(6, row)
    local border = stroke(THEME.surface, 1, row)

    local tick = new("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.fromOffset(8, 13),
        BackgroundColor3 = THEME.surfaceAlt,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(4, tick)
    local tickBorder = stroke(THEME.line, 1, tick)

    new("ImageLabel", {
        Image = ("rbxthumb://type=AvatarHeadShot&id=%s&w=48&h=48"):format(entry.userId),
        BackgroundColor3 = THEME.surfaceAlt,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(28, 28),
        Position = UDim2.fromOffset(30, 6),
        Parent = row,
    }, { Instance.new("UICorner") })

    label({
        Text = entry.displayName or entry.username,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        Position = UDim2.fromOffset(66, 6),
        Size = UDim2.new(1, -76, 0, 15),
        Parent = row,
    })

    -- Con varios bridges hace falta saber de qué partida sale cada uno.
    local secondary = ("@%s · %s"):format(entry.username, entry.userId)
    if entry.bridgeName and latest and (tonumber(latest.online) or 0) > 1 then
        secondary = secondary .. "  [" .. entry.bridgeName .. "]"
    end

    label({
        Text = secondary,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = THEME.faint,
        Position = UDim2.fromOffset(66, 21),
        Size = UDim2.new(1, -76, 0, 13),
        Parent = row,
    })

    local function setSelected(isSelected)
        if isSelected then
            row.BackgroundTransparency = 0.86
            row.BackgroundColor3 = THEME.acid
            border.Color = THEME.acid
            tick.BackgroundColor3 = THEME.acid
            tickBorder.Color = THEME.acid
        else
            row.BackgroundTransparency = 1
            border.Color = THEME.surface
            tick.BackgroundColor3 = THEME.surfaceAlt
            tickBorder.Color = THEME.line
        end
    end

    row.MouseButton1Click:Connect(function()
        if selected[entry.userId] then
            selected[entry.userId] = nil
            setSelected(false)
        else
            selected[entry.userId] = true
            setSelected(true)
        end
        refreshSelectionUi()
    end)

    row.MouseEnter:Connect(function()
        if not selected[entry.userId] then
            border.Color = THEME.line
        end
    end)
    row.MouseLeave:Connect(function()
        if not selected[entry.userId] then
            border.Color = THEME.surface
        end
    end)

    return { instance = row, setSelected = setSelected }
end

local function renderRoster(list)
    playerBridge = {}
    for _, entry in ipairs(list) do
        playerBridge[entry.userId] = entry.bridgeId
    end

    local signature = {}
    for _, entry in ipairs(list) do
        table.insert(signature, entry.userId)
    end
    signature = table.concat(signature, ",")

    rosterCount.Text = tostring(#list)
    emptyNote.Visible = #list == 0

    if emptyNote.Visible then
        local online = latest and (tonumber(latest.online) or 0) > 0
        emptyNote.Text = online and "nadie a quien teletransportar"
            or "conecta un bridge en el juego"
    end

    if signature == rosterSignature then
        return
    end
    rosterSignature = signature

    for _, row in pairs(rosterRows) do
        row.instance:Destroy()
    end
    rosterRows = {}

    for index, entry in ipairs(list) do
        local row = makeRow(entry, index)
        row.setSelected(selected[entry.userId] == true)
        rosterRows[entry.userId] = row
    end

    -- Quita de la selección a quien ya no está en la lista.
    for userId in pairs(selected) do
        if not rosterRows[userId] then
            selected[userId] = nil
        end
    end
    refreshSelectionUi()
end

----------------------------------------------------------------------
-- reloj de acceso y destinos
----------------------------------------------------------------------

local ACCESS_LABEL = {
    active = "corriendo",
    paused = "pausado",
    permanent = "permanente",
    locked = "sin acceso",
    blacklisted = "bloqueado",
}

local function mmss(seconds)
    local total = math.max(0, math.floor(seconds + 0.5))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60

    if hours > 0 then
        return ("%d:%02d:%02d"):format(hours, minutes, secs)
    end
    return ("%d:%02d"):format(minutes, secs)
end

local function renderClock()
    if not access or not access.status then
        clockText.Text = ""
        return
    end

    local label = ACCESS_LABEL[access.status] or access.status
    if access.status == "active" or access.status == "paused" then
        -- Solo corre el reloj cuando el tiempo está corriendo de verdad.
        local elapsed = access.status == "active" and (os.clock() - accessReadAt) or 0
        local left = math.max(0, (tonumber(access.remainingSeconds) or 0) - elapsed)
        clockText.Text = label .. " · " .. mmss(left)
    else
        clockText.Text = label
    end

    if access.status == "paused" then
        clockText.TextColor3 = THEME.amber
    elseif access.status == "active" or access.status == "permanent" then
        clockText.TextColor3 = THEME.acid
    else
        clockText.TextColor3 = THEME.red
    end
end

--- Atajos a los destinos que ofrece el propio panel del juego, en el
--- sitio donde antes solo había un "listo" que no decía gran cosa.
local function renderPlaces(places)
    places = places or {}

    local signature = ""
    for _, place in ipairs(places) do
        signature = signature .. tostring(place.placeId) .. ","
    end

    if signature ~= placesSignature then
        placesSignature = signature
        for _, button in ipairs(placeButtons) do
            button:Destroy()
        end
        placeButtons = {}

        local x = 18
        for _, place in ipairs(places) do
            local placeId = tostring(place.placeId)
            local text = string.gsub(tostring(place.label or placeId), "^SAB%s+", "")
            local width = math.max(42, #text * 6 + 12)

            local button = new("TextButton", {
                Name = "Place_" .. placeId,
                Text = text,
                Font = Enum.Font.Code,
                TextSize = 10,
                TextColor3 = THEME.faint,
                TextXAlignment = Enum.TextXAlignment.Left,
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Size = UDim2.fromOffset(width, 14),
                Position = UDim2.fromOffset(x, 268),
                Parent = window,
            })

            button.MouseButton1Click:Connect(function()
                applyingState = true
                placeBox.Text = placeId
                applyingState = false
                pendingPlaceId = placeId
                sendCommand("settings.placeId", { placeId = placeId }, "destino → " .. text)
            end)

            table.insert(placeButtons, button)
            x = x + width + 8
        end
    end

    local current = placeBox.Text:match("^%s*(.-)%s*$")
    for _, button in ipairs(placeButtons) do
        button.TextColor3 = button.Name == ("Place_" .. current) and THEME.acid or THEME.faint
    end
end

----------------------------------------------------------------------
-- sincronización con el panel
----------------------------------------------------------------------

local function applyState(state)
    latest = state
    applyingState = true

    local bridges = state.bridges or {}
    local count = tonumber(state.online) or 0

    led.BackgroundColor3 = count > 0 and THEME.acid or THEME.red
    ledText.TextColor3 = count > 0 and THEME.acid or THEME.red

    if count == 0 then
        ledText.Text = "sin bridges"
    elseif count == 1 then
        local only
        for _, bridge in ipairs(bridges) do
            if bridge.online then
                only = bridge
            end
        end
        ledText.Text = only and (only.username or "1 en línea") or "1 en línea"
    else
        ledText.Text = count .. " bridges"
    end

    -- De todos los conectados enseñamos el que antes se queda sin
    -- tiempo, que es el que va a dar problemas primero.
    local worst = nil
    for _, bridge in ipairs(bridges) do
        if bridge.online and bridge.access and bridge.access.status then
            local remaining = tonumber(bridge.access.remainingSeconds) or 0
            if not worst or remaining < (tonumber(worst.remainingSeconds) or 0) then
                worst = bridge.access
            end
        end
    end

    access = worst
    accessReadAt = os.clock()
    renderClock()

    local panelJobId = nil
    for _, bridge in ipairs(bridges) do
        if bridge.online and bridge.panelJobId then
            panelJobId = bridge.panelJobId
            break
        end
    end

    renderPlaces(state.places)

    local savedPlaceId = state.settings and state.settings.placeId or nil

    -- En cuanto el juego confirma lo que mandamos, el campo vuelve a
    -- seguir al juego.
    if pendingJobId and panelJobId == pendingJobId then
        pendingJobId = nil
        jobDirty = false
    end
    if pendingPlaceId and savedPlaceId == pendingPlaceId then
        pendingPlaceId = nil
        placeDirty = false
    end

    if not placeDirty and not pendingPlaceId then
        placeBox.Text = savedPlaceId or ""
    end
    if not jobDirty and not pendingJobId then
        jobBox.Text = panelJobId or (state.settings and state.settings.jobId) or ""
    end
    applyingState = false

    -- Igual que en la web: manda lo que el juego tiene en el cuadro.
    local typed = jobBox.Text:match("^%s*(.-)%s*$")
    if pendingJobId then
        jobHint.Text = "guardando…"
        jobHint.TextColor3 = THEME.amber
    elseif panelJobId == nil then
        jobHint.Text = "sin datos del panel del juego"
        jobHint.TextColor3 = THEME.faint
    elseif panelJobId == "" then
        jobHint.Text = "el panel del juego lo tiene vacío"
        jobHint.TextColor3 = THEME.faint
    elseif panelJobId == typed then
        jobHint.Text = "activo en el panel del juego"
        jobHint.TextColor3 = THEME.acid
    else
        jobHint.Text = "el panel tiene " .. string.sub(panelJobId, 1, 16) .. "…"
        jobHint.TextColor3 = THEME.amber
    end

    renderRoster(state.players or {})

    local entries = state.log or {}
    if #entries > 0 then
        setStatus(entries[1].message, entries[1].level)
    end
end

task.spawn(function()
    while running do
        local ok, state = httpJson("GET", "/api/control/state")
        if not running then
            break
        end

        if ok and type(state) == "table" then
            local applied, applyError = pcall(applyState, state)
            if not applied then
                applyingState = false -- que un fallo a medias no congele los campos
                setStatus("error pintando el estado: " .. tostring(applyError), "error")
            end
        else
            led.BackgroundColor3 = THEME.red
            ledText.Text = "sin panel"
            ledText.TextColor3 = THEME.red
            setStatus("no se pudo hablar con el panel: " .. tostring(state), "error")
        end

        task.wait(SYNC_SECONDS)
    end
end)

----------------------------------------------------------------------
-- arrastrar, ocultar y cerrar
----------------------------------------------------------------------

do
    local dragging = false
    local dragStart, startPosition

    titleBar.InputBegan:Connect(function(input)
        if
            input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = true
            dragStart = input.Position
            startPosition = window.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        then
            local delta = input.Position - dragStart
            window.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end)
end

local collapsed = false
minimizeButton.MouseButton1Click:Connect(function()
    collapsed = not collapsed
    TweenService:Create(window, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = collapsed and UDim2.fromOffset(586, 46) or UDim2.fromOffset(586, 424),
    }):Play()
    minimizeButton.Text = collapsed and "+" or "_"
end)

local function shutdown()
    running = false
    if screen then
        screen:Destroy()
    end
    if getgenv then
        getgenv().MANYSTEPS_CONTROL_STOP = nil
    end
end

closeButton.MouseButton1Click:Connect(shutdown)

if getgenv then
    getgenv().MANYSTEPS_CONTROL_STOP = shutdown
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.KeyCode == Enum.KeyCode.RightControl then
        window.Visible = not window.Visible
    end
end)

----------------------------------------------------------------------

-- La cuenta atrás corre aquí: el panel solo relee el juego de tanto en
-- tanto, y un reloj que salta de veinte en veinte segundos no es reloj.
task.spawn(function()
    while running do
        if access and access.status then
            renderClock()
        end
        task.wait(1)
    end
end)

-- Latido del LED, para que se note que el mando sigue vivo.
task.spawn(function()
    while running do
        TweenService:Create(led, TweenInfo.new(1.1), { BackgroundTransparency = 0.55 }):Play()
        task.wait(1.2)
        TweenService:Create(led, TweenInfo.new(1.1), { BackgroundTransparency = 0 }):Play()
        task.wait(1.2)
    end
end)

refreshSelectionUi()
print("[Manysteps] mando abierto · RightControl para ocultarlo")
