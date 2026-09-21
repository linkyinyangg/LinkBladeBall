-- ══════════════════════════════════════════════════════════════════════
--  WAYPOINT AUTOPILOT v1
--  Reemplaza JumpAccel.lua — la lógica de BodyVelocity + auto-salto
--  está integrada directamente acá, pero la dirección ya no viene de
--  la cámara sino del vector hacia el waypoint actual.
--
--  Flujo:
--    1. Parate en un lugar → "＋ Waypoint"  (repite N veces)
--    2. "▶ Iniciar" → el personaje se mueve con JumpAccel hacia WP 1,
--       luego WP 2, etc. Al llegar al último se detiene solo.
--    3. Si el personaje muere, reanuda desde el mismo waypoint al
--       respawnear — sin teletransporte.
--    4. "▶ Iniciar" siempre reinicia desde WP 1.
-- ══════════════════════════════════════════════════════════════════════

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Debris           = game:GetService("Debris")
local Workspace        = game:GetService("Workspace")

local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

-- ── Limpiar instancias previas ────────────────────────────────────────
do
    local prev = pg:FindFirstChild("_WPAutopilotGui")
    if prev then prev:Destroy() end
    local prevF = Workspace:FindFirstChild("_WPMarkers")
    if prevF then prevF:Destroy() end
end

local markerFolder = Instance.new("Folder")
markerFolder.Name   = "_WPMarkers"
markerFolder.Parent = Workspace

-- ── CONFIG ────────────────────────────────────────────────────────────
local SPEED         = 60    -- studs/s de empuje horizontal (mismo rango que JumpAccel)
local JUMP_INTERVAL = 0.50  -- segundos entre auto-saltos
local REACH_DIST    = 12    -- studs para considerar un waypoint alcanzado

-- ── ESTADO ────────────────────────────────────────────────────────────
local waypoints  = {}   -- { [i] = Vector3 }
local markers    = {}   -- { [i] = Part }  paralelo a waypoints
local currentIdx = 1
local isRunning  = false
local hbConn     = nil

-- Variables internas de movimiento
local airAccumulator = 0
local lastTick       = tick()
local wasAir         = false
local activeBV       = nil
local lastJumpTime   = tick()

-- NoClip / movimiento agresivo (sin gravedad ni colision)
local noclipEnabled  = false
local noclipBV       = nil
local noclipBG       = nil
local noclipConn     = nil
local noclipBtn      = nil  -- forward-declare, se asigna con la GUI

-- Forward-declare: statusLabel y startBtn se asignan después de crear la GUI
local statusLabel = nil
local startBtn    = nil

local function setStatus(text)
    if statusLabel then statusLabel.Text = text end
end

-- ── MARCADORES VISUALES EN WORKSPACE ─────────────────────────────────
local function makeMarker(pos, idx)
    local part = Instance.new("Part")
    part.Name         = "WP" .. idx
    part.Shape        = Enum.PartType.Ball
    part.Size         = Vector3.new(2.5, 2.5, 2.5)
    part.Position     = pos
    part.Anchored     = true
    part.CanCollide   = false
    part.Material     = Enum.Material.Neon
    part.Color        = Color3.fromRGB(240, 240, 240)
    part.Transparency = 0.25
    part.Parent       = markerFolder

    local bg = Instance.new("BillboardGui")
    bg.Size        = UDim2.fromOffset(28, 16)
    bg.StudsOffset = Vector3.new(0, 3, 0)
    bg.AlwaysOnTop = true
    bg.Parent      = part

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = tostring(idx)
    lbl.Font                   = Enum.Font.GothamBlack
    lbl.TextSize               = 14
    lbl.TextColor3             = Color3.fromRGB(255, 255, 255)
    lbl.TextStrokeTransparency = 0
    lbl.TextStrokeColor3       = Color3.fromRGB(0, 0, 0)
    lbl.Parent                 = bg

    return part
end

-- ── WAYPOINT HELPERS ──────────────────────────────────────────────────
local function addWaypoint()
    local char = lp.Character
    if not char then setStatus("Sin personaje.") return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local pos = root.Position
    table.insert(waypoints, pos)
    local idx = #waypoints
    markers[idx] = makeMarker(pos, idx)
    setStatus(idx .. " WP colocado(s).")
    saveWaypoints()
end

