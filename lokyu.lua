--[[
    LOKYU  |  ESP • Tracers • Aimbot

    • Тёмная тема, скруглённые углы, ПК + телефон (тач, перетаскивание)
    • Кнопки: свернуть (–) и выгрузить скрипт (×, нажать дважды)
    • Без внешних библиотек. Если в экзекуторе нет Drawing API,
      отрисовка автоматически переключается на GUI-фреймы.

    ПК:      зажать ПКМ — аим | RightShift — скрыть/показать меню
    Телефон: плавающая кнопка AIM — включить/выключить аим
]]

-- ============================================================
--  СЕРВИСЫ И ОКРУЖЕНИЕ
-- ============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera
local env         = (getgenv and getgenv()) or _G
local IS_MOBILE   = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Повторный запуск: сначала выгружаем предыдущую копию
if env.LokyuUnload then
    pcall(env.LokyuUnload)
end

-- Все соединения собираем здесь, чтобы чисто отключить при выгрузке
local connections = {}
local function track(connection)
    connections[#connections + 1] = connection
    return connection
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
end))

local Unload -- объявлена заранее, определяется в конце файла
local rebuildRenderers -- пересоздаёт объекты отрисовки при смене режима
local unloaded = false

-- ============================================================
--  КОНФИГ (значения по умолчанию)
-- ============================================================
local Config = {
    ESP = {
        Enabled = true, Box = true, Name = true, Distance = true,
        Health = true, Skeleton = false, Chams = true,
        TeamCheck = true, VisibleCheck = false, Bots = true, MaxDistance = 1500,
        Colors = {
            Box        = Color3.fromRGB(255, 40, 40),
            Name       = Color3.fromRGB(255, 70, 70),
            Distance   = Color3.fromRGB(255, 140, 140),
            Skeleton   = Color3.fromRGB(255, 40, 40),
            Chams      = Color3.fromRGB(255, 0, 0),
            HealthFull = Color3.fromRGB(80, 255, 120),
            HealthLow  = Color3.fromRGB(255, 70, 70),
        },
    },
    Tracer = {
        Enabled = false, TeamCheck = true, Origin = "Bottom",
        Thickness = 1.5, Color = Color3.fromRGB(255, 40, 40),
    },
    Aim = {
        Enabled = false, Part = "Head", Smoothness = 35,
        FOV = 150, ShowFOV = false, FOVColor = Color3.fromRGB(255, 255, 255),
        TeamCheck = true, WallCheck = true,
        Active = false, -- рантайм-состояние (ПКМ / кнопка на телефоне)
    },
}
-- Режим отрисовки: Drawing API (быстрее) или GUI-фреймы (работает в любом экзекуторе).
-- На телефоне по умолчанию GUI: Drawing там часто отсутствует или является заглушкой.
Config.Render = {Mode = IS_MOBILE and "GUI" or "Drawing"}
local ESP, TRACER, AIM = Config.ESP, Config.Tracer, Config.Aim

-- ============================================================
--  ТЕМА И ПАРАМЕТРЫ АДАПТИВНОСТИ
-- ============================================================
local Theme = {
    Background = Color3.fromRGB(16, 16, 22),
    Surface    = Color3.fromRGB(24, 24, 33),
    Element    = Color3.fromRGB(32, 32, 44),
    Accent     = Color3.fromRGB(124, 92, 255),
    Text       = Color3.fromRGB(235, 235, 245),
    SubText    = Color3.fromRGB(140, 140, 165),
    Danger     = Color3.fromRGB(220, 72, 72),
}

local ROW_H     = IS_MOBILE and 38 or 32 -- высота строки (на телефоне крупнее для нажатий)
local TITLE_H   = IS_MOBILE and 40 or 36
local TAB_H     = IS_MOBILE and 32 or 28
local FONT      = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

-- ============================================================
--  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================
local function create(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props) do
        inst[key] = value
    end
    inst.Parent = parent
    return inst
end

local function round(inst, radius)
    return create("UICorner", {CornerRadius = UDim.new(0, radius)}, inst)
end

