-- ═══════════════════════════════════════════════════════════════════════════
--  Consola tipo Roblox Studio (Output) — captura TODO el output del juego
--  (prints, warns, errores) de cualquier script, no solo de este.
--  Usa LogService.MessageOut, la API real de Roblox para esto (no algo
--  inventado ni específico de tu script).
--
--  - Aparece en la esquina superior derecha (asunción mía, fácil de mover
--    si preferís otra esquina — solo cambiar PANEL_POS más abajo)
--  - Se puede minimizar (se achica a solo la barra de título)
--  - Se abre sola automáticamente si estaba minimizada y llega un mensaje
--    nuevo
--  - Funciona igual en PC y celular: los TextButton ya responden a tap
--    táctil solos, y Frame.Draggable ya soporta arrastre táctil, sin
--    necesidad de código extra para eso
-- ═══════════════════════════════════════════════════════════════════════════

local LogService    = game:GetService("LogService")
local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")
local SoundService  = game:GetService("SoundService")
local LocalPlayer   = Players.LocalPlayer

-- ── CONFIG ─────────────────────────────────────────────────────────────────
local PANEL_W        = 300
local PANEL_H         = 230
local TITLEBAR_H      = 28
local PANEL_POS       = UDim2.new(1, -PANEL_W - 10, 0, 10)  -- esquina sup. derecha
local MAX_ENTRIES      = 200  -- tope de líneas guardadas (para que no se ponga pesado)
local ACCENT           = Color3.fromRGB(255, 255, 255)  -- color de acento del brillo del borde (blanco)
local CLICK_SOUND_ID   = "rbxassetid://138567614125924" -- mismo sonido de click que usa tu librería Zin/YinYang

-- ── SONIDO (pool chico, mismo patrón que la librería: reusar Sound en vez de crear uno por click) ──
local SoundPool = {}
local function playClickSound()
    local sound = SoundPool[1]
    if not sound then
        sound = Instance.new("Sound")
        sound.SoundId = CLICK_SOUND_ID
        sound.Volume  = 0.5
        sound.Parent  = SoundService
        SoundPool[1]  = sound
    end
    pcall(function()
        sound.TimePosition = 0
        sound.Playing = false
        sound:Play()
    end)
end

-- ── ESTADO ─────────────────────────────────────────────────────────────────
local isMinimized = false
local entryCount  = 0

-- ── GUI BASE ───────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name           = "StudioConsole"
gui.ResetOnSpawn   = false
gui.DisplayOrder   = 999995
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local panel = Instance.new("Frame", gui)
panel.Name             = "ConsolePanel"
panel.Size             = UDim2.new(0, PANEL_W, 0, PANEL_H)
panel.Position         = PANEL_POS
panel.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
panel.BorderSizePixel  = 0
panel.Active            = true
panel.Draggable         = true
panel.ClipsDescendants  = true

Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local panelGrad = Instance.new("UIGradient", panel)
panelGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(22, 22, 32)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 10, 15)),
})
panelGrad.Rotation = 90

local panelStroke = Instance.new("UIStroke", panel)
panelStroke.Color         = ACCENT
panelStroke.Thickness     = 1.3
panelStroke.Transparency = 0.35  -- valor de partida del pulso (el tween lo lleva a 0 y vuelve)

-- ── BRILLO ANIMADO EN EL BORDE ───────────────────────────────────────────
-- Mismo patrón que buildGlowOnStroke() de tu librería Zin/YinYang: un
-- UIGradient barriendo el stroke (sweep) + un pulso de transparencia,
-- ambos en loop infinito con TweenService.
local glowGrad = Instance.new("UIGradient", panelStroke)
do
    local h, s, v = Color3.toHSV(ACCENT)
    local accentLight = Color3.fromHSV(h, math.max(0, s - 0.3), math.min(1, v + 0.25))
    local accentDark  = Color3.fromHSV(h, math.min(1, s + 0.1), math.max(0, v - 0.25))

    glowGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, accentDark),
        ColorSequenceKeypoint.new(0.5, accentLight),
        ColorSequenceKeypoint.new(1, accentDark),
    })
    glowGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(0.5, 0),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    glowGrad.Offset = Vector2.new(-1.5, 0)

    TweenService:Create(
        glowGrad,
        TweenInfo.new(1.4, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false),
        {Offset = Vector2.new(1.5, 0)}
    ):Play()

    TweenService:Create(
        panelStroke,
        TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        {Transparency = 0.0}
    ):Play()