local function removeLastWaypoint()
    local n = #waypoints
    if n == 0 then setStatus("No hay waypoints.") return end
    -- Destruir el marcador visual y limpiar la entrada de la tabla en un solo paso
    if markers[n] and markers[n].Parent then markers[n]:Destroy() end
    markers[n] = nil
    table.remove(waypoints, n)  -- remover por indice para mantener alineacion
    table.remove(markers,   n)  -- idem
    setStatus((#waypoints) .. " WP restante(s).")
    saveWaypoints()
end

-- ── MOVIMIENTO (lógica JumpAccel adaptada) ────────────────────────────
local function getChar()
    local c = lp.Character
    if not c then return nil, nil end
    return c:FindFirstChild("HumanoidRootPart"),
           c:FindFirstChildOfClass("Humanoid")
end

local function stopMovement(reason)
    isRunning = false
    if hbConn then hbConn:Disconnect(); hbConn = nil end
    if activeBV then activeBV:Destroy(); activeBV = nil end
    setStatus(reason or "Detenido.")
    if startBtn then startBtn.Text = "▶  Iniciar" end
end

local function onHeartbeat()
    if not isRunning then return end

    if currentIdx > #waypoints then
        stopMovement("✓ Destino alcanzado.")
        return
    end

    local root, hum = getChar()
    if not root or not hum then return end  -- respawn en curso, esperar

    local target   = waypoints[currentIdx]
    local diff     = target - root.Position
    local distFlat = Vector3.new(diff.X, 0, diff.Z).Magnitude

    -- Waypoint alcanzado → avanzar al siguiente
    if distFlat <= REACH_DIST then
        currentIdx = currentIdx + 1
        if currentIdx > #waypoints then
            stopMovement("✓ Destino alcanzado.")
        else
            setStatus("WP " .. (currentIdx - 1) .. " ✓ → WP " .. currentIdx .. "/" .. #waypoints)
        end
        return
    end

    local dt   = tick() - lastTick
    lastTick   = tick()

    if noclipEnabled then
        -- Movimiento agresivo: sin gravedad, sin colision, va directo al WP en 3D
        local dir3d = diff
        if dir3d.Magnitude > 0 then dir3d = dir3d.Unit end
        if activeBV then activeBV:Destroy() end
        local bv = Instance.new("BodyVelocity")
        bv.Velocity = dir3d * SPEED
        bv.MaxForce = Vector3.new(4e5, 4e5, 4e5)
        bv.P        = 1250
        bv.Parent   = root
        Debris:AddItem(bv, 0.1)
        activeBV = bv
    else
        -- Movimiento normal: plano con auto-salto
        local dir = Vector3.new(diff.X, 0, diff.Z)
        if dir.Magnitude > 0 then dir = dir.Unit end

        local isAir  = hum.FloorMaterial == Enum.Material.Air
        local state  = hum:GetState()
        local onGround = (
            state == Enum.HumanoidStateType.Landed or
            state == Enum.HumanoidStateType.Running
        ) and not isAir

        if wasAir and onGround then airAccumulator = 0 end
        wasAir = isAir

        if activeBV then activeBV:Destroy() end
        local bv = Instance.new("BodyVelocity")
        bv.Velocity = dir * SPEED
        bv.MaxForce = Vector3.new(4e5, 0, 4e5)
        bv.P        = 1250
        bv.Parent   = root
        Debris:AddItem(bv, 0.1)
        activeBV = bv

        if onGround then
            airAccumulator = airAccumulator + dt
            if tick() - lastJumpTime >= JUMP_INTERVAL then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
                lastJumpTime = tick()
            end
        end
    end
end


-- ── NOCLIP / MOVIMIENTO AGRESIVO ──────────────────────────────────────
local function setNoclipParts(char, nocollide)
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = not nocollide
        end
    end
end

local function stopNoclip()
    noclipEnabled = false
    if noclipConn  then noclipConn:Disconnect();  noclipConn  = nil end
    if noclipBV    then pcall(function() noclipBV:Destroy() end); noclipBV = nil end
    if noclipBG    then pcall(function() noclipBG:Destroy() end); noclipBG = nil end
    -- Restaurar colision y gravedad al personaje
    local char = lp.Character
    if char then
        setNoclipParts(char, false)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.PlatformStand = false end
    end
    if noclipBtn then
        noclipBtn.Text             = "NoClip  OFF"
        noclipBtn.BackgroundColor3 = BG_PANEL
        noclipBtn.TextColor3       = GRAY_TEXT
    end
end

local function startNoclip()
    noclipEnabled = true
    if noclipBtn then
        noclipBtn.Text             = "NoClip  ON"
        noclipBtn.BackgroundColor3 = WHITE
        noclipBtn.TextColor3       = Color3.fromRGB(15, 15, 15)
    end

    -- Loop que elimina colision frame a frame (necesario porque Roblox la restaura)
    noclipConn = RunService.Stepped:Connect(function()
        local char = lp.Character
        if not char then return end
        setNoclipParts(char, true)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.PlatformStand = true end

        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        -- BodyVelocity para vuelo: si el autopilot esta corriendo,
        -- dirigir hacia el waypoint con Y libre; si no, mantener en sitio
        if activeBV then return end  -- el autopilot ya maneja el BV
        if noclipBV and noclipBV.Parent then
            noclipBV.Velocity = Vector3.new(0, 0, 0)
        else
            if noclipBV then pcall(function() noclipBV:Destroy() end) end
            local bv = Instance.new("BodyVelocity")
            bv.Velocity = Vector3.new(0, 0, 0)
            bv.MaxForce = Vector3.new(4e5, 4e5, 4e5)
            bv.P        = 1250
            bv.Parent   = root
            noclipBV    = bv
        end
    end)
end

local function toggleNoclip()
    if noclipEnabled then
        stopNoclip()
    else
        startNoclip()
    end
end

local function startMovement()
    if #waypoints == 0 then setStatus("Poné waypoints primero.") return end

    -- Siempre reinicia desde WP 1
    currentIdx     = 1
    airAccumulator = 0
    wasAir         = false
    lastTick       = tick()
    lastJumpTime   = tick()
    isRunning      = true

    hbConn = RunService.Heartbeat:Connect(function() pcall(onHeartbeat) end)
    setStatus("Yendo a WP 1/" .. #waypoints)
    if startBtn then startBtn.Text = "■  Detener" end
end

-- ── RESPAWN: reanudar sin teletransporte ─────────────────────────────
-- El hbConn sigue conectado. getChar() devolverá el nuevo personaje
-- en cuanto cargue. Solo reseteamos las variables internas de movimiento
-- para que no haya acumuladores de la vida anterior.
lp.CharacterAdded:Connect(function(char)
    if not isRunning then return end
    char:WaitForChild("HumanoidRootPart", 8)
    airAccumulator = 0
    wasAir         = false
    lastTick       = tick()
    lastJumpTime   = tick()
    activeBV       = nil  -- el BV murió con el personaje anterior
    setStatus("Respawn → retomando desde WP " .. currentIdx .. "/" .. #waypoints)
end)


-- ── PERSISTENCIA (Gamepoint.json) ────────────────────────────────────
local SAVE_FILE = "Gamepoint.json"

local function encodeJSON(wp)
    local parts = {}
    for _, v in ipairs(wp) do
        parts[#parts+1] = string.format(
            "{"x":%.4f,"y":%.4f,"z":%.4f}", v.X, v.Y, v.Z)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function decodeJSON(str)
    local result = {}
    for x, y, z in str:gmatch('"x":(%-?[%d%.]+),"y":(%-?[%d%.]+),"z":(%-?[%d%.]+)') do
        result[#result+1] = Vector3.new(tonumber(x), tonumber(y), tonumber(z))
    end
    return result
end

local function saveWaypoints()
    pcall(function()
        if writefile then
            writefile(SAVE_FILE, encodeJSON(waypoints))
        end
    end)
end

local function loadWaypoints()
    pcall(function()
        if not readfile then return end
        local ok, raw = pcall(readfile, SAVE_FILE)
        if not ok or not raw or raw == "" then return end
        local loaded = decodeJSON(raw)
        for _, pos in ipairs(loaded) do
            table.insert(waypoints, pos)
            local idx = #waypoints
            markers[idx] = makeMarker(pos, idx)
        end
        if #waypoints > 0 then
            setStatus(#waypoints .. " WP cargados de Gamepoint.json")
        end
    end)
end

-- ══════════════════════════════════════════════════════════════════════
--  GUI — pill B&W glassy (mismo estilo que el scanner de sonido)
-- ══════════════════════════════════════════════════════════════════════

local BG_FRAME  = Color3.fromRGB(14, 14, 16)
local BG_PANEL  = Color3.fromRGB(24, 24, 27)
local WHITE     = Color3.fromRGB(245, 245, 245)
local GRAY_TEXT = Color3.fromRGB(190, 190, 195)
local GRAY_DARK = Color3.fromRGB(60, 60, 65)

local gui = Instance.new("ScreenGui")
gui.Name           = "_WPAutopilotGui"
gui.ResetOnSpawn   = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent         = pg

local frame = Instance.new("Frame")
frame.Size                   = UDim2.fromOffset(210, 164)
frame.Position               = UDim2.new(0, 10, 0.20, 0)
frame.BackgroundColor3       = BG_FRAME
frame.BackgroundTransparency = 0.08
frame.BorderSizePixel        = 0
frame.Active                 = true
frame.Parent                 = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 14)

-- Overlay diagonal glassy
local glassy = Instance.new("UIGradient")
glassy.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(70, 70, 75)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(30, 30, 33)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(70, 70, 75)),
})
glassy.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0,   0.55),
    NumberSequenceKeypoint.new(0.5, 0.25),
    NumberSequenceKeypoint.new(1,   0.55),
})
glassy.Rotation = 90
glassy.Parent   = frame