local function addStroke(inst, color, thickness, transparency)
    return create("UIStroke", {
        Color = color, Thickness = thickness, Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function makeLabel(parent, text, size, position, align)
    return create("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextColor3 = Theme.Text,
        Font = FONT, TextSize = 13, Size = size, Position = position,
        TextXAlignment = align or Enum.TextXAlignment.Left,
    }, parent)
end

-- Монтирует ScreenGui максимально безопасным из доступных способов
local function mountGui(gui, order)
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = order
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end

    local mounted = false
    if gethui then
        mounted = pcall(function() gui.Parent = gethui() end)
    end
    if not mounted then
        mounted = pcall(function() gui.Parent = CoreGui end)
    end
    if not mounted then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
end

-- ============================================================
--  СЛОЙ ОТРИСОВКИ: Drawing API или запасной вариант на GUI
-- ============================================================
local Draw = {}
local overlay -- ScreenGui для запасной отрисовки

local function removeDrawing(obj)
    if not pcall(function() obj:Remove() end) then
        pcall(function() obj:Destroy() end)
    end
end

local HAS_DRAWING = false
do
    local ok, probe = pcall(function() return Drawing.new("Line") end)
    if ok and probe then
        HAS_DRAWING = true
        removeDrawing(probe)
    end
end

-- Запасной объект: имитирует Drawing-объект (Line/Square/Circle/Text) через Frame/TextLabel
local function newFallback(kind)
    if not overlay then
        overlay = create("ScreenGui", {Name = "LK_Overlay_" .. math.random(100000, 999999)})
        mountGui(overlay, 998)
    end

    local state, inst, stroke = {}, nil, nil
    local apply = {}

    if kind == "Line" then
        inst = create("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0}, overlay)
        local function geometry()
            local a, b = state.From, state.To
            if not (a and b) then return end
            local delta = b - a
            inst.Size = UDim2.fromOffset(delta.Magnitude, state.Thickness or 1)
            inst.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
            inst.Rotation = math.deg(math.atan2(delta.Y, delta.X))
        end
        apply.From, apply.To, apply.Thickness = geometry, geometry, geometry
        apply.Color = function(v) inst.BackgroundColor3 = v end
    elseif kind == "Square" then
        inst = create("Frame", {BorderSizePixel = 0, BackgroundTransparency = 1}, overlay)
        stroke = create("UIStroke", {Thickness = 1}, inst)
        apply.Position = function(v) inst.Position = UDim2.fromOffset(v.X, v.Y) end
        apply.Size = function(v) inst.Size = UDim2.fromOffset(v.X, v.Y) end
        apply.Thickness = function(v) stroke.Thickness = v end
        apply.Color = function(v) inst.BackgroundColor3 = v; stroke.Color = v end
        apply.Filled = function(v)
            inst.BackgroundTransparency = v and 0 or 1
            stroke.Enabled = not v
        end
    elseif kind == "Circle" then
        inst = create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundTransparency = 1,
        }, overlay)
        create("UICorner", {CornerRadius = UDim.new(0.5, 0)}, inst)
        stroke = create("UIStroke", {Thickness = 1}, inst)
        apply.Position = function(v) inst.Position = UDim2.fromOffset(v.X, v.Y) end
        apply.Radius = function(v) inst.Size = UDim2.fromOffset(v * 2, v * 2) end
        apply.Thickness = function(v) stroke.Thickness = v end
        apply.Color = function(v) stroke.Color = v end
    else -- Text
        inst = create("TextLabel", {
            BackgroundTransparency = 1, BorderSizePixel = 0, Font = FONT,
            AutomaticSize = Enum.AutomaticSize.XY, TextSize = 13,
        }, overlay)
        apply.Text = function(v) inst.Text = v end
        apply.Position = function(v) inst.Position = UDim2.fromOffset(v.X, v.Y) end
        apply.Size = function(v) inst.TextSize = v end
        apply.Color = function(v) inst.TextColor3 = v end
        apply.Outline = function(v) inst.TextStrokeTransparency = v and 0 or 1 end
        apply.Center = function(v) inst.AnchorPoint = Vector2.new(v and 0.5 or 0, 0) end
    end
    apply.Visible = function(v) inst.Visible = v end

    return setmetatable({}, {
        __index = function(_, key)
            if key == "Remove" or key == "Destroy" then
                return function() inst:Destroy() end
            end
            return state[key]
        end,
        __newindex = function(_, key, value)
            state[key] = value
            local handler = apply[key]
            if handler then handler(value) end
        end,
    })
end

-- Фактически используемый режим (Drawing недоступен -> всегда GUI)
function Draw.Mode()
    return (Config.Render.Mode == "Drawing" and HAS_DRAWING) and "Drawing" or "GUI"
end

function Draw.new(kind, props)
    local obj
    if Draw.Mode() == "Drawing" then
        local ok, created = pcall(Drawing.new, kind)
        if ok and created then
            obj = created
            pcall(function() obj.Transparency = 1 end)
        end
    end
    obj = obj or newFallback(kind) -- если Drawing не создал объект — берём GUI
    pcall(function() obj.Visible = false end)
    for key, value in pairs(props or {}) do
        pcall(function() obj[key] = value end)
    end
    return obj
end

-- ============================================================
--  UI-БИБЛИОТЕКА (кастомная, ПК + тач)
-- ============================================================

-- Единый обработчик перетаскивания: окно, ползунки, плавающая кнопка
local activeDrag
local function beginDrag(input, onMove, onEnd)
    activeDrag = onMove
    local connection
    connection = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then
            connection:Disconnect()
            if activeDrag == onMove then activeDrag = nil end
            if onEnd then onEnd() end
        end
    end)
end

track(UserInputService.InputChanged:Connect(function(input)
    if activeDrag and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        activeDrag(input)
    end
end))

local function isPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

-- Делает handle «ручкой» для перемещения target. Короткое нажатие без сдвига вызывает onTap
local function makeDraggable(handle, target, onTap)
    handle.InputBegan:Connect(function(input)
        if not isPress(input) then return end
        local startInput = input.Position
        local startPos = target.AbsolutePosition
        local moved = false

        beginDrag(input, function(current)
            local delta = current.Position - startInput
            if delta.Magnitude > 6 then moved = true end
            if not moved then return end
            local screen = target.Parent.AbsoluteSize
            local size = target.AbsoluteSize
            -- Не даём окну полностью уйти за экран
            local x = math.clamp(startPos.X + delta.X, 60 - size.X, screen.X - 60)
            local y = math.clamp(startPos.Y + delta.Y, 0, screen.Y - 40)
            target.Position = UDim2.fromOffset(x, y)
        end, function()
            if not moved and onTap then onTap() end
        end)
    end)
end