end

-- ── BARRA DE TÍTULO ────────────────────────────────────────────────────────
local titleBar = Instance.new("Frame", panel)
titleBar.Size             = UDim2.new(1, 0, 0, TITLEBAR_H)
titleBar.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
titleBar.BorderSizePixel  = 0

Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)
local titleFix = Instance.new("Frame", titleBar)
titleFix.Size             = UDim2.new(1, 0, 0, 8)
titleFix.Position         = UDim2.new(0, 0, 1, -8)
titleFix.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
titleFix.BorderSizePixel  = 0

local titleIcon = Instance.new("ImageLabel", titleBar)
titleIcon.Size              = UDim2.new(0, 16, 0, 16)
titleIcon.Position          = UDim2.new(0, 10, 0, 6)  -- centrado verticalmente en la barra (28px alto)
titleIcon.BackgroundTransparency = 1
titleIcon.Image              = "rbxassetid://128051642530027"
titleIcon.ScaleType          = Enum.ScaleType.Fit

local titleLbl = Instance.new("TextLabel", titleBar)
titleLbl.Size              = UDim2.new(1, -68, 1, 0)
titleLbl.Position          = UDim2.new(0, 32, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text              = "Console"
titleLbl.TextColor3        = Color3.fromRGB(225, 225, 245)
titleLbl.Font              = Enum.Font.GothamBold
titleLbl.TextSize           = 13
titleLbl.TextXAlignment    = Enum.TextXAlignment.Left

local minimizeBtn = Instance.new("TextButton", titleBar)
minimizeBtn.Size             = UDim2.new(0, 30, 0, 22)
minimizeBtn.Position         = UDim2.new(1, -36, 0, 3)
minimizeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 58)
minimizeBtn.BorderSizePixel  = 0
minimizeBtn.Text             = "—"
minimizeBtn.TextColor3       = Color3.fromRGB(220, 220, 240)
minimizeBtn.Font             = Enum.Font.GothamBold
minimizeBtn.TextSize         = 14
Instance.new("UICorner", minimizeBtn).CornerRadius = UDim.new(0, 6)

-- Feedback táctil: se achica al tocar/clickear y rebota al soltar
-- (mismo patrón que createWindowControl() de tu librería Zin/YinYang)
local minimizeScale = Instance.new("UIScale", minimizeBtn)
minimizeBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        TweenService:Create(minimizeScale, TweenInfo.new(0.08), {Scale = 0.82}):Play()
    end
end)
minimizeBtn.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        TweenService:Create(minimizeScale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end
end)


-- ── CUERPO (lista de logs con scroll) ──────────────────────────────────────
local body = Instance.new("Frame", panel)
body.Name             = "Body"
body.Size              = UDim2.new(1, 0, 1, -TITLEBAR_H)
body.Position          = UDim2.new(0, 0, 0, TITLEBAR_H)
body.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
body.BorderSizePixel   = 0
body.ClipsDescendants  = true

local bodyBgImage = Instance.new("ImageLabel", body)
bodyBgImage.Name                = "BackgroundImage"
bodyBgImage.Size                 = UDim2.new(1, 0, 1, 0)
bodyBgImage.BackgroundTransparency = 1
bodyBgImage.Image                = "rbxassetid://105426680954878"
bodyBgImage.ScaleType            = Enum.ScaleType.Crop
bodyBgImage.ZIndex               = 1

local scroll = Instance.new("ScrollingFrame", body)
scroll.ZIndex                   = 2
scroll.Size                    = UDim2.new(1, -6, 1, -6)
scroll.Position                = UDim2.new(0, 3, 0, 3)
scroll.BackgroundTransparency  = 1
scroll.BorderSizePixel         = 0
scroll.ScrollBarThickness      = 4
scroll.ScrollBarImageColor3    = Color3.fromRGB(90, 90, 120)
scroll.CanvasSize              = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize     = Enum.AutomaticSize.Y