-- UIStroke animado sweep + pulse
local stroke = Instance.new("UIStroke")
stroke.Thickness    = 1.4
stroke.Color        = WHITE
stroke.Transparency = 0.35
stroke.LineJoinMode = Enum.LineJoinMode.Round
stroke.Parent       = frame

local strokeGrad = Instance.new("UIGradient")
strokeGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   GRAY_DARK),
    ColorSequenceKeypoint.new(0.5, WHITE),
    ColorSequenceKeypoint.new(1,   GRAY_DARK),
})
strokeGrad.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0,   0.4),
    NumberSequenceKeypoint.new(0.5, 0),
    NumberSequenceKeypoint.new(1,   0.4),
})
strokeGrad.Offset = Vector2.new(-1.5, 0)
strokeGrad.Parent = stroke

TweenService:Create(strokeGrad,
    TweenInfo.new(1.6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false),
    { Offset = Vector2.new(1.5, 0) }):Play()

TweenService:Create(stroke,
    TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
    { Transparency = 0.1 }):Play()

-- Título
local titleLbl = Instance.new("TextLabel")
titleLbl.Size               = UDim2.new(1, -16, 0, 16)
titleLbl.Position           = UDim2.new(0, 8, 0, 5)
titleLbl.BackgroundTransparency = 1
titleLbl.Text               = "AUTOPILOT — WAYPOINTS"
titleLbl.Font               = Enum.Font.GothamBlack
titleLbl.TextSize           = 9
titleLbl.TextColor3         = WHITE
titleLbl.TextXAlignment     = Enum.TextXAlignment.Left
titleLbl.Parent             = frame