-- Универсальная полоса-ползунок. Возвращает setAlpha, bar, fill
local function sliderBar(parent, page, y, initialAlpha, onChange)
    local hit = create("TextButton", {
        Text = "", BackgroundTransparency = 1, ZIndex = 3,
        Position = UDim2.new(0, 0, 0, y - 8), Size = UDim2.new(1, 0, 0, 24),
    }, parent)
    local bar = create("Frame", {
        Position = UDim2.new(0, 10, 0, y), Size = UDim2.new(1, -20, 0, 6),
        BackgroundColor3 = Theme.Surface, BorderSizePixel = 0,
    }, parent)
    round(bar, 3)
    local fill = create("Frame", {
        Size = UDim2.fromScale(initialAlpha, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
    }, bar)
    round(fill, 3)
    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(initialAlpha, 0.5),
        Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, bar)
    round(knob, 7)

    local function setAlpha(alpha)
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
    end

    local function fromInput(input)
        local alpha = math.clamp((input.Position.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        setAlpha(alpha)
        onChange(alpha)
    end

    hit.InputBegan:Connect(function(input)
        if not isPress(input) then return end
        page.ScrollingEnabled = false -- чтобы страница не скроллилась под пальцем
        fromInput(input)
        beginDrag(input, fromInput, function() page.ScrollingEnabled = true end)
    end)

    return setAlpha, bar, fill
end

-- ---------- Элементы вкладки ----------
local Tab = {}
Tab.__index = Tab

function Tab:_row(height)
    self.Order = self.Order + 1
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0, LayoutOrder = self.Order,
    }, self.Page)
    round(row, 8)
    return row
end

function Tab:AddSection(text)
    self.Order = self.Order + 1
    local label = create("TextLabel", {
        BackgroundTransparency = 1, Text = string.upper(text), TextColor3 = Theme.Accent,
        Font = FONT_BOLD, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1, 0, 0, 20), LayoutOrder = self.Order,
    }, self.Page)
    create("UIPadding", {PaddingLeft = UDim.new(0, 4)}, label)
end

function Tab:AddLabel(text, height)
    local row = self:_row(height or ROW_H)
    local label = makeLabel(row, text, UDim2.new(1, -24, 1, 0), UDim2.fromOffset(12, 0))
    label.TextColor3 = Theme.SubText
    label.TextSize = 12
    label.TextWrapped = true
    return label
end

function Tab:AddToggle(text, default, callback)
    local row = self:_row(ROW_H)
    makeLabel(row, text, UDim2.new(1, -64, 1, 0), UDim2.fromOffset(12, 0))

    local switch = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(38, 20), BorderSizePixel = 0,
    }, row)
    round(switch, 10)
    local knob = create("Frame", {
        Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, switch)
    round(knob, 7)

    local state = default
    local function render(animate)
        local knobPos = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        local color = state and Theme.Accent or Theme.Surface
        if animate then
            local info = TweenInfo.new(0.12)
            TweenService:Create(knob, info, {Position = knobPos}):Play()
            TweenService:Create(switch, info, {BackgroundColor3 = color}):Play()
        else
            knob.Position = knobPos
            switch.BackgroundColor3 = color
        end
    end
    render(false)

    local button = create("TextButton", {
        Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2,
    }, row)
    button.Activated:Connect(function()
        state = not state
        render(true)
        callback(state)
    end)
end

function Tab:AddSlider(text, min, max, default, decimals, callback)
    local row = self:_row(ROW_H + 16)
    makeLabel(row, text, UDim2.new(1, -90, 0, ROW_H - 8), UDim2.fromOffset(12, 2))
    local valueLabel = makeLabel(row, "", UDim2.fromOffset(70, ROW_H - 8), UDim2.new(1, -82, 0, 2), Enum.TextXAlignment.Right)
    valueLabel.TextColor3 = Theme.SubText

    local factor = 10 ^ decimals
    local function setValue(value, silent)
        value = math.clamp(math.floor(value * factor + 0.5) / factor, min, max)
        valueLabel.Text = string.format("%." .. decimals .. "f", value)
        if not silent then callback(value) end
    end

    sliderBar(row, self.Page, ROW_H + 2, (default - min) / (max - min), function(alpha)
        setValue(min + (max - min) * alpha)
    end)
    setValue(default, true)
end

-- Сегментированный переключатель (удобнее выпадающего списка на телефоне)
function Tab:AddSelector(text, options, default, callback)
    local row = self:_row(ROW_H + 34)
    makeLabel(row, text, UDim2.new(1, -24, 0, ROW_H - 8), UDim2.fromOffset(12, 2))

    local holder = create("Frame", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(10, ROW_H - 4),
        Size = UDim2.new(1, -20, 0, 28),
    }, row)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, holder)

    local buttons = {}
    local function render(selected)
        for name, button in pairs(buttons) do
            local active = name == selected
            button.BackgroundColor3 = active and Theme.Accent or Theme.Surface
            button.TextColor3 = active and Color3.new(1, 1, 1) or Theme.SubText
        end
    end

    local count = #options
    for index, option in ipairs(options) do
        local button = create("TextButton", {
            Text = option, Font = FONT, TextScaled = true, AutoButtonColor = false,
            BorderSizePixel = 0, LayoutOrder = index,
            Size = UDim2.new(1 / count, -(6 * (count - 1)) / count, 1, 0),
        }, holder)
        round(button, 6)
        create("UITextSizeConstraint", {MaxTextSize = 12, MinTextSize = 8}, button)
        buttons[option] = button
        button.Activated:Connect(function()
            render(option)
            callback(option)
        end)
    end
    render(default)
end