local listLayout = Instance.new("UIListLayout", scroll)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding    = UDim.new(0, 2)

local listPad = Instance.new("UIPadding", scroll)
listPad.PaddingLeft  = UDim.new(0, 4)
listPad.PaddingRight = UDim.new(0, 4)
listPad.PaddingTop   = UDim.new(0, 2)

-- ── MINIMIZAR / RESTAURAR ───────────────────────────────────────────────────
local function setMinimized(state)
    isMinimized = state
    minimizeBtn.Text = state and "▢" or "—"

    if state then
        -- Se achica primero, y recién cuando termina la animación se oculta
        -- el body (si lo ocultás antes, se ve el corte feo del contenido)
        local tw = TweenService:Create(panel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Size = UDim2.new(0, PANEL_W, 0, TITLEBAR_H)})
        tw.Completed:Connect(function() body.Visible = false end)
        tw:Play()
    else
        body.Visible = true
        TweenService:Create(panel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Size = UDim2.new(0, PANEL_W, 0, PANEL_H)}):Play()
    end
end

minimizeBtn.Activated:Connect(function()
    playClickSound()
    setMinimized(not isMinimized)
end)

-- ── CLASIFICAR TIPO DE MENSAJE (color + ícono) ─────────────────────────────
local function classify(messageType)
    if messageType == Enum.MessageType.MessageError then
        return "🔴", Color3.fromRGB(255, 95, 95)
    elseif messageType == Enum.MessageType.MessageWarning then
        return "🟡", Color3.fromRGB(255, 205, 80)
    elseif messageType == Enum.MessageType.MessageInfo then
        return "🔵", Color3.fromRGB(110, 180, 255)
    else
        return "⚪", Color3.fromRGB(215, 215, 225)
    end
end

-- ── AGREGAR UNA LÍNEA AL LOG ────────────────────────────────────────────────
local function addEntry(text, messageType, autoOpen)
    local icon, color = classify(messageType)

    local now = DateTime.now():ToLocalTime()
    local timestamp = string.format("%02d:%02d:%02d", now.Hour, now.Minute, now.Second)

    local entry = Instance.new("TextLabel")
    entry.BackgroundTransparency = 1
    entry.Size                    = UDim2.new(1, 0, 0, 0)
    entry.AutomaticSize            = Enum.AutomaticSize.Y
    entry.Text                     = string.format("[%s] %s %s", timestamp, icon, tostring(text))
    entry.TextColor3               = color
    entry.Font                     = Enum.Font.Code
    entry.TextSize                 = 12
    entry.TextWrapped              = true
    entry.TextXAlignment           = Enum.TextXAlignment.Left
    entry.LayoutOrder              = entryCount
    entry.Parent                   = scroll

    entryCount = entryCount + 1

    -- Tope de líneas: si nos pasamos, borramos la más vieja
    if #scroll:GetChildren() - 3 > MAX_ENTRIES then  -- -3 por UIListLayout/UIPadding
        local oldest = nil
        local oldestOrder = math.huge
        for _, child in ipairs(scroll:GetChildren()) do
            if child:IsA("TextLabel") and child.LayoutOrder < oldestOrder then
                oldest = child
                oldestOrder = child.LayoutOrder
            end
        end
        if oldest then oldest:Destroy() end
    end

    -- Autoscroll al final
    task.defer(function()
        scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y))
    end)

    -- Se abre sola si estaba minimizada y llegó algo nuevo
    if autoOpen ~= false and isMinimized then
        setMinimized(false)
    end
end

-- ── CARGAR HISTORIAL YA EXISTENTE (sin que eso la abra sola) ───────────────
local ok, history = pcall(function() return LogService:GetLogHistory() end)
if ok and history then
    for _, item in ipairs(history) do
        addEntry(item.message, item.messageType, false)
    end
end

-- ── ESCUCHAR TODO EL OUTPUT NUEVO (de cualquier script) ────────────────────
LogService.MessageOut:Connect(function(message, messageType)
    addEntry(message, messageType, true)
end)

print("✅ Console cargada — capturando todo el output del juego")