-- Helper botón
local function makeBtn(text, x, y, w, h, primary)
    local b = Instance.new("TextButton")
    b.Size                   = UDim2.fromOffset(w, h)
    b.Position               = UDim2.fromOffset(x, y)
    b.BackgroundColor3       = primary and WHITE or BG_PANEL
    b.BackgroundTransparency = primary and 0 or 0.05
    b.BorderSizePixel        = 0
    b.Text                   = text
    b.Font                   = Enum.Font.GothamBold
    b.TextSize               = 9
    b.TextColor3             = primary and Color3.fromRGB(15, 15, 15) or GRAY_TEXT
    b.Parent                 = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
    local st = Instance.new("UIStroke")
    st.Thickness    = 1
    st.Color        = WHITE
    st.Transparency = primary and 1 or 0.75
    st.Parent       = b
    return b
end

-- Fila 1: [ ＋ Waypoint ] [ ✕ Último ]
local btnAdd    = makeBtn("＋  Waypoint",  8, 26, 96, 22, false)
local btnRemove = makeBtn("✕  Último",   107, 26, 95, 22, false)

-- Fila 2: [ ▶ Iniciar ] (ancho completo, primario)
startBtn = makeBtn("▶  Iniciar", 8, 52, 194, 24, true)

-- Fila 3: [ NoClip ] toggle
noclipBtn = makeBtn("NoClip  OFF", 8, 80, 194, 22, false)
noclipBtn.MouseButton1Click:Connect(toggleNoclip)

-- Fila 4: slider de velocidad (10 - 600)
-- Slider de velocidad (10 - 600)
local SLIDER_MIN = 10
local SLIDER_MAX = 600