-- Цвет: плашка-превью, по нажатию раскрываются три ползунка H / S / V
function Tab:AddColor(text, default, callback)
    local panelHeight = 3 * 26 + 8
    local row = self:_row(ROW_H)
    makeLabel(row, text, UDim2.new(1, -70, 0, ROW_H), UDim2.fromOffset(12, 0))

    local swatch = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0, ROW_H / 2),
        Size = UDim2.fromOffset(36, 18), BackgroundColor3 = default, BorderSizePixel = 0,
    }, row)
    round(swatch, 6)
    addStroke(swatch, Color3.new(1, 1, 1), 1, 0.7)

    local panel = create("Frame", {
        BackgroundTransparency = 1, Visible = false,
        Position = UDim2.fromOffset(0, ROW_H), Size = UDim2.new(1, 0, 0, panelHeight),
    }, row)

    local h, s, v = default:ToHSV()
    local satGradient, valGradient

    local function refresh(fire)
        local color = Color3.fromHSV(h, s, v)
        swatch.BackgroundColor3 = color
        satGradient.Color = ColorSequence.new(Color3.fromHSV(h, 0, 1), Color3.fromHSV(h, 1, 1))
        valGradient.Color = ColorSequence.new(Color3.new(0, 0, 0), Color3.fromHSV(h, s, 1))
        if fire then callback(color) end
    end

    local function colorBar(index, alpha, onChange)
        local _, bar, fill = sliderBar(panel, self.Page, 12 + (index - 1) * 26, alpha, onChange)
        bar.Size = UDim2.new(1, -20, 0, 10)
        bar.BackgroundColor3 = Color3.new(1, 1, 1)
        fill.Visible = false
        round(bar, 5)
        return bar
    end

    local hueKeys = {}
    for i = 0, 6 do
        hueKeys[#hueKeys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i / 6) % 1, 1, 1))
    end
    local hueBar = colorBar(1, h, function(a) h = a; refresh(true) end)
    create("UIGradient", {Color = ColorSequence.new(hueKeys)}, hueBar)
    satGradient = create("UIGradient", {}, colorBar(2, s, function(a) s = a; refresh(true) end))
    valGradient = create("UIGradient", {}, colorBar(3, v, function(a) v = a; refresh(true) end))
    refresh(false)

    local header = create("TextButton", {
        Text = "", BackgroundTransparency = 1, ZIndex = 2, Size = UDim2.new(1, 0, 0, ROW_H),
    }, row)
    header.Activated:Connect(function()
        panel.Visible = not panel.Visible
        row.Size = UDim2.new(1, 0, 0, panel.Visible and (ROW_H + panelHeight) or ROW_H)
    end)
end

function Tab:AddButton(text, callback, color)
    local row = self:_row(ROW_H)
    row.BackgroundColor3 = color or Theme.Accent
    local button = create("TextButton", {
        Text = text, Font = FONT_BOLD, TextSize = 13, TextColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
    }, row)
    button.Activated:Connect(callback)
end

-- ---------- Окно ----------
local function createWindow(title)
    local gui = create("ScreenGui", {Name = "LK_" .. math.random(100000, 999999)})
    mountGui(gui, 999)

    -- Размер подстраивается под экран: средний на ПК, компактный на телефоне
    local viewport = Camera.ViewportSize
    local width  = math.min(IS_MOBILE and 400 or 460, viewport.X * 0.92)
    local height = math.min(IS_MOBILE and 262 or 340, viewport.Y * 0.80)

    local main = create("Frame", {
        Name = "Main", Size = UDim2.fromOffset(width, height),
        Position = UDim2.new(0.5, -width / 2, 0.5, -height / 2),
        BackgroundColor3 = Theme.Background, BorderSizePixel = 0, ClipsDescendants = true,
    }, gui)
    round(main, 12)
    addStroke(main, Theme.Accent, 1, 0.55)

    -- Заголовок (он же ручка для перетаскивания)
    local titleBar = create("Frame", {Size = UDim2.new(1, 0, 0, TITLE_H), BackgroundTransparency = 1}, main)
    local dot = create("Frame", {
        Position = UDim2.fromOffset(14, TITLE_H / 2 - 4), Size = UDim2.fromOffset(8, 8),
        BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
    }, titleBar)
    round(dot, 4)
    makeLabel(titleBar, title, UDim2.new(1, -110, 1, 0), UDim2.fromOffset(30, 0)).Font = FONT_BOLD

    local buttonSize = TITLE_H - 10
    local function headerButton(text, offsetX)
        local button = create("TextButton", {
            Text = text, Font = FONT_BOLD, TextSize = 16, TextColor3 = Theme.Text,
            BackgroundColor3 = Theme.Element, AutoButtonColor = true, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, offsetX, 0.5, 0),
            Size = UDim2.fromOffset(buttonSize, buttonSize),
        }, titleBar)
        round(button, 8)
        return button
    end
    local closeButton = headerButton("×", -8)
    local minimizeButton = headerButton("–", -(8 + buttonSize + 6))

    makeDraggable(titleBar, main)

    -- Тело окна
    local body = create("Frame", {
        Position = UDim2.fromOffset(0, TITLE_H), Size = UDim2.new(1, 0, 1, -TITLE_H),
        BackgroundTransparency = 1,
    }, main)
    create("Frame", {Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Element, BorderSizePixel = 0}, body)

    -- Сворачивание: остаётся только заголовок
    local minimized = false
    minimizeButton.Activated:Connect(function()
        minimized = not minimized
        minimizeButton.Text = minimized and "+" or "–"
        if minimized then body.Visible = false end
        TweenService:Create(main, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
            Size = UDim2.fromOffset(width, minimized and TITLE_H or height),
        }):Play()
        if not minimized then body.Visible = true end
    end)

    local tabBar = create("Frame", {
        Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, TAB_H), BackgroundTransparency = 1,
    }, body)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, tabBar)
    local pages = create("Frame", {
        Position = UDim2.fromOffset(0, TAB_H + 16), Size = UDim2.new(1, 0, 1, -(TAB_H + 16)),
        BackgroundTransparency = 1,
    }, body)

    local window = {Gui = gui, Main = main, CloseButton = closeButton}
    local tabs = {}

    local function selectTab(entry)
        for _, tab in ipairs(tabs) do
            local active = tab == entry
            tab.Page.Visible = active
            tab.Button.BackgroundColor3 = active and Theme.Accent or Theme.Surface
            tab.Button.TextColor3 = active and Color3.new(1, 1, 1) or Theme.SubText
        end
    end

    function window:AddTab(name)
        local button = create("TextButton", {
            Text = name, Font = FONT_BOLD, TextSize = 13, AutoButtonColor = false,
            BorderSizePixel = 0, LayoutOrder = #tabs + 1,
        }, tabBar)
        round(button, 8)

        local page = create("ScrollingFrame", {
            Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -16, 1, -8),
            BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
            ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Accent,
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
        }, pages)
        create("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, page)
        create("UIPadding", {PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6)}, page)

        local entry = {Button = button, Page = page}
        tabs[#tabs + 1] = entry
        -- Кнопки вкладок делят ширину поровну
        local count = #tabs
        for _, tab in ipairs(tabs) do
            tab.Button.Size = UDim2.new(1 / count, -(6 * (count - 1)) / count, 1, 0)
        end
        button.Activated:Connect(function() selectTab(entry) end)
        if count == 1 then selectTab(entry) end

        return setmetatable({Page = page, Order = 0}, Tab)
    end

    return window
end

-- ============================================================
--  СБОРКА ОКНА И ПЛАВАЮЩЕЙ КНОПКИ АИМА (ТЕЛЕФОН)
-- ============================================================
local window = createWindow("LOKYU")

local aimButton = create("TextButton", {
    Text = "AIM", Font = FONT_BOLD, TextSize = 14, TextColor3 = Theme.Text,
    BackgroundColor3 = Theme.Surface, AutoButtonColor = false, BorderSizePixel = 0,
    Size = UDim2.fromOffset(60, 60), Position = UDim2.new(1, -96, 0.55, 0), Visible = false,
}, window.Gui)
round(aimButton, 30)
addStroke(aimButton, Theme.Accent, 2, 0.1)

local function refreshAimButton()
    aimButton.Visible = UserInputService.TouchEnabled and AIM.Enabled
    aimButton.BackgroundColor3 = AIM.Active and Theme.Accent or Theme.Surface
    aimButton.Text = AIM.Active and "ON" or "AIM"
end
-- Тап — включить/выключить аим, перетаскивание — переместить кнопку
makeDraggable(aimButton, aimButton, function()
    AIM.Active = not AIM.Active
    refreshAimButton()
end)

-- ---------- Вкладка ESP ----------
local espTab = window:AddTab("ESP")
espTab:AddSection("Main")
espTab:AddToggle("Enable ESP", ESP.Enabled, function(v) ESP.Enabled = v end)
espTab:AddToggle("Team Check", ESP.TeamCheck, function(v) ESP.TeamCheck = v end)
espTab:AddToggle("Visible Check", ESP.VisibleCheck, function(v) ESP.VisibleCheck = v end)
espTab:AddToggle("Include Bots (NPCs)", ESP.Bots, function(v) ESP.Bots = v end)
espTab:AddSlider("Max Distance", 100, 5000, ESP.MaxDistance, 0, function(v) ESP.MaxDistance = v end)
espTab:AddSection("Elements")
espTab:AddToggle("2D Box", ESP.Box, function(v) ESP.Box = v end)
espTab:AddColor("Box Color", ESP.Colors.Box, function(c) ESP.Colors.Box = c end)
espTab:AddToggle("Name", ESP.Name, function(v) ESP.Name = v end)
espTab:AddColor("Name Color", ESP.Colors.Name, function(c) ESP.Colors.Name = c end)
espTab:AddToggle("Distance", ESP.Distance, function(v) ESP.Distance = v end)
espTab:AddColor("Distance Color", ESP.Colors.Distance, function(c) ESP.Colors.Distance = c end)
espTab:AddToggle("Health Bar", ESP.Health, function(v) ESP.Health = v end)
espTab:AddColor("Health: Full", ESP.Colors.HealthFull, function(c) ESP.Colors.HealthFull = c end)
espTab:AddColor("Health: Low", ESP.Colors.HealthLow, function(c) ESP.Colors.HealthLow = c end)
espTab:AddToggle("Skeleton", ESP.Skeleton, function(v) ESP.Skeleton = v end)
espTab:AddColor("Skeleton Color", ESP.Colors.Skeleton, function(c) ESP.Colors.Skeleton = c end)
espTab:AddToggle("Chams (glow through walls)", ESP.Chams, function(v) ESP.Chams = v end)
espTab:AddColor("Chams Color", ESP.Colors.Chams, function(c) ESP.Colors.Chams = c end)

-- ---------- Вкладка Tracers ----------
local tracerTab = window:AddTab("Tracers")
tracerTab:AddSection("Tracers")
tracerTab:AddToggle("Enable Tracers", TRACER.Enabled, function(v) TRACER.Enabled = v end)
tracerTab:AddToggle("Team Check", TRACER.TeamCheck, function(v) TRACER.TeamCheck = v end)
tracerTab:AddSelector("Origin", {"Bottom", "Center"}, TRACER.Origin, function(v) TRACER.Origin = v end)
tracerTab:AddSlider("Thickness", 1, 5, TRACER.Thickness, 1, function(v) TRACER.Thickness = v end)
tracerTab:AddColor("Color", TRACER.Color, function(c) TRACER.Color = c end)
tracerTab:AddLabel("Max distance and the Bots toggle are shared with ESP.", 28)

-- ---------- Вкладка Aimbot ----------
local aimTab = window:AddTab("Aimbot")
aimTab:AddSection("Main")
aimTab:AddToggle("Enable Aimbot", AIM.Enabled, function(v)
    AIM.Enabled = v
    if not v then AIM.Active = false end
    refreshAimButton()
end)
aimTab:AddSelector("Target Part", {"Head", "Torso", "HumanoidRootPart"}, AIM.Part, function(v) AIM.Part = v end)
aimTab:AddSlider("Smoothness (0 = instant)", 0, 100, AIM.Smoothness, 0, function(v) AIM.Smoothness = v end)
aimTab:AddSection("Checks")
aimTab:AddToggle("Team Check", AIM.TeamCheck, function(v) AIM.TeamCheck = v end)
aimTab:AddToggle("Wall Check", AIM.WallCheck, function(v) AIM.WallCheck = v end)
aimTab:AddSection("FOV")
aimTab:AddToggle("Show FOV Circle", AIM.ShowFOV, function(v) AIM.ShowFOV = v end)
aimTab:AddSlider("FOV Radius", 20, 600, AIM.FOV, 0, function(v) AIM.FOV = v end)
aimTab:AddColor("FOV Color", AIM.FOVColor, function(c) AIM.FOVColor = c end)
aimTab:AddSection("Activation")
aimTab:AddLabel("PC: hold Right Mouse Button.\nMobile: tap the floating AIM button (drag to move it).", 44)

-- ---------- Вкладка Misc ----------
local miscTab = window:AddTab("Misc")
miscTab:AddSection("Rendering")
miscTab:AddSelector("Render Mode", {"Drawing", "GUI"}, Config.Render.Mode, function(v)
    Config.Render.Mode = v
    rebuildRenderers()
end)
local statusLabel = miscTab:AddLabel("", 28)
miscTab:AddLabel("If ESP / FOV are invisible, switch Render Mode to GUI.", 40)
miscTab:AddSection("Info")
miscTab:AddLabel("RightShift — show / hide menu.\n[–] minimize, [×] unload (press twice).", 44)
miscTab:AddButton("Unload Script", function() Unload() end, Theme.Danger)

-- ============================================================
--  ДВИЖОК: ПРОВЕРКИ (команда, видимость)
-- ============================================================
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true -- игнорируем непроходимые декорации/триггеры

local function isTeammate(player)
    local myTeam = LocalPlayer.Team
    return myTeam ~= nil and player.Team == myTeam
end

-- Нет ли преграды между камерой и частью (Wall Check / Visible Check)
local function isVisible(part, character)
    local origin = Camera.CFrame.Position
    local ignore = {Camera}
    if LocalPlayer.Character then ignore[2] = LocalPlayer.Character end
    rayParams.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(origin, part.Position - origin, rayParams)
    return hit == nil or hit.Instance:IsDescendantOf(character)
end

-- ============================================================
--  ДВИЖОК: ESP + TRACERS
-- ============================================================
local BONES_R15 = {
    {"Head", "UpperTorso"}, {"UpperTorso", "LowerTorso"},
    {"UpperTorso", "LeftUpperArm"}, {"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"},
    {"UpperTorso", "RightUpperArm"}, {"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"},
    {"LowerTorso", "LeftUpperLeg"}, {"LeftUpperLeg", "LeftLowerLeg"}, {"LeftLowerLeg", "LeftFoot"},
    {"LowerTorso", "RightUpperLeg"}, {"RightUpperLeg", "RightLowerLeg"}, {"RightLowerLeg", "RightFoot"},
}
local BONES_R6 = {
    {"Head", "Torso"}, {"Torso", "Left Arm"}, {"Torso", "Right Arm"},
    {"Torso", "Left Leg"}, {"Torso", "Right Leg"},
}

local espObjects = {}

local function createEsp()
    local e = {
        Shown = false,
        Box = Draw.new("Square", {Thickness = 1, Filled = false}),
        Name = Draw.new("Text", {Size = 13, Center = true, Outline = true}),
        Distance = Draw.new("Text", {Size = 12, Center = true, Outline = true}),
        HealthBack = Draw.new("Square", {Filled = true, Color = Color3.new(0, 0, 0)}),
        HealthFill = Draw.new("Square", {Filled = true}),
        Tracer = Draw.new("Line", {Thickness = 1}),
        -- Chams: Highlight с AlwaysOnTop виден сквозь любые преграды
        Chams = create("Highlight", {
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Enabled = false,
            FillTransparency = 0.5, OutlineTransparency = 0,
        }, window.Gui),
        Bones = {},
    }
    for i = 1, #BONES_R15 do
        e.Bones[i] = Draw.new("Line", {Thickness = 1})
    end
    return e
end

local function destroyEsp(e)
    for key, obj in pairs(e) do
        if key == "Bones" then
            for _, line in ipairs(obj) do removeDrawing(line) end
        elseif key == "Chams" then
            obj:Destroy()
        elseif key ~= "Shown" then
            removeDrawing(obj)
        end
    end
end

-- Скрывает всё, кроме трассера
local function hideElements(e)
    e.Box.Visible = false
    e.Name.Visible = false
    e.Distance.Visible = false
    e.HealthBack.Visible = false
    e.HealthFill.Visible = false
    for _, line in ipairs(e.Bones) do line.Visible = false end
    e.Chams.Enabled = false
end

local function hideEsp(e)
    if not e.Shown then return end
    e.Shown = false
    hideElements(e)
    e.Tracer.Visible = false
end

-- entity: Player или Model бота (NPC с Humanoid, не принадлежащий игроку)
local function updateEsp(entity, e, cam, viewport)
    local isPlayer = entity:IsA("Player")
    if not isPlayer and not ESP.Bots then return hideEsp(e) end
    local character = isPlayer and entity.Character or entity
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local head = character and character:FindFirstChild("Head")
    if not (humanoid and root and head) or humanoid.Health <= 0 then return hideEsp(e) end

    local distance = (cam.CFrame.Position - root.Position).Magnitude
    if distance > ESP.MaxDistance then return hideEsp(e) end

    local rootPos = cam:WorldToViewportPoint(root.Position)
    if rootPos.Z <= 0 then return hideEsp(e) end -- позади камеры

    local teammate = isPlayer and isTeammate(entity)
    local espOn = ESP.Enabled and not (ESP.TeamCheck and teammate)
    if espOn and ESP.VisibleCheck and not isVisible(head, character) then espOn = false end
    local tracerOn = TRACER.Enabled and not (TRACER.TeamCheck and teammate)
    if not (espOn or tracerOn) then return hideEsp(e) end

    e.Shown = true

    -- Трассер: от низа/центра экрана к игроку
    e.Tracer.Visible = tracerOn
    if tracerOn then
        e.Tracer.From = (TRACER.Origin == "Center") and (viewport / 2) or Vector2.new(viewport.X / 2, viewport.Y)
        e.Tracer.To = Vector2.new(rootPos.X, rootPos.Y)
        e.Tracer.Color = TRACER.Color
        e.Tracer.Thickness = TRACER.Thickness
    end

    if not espOn then return hideElements(e) end

    e.Chams.Enabled = ESP.Chams
    if ESP.Chams then
        if e.Chams.Adornee ~= character then e.Chams.Adornee = character end
        e.Chams.FillColor = ESP.Colors.Chams
        e.Chams.OutlineColor = ESP.Colors.Chams
    end

    -- Габариты бокса считаем по проекции макушки и ступней
    local top = cam:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y / 2 + 0.15, 0))
    local legOffset = (humanoid.RigType == Enum.HumanoidRigType.R6) and 3 or (humanoid.HipHeight + root.Size.Y / 2)
    local bottom = cam:WorldToViewportPoint(root.Position - Vector3.new(0, legOffset + 0.15, 0))
    local boxH = math.abs(bottom.Y - top.Y)
    local boxW = boxH * 0.55
    local boxX = rootPos.X - boxW / 2
    local boxY = math.min(top.Y, bottom.Y)

    e.Box.Visible = ESP.Box
    if ESP.Box then
        e.Box.Position = Vector2.new(boxX, boxY)
        e.Box.Size = Vector2.new(boxW, boxH)
        e.Box.Color = ESP.Colors.Box
    end

    e.Name.Visible = ESP.Name
    if ESP.Name then
        e.Name.Text = isPlayer and entity.DisplayName or entity.Name
        e.Name.Position = Vector2.new(rootPos.X, boxY - 16)
        e.Name.Color = ESP.Colors.Name
    end

    e.Distance.Visible = ESP.Distance
    if ESP.Distance then
        e.Distance.Text = string.format("%d studs", math.floor(distance))
        e.Distance.Position = Vector2.new(rootPos.X, boxY + boxH + 2)
        e.Distance.Color = ESP.Colors.Distance
    end

    -- Полоса здоровья слева от бокса: цвет плавно меняется от Full к Low
    e.HealthBack.Visible = ESP.Health
    e.HealthFill.Visible = ESP.Health
    if ESP.Health then
        local hp = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
        local barX = boxX - 6
        e.HealthBack.Position = Vector2.new(barX - 1, boxY - 1)
        e.HealthBack.Size = Vector2.new(4, boxH + 2)
        e.HealthFill.Position = Vector2.new(barX, boxY + boxH * (1 - hp))
        e.HealthFill.Size = Vector2.new(2, boxH * hp)
        e.HealthFill.Color = ESP.Colors.HealthLow:Lerp(ESP.Colors.HealthFull, hp)
    end

    -- Скелет: линии между суставами в экранных координатах
    local bones = (humanoid.RigType == Enum.HumanoidRigType.R15) and BONES_R15 or BONES_R6
    for i, line in ipairs(e.Bones) do
        local shown = false
        local pair = bones[i]
        if ESP.Skeleton and pair then
            local partA = character:FindFirstChild(pair[1])
            local partB = character:FindFirstChild(pair[2])
            if partA and partB then
                local a = cam:WorldToViewportPoint(partA.Position)
                local b = cam:WorldToViewportPoint(partB.Position)
                if a.Z > 0 and b.Z > 0 then
                    line.From = Vector2.new(a.X, a.Y)
                    line.To = Vector2.new(b.X, b.Y)
                    line.Color = ESP.Colors.Skeleton
                    shown = true
                end
            end
        end
        line.Visible = shown
    end
end

local function addPlayer(player)
    if player ~= LocalPlayer and not espObjects[player] then
        espObjects[player] = createEsp()
    end
end

local function removePlayer(player)
    local e = espObjects[player]
    if e then
        destroyEsp(e)
        espObjects[player] = nil
    end
end

-- Бот = Model с Humanoid, который не является персонажем игрока
local function addBot(humanoid)
    local model = humanoid.Parent
    if model and model:IsA("Model") and not espObjects[model]
        and not Players:GetPlayerFromCharacter(model) then
        espObjects[model] = createEsp()
    end
end

local function populateEntities()
    for _, player in ipairs(Players:GetPlayers()) do addPlayer(player) end
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("Humanoid") then addBot(descendant) end
    end
end
populateEntities()

-- Новые боты: небольшая задержка, чтобы отличить их от загружающихся персонажей игроков
track(Workspace.DescendantAdded:Connect(function(descendant)
    if descendant:IsA("Humanoid") then
        task.delay(1, function() addBot(descendant) end)
    end
end))
track(Players.PlayerAdded:Connect(addPlayer))
track(Players.PlayerRemoving:Connect(removePlayer))

-- ============================================================
--  ДВИЖОК: AIMBOT
-- ============================================================
local function createFov()
    return Draw.new("Circle", {Thickness = 1.5, NumSides = 64, Filled = false})