local sliderRow = Instance.new("Frame")
sliderRow.Size               = UDim2.fromOffset(194, 22)
sliderRow.Position           = UDim2.fromOffset(8, 106)
sliderRow.BackgroundTransparency = 1
sliderRow.Parent             = frame

local track = Instance.new("Frame")
track.Size             = UDim2.new(1, -36, 0, 4)
track.Position         = UDim2.new(0, 0, 0.5, -2)
track.BackgroundColor3 = Color3.fromRGB(80, 80, 85)
track.BorderSizePixel  = 0
track.Parent           = sliderRow
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

local fill = Instance.new("Frame")
fill.Size             = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = WHITE
fill.BorderSizePixel  = 0
fill.Parent           = track
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

local sKnob = Instance.new("Frame")
sKnob.Size             = UDim2.fromOffset(12, 12)
sKnob.Position         = UDim2.new(0, -6, 0.5, -6)
sKnob.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
sKnob.BorderSizePixel  = 0
sKnob.Parent           = track
Instance.new("UICorner", sKnob).CornerRadius = UDim.new(1, 0)

local valLabel = Instance.new("TextLabel")
valLabel.Size               = UDim2.fromOffset(34, 22)
valLabel.Position           = UDim2.new(1, 2, 0, 0)
valLabel.BackgroundTransparency = 1
valLabel.Text               = tostring(SPEED)
valLabel.Font               = Enum.Font.GothamBold
valLabel.TextSize           = 9
valLabel.TextColor3         = GRAY_TEXT
valLabel.TextXAlignment     = Enum.TextXAlignment.Left
valLabel.Parent             = sliderRow

local function sliderSet(v)
    v = math.clamp(math.round(v), SLIDER_MIN, SLIDER_MAX)
    SPEED = v
    valLabel.Text = tostring(v)
    local pct = (v - SLIDER_MIN) / (SLIDER_MAX - SLIDER_MIN)
    fill.Size      = UDim2.new(pct, 0, 1, 0)
    sKnob.Position = UDim2.new(pct, -6, 0.5, -6)
end

sliderSet(SPEED)  -- inicializar posición visual

local sliderDragging = false

track.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseButton1 then
        sliderDragging = true
        local pct = math.clamp((inp.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        sliderSet(SLIDER_MIN + pct * (SLIDER_MAX - SLIDER_MIN))
    end
end)
UserInputService.InputChanged:Connect(function(inp)
    if not sliderDragging then return end
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseMovement then
        local pct = math.clamp((inp.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        sliderSet(SLIDER_MIN + pct * (SLIDER_MAX - SLIDER_MIN))
    end
end)
UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseButton1 then
        sliderDragging = false
    end
end)

-- Status (2 líneas)
statusLabel = Instance.new("TextLabel")
statusLabel.Size               = UDim2.new(1, -16, 0, 24)
statusLabel.Position           = UDim2.new(0, 8, 0, 134)
statusLabel.BackgroundTransparency = 1
statusLabel.Text               = "Sin waypoints."
statusLabel.Font               = Enum.Font.Gotham
statusLabel.TextSize           = 8
statusLabel.TextColor3         = GRAY_TEXT
statusLabel.TextXAlignment     = Enum.TextXAlignment.Left
statusLabel.TextYAlignment     = Enum.TextYAlignment.Top
statusLabel.TextWrapped        = true
statusLabel.Parent             = frame

-- Callbacks
btnAdd.MouseButton1Click:Connect(addWaypoint)
btnRemove.MouseButton1Click:Connect(removeLastWaypoint)
startBtn.MouseButton1Click:Connect(function()
    if isRunning then
        stopMovement("Detenido manualmente.")
    else
        startMovement()
    end
end)

-- Cargar waypoints guardados
loadWaypoints()

-- Drag
local dragging, dragStart, pillOrigin = false, nil, nil
frame.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging   = true
        dragStart  = inp.Position
        pillOrigin = frame.Position
    end
end)
frame.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(inp)
    if not dragging then return end
    if inp.UserInputType == Enum.UserInputType.Touch
    or inp.UserInputType == Enum.UserInputType.MouseMovement then
        local d = inp.Position - dragStart
        frame.Position = UDim2.new(
            pillOrigin.X.Scale, pillOrigin.X.Offset + d.X,
            pillOrigin.Y.Scale, pillOrigin.Y.Offset + d.Y
        )
    end
end)