end
local fovCircle = createFov()

rebuildRenderers = function()
    for player, e in pairs(espObjects) do
        destroyEsp(e)
        espObjects[player] = nil
    end
    removeDrawing(fovCircle)
    fovCircle = createFov()
    populateEntities()
end

-- Центр FOV: центр экрана на телефоне / в lock-режиме, иначе позиция курсора
local function getAimOrigin(cam)
    if IS_MOBILE or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return cam.ViewportSize / 2
    end
    return UserInputService:GetMouseLocation()
end

local function getAimPart(character)
    local part
    if AIM.Part == "Head" then
        part = character:FindFirstChild("Head")
    elseif AIM.Part == "Torso" then
        part = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    end
    return part or character:FindFirstChild("HumanoidRootPart")
end

-- Ближайшая к центру FOV цель, прошедшая все проверки
local function getTarget(cam)
    local origin = getAimOrigin(cam)
    local bestPart, bestDistance = nil, AIM.FOV

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not (AIM.TeamCheck and isTeammate(player)) then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local part = character and getAimPart(character)
            if humanoid and part and humanoid.Health > 0 then
                local pos = cam:WorldToViewportPoint(part.Position)
                if pos.Z > 0 then
                    local dist = (Vector2.new(pos.X, pos.Y) - origin).Magnitude
                    if dist < bestDistance and (not AIM.WallCheck or isVisible(part, character)) then
                        bestPart, bestDistance = part, dist
                    end
                end
            end
        end
    end
    return bestPart
end

-- Наведение камеры: BindToRenderStep с приоритетом после Camera, чтобы игра не перебивала поворот
local BIND_NAME = "LokyuAim"
RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
    if not (AIM.Enabled and AIM.Active) then return end
    local cam = Camera
    if not cam then return end

    local target = getTarget(cam)
    if not target then return end

    local goal = CFrame.lookAt(cam.CFrame.Position, target.Position)
    local alpha = 1
    if AIM.Smoothness > 0 then
        -- Не зависит от FPS: 0 → почти мгновенно, 100 → очень плавно
        local speed = 300 * (1 - AIM.Smoothness / 100) ^ 2 + 0.5
        alpha = 1 - math.exp(-dt * speed)
    end
    cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end)

-- Активация на ПК: удержание ПКМ
track(UserInputService.InputBegan:Connect(function(input, processed)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        AIM.Active = true
    elseif input.KeyCode == Enum.KeyCode.RightShift and not processed then
        window.Main.Visible = not window.Main.Visible
    end
end))
track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        AIM.Active = false
    end
end))

-- ============================================================
--  ГЛАВНЫЙ ЦИКЛ ОТРИСОВКИ
-- ============================================================
-- Ошибки не должны ломать весь цикл: логируем в консоль один раз
local lastError
local function reportError(err)
    if err ~= lastError then
        lastError = err
        warn("[LOKYU] " .. tostring(err))
    end
end

local statusTimer = 0
local function renderFrame()
    local cam = Camera
    if not cam then return end

    -- Круг FOV зависит только от переключателя Show FOV
    fovCircle.Visible = AIM.ShowFOV
    if AIM.ShowFOV then
        fovCircle.Position = getAimOrigin(cam)
        fovCircle.Radius = AIM.FOV
        fovCircle.Color = AIM.FOVColor
    end

    -- ESP и трассеры (каждый игрок обновляется отдельно под pcall)
    local active = ESP.Enabled or TRACER.Enabled
    local viewport = cam.ViewportSize
    local tracked, drawn = 0, 0
    for entity, e in pairs(espObjects) do
        -- Бот удалён из мира или оказался персонажем игрока — объект больше не нужен
        if not entity:IsA("Player") and (not entity:IsDescendantOf(Workspace)
            or Players:GetPlayerFromCharacter(entity)) then
            destroyEsp(e)
            espObjects[entity] = nil
        else
            tracked = tracked + 1
            if active then
                local ok, err = pcall(updateEsp, entity, e, cam, viewport)
                if not ok then reportError(err) end
            else
                hideEsp(e)
            end
            if e.Shown then drawn = drawn + 1 end
        end
    end

    -- Строка статуса во вкладке Misc (помогает понять, что именно не работает)
    if os.clock() - statusTimer > 0.5 then
        statusTimer = os.clock()
        statusLabel.Text = string.format("Renderer: %s  |  Targets: %d  |  Drawn: %d", Draw.Mode(), tracked, drawn)
    end
end

track(RunService.RenderStepped:Connect(function()
    local ok, err = pcall(renderFrame)
    if not ok then reportError(err) end
end))

-- ============================================================
--  ВЫГРУЗКА
-- ============================================================
Unload = function()
    if unloaded then return end
    unloaded = true

    pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    for _, e in pairs(espObjects) do destroyEsp(e) end
    removeDrawing(fovCircle)

    window.Gui:Destroy()
    if overlay then overlay:Destroy() end
    env.LokyuUnload = nil
end
env.LokyuUnload = Unload

-- Кнопка «×»: двойное нажатие (защита от случайного тапа на телефоне)
do
    local armed = false
    local closeButton = window.CloseButton
    closeButton.Activated:Connect(function()
        if armed then
            Unload()
            return
        end
        armed = true
        closeButton.Text = "?"
        closeButton.BackgroundColor3 = Theme.Danger
        task.delay(2, function()
            armed = false
            if closeButton.Parent then
                closeButton.Text = "×"
                closeButton.BackgroundColor3 = Theme.Element
            end
        end)
    end)
end
