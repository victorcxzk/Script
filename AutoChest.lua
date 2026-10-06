--!nolint DeprecatedApi
--[[
    ================================================================================
    AUTO CHEST & SERVER HOP (v2.4.0)
    Suporte: Sea 1 (2753915549) | Sea 2 (4442272183) | Sea 3 (7449423635)
    ================================================================================
    PROJETO / IDEIA CENTRAL:
    1. AUTO-CHEST:
       - Escaneia Workspace.Map pelos gatilhos reais Chest1, Chest2 e Chest3.
       - Deslocamento seguro (Tween com Noclip e protecao contra dano de agua para usuarios de fruta).
       - Coleta por contato fisico (CFrame) e firetouchinterest.
    2. CHEST LIMIT & HOP AUTOMATICO:
       - Config.TargetChests: O usuario define a meta de baus por servidor (ex: 15).
       - Auto Hop quando atinge a meta OU quando esgotam os baus do servidor atual.
    3. AUTO-RECONNECT & ANTI-AFK:
       - VirtualUser previne desconexao por inatividade (kick de 20 minutos).
       - Monitoramento de erros 268/277/279/773 com reconexao automatica.
    4. AUTO-EXECUTE & PERSISTENCIA:
       - Suporte a queue_on_teleport para continuar farmando automaticamente em cada servidor.
       - Compativel com a pasta autoexec do seu executor.

    NOTA PARA DESENVOLVIMENTO / OUTRAS IAs:
    - O codigo foi modularizado em secoes claras (Config, Services, Movement, Chests, Hop, HUD).
    - Para adicionar recursos futuros (ex: webhook Discord, kill aura em mobs que atrapalham,
      ou filtro exclusivo de baus de ouro/diamante), veja as secoes correspondentes abaixo.
    ================================================================================
]]

local SCRIPT_NAME = "Auto Chest"
local SCRIPT_VERSION = "2.4.0"
local SCRIPT_BUILD = "2026-10-06 / factory-esp-stable-motion"
local RAW_SCRIPT_URL = "https://raw.githubusercontent.com/victorcxzk/Script/main/AutoChest.lua"
local SETTINGS_SCHEMA = 2

-- ============================================================================
-- 1. CONFIGURACOES DO USUARIO
-- ============================================================================
local Config = {
    Enabled = true,                 -- Inicia ligado (true/false)
    Minimized = false,              -- Mantem o estado visual do menu entre executes
    TargetChests = 15,              -- Meta de baus por servidor antes de dar Hop
    HopWhenEmpty = true,            -- Dá Hop automaticamente se nao houver mais baus no servidor
    HopAfterTarget = true,          -- Dá Hop automaticamente ao atingir TargetChests
    EmptyScanGrace = 12,            -- Confirma servidor vazio antes de dar Hop
    ScannerWarmup = 8,              -- Impede hop antes do scanner estabilizar
    MinimumChestAnchors = 3,        -- Evita Hop enquanto o mapa ainda esta incompleto

    TweenSpeed = 190,               -- Viagem mais rapida; contato continua lento e confiavel
    VerticalSpeed = 75,             -- Subida e descida controladas
    MovementTimeout = 90,           -- Prazo por trecho; viagens longas sao divididas em trechos
    FinalApproachDistance = 55,     -- Alvos proximos nao fazem a rota alta completa
    FinalApproachSpeed = 55,        -- Velocidade da aproximacao final
    ContactSpeed = 14,              -- Velocidade ao entrar no hitbox do bau
    ArrivalTolerance = 5,           -- Distancia maxima para considerar que chegou ao bau

    Noclip = true,                  -- Atravessa paredes durante o deslocamento
    AntiSit = true,                 -- Impede cadeiras/bancos de prenderem o personagem
    BypassWater = true,             -- Mantem o personagem suspenso para nao tomar dano de agua do mar
    SafeTravelHeight = 45,          -- Altura minima usada durante a travessia rapida
    CollectDelay = 0.35,            -- Intervalo (segundos) entre cada coleta
    TouchHold = 0.40,               -- Tempo mantendo contato com o gatilho do bau
    CollectionTimeout = 3.0,        -- Prazo para o servidor confirmar a coleta
    CollectionRetries = 3,          -- Novas tentativas antes de desistir do bau
    FailedChestCooldown = 8,        -- Evita insistir imediatamente no mesmo bau

    AntiAFK = true,                 -- Evita kick de inatividade do Roblox
    AutoReconnect = true,           -- Reconecta automaticamente se perder conexao
    PersistOnTeleport = true,       -- Injeta o script para auto-executar no proximo servidor via queue_on_teleport
    HopTimeout = 20,                -- Troca de alvo se o loading nao terminar
    MaxHopAttempts = 3,             -- Evita retries infinitos de teleporte
    GameReadyTimeout = 15,          -- Prazo maximo para personagem e mapa aparecerem
    LoadingGuiSoftTimeout = 4,      -- Depois disso, mapa+personagem liberam o scanner
    VisitedServerTTL = 3600,        -- Reutiliza servidores apos uma hora
    DebugLog = true,
    DebugLogFile = "AutoChest_Debug.log",
    MaxHudLogs = 7,
}

-- ESP de fabrica: sempre ativo e propositalmente fora de Config/settings/UI.
-- Chest1 = bronze, Chest2 = prata, Chest3 = ouro.
local CHEST_ESP_STYLE = {
    chest1 = {Label = "BRONZE", Color = Color3.fromRGB(205, 127, 50)},
    chest2 = {Label = "PRATA", Color = Color3.fromRGB(205, 218, 235)},
    chest3 = {Label = "OURO", Color = Color3.fromRGB(255, 198, 36)},
}

-- Em auto-execute, aguarda o cliente concluir o carregamento antes de criar
-- HUD, escanear o mapa ou mover o personagem.
if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- APIs que pertencem ao executor nao fazem parte do ambiente tipado padrao do
-- Roblox. Resolve todas uma unica vez para evitar globais desconhecidas no editor.
local runtimeEnvironment = getfenv(0)
local function runtimeValue(name)
    local value = runtimeEnvironment[name]
    if value == nil then
        value = rawget(_G, name)
    end
    return value
end

local synRuntime = runtimeValue("syn")
local fluxusRuntime = runtimeValue("fluxus")
local Runtime = {
    CloneRef = runtimeValue("cloneref"),
    IsFile = runtimeValue("isfile"),
    ReadFile = runtimeValue("readfile"),
    WriteFile = runtimeValue("writefile"),
    AppendFile = runtimeValue("appendfile"),
    GetHui = runtimeValue("gethui"),
    GetGlobalEnvironment = runtimeValue("getgenv"),
    FireTouchInterest = runtimeValue("firetouchinterest"),
    QueueOnTeleport = runtimeValue("queue_on_teleport")
        or runtimeValue("queueonteleport")
        or (type(synRuntime) == "table" and synRuntime.queue_on_teleport)
        or (type(fluxusRuntime) == "table" and fluxusRuntime.queue_on_teleport),
    ProtectGui = type(synRuntime) == "table" and synRuntime.protect_gui or nil,
}

-- ============================================================================
-- 2. SERVICOS E UTILITARIOS SEGUROS
-- ============================================================================
local function safeService(name)
    local s = nil
    pcall(function()
        s = Runtime.CloneRef and Runtime.CloneRef(game:GetService(name)) or game:GetService(name)
    end)
    if not s then pcall(function() s = game:GetService(name) end) end
    return s
end

local Players = safeService("Players")
local Workspace = safeService("Workspace")
local TweenService = safeService("TweenService")
local RunService = safeService("RunService")
local HttpService = safeService("HttpService")
local TeleportService = safeService("TeleportService")
local GuiService = safeService("GuiService")
local CoreGui = safeService("CoreGui")
local VirtualUser = safeService("VirtualUser")
local UserInputService = safeService("UserInputService")

local settingsFile = "AutoChest_Settings.json"
local legacySettingsFile = "BF_AutoChest_Settings.json"
local settingsLoadMessage = "Configuracoes padrao em uso"

local function loadSettings()
    if not (Runtime.IsFile and Runtime.ReadFile) then return end

    local loadedFile = Runtime.IsFile(settingsFile) and settingsFile
        or (Runtime.IsFile(legacySettingsFile) and legacySettingsFile)
    local ok, saved = pcall(function()
        if not loadedFile then return nil end
        return HttpService:JSONDecode(Runtime.ReadFile(loadedFile))
    end)
    if ok and saved == nil then return end
    if not ok or type(saved) ~= "table" then
        settingsLoadMessage = "Falha ao ler configuracoes salvas"
        return
    end

    local savedSchema = tonumber(saved.__SchemaVersion) or 1
    local applied = 0
    for key, value in pairs(saved) do
        if Config[key] ~= nil and type(value) == type(Config[key])
            and (type(value) ~= "number" or (value == value and math.abs(value) < math.huge)) then
            Config[key] = value
            applied = applied + 1
        end
    end
    -- Migra apenas os antigos valores de fabrica. Valores personalizados mais
    -- altos continuam intactos, e a entrada no hitbox permanece deliberadamente lenta.
    if savedSchema < 2 then
        if Config.TweenSpeed == 150 then Config.TweenSpeed = 190 end
        if Config.VerticalSpeed == 60 then Config.VerticalSpeed = 75 end
        if Config.FinalApproachDistance == 35 then Config.FinalApproachDistance = 55 end
        if Config.FinalApproachSpeed == 45 then Config.FinalApproachSpeed = 55 end
    end
    settingsLoadMessage = string.format("%d configuracoes restauradas%s", applied,
        loadedFile == legacySettingsFile and " (configuracoes antigas migradas)" or "")
end

local function saveSettings()
    if not (Runtime.WriteFile and HttpService) then return false end

    local serializable = {}
    serializable.__SchemaVersion = SETTINGS_SCHEMA
    for key, value in pairs(Config) do
        local valueType = type(value)
        if valueType == "boolean" or valueType == "number" or valueType == "string" then
            serializable[key] = value
        end
    end

    return pcall(function()
        Runtime.WriteFile(settingsFile, HttpService:JSONEncode(serializable))
    end)
end

local function normalizeSettings()
    Config.TargetChests = math.clamp(math.floor(tonumber(Config.TargetChests) or 15), 1, 999)
    Config.GameReadyTimeout = math.clamp(tonumber(Config.GameReadyTimeout) or 15, 6, 15)
    Config.LoadingGuiSoftTimeout = math.clamp(tonumber(Config.LoadingGuiSoftTimeout) or 4, 1, 8)
    Config.ScannerWarmup = math.clamp(tonumber(Config.ScannerWarmup) or 8, 3, 30)
    Config.SafeTravelHeight = math.clamp(tonumber(Config.SafeTravelHeight) or 45, 20, 150)
    Config.TweenSpeed = math.clamp(Config.TweenSpeed, 20, 240)
    Config.VerticalSpeed = math.clamp(Config.VerticalSpeed, 10, 110)
    Config.MovementTimeout = math.clamp(Config.MovementTimeout, 10, 180)
    Config.FinalApproachDistance = math.clamp(Config.FinalApproachDistance, 8, 90)
    Config.FinalApproachSpeed = math.clamp(Config.FinalApproachSpeed, 5, 70)
    Config.ContactSpeed = math.clamp(Config.ContactSpeed, 2, 20)
    Config.ArrivalTolerance = math.clamp(Config.ArrivalTolerance, 0.5, 3)
    Config.TouchHold = math.clamp(Config.TouchHold, 0.2, 2)
    Config.CollectionTimeout = math.clamp(Config.CollectionTimeout, 1, 10)
    Config.CollectionRetries = math.clamp(math.floor(Config.CollectionRetries), 1, 5)
    Config.FailedChestCooldown = math.clamp(Config.FailedChestCooldown, 2, 60)
    Config.EmptyScanGrace = math.clamp(Config.EmptyScanGrace, 10, 60)
    Config.MaxHudLogs = math.clamp(math.floor(Config.MaxHudLogs), 1, 20)
    if Config.DebugLogFile == "BF_AutoChest_Debug.log" then
        Config.DebugLogFile = "AutoChest_Debug.log"
    end
end

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

-- Reexecutar o arquivo descarrega a instancia anterior em vez de criar loops duplicados.
local globalEnv = _G
if type(Runtime.GetGlobalEnvironment) == "function" then
    pcall(function()
        globalEnv = Runtime.GetGlobalEnvironment()
    end)
end
local previousController = rawget(globalEnv, "AutoChestController")
    or rawget(globalEnv, "BFAutoChestController")
if type(previousController) == "table" and type(previousController.Unload) == "function" then
    pcall(previousController.Unload)
end
-- O unload anterior pode salvar escolhas pendentes; so depois le o JSON.
loadSettings()
normalizeSettings()
local Controller = {}
globalEnv.AutoChestController = Controller
Controller.SaveSettings = saveSettings
Controller.Config = Config
Controller.Version = SCRIPT_VERSION

-- ============================================================================
-- 3. ESTADO GLOBAL DA SESSAO
-- ============================================================================
local State = {
    CollectedInServer = 0,
    TotalCollectedSession = 0,
    IsHopping = false,
    CurrentTarget = nil,
    StatusMessage = "Iniciando...",
    CurrentTween = nil,
    NoclipConn = nil,
    FailedUntil = setmetatable({}, {__mode = "k"}),
    CountedChests = setmetatable({}, {__mode = "k"}),
    OriginalCollision = setmetatable({}, {__mode = "k"}),
    Connections = {},
    EmptySince = nil,
    Unloaded = false,
    HasValidScan = false,
    LogEntries = {},
    LastScanSignature = nil,
    LastScanLogAt = 0,
    LastGuardReason = nil,
    LastScanDiagnostics = nil,
    HopAttempts = 0,
    HopToken = 0,
    HopBlocked = false,
    AutoExecuteQueued = false,
    SettingsPersisted = false,
    IsRespawning = true,
    RespawnToken = 0,
    DeathCount = 0,
    ReadyAt = nil,
    ScannerReadyAt = nil,
    ScanCount = 0,
    ConsecutiveReliableScans = 0,
    LastRuntimeError = nil,
    MovementToken = 0,
    MotionAttachment = nil,
    MotionSupport = nil,
    MotionRoot = nil,
    MotionHumanoid = nil,
    OriginalAutoRotate = nil,
    CharacterDiedConnection = nil,
    EmptyScanMap = nil,
    EmptyScanAnchors = nil,
    LastScannerMap = nil,
    SeatHumanoid = nil,
    OriginalSeatedEnabled = nil,
    OriginalSeatTouch = setmetatable({}, {__mode = "k"}),
    WasSeated = false,
    ChestESP = {},
    ESPContainer = nil,
}

local hud = {}

local function destroyChestESPMarker(part)
    local marker = State.ChestESP[part]
    if not marker then return end
    State.ChestESP[part] = nil
    if marker.Box then pcall(function() marker.Box:Destroy() end) end
    if marker.Billboard then pcall(function() marker.Billboard:Destroy() end) end
end

local function clearChestESP()
    local parts = {}
    for part in pairs(State.ChestESP) do table.insert(parts, part) end
    for _, part in ipairs(parts) do destroyChestESPMarker(part) end
    if State.ESPContainer then
        pcall(function() State.ESPContainer:Destroy() end)
        State.ESPContainer = nil
    end
end

local function trackConnection(connection)
    if connection then
        table.insert(State.Connections, connection)
    end
    return connection
end

local function addLog(level, message)
    local stamp = os.date("%H:%M:%S")
    local line = string.format("[%s] [%s] %s", stamp, tostring(level), tostring(message))
    table.insert(State.LogEntries, line)
    while #State.LogEntries > Config.MaxHudLogs do
        table.remove(State.LogEntries, 1)
    end

    if level == "ERRO" or level == "WARN" then
        warn("[AUTO-CHEST] " .. line)
    else
        print("[AUTO-CHEST] " .. line)
    end

    if Config.DebugLog and Runtime.AppendFile then
        pcall(Runtime.AppendFile, Config.DebugLogFile, line .. "\n")
    end
end

local function getCharacter(timeoutSeconds)
    local deadline = os.clock() + (timeoutSeconds or 10)
    repeat
        local char = LocalPlayer.Character
        local humanoid = char and char:FindFirstChildWhichIsA("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if char and char.Parent and humanoid and humanoid.Health > 0 and root then
            return char
        end
        task.wait(0.1)
    until State.Unloaded or os.clock() >= deadline
    return nil
end

local function getRoot(char)
    char = char or getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function getHumanoid(char)
    char = char or getCharacter()
    return char and char:FindFirstChildWhichIsA("Humanoid") or nil
end

local function isLoadingGuiVisible()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local loadingGui = playerGui and playerGui:FindFirstChild("LoadingGui")
    if not loadingGui then return false end
    if loadingGui:IsA("ScreenGui") and not loadingGui.Enabled then return false end

    local root = loadingGui:FindFirstChild("Root")
    if root and root:IsA("GuiObject") then
        local canvas = root:FindFirstChildWhichIsA("CanvasGroup", true)
        if canvas and (not canvas.Visible or canvas.GroupTransparency >= 0.95) then
            return false
        end
        return root.Visible
    end
    return true
end

local function waitForGameReady(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    local softLoadingDeadline = os.clock() + Config.LoadingGuiSoftTimeout
    local prerequisitesSince = nil
    local ignoredStaleLoadingGui = false
    State.StatusMessage = "Aguardando LoadingGui e mapa..."

    while not State.Unloaded and os.clock() < deadline do
        local char = LocalPlayer.Character
        local humanoid = char and char:FindFirstChildWhichIsA("Humanoid")
        local hasRoot = char and char:FindFirstChild("HumanoidRootPart") ~= nil
        local alive = humanoid and humanoid.Health > 0
        local hasMap = Workspace:FindFirstChild("Map") ~= nil
        local prerequisitesReady = game:IsLoaded() and hasRoot and alive and hasMap

        if prerequisitesReady then
            prerequisitesSince = prerequisitesSince or os.clock()
            local stableFor = os.clock() - prerequisitesSince
            local loadingVisible = isLoadingGuiVisible()
            if stableFor >= 0.75 and (not loadingVisible or os.clock() >= softLoadingDeadline) then
                if loadingVisible and not ignoredStaleLoadingGui then
                    ignoredStaleLoadingGui = true
                    addLog("WARN", "LoadingGui ainda visivel; mapa e personagem estaveis, liberando scanner")
                end
                State.ReadyAt = os.clock()
                State.IsRespawning = false
                return true
            end
        else
            prerequisitesSince = nil
        end
        task.wait(0.25)
    end

    return false
end

-- ============================================================================
-- 4. ANTI-AFK & AUTO-RECONNECT
-- ============================================================================
if Config.AntiAFK then
    pcall(function()
        trackConnection(LocalPlayer.Idled:Connect(function()
            if not State.Unloaded and VirtualUser then
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end
        end))
    end)
end

-- Forward declaration do Server Hop
local doServerHop

if Config.AutoReconnect and GuiService then
    pcall(function()
        trackConnection(GuiService.ErrorMessageChanged:Connect(function(message)
            if type(message) ~= "string" or message == "" then
                pcall(function()
                    message = GuiService:GetErrorMessage()
                end)
            end

            local text = type(message) == "string" and message:lower() or ""
            local isDisconnectError = text ~= "" and (
                text:find("268", 1, true)
                or text:find("277", 1, true)
                or text:find("279", 1, true)
                or text:find("disconnect", 1, true)
                or text:find("conexao", 1, true)
                or text:find("connection", 1, true)
            )
            local isTeleportError = text ~= "" and (
                text:find("773", 1, true)
                or text:find("restricted", 1, true)
                or text:find("restrito", 1, true)
                or text:find("teleport", 1, true)
            )
            local isConnectionError = isDisconnectError or (isTeleportError and State.IsHopping)

            if isTeleportError and not State.IsHopping then
                addLog("WARN", "Prompt antigo de teleporte ignorado; nenhum hop estava ativo")
                pcall(function() GuiService:ClearError() end)
            end

            if isConnectionError then
                local retryExistingHop = State.IsHopping and State.HopAttempts > 0
                local failedToken = State.HopToken
                State.IsHopping = true
                State.StatusMessage = "Erro de teleporte detectado; preparando retry"
                addLog("WARN", "Prompt do Roblox: " .. tostring(message))
                pcall(function() GuiService:ClearError() end)

                task.delay(1, function()
                    if not State.Unloaded and State.HopToken == failedToken and doServerHop then
                        State.IsHopping = false
                        doServerHop("Erro Roblox: " .. tostring(message), retryExistingHop)
                    end
                end)
            end
        end))
    end)
end

if Config.AutoReconnect and TeleportService then
    pcall(function()
        trackConnection(TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
            if player ~= LocalPlayer or State.Unloaded then return end

            local failedToken = State.HopToken
            State.IsHopping = true
            State.StatusMessage = "Reconectando apos falha no teleporte..."
            addLog("WARN", "TeleportInitFailed: " .. tostring(result) .. " | " .. tostring(errorMessage))
            pcall(function() GuiService:ClearError() end)
            task.delay(1, function()
                if not State.Unloaded and State.HopToken == failedToken and doServerHop then
                    State.IsHopping = false
                    doServerHop("Retry de teleporte: " .. tostring(errorMessage or result), true)
                end
            end)
        end))
    end)
end

pcall(function()
    trackConnection(LocalPlayer.OnTeleport:Connect(function(teleportState, placeId)
        addLog("TPSTATE", string.format("%s | place=%s | job=%s",
            tostring(teleportState), tostring(placeId), tostring(game.JobId)))
    end))
end)

-- ============================================================================
-- 5. SISTEMA DE NOCLIP E PROTECAO DE MOVIMENTO
-- ============================================================================
local function restoreSeatState()
    local humanoid = State.SeatHumanoid
    if humanoid and humanoid.Parent and State.OriginalSeatedEnabled ~= nil then
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, State.OriginalSeatedEnabled)
        end)
    end
    State.SeatHumanoid = nil
    State.OriginalSeatedEnabled = nil
    State.WasSeated = false
end

local function restoreNearbySeats()
    for seat, originalCanTouch in pairs(State.OriginalSeatTouch) do
        if seat and seat.Parent then
            pcall(function()
                seat.CanTouch = originalCanTouch
            end)
        end
    end
    State.OriginalSeatTouch = setmetatable({}, {__mode = "k"})
end

local function suppressNearbySeats(char)
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local ok, nearby = pcall(function()
        return Workspace:GetPartBoundsInRadius(root.Position, 14)
    end)
    if not ok or type(nearby) ~= "table" then return end

    for _, part in ipairs(nearby) do
        if part:IsA("Seat") or part:IsA("VehicleSeat") then
            if State.OriginalSeatTouch[part] == nil then
                State.OriginalSeatTouch[part] = part.CanTouch
            end
            part.CanTouch = false
        end
    end
end

local function ensureStanding(char)
    if not Config.AntiSit then
        restoreNearbySeats()
        restoreSeatState()
        return
    end
    char = char or LocalPlayer.Character
    suppressNearbySeats(char)
    local humanoid = char and char:FindFirstChildWhichIsA("Humanoid")
    if not humanoid then return end

    if State.SeatHumanoid ~= humanoid then
        restoreSeatState()
        State.SeatHumanoid = humanoid
        pcall(function()
            State.OriginalSeatedEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Seated)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
        end)
    end

    local seated = humanoid.Sit
        or humanoid.SeatPart ~= nil
        or humanoid:GetState() == Enum.HumanoidStateType.Seated

    if seated then
        if not State.WasSeated then
            addLog("MOVE", "Assento detectado; levantando personagem")
        end
        State.WasSeated = true
        humanoid.Sit = false
        humanoid.Jump = true
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    else
        State.WasSeated = false
    end
end

local function restoreCollision()
    for part, originalCanCollide in pairs(State.OriginalCollision) do
        if part and part.Parent then
            pcall(function() part.CanCollide = originalCanCollide end)
        end
    end
    State.OriginalCollision = setmetatable({}, {__mode = "k"})
end

local function releaseMotionSupport()
    if State.MotionSupport then State.MotionSupport:Destroy() end
    if State.MotionAttachment then State.MotionAttachment:Destroy() end
    if State.MotionHumanoid and State.MotionHumanoid.Parent and State.OriginalAutoRotate ~= nil then
        State.MotionHumanoid.AutoRotate = State.OriginalAutoRotate
    end
    State.MotionSupport = nil
    State.MotionAttachment = nil
    State.MotionRoot = nil
    State.MotionHumanoid = nil
    State.OriginalAutoRotate = nil
    restoreCollision()
    restoreNearbySeats()
    restoreSeatState()
end

local function prepareMotionSupport(char, root, humanoid)
    if State.MotionRoot == root and State.MotionSupport and State.MotionSupport.Parent then return end
    releaseMotionSupport()
    State.MotionRoot = root
    State.MotionHumanoid = humanoid
    State.OriginalAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero

    -- Mantem a gravidade e a inercia controladas sem ancorar ou mudar a posicao.
    local attachment = Instance.new("Attachment")
    attachment.Name = "AutoChestMotionAttachment"
    attachment.Parent = root
    State.MotionAttachment = attachment
    local support = Instance.new("LinearVelocity")
    State.MotionSupport = support
    support.Name = "AutoChestMotionSupport"
    support.Attachment0 = attachment
    support.RelativeTo = Enum.ActuatorRelativeTo.World
    support.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
    support.VectorVelocity = Vector3.zero
    support.MaxForce = math.huge
    support.Parent = root
    ensureStanding(char)
end

local function enableNoclip()
    if State.NoclipConn or State.Unloaded then return end
    State.NoclipConn = RunService.Stepped:Connect(function()
        if not State.Unloaded and Config.Enabled then
            local char = LocalPlayer.Character
            if char then
                if State.MotionRoot then ensureStanding(char) end
                if Config.Noclip and State.MotionRoot and State.MotionRoot:IsDescendantOf(char) then
                    for _, part in ipairs(char:GetDescendants()) do
                        if part:IsA("BasePart") and part.CanCollide then
                            State.OriginalCollision[part] = true
                            part.CanCollide = false
                        end
                    end
                end
            end
        end
    end)
end

local function disableNoclip()
    if State.NoclipConn then
        State.NoclipConn:Disconnect()
        State.NoclipConn = nil
    end

    releaseMotionSupport()
    restoreNearbySeats()
    restoreSeatState()
end

enableNoclip()

local function cancelCurrentMovement()
    State.MovementToken = State.MovementToken + 1
    if State.CurrentTween then
        pcall(function() State.CurrentTween:Cancel() end)
        State.CurrentTween = nil
    end
    releaseMotionSupport()
end

local function bindCharacterLifecycle(char)
    State.RespawnToken = State.RespawnToken + 1
    local respawnToken = State.RespawnToken
    State.IsRespawning = true
    State.CurrentTarget = nil
    State.EmptySince = nil
    cancelCurrentMovement()
    restoreNearbySeats()
    restoreSeatState()
    if State.CharacterDiedConnection then
        State.CharacterDiedConnection:Disconnect()
        State.CharacterDiedConnection = nil
    end

    task.spawn(function()
        local humanoid = char and char:WaitForChild("Humanoid", 10)
        local root = char and char:WaitForChild("HumanoidRootPart", 10)
        if State.Unloaded or State.RespawnToken ~= respawnToken then return end
        if not humanoid or not root or humanoid.Health <= 0 then return end

        State.CharacterDiedConnection = humanoid.Died:Connect(function()
            if State.Unloaded or State.RespawnToken ~= respawnToken then return end
            State.DeathCount = State.DeathCount + 1
            State.IsRespawning = true
            State.CurrentTarget = nil
            State.EmptySince = nil
            State.StatusMessage = "Personagem morreu; aguardando respawn automatico"
            cancelCurrentMovement()
            addLog("RESPAWN", string.format("Morte detectada (%d); coleta pausada", State.DeathCount))
        end)

        State.FailedUntil = setmetatable({}, {__mode = "k"})
        State.IsRespawning = false
        State.StatusMessage = "Respawn concluido; retomando scanner"
        addLog("RESPAWN", "Novo personagem pronto; ciclo retomado automaticamente")
    end)
end

trackConnection(LocalPlayer.CharacterAdded:Connect(bindCharacterLifecycle))
trackConnection(LocalPlayer.CharacterRemoving:Connect(function(char)
    if State.MotionRoot and State.MotionRoot:IsDescendantOf(char) then cancelCurrentMovement() end
    State.IsRespawning = true
    State.EmptySince = nil
end))
if LocalPlayer.Character then
    bindCharacterLifecycle(LocalPlayer.Character)
end

local function unload()
    if State.Unloaded then return end

    State.SettingsPersisted = saveSettings()
    State.Unloaded = true
    Config.Enabled = false
    State.IsHopping = true
    State.StatusMessage = "Descarregado"
    cancelCurrentMovement()

    disableNoclip()
    clearChestESP()
    if State.CharacterDiedConnection then
        State.CharacterDiedConnection:Disconnect()
        State.CharacterDiedConnection = nil
    end

    for _, connection in ipairs(State.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(State.Connections)

    if hud.Gui then
        pcall(function() hud.Gui:Destroy() end)
        hud.Gui = nil
    end

    if rawget(globalEnv, "AutoChestController") == Controller then
        globalEnv.AutoChestController = nil
    end
    if rawget(globalEnv, "BFAutoChestController") == Controller then
        globalEnv.BFAutoChestController = nil
    end

    addLog("INFO", "Unload completo")
end

Controller.Unload = unload

-- ============================================================================
-- 6. SCANNER FORENSE DE BAUS (WORKSPACE)
-- ============================================================================
-- O dump mostra duas representacoes nas mesmas coordenadas:
--   Workspace.Map....Chest1/2/3       = gatilho real com TouchTransmitter
--   Workspace.ChestModels.SilverChest = clone visual/animacao do cliente
-- Somente a primeira deve ser usada para coleta e confirmacao.
local function getChestPart(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then
        return inst
    end
    return nil
end

local function getTouchTransmitter(part)
    if not part then return nil end
    return part:FindFirstChildWhichIsA("TouchTransmitter", true)
        or part:FindFirstChild("TouchInterest", true)
end

local function isValidChest(inst)
    if not inst or not inst:IsDescendantOf(Workspace) then return false end
    if not inst:IsA("BasePart") then return false end

    local name = inst.Name:lower()

    -- No material fornecido, os coletores reais sao exclusivamente Chest1/2/3.
    -- Isso exclui PushBox, modelos decorativos, CursedChest e outros falsos positivos.
    if not name:match("^chest[123]$") then return false end

    local map = Workspace:FindFirstChild("Map")
    if not map or not inst:IsDescendantOf(map) then return false end

    local part = getChestPart(inst)
    if not part then return false end

    -- A Part real pode ser transparente: ChestModels fornece o visual. O sinal
    -- autoritativo de disponibilidade no dump e o TouchTransmitter.
    if not getTouchTransmitter(part) then return false end

    return true, part
end

local function ensureChestESPContainer()
    if State.ESPContainer and State.ESPContainer.Parent then return State.ESPContainer end

    local parent = CoreGui
    if Runtime.GetHui then
        pcall(function()
            parent = Runtime.GetHui() or parent
        end)
    end
    if not parent then parent = LocalPlayer:FindFirstChild("PlayerGui") end
    if not parent then return nil end

    local old = parent:FindFirstChild("AutoChestESP")
    if old then old:Destroy() end
    local folder = Instance.new("Folder")
    folder.Name = "AutoChestESP"
    folder.Parent = parent
    State.ESPContainer = folder
    return folder
end

local function createChestESPMarker(chestData)
    local part = chestData.Part
    local container = ensureChestESPContainer()
    local style = CHEST_ESP_STYLE[part.Name:lower()]
    if not container or not style then return nil end

    -- A caixa continua visivel mesmo quando o gatilho real do bau e transparente.
    local box = Instance.new("BoxHandleAdornment")
    box.Name = "ChestBox"
    box.Adornee = part
    box.AlwaysOnTop = true
    box.ZIndex = 8
    box.Size = part.Size + Vector3.new(0.35, 0.35, 0.35)
    box.Color3 = style.Color
    box.Transparency = 0.38
    box.Parent = container

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ChestLabel"
    billboard.Adornee = part
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.MaxDistance = 10000
    billboard.Size = UDim2.fromOffset(148, 26)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, math.max(2.5, part.Size.Y * 0.5 + 1.5), 0)
    billboard.Parent = container

    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundColor3 = Color3.fromRGB(5, 5, 6)
    label.BackgroundTransparency = 0.18
    label.BorderSizePixel = 0
    label.Font = Enum.Font.GothamBold
    label.TextColor3 = style.Color
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.25
    label.TextSize = 12
    label.Parent = billboard
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = label
    local stroke = Instance.new("UIStroke")
    stroke.Color = style.Color
    stroke.Transparency = 0.25
    stroke.Thickness = 1
    stroke.Parent = label

    local marker = {
        Box = box,
        Billboard = billboard,
        Label = label,
        Style = style,
        ChestData = chestData,
    }
    State.ChestESP[part] = marker
    return marker
end

local function updateChestESP()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local stale = {}
    for part, marker in pairs(State.ChestESP) do
        if not part or not part:IsDescendantOf(Workspace) or not getTouchTransmitter(part) then
            table.insert(stale, part)
        else
            local distance = root and (part.Position - root.Position).Magnitude or 0
            local selected = State.CurrentTarget and State.CurrentTarget.Part == part
            marker.Box.Transparency = selected and 0.12 or 0.38
            marker.Label.Text = string.format("%s%s  |  %.0fm", selected and "> " or "", marker.Style.Label, distance)
        end
    end
    for _, part in ipairs(stale) do destroyChestESPMarker(part) end
end

local function syncChestESP(chests)
    local active = {}
    for _, chestData in ipairs(chests) do
        local part = chestData.Part
        active[part] = true
        local marker = State.ChestESP[part] or createChestESPMarker(chestData)
        if marker then marker.ChestData = chestData end
    end

    local stale = {}
    for part in pairs(State.ChestESP) do
        if not active[part] then table.insert(stale, part) end
    end
    for _, part in ipairs(stale) do destroyChestESPMarker(part) end
    updateChestESP()
end

local function scanAllChests()
    local chests = {}
    local espChests = {}
    local seen = {}
    local coolingDown = 0
    local diagnostics = {
        Descendants = 0,
        NamedParts = 0,
        InMap = 0,
        WithTouch = 0,
        Active = 0,
    }
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = hrp and hrp.Position or Vector3.new(0, 0, 0)

    local map = Workspace:FindFirstChild("Map")
    local descendants = map and map:GetDescendants() or {}
    if map ~= State.LastScannerMap then
        State.LastScannerMap = map
        State.HasValidScan = false
        State.ScannerReadyAt = nil
        State.ConsecutiveReliableScans = 0
        State.EmptySince = nil
    end
    diagnostics.Descendants = #descendants

    for _, desc in ipairs(descendants) do
        if desc:IsA("BasePart") and desc.Name:lower():match("^chest[123]$") then
            diagnostics.NamedParts = diagnostics.NamedParts + 1
            diagnostics.InMap = diagnostics.InMap + 1
            if getTouchTransmitter(desc) then
                diagnostics.WithTouch = diagnostics.WithTouch + 1
            end
        end

        local valid, part = isValidChest(desc)
        if valid and part and not seen[part] then
            seen[part] = true
            State.CountedChests[part] = nil -- o mesmo gatilho pode voltar depois do respawn do bau
            local dist = (part.Position - myPos).Magnitude

            -- Prioridade de valor: Chest3 (Ouro) > Chest2 (Prata) > Chest1 (Bronze)
            local priority = 1
            local pName = desc.Name:lower()
            if pName:find("chest3") or pName:find("gold") or pName:find("diamond") then
                priority = 3
            elseif pName:find("chest2") or pName:find("silver") then
                priority = 2
            end

            local chestData = {
                Instance = desc,
                Part = part,
                Position = part.Position,
                Distance = dist,
                Priority = priority,
                Name = desc.Name,
            }
            table.insert(espChests, chestData)
            diagnostics.Active = diagnostics.Active + 1

            local retryAt = State.FailedUntil[part]
            if retryAt and retryAt > os.clock() then
                coolingDown = coolingDown + 1
                continue
            end
            State.FailedUntil[part] = nil
            table.insert(chests, chestData)
        end
    end

    -- Confiabilidade primeiro: coleta o bau mais proximo. Priorizar ouro antes
    -- da distancia fazia o personagem cruzar o mapa em tweens muito longos.
    table.sort(chests, function(a, b)
        if a.Distance ~= b.Distance then return a.Distance < b.Distance end
        return a.Priority > b.Priority
    end)
    syncChestESP(espChests)

    if diagnostics.WithTouch > 0 then
        State.HasValidScan = true
        State.EmptySince = nil
    end
    State.ScanCount = State.ScanCount + 1
    if diagnostics.InMap >= Config.MinimumChestAnchors then
        State.ConsecutiveReliableScans = State.ConsecutiveReliableScans + 1
        State.ScannerReadyAt = State.ScannerReadyAt or os.clock()
    else
        State.ConsecutiveReliableScans = 0
        if not State.HasValidScan then
            State.ScannerReadyAt = nil
        end
    end
    State.LastScanDiagnostics = diagnostics

    local signature = string.format("d=%d named=%d map=%d touch=%d active=%d cooldown=%d",
        diagnostics.Descendants, diagnostics.NamedParts, diagnostics.InMap,
        diagnostics.WithTouch, diagnostics.Active, coolingDown)
    if signature ~= State.LastScanSignature or os.clock() - State.LastScanLogAt >= 5 then
        State.LastScanSignature = signature
        State.LastScanLogAt = os.clock()
        addLog("SCAN", signature)
    end

    return chests, coolingDown, diagnostics
end

-- ============================================================================
-- 7. MOTOR DE DESLOCAMENTO & COLETA (MOVIMENTO CONTINUO)
-- ============================================================================
local function movementIsActive(char, root, humanoid, token)
    return not State.Unloaded and Config.Enabled and not State.IsHopping
        and not State.IsRespawning and State.MovementToken == token
        and LocalPlayer.Character == char and char.Parent ~= nil
        and root:IsDescendantOf(Workspace) and humanoid.Health > 0
end

local function moveToPosition(targetCFrame, speed, context)
    local char = context and context.Character or getCharacter(1)
    local root = char and getRoot(char)
    local humanoid = char and getHumanoid(char)
    local token = context and context.Token or State.MovementToken
    if not char or not root or not humanoid or not movementIsActive(char, root, humanoid, token) then
        return false
    end

    prepareMotionSupport(char, root, humanoid)
    local distance = (targetCFrame.Position - root.Position).Magnitude
    if distance <= 0.15 then return true end
    local duration = math.max(distance / math.max(speed or Config.TweenSpeed, 1), 0.05)
    if duration > Config.MovementTimeout then
        addLog("WARN", string.format("Trecho requer %.1fs; limite=%ds, alvo adiado", duration, Config.MovementTimeout))
        return false
    end

    local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {CFrame = targetCFrame})
    State.CurrentTween = tween
    tween:Play()
    local deadline = os.clock() + duration + 2
    local nextProgressAt = os.clock() + 1
    local ok, arrived = pcall(function()
        while os.clock() < deadline do
            if not movementIsActive(char, root, humanoid, token) then return false end
            if context and context.ContactPosition
                and (root.Position - context.ContactPosition).Magnitude <= 3.5 then
                context.ContactStarted = true
            end
            if tween.PlaybackState == Enum.PlaybackState.Completed then
                local remaining = (root.Position - targetCFrame.Position).Magnitude
                if remaining > Config.ArrivalTolerance then
                    addLog("WARN", string.format("Tween terminou fora do alvo: %.1f studs | Y=%.1f HP=%.1f",
                        remaining, root.Position.Y, humanoid.Health))
                    return false
                end
                return true
            end
            if tween.PlaybackState == Enum.PlaybackState.Cancelled then return false end
            if context and context.PhaseLabel and os.clock() >= nextProgressAt then
                nextProgressAt = os.clock() + 1
                State.StatusMessage = string.format("%s | faltam %.0f studs", context.PhaseLabel,
                    (root.Position - targetCFrame.Position).Magnitude)
            end
            task.wait(0.05)
        end
        addLog("WARN", "Tween excedeu prazo; movimento cancelado")
        return false
    end)
    if not ok or not arrived then tween:Cancel() end
    if State.CurrentTween == tween then State.CurrentTween = nil end
    tween:Destroy()
    if not ok then error(arrived) end
    return arrived
end

-- Planeja tres trechos: subir, cruzar na altura segura, descer sobre o bau.
local function buildChestRoute(origin, finalPosition)
    local route
    if not Config.BypassWater or (finalPosition - origin).Magnitude <= Config.FinalApproachDistance then
        route = {{Position = finalPosition, Speed = Config.FinalApproachSpeed, Phase = "aproximacao"}}
    else
        -- A distancia que decide a rota direta nao deve virar altura extra. Uma
        -- folga fixa evita subir exageradamente antes de cada bau elevado.
        local clearance = math.max(origin.Y, finalPosition.Y + 35, Config.SafeTravelHeight)
        route = {
            {Position = Vector3.new(origin.X, clearance, origin.Z), Speed = Config.VerticalSpeed, Phase = "subida"},
            {Position = Vector3.new(finalPosition.X, clearance, finalPosition.Z), Speed = Config.TweenSpeed, Phase = "travessia"},
            {Position = finalPosition, Speed = Config.FinalApproachSpeed, Phase = "descida"},
        }
    end

    -- Fishmen no dump fica a mais de 60 mil studs: mantem acesso sem TP,
    -- dividindo viagens extensas em tweens com prazo individual.
    local segments = {}
    local previous = origin
    for _, waypoint in ipairs(route) do
        local distance = (waypoint.Position - previous).Magnitude
        local count = math.max(1, math.ceil(distance / (waypoint.Speed * Config.MovementTimeout * 0.8)))
        for index = 1, count do
            table.insert(segments, {
                Position = previous:Lerp(waypoint.Position, index / count),
                Speed = waypoint.Speed,
                Phase = waypoint.Phase,
            })
        end
        previous = waypoint.Position
    end
    return segments
end

local function moveToChest(part, context)
    local root = getRoot(context.Character)
    if not root or not part or not part:IsDescendantOf(Workspace) then return false end
    local finalPosition = part.Position + Vector3.new(0, 1.5, 0)
    local route = buildChestRoute(root.Position, finalPosition)
    for _, waypoint in ipairs(route) do
        if not part:IsDescendantOf(Workspace) then return false end
        if waypoint.Phase == "descida" or waypoint.Phase == "aproximacao" then
            context.PrepareContact()
        end
        State.StatusMessage = string.format("%s: %s @ %.0f/s", part.Name, waypoint.Phase, waypoint.Speed)
        context.PhaseLabel = State.StatusMessage
        addLog("MOVE", string.format("%s %s | %.1f studs @ %.0f/s", part.Name,
            waypoint.Phase, (waypoint.Position - root.Position).Magnitude, waypoint.Speed))
        if not moveToPosition(CFrame.new(waypoint.Position) * root.CFrame.Rotation, waypoint.Speed, context) then
            return false
        end
    end
    return true
end

local function getChestExitPosition(part, attempt)
    local directions = {
        Vector3.new(1, 0, 0),
        Vector3.new(-1, 0, 0),
        Vector3.new(0, 0, 1),
        Vector3.new(0, 0, -1),
    }
    local direction = directions[((attempt - 1) % #directions) + 1]
    local triggerRadius = math.max(part.Size.X, part.Size.Z) * 0.5 + 2
    return part.Position + direction * triggerRadius + Vector3.new(0, 0.5, 0)
end

local function readPlayerBalance()
    local data = LocalPlayer:FindFirstChild("Data")
    if not data then return nil, nil end

    local beli = data:FindFirstChild("Beli")
    local fragments = data:FindFirstChild("Fragments") or data:FindFirstChild("Fragment")
    local beliValue = beli and beli:IsA("ValueBase") and tonumber(beli.Value) or nil
    local fragmentValue = fragments and fragments:IsA("ValueBase") and tonumber(fragments.Value) or nil
    return beliValue, fragmentValue
end

local function isChestConsumed(part, context)
    if not context.ContactStarted then return false end
    local disappeared = not part or not part:IsDescendantOf(Workspace) or not getTouchTransmitter(part)
    if not disappeared then return false end
    local beli, fragments = readPlayerBalance()
    local reward = (context.InitialBeli ~= nil and beli ~= nil and beli > context.InitialBeli)
        or (context.InitialFragments ~= nil and fragments ~= nil and fragments > context.InitialFragments)
    if context.InitialBeli ~= nil or context.InitialFragments ~= nil then return reward end
    -- Sem Data, exige a desativacao do gatilho depois do contato, nunca durante a viagem.
    return true
end

local function waitForChestConfirmation(part, context)
    local deadline = os.clock() + Config.CollectionTimeout
    local root = getRoot(context.Character)
    local humanoid = getHumanoid(context.Character)
    if not root or not humanoid then return false end
    repeat
        if not movementIsActive(context.Character, root, humanoid, context.Token) then return false end
        if isChestConsumed(part, context) then return true end
        task.wait(0.05)
    until os.clock() >= deadline
    return movementIsActive(context.Character, root, humanoid, context.Token) and isChestConsumed(part, context)
end

local function collectChest(chestData)
    if State.Unloaded then return false end

    local part = chestData.Part
    local valid = isValidChest(part)
    if not valid then return false end

    local char = getCharacter()
    local hrp = getRoot(char)
    local humanoid = getHumanoid(char)
    if not char or not hrp or not humanoid or humanoid.Health <= 0 then return false end

    local context = {Character = char, Token = State.MovementToken, ContactStarted = false}
    context.ContactPosition = part.Position + Vector3.new(0, 0.5, 0)
    context.PrepareContact = function()
        if not context.BaselineCaptured then
            context.InitialBeli, context.InitialFragments = readPlayerBalance()
            context.BaselineCaptured = true
        end
    end
    local function confirmCollected()
        if State.CountedChests[part] then return true end
        State.CountedChests[part] = true
        State.FailedUntil[part] = nil
        State.CollectedInServer = State.CollectedInServer + 1
        State.TotalCollectedSession = State.TotalCollectedSession + 1
        addLog("OK", string.format("%s confirmado | servidor=%d", chestData.Name, State.CollectedInServer))
        return true
    end
    addLog("ALVO", string.format("%s | dist=%.1f | %s", chestData.Name, chestData.Distance, part:GetFullName()))

    local arrived = moveToChest(part, context)
    if not arrived then
        State.FailedUntil[part] = os.clock() + Config.FailedChestCooldown
        addLog("WARN", "Falha ao chegar em " .. chestData.Name)
        return false
    end

    for attempt = 1, Config.CollectionRetries do
        if not movementIsActive(char, hrp, humanoid, context.Token) then
            return false
        end

        if isChestConsumed(part, context) then return confirmCollected() end
        if not isValidChest(part) then
            if waitForChestConfirmation(part, context) then return confirmCollected() end
            break
        end

        State.StatusMessage = string.format("Confirmando %s (%d/%d)", chestData.Name, attempt, Config.CollectionRetries)
        addLog("TOQUE", string.format("%s tentativa %d/%d", chestData.Name, attempt, Config.CollectionRetries))

        -- Para no gatilho e zera a inercia: atravessar rapidamente a Part pode
        -- produzir apenas o efeito visual sem o servidor validar a coleta.
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        local contacted = moveToPosition(
            CFrame.new(part.Position + Vector3.new(0, 0.5, 0)),
            Config.ContactSpeed,
            context
        )

        if not contacted then
            addLog("WARN", chestData.Name .. " falhou na aproximacao de contato")
            continue
        end

        if Runtime.FireTouchInterest then
            pcall(Runtime.FireTouchInterest, hrp, part, 0)
        end

        -- O suporte de movimento segura a gravidade durante o contato; nao ha salto de CFrame.
        local holdDeadline = os.clock() + Config.TouchHold
        while movementIsActive(char, hrp, humanoid, context.Token) and part:IsDescendantOf(Workspace)
            and os.clock() < holdDeadline do
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            task.wait(0.05)
        end

        if Runtime.FireTouchInterest then
            pcall(Runtime.FireTouchInterest, hrp, part, 1)
        end
        if not movementIsActive(char, hrp, humanoid, context.Token) then return false end

        if waitForChestConfirmation(part, context) then return confirmCollected() end

        -- Sai lateralmente do hitbox para gerar TouchEnded -> Touched sem o
        -- antigo efeito de subir/descer repetidamente em cima do bau.
        if part:IsDescendantOf(Workspace) then
            if not moveToPosition(CFrame.new(getChestExitPosition(part, attempt)), Config.ContactSpeed, context) then
                return false
            end
        end
    end

    State.FailedUntil[part] = os.clock() + Config.FailedChestCooldown
    addLog("ERRO", chestData.Name .. " nao foi confirmado apos todas as tentativas")
    return false
end

-- ============================================================================
-- 8. SISTEMA DE SERVER HOP & AUTO-EXECUTE PERSISTENCE
-- ============================================================================
local visitedServersFile = "AutoChest_VisitedServers.json"
local legacyVisitedServersFile = "BF_VisitedServers.json"
local visitedServers = {}

pcall(function()
    if Runtime.IsFile and Runtime.ReadFile then
        local loadedFile = Runtime.IsFile(visitedServersFile) and visitedServersFile
            or (Runtime.IsFile(legacyVisitedServersFile) and legacyVisitedServersFile)
        if loadedFile then
            visitedServers = HttpService:JSONDecode(Runtime.ReadFile(loadedFile)) or {}
        end
    end
end)

for jobId, visitedAt in pairs(visitedServers) do
    if type(visitedAt) ~= "number" or os.time() - visitedAt > Config.VisitedServerTTL then
        visitedServers[jobId] = nil
    end
end

local function saveVisitedServer(jobId)
    visitedServers[jobId] = os.time()
    pcall(function()
        if Runtime.WriteFile then
            Runtime.WriteFile(visitedServersFile, HttpService:JSONEncode(visitedServers))
        end
    end)
end

doServerHop = function(reason, isRetry)
    if State.Unloaded or State.IsHopping then return end

    if not isRetry then
        State.HopAttempts = 0
    end

    if State.HopBlocked then
        State.StatusMessage = "Hop bloqueado apos falhas; use FORCAR SERVER HOP"
        return
    end

    if isRetry and State.HopAttempts >= Config.MaxHopAttempts then
        State.HopBlocked = true
        State.IsHopping = false
        State.StatusMessage = "Hop falhou 3 vezes; retry automatico interrompido"
        addLog("ERRO", "Limite de tentativas de hop atingido; loop interrompido")
        return
    end

    State.HopAttempts = State.HopAttempts + 1
    State.HopToken = State.HopToken + 1
    local hopToken = State.HopToken
    State.IsHopping = true
    State.StatusMessage = string.format("Server Hop %d/%d: %s",
        State.HopAttempts, Config.MaxHopAttempts, tostring(reason or "Meta atingida!"))
    addLog("HOP", State.StatusMessage)

    cancelCurrentMovement()

    -- Injeta no queue_on_teleport para persistir no novo servidor
    if Config.PersistOnTeleport and not State.AutoExecuteQueued then
        local queueTeleport = Runtime.QueueOnTeleport
        if queueTeleport then
            local queued = pcall(queueTeleport, [[
                if not game:IsLoaded() then
                    game.Loaded:Wait()
                end
                task.wait(2)
                pcall(function()
                    local url = "https://raw.githubusercontent.com/victorcxzk/Script/main/AutoChest.lua"
                    local fetched, source = pcall(function()
                        return game:HttpGet(url)
                    end)
                    if fetched and type(source) == "string" and #source > 0 then
                        local chunk = loadstring(source)
                        if chunk then
                            chunk()
                            return
                        end
                    end
                    if isfile and readfile and isfile("scripts/auto_chest.lua") then
                        loadstring(readfile("scripts/auto_chest.lua"))()
                    elseif isfile and readfile and isfile("auto_chest.lua") then
                        loadstring(readfile("auto_chest.lua"))()
                    end
                end)
            ]])
            if queued then
                State.AutoExecuteQueued = true
                addLog("HOP", "Auto-execute enfileirado para o proximo servidor")
            else
                addLog("WARN", "Executor recusou queue_on_teleport")
            end
        else
            addLog("WARN", "queue_on_teleport indisponivel; auto-execute nao garantido")
        end
    end

    saveVisitedServer(game.JobId)

    local placeId = game.PlaceId
    local currentJob = game.JobId
    local url = string.format("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=100", tostring(placeId))

    local candidates = {}
    pcall(function()
        local raw = game:HttpGet(url)
        local data = HttpService:JSONDecode(raw)
        if data and data.data then
            for _, srv in ipairs(data.data) do
                if type(srv) == "table" and srv.id ~= currentJob and srv.playing and srv.maxPlayers then
                    if srv.playing > 0 and srv.playing < srv.maxPlayers and not visitedServers[srv.id] then
                        table.insert(candidates, srv.id)
                    end
                end
            end
        end
    end)

    -- Matchmaking padrao evita o 773. Um JobId publico especifico e usado
    -- apenas como fallback na segunda tentativa.
    local chosen = nil
    if #candidates > 0 and State.HopAttempts == 2 then
        chosen = candidates[math.random(1, #candidates)]
        saveVisitedServer(chosen)
    end

    local teleportOk, teleportError = pcall(function()
        if chosen then
            addLog("HOP", "Tentando servidor " .. tostring(chosen))
            TeleportService:TeleportToPlaceInstance(placeId, chosen, LocalPlayer)
        else
            addLog("HOP", "Usando matchmaking padrao do Roblox")
            TeleportService:Teleport(placeId, LocalPlayer)
        end
    end)

    if not teleportOk then
        State.IsHopping = true
        State.StatusMessage = "Falha no hop: " .. tostring(teleportError)
        if Config.AutoReconnect then
            task.delay(3, function()
                if not State.Unloaded and State.HopToken == hopToken and doServerHop then
                    State.IsHopping = false
                    doServerHop("Retry apos falha no hop", true)
                end
            end)
        else
            State.IsHopping = false
        end
        return
    end

    -- Timeout caso o teleporte demore
    local originJob = currentJob
    task.delay(Config.HopTimeout, function()
        if State.Unloaded or State.HopToken ~= hopToken then return end
        if game.JobId ~= originJob then return end

        State.IsHopping = false
        addLog("WARN", string.format("Hop %d travou no loading por %ds", State.HopAttempts, Config.HopTimeout))
        doServerHop("Timeout na tela de loading", true)
    end)
end

-- ============================================================================
-- 9. INTERFACE VISUAL (ALL BLACK + RED)
-- ============================================================================
local uiOk, uiError = pcall(function()
    local colors = {
        Black = Color3.fromRGB(5, 5, 6),
        Panel = Color3.fromRGB(11, 11, 13),
        Raised = Color3.fromRGB(18, 18, 21),
        Border = Color3.fromRGB(42, 42, 48),
        Red = Color3.fromRGB(225, 29, 72),
        RedDark = Color3.fromRGB(115, 18, 38),
        White = Color3.fromRGB(242, 242, 244),
        Muted = Color3.fromRGB(142, 142, 151),
    }

    local old = CoreGui:FindFirstChild("AutoChestHUD")
    if old then old:Destroy() end
    local legacyOld = CoreGui:FindFirstChild("BFAutoChestHUD")
    if legacyOld then legacyOld:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "AutoChestHUD"
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    pcall(function()
        if Runtime.GetHui then sg.Parent = Runtime.GetHui()
        elseif Runtime.ProtectGui then Runtime.ProtectGui(sg); sg.Parent = CoreGui
        else sg.Parent = CoreGui end
    end)
    if not sg.Parent then sg.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local card = Instance.new("Frame")
    card.Name = "Window"
    card.Size = Config.Minimized and UDim2.fromOffset(440, 54) or UDim2.fromOffset(440, 376)
    card.Position = UDim2.new(0.025, 0, 0.22, 0)
    card.BackgroundColor3 = colors.Black
    card.BorderSizePixel = 0
    card.Active = true
    card.ClipsDescendants = true
    card.Parent = sg
    local cardCorner = Instance.new("UICorner")
    cardCorner.CornerRadius = UDim.new(0, 5)
    cardCorner.Parent = card
    local cardStroke = Instance.new("UIStroke")
    cardStroke.Color = colors.RedDark
    cardStroke.Thickness = 1
    cardStroke.Parent = card

    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(1, 0, 0, 3)
    accent.BackgroundColor3 = colors.Red
    accent.BorderSizePixel = 0
    accent.Parent = card

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -110, 0, 25)
    title.Position = UDim2.fromOffset(16, 11)
    title.BackgroundTransparency = 1
    title.Text = string.format("CHEST CONTROL  v%s", SCRIPT_VERSION)
    title.TextColor3 = colors.White
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = card

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -110, 0, 14)
    subtitle.Position = UDim2.fromOffset(16, 34)
    subtitle.BackgroundTransparency = 1
    local hasQueueApi = Runtime.QueueOnTeleport
    subtitle.Text = string.format("AUTO-EXEC %s  /  RECONNECT %s  /  SETTINGS %s",
        hasQueueApi and "READY" or "N/A",
        Config.AutoReconnect and "ON" or "OFF",
        Runtime.WriteFile and "READY" or "N/A")
    subtitle.TextColor3 = colors.Muted
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 9
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = card

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(30, 30)
    closeBtn.Position = UDim2.new(1, -42, 0, 11)
    closeBtn.BackgroundColor3 = colors.Raised
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "X"
    closeBtn.TextColor3 = colors.Red
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = card
    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 4)
    closeCorner.Parent = closeBtn
    local closeStroke = Instance.new("UIStroke")
    closeStroke.Color = colors.RedDark
    closeStroke.Thickness = 1
    closeStroke.Parent = closeBtn

    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Size = UDim2.fromOffset(30, 30)
    minimizeBtn.Position = UDim2.new(1, -78, 0, 11)
    minimizeBtn.BackgroundColor3 = colors.Raised
    minimizeBtn.BorderSizePixel = 0
    minimizeBtn.Text = Config.Minimized and "+" or "-"
    minimizeBtn.TextColor3 = colors.White
    minimizeBtn.Font = Enum.Font.GothamBold
    minimizeBtn.TextSize = 15
    minimizeBtn.Parent = card
    local minimizeCorner = Instance.new("UICorner")
    minimizeCorner.CornerRadius = UDim.new(0, 4)
    minimizeCorner.Parent = minimizeBtn
    local minimizeStroke = Instance.new("UIStroke")
    minimizeStroke.Color = colors.Border
    minimizeStroke.Thickness = 1
    minimizeStroke.Parent = minimizeBtn

    -- Drag manual para substituir Frame.Draggable, que e obsoleto no Luau atual.
    local dragging = false
    local dragInput = nil
    local dragStart = nil
    local startPosition = nil
    trackConnection(card.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = card.Position
            trackConnection(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end))
        end
    end))
    trackConnection(card.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end))
    if UserInputService then
        trackConnection(UserInputService.InputChanged:Connect(function(input)
            if dragging and input == dragInput and dragStart and startPosition then
                local delta = input.Position - dragStart
                card.Position = UDim2.new(
                    startPosition.X.Scale,
                    startPosition.X.Offset + delta.X,
                    startPosition.Y.Scale,
                    startPosition.Y.Offset + delta.Y
                )
            end
        end))
    end

    local stats = Instance.new("Frame")
    stats.Size = UDim2.new(1, -32, 0, 48)
    stats.Position = UDim2.fromOffset(16, 58)
    stats.BackgroundTransparency = 1
    stats.Parent = card

    local function makeStat(x, width, caption)
        local box = Instance.new("Frame")
        box.Size = UDim2.fromOffset(width, 48)
        box.Position = UDim2.fromOffset(x, 0)
        box.BackgroundColor3 = colors.Panel
        box.BorderSizePixel = 0
        box.Parent = stats
        local stroke = Instance.new("UIStroke")
        stroke.Color = colors.Border
        stroke.Thickness = 1
        stroke.Parent = box

        local cap = Instance.new("TextLabel")
        cap.Size = UDim2.new(1, -16, 0, 14)
        cap.Position = UDim2.fromOffset(8, 6)
        cap.BackgroundTransparency = 1
        cap.Text = caption
        cap.TextColor3 = colors.Muted
        cap.Font = Enum.Font.GothamBold
        cap.TextSize = 9
        cap.TextXAlignment = Enum.TextXAlignment.Left
        cap.Parent = box

        local value = Instance.new("TextLabel")
        value.Size = UDim2.new(1, -16, 0, 20)
        value.Position = UDim2.fromOffset(8, 22)
        value.BackgroundTransparency = 1
        value.Text = "0"
        value.TextColor3 = colors.White
        value.Font = Enum.Font.GothamBold
        value.TextSize = 14
        value.TextXAlignment = Enum.TextXAlignment.Left
        value.Parent = box
        return value
    end

    local collectedValue = makeStat(0, 128, "COLETADOS")
    local targetValue = makeStat(138, 128, "META")
    local scanValue = makeStat(276, 132, "SCANNER")

    local statusPanel = Instance.new("Frame")
    statusPanel.Size = UDim2.new(1, -32, 0, 42)
    statusPanel.Position = UDim2.fromOffset(16, 116)
    statusPanel.BackgroundColor3 = colors.Panel
    statusPanel.BorderSizePixel = 0
    statusPanel.Parent = card
    local statusStroke = Instance.new("UIStroke")
    statusStroke.Color = colors.Border
    statusStroke.Thickness = 1
    statusStroke.Parent = statusPanel
    local statusBar = Instance.new("Frame")
    statusBar.Size = UDim2.fromOffset(3, 42)
    statusBar.BackgroundColor3 = colors.Red
    statusBar.BorderSizePixel = 0
    statusBar.Parent = statusPanel

    local statusLbl = Instance.new("TextLabel")
    statusLbl.Size = UDim2.new(1, -20, 1, 0)
    statusLbl.Position = UDim2.fromOffset(12, 0)
    statusLbl.BackgroundTransparency = 1
    statusLbl.Text = "INICIALIZANDO"
    statusLbl.TextColor3 = colors.White
    statusLbl.Font = Enum.Font.GothamMedium
    statusLbl.TextSize = 10
    statusLbl.TextXAlignment = Enum.TextXAlignment.Left
    statusLbl.TextTruncate = Enum.TextTruncate.AtEnd
    statusLbl.Parent = statusPanel

    local function makeButton(x, y, width, text)
        local button = Instance.new("TextButton")
        button.Size = UDim2.fromOffset(width, 32)
        button.Position = UDim2.fromOffset(x, y)
        button.BackgroundColor3 = colors.Raised
        button.BorderSizePixel = 0
        button.Text = text
        button.TextColor3 = colors.White
        button.Font = Enum.Font.GothamBold
        button.TextSize = 10
        button.Parent = card
        local stroke = Instance.new("UIStroke")
        stroke.Color = colors.RedDark
        stroke.Thickness = 1
        stroke.Parent = button
        return button
    end

    local toggleBtn = makeButton(16, 170, 198, Config.Enabled and "AUTO-CHEST  /  ON" or "AUTO-CHEST  /  OFF")
    local targetHopBtn = makeButton(226, 170, 198, Config.HopAfterTarget and "HOP NA META  /  ON" or "HOP NA META  /  OFF")
    toggleBtn.BackgroundColor3 = Config.Enabled and colors.RedDark or colors.Raised
    targetHopBtn.BackgroundColor3 = Config.HopAfterTarget and colors.RedDark or colors.Raised

    local targetBox = Instance.new("TextBox")
    targetBox.Size = UDim2.fromOffset(198, 32)
    targetBox.Position = UDim2.fromOffset(16, 212)
    targetBox.BackgroundColor3 = colors.Panel
    targetBox.BorderSizePixel = 0
    targetBox.PlaceholderText = "META DE BAUS"
    targetBox.PlaceholderColor3 = colors.Muted
    targetBox.Text = tostring(Config.TargetChests)
    targetBox.TextColor3 = colors.White
    targetBox.Font = Enum.Font.GothamBold
    targetBox.TextSize = 11
    targetBox.ClearTextOnFocus = true
    targetBox.Parent = card
    local targetStroke = Instance.new("UIStroke")
    targetStroke.Color = colors.Border
    targetStroke.Thickness = 1
    targetStroke.Parent = targetBox

    local hopBtn = makeButton(226, 212, 198, "FORCAR SERVER HOP")

    local logPanel = Instance.new("Frame")
    logPanel.Size = UDim2.new(1, -32, 0, 108)
    logPanel.Position = UDim2.fromOffset(16, 256)
    logPanel.BackgroundColor3 = colors.Panel
    logPanel.BorderSizePixel = 0
    logPanel.Parent = card
    local logStroke = Instance.new("UIStroke")
    logStroke.Color = colors.Border
    logStroke.Thickness = 1
    logStroke.Parent = logPanel

    local logTitle = Instance.new("TextLabel")
    logTitle.Size = UDim2.new(1, -16, 0, 18)
    logTitle.Position = UDim2.fromOffset(8, 4)
    logTitle.BackgroundTransparency = 1
    logTitle.Text = "LIVE DIAGNOSTICS"
    logTitle.TextColor3 = colors.Red
    logTitle.Font = Enum.Font.Code
    logTitle.TextSize = 10
    logTitle.TextXAlignment = Enum.TextXAlignment.Left
    logTitle.Parent = logPanel

    local logLbl = Instance.new("TextLabel")
    logLbl.Size = UDim2.new(1, -16, 1, -26)
    logLbl.Position = UDim2.fromOffset(8, 22)
    logLbl.BackgroundTransparency = 1
    logLbl.Text = "Aguardando o primeiro scan..."
    logLbl.TextColor3 = colors.Muted
    logLbl.Font = Enum.Font.Code
    logLbl.TextSize = 9
    logLbl.TextXAlignment = Enum.TextXAlignment.Left
    logLbl.TextYAlignment = Enum.TextYAlignment.Top
    logLbl.TextWrapped = false
    logLbl.TextTruncate = Enum.TextTruncate.AtEnd
    logLbl.Parent = logPanel

    trackConnection(toggleBtn.MouseButton1Click:Connect(function()
        Config.Enabled = not Config.Enabled
        toggleBtn.Text = Config.Enabled and "AUTO-CHEST  /  ON" or "AUTO-CHEST  /  OFF"
        toggleBtn.BackgroundColor3 = Config.Enabled and colors.RedDark or colors.Raised
        if Config.Enabled then
            State.EmptySince = nil
            State.StatusMessage = "Auto-chest reativado"
            enableNoclip()
            addLog("INFO", "Auto-chest ligado")
        else
            cancelCurrentMovement()
            disableNoclip()
            State.StatusMessage = "Pausado pelo usuario"
            addLog("INFO", "Auto-chest pausado")
        end
        State.SettingsPersisted = saveSettings()
    end))

    trackConnection(targetHopBtn.MouseButton1Click:Connect(function()
        Config.HopAfterTarget = not Config.HopAfterTarget
        targetHopBtn.Text = Config.HopAfterTarget and "HOP NA META  /  ON" or "HOP NA META  /  OFF"
        targetHopBtn.BackgroundColor3 = Config.HopAfterTarget and colors.RedDark or colors.Raised
        addLog("INFO", "Hop na meta: " .. (Config.HopAfterTarget and "ON" or "OFF"))
        State.SettingsPersisted = saveSettings()
    end))

    trackConnection(targetBox.FocusLost:Connect(function()
        local requested = tonumber(targetBox.Text:match("%d+"))
        if requested then
            Config.TargetChests = math.clamp(math.floor(requested), 1, 999)
            addLog("INFO", "Nova meta: " .. tostring(Config.TargetChests))
        else
            addLog("WARN", "Meta invalida ignorada")
        end
        targetBox.Text = tostring(Config.TargetChests)
        State.SettingsPersisted = saveSettings()
    end))

    trackConnection(hopBtn.MouseButton1Click:Connect(function()
        State.HopBlocked = false
        State.HopAttempts = 0
        doServerHop("Acionado pelo usuario")
    end))
    trackConnection(minimizeBtn.MouseButton1Click:Connect(function()
        Config.Minimized = not Config.Minimized
        minimizeBtn.Text = Config.Minimized and "+" or "-"
        card.Size = Config.Minimized and UDim2.fromOffset(440, 54) or UDim2.fromOffset(440, 376)
        State.SettingsPersisted = saveSettings()
    end))
    trackConnection(closeBtn.MouseButton1Click:Connect(unload))

    hud.Gui = sg
    hud.subtitle = subtitle
    hud.collectedValue = collectedValue
    hud.targetValue = targetValue
    hud.scanValue = scanValue
    hud.statusLbl = statusLbl
    hud.logLbl = logLbl
end)

if not uiOk then
    addLog("ERRO", "Falha ao criar UI: " .. tostring(uiError))
end

-- ============================================================================
-- 10. LOOP PRINCIPAL DE EXECUCAO
-- ============================================================================
addLog("BOOT", string.format("%s v%s | build %s | place=%s | job=%s",
    SCRIPT_NAME, SCRIPT_VERSION, SCRIPT_BUILD, tostring(game.PlaceId), tostring(game.JobId)))
addLog("SOURCE", RAW_SCRIPT_URL)
addLog("BOOT", "Scanner baseado no dump: Workspace.Map + Chest1/2/3 + TouchTransmitter")
addLog("MOVE", string.format("Movimento continuo | viagem=%.0f/s vertical=%.0f/s contato=%.0f/s",
    Config.TweenSpeed, Config.VerticalSpeed, Config.ContactSpeed))
addLog("ESP", "Sempre ativo | bronze=laranja prata=claro ouro=amarelo")
State.SettingsPersisted = saveSettings()
addLog("SETTINGS", settingsLoadMessage .. (State.SettingsPersisted and " | persistencia OK" or " | falha ao salvar"))
local queueApiAvailable = Runtime.QueueOnTeleport
addLog("AUTOEXEC", queueApiAvailable and "queue_on_teleport detectado" or "queue_on_teleport indisponivel")
addLog("RECONNECT", Config.AutoReconnect and "monitores de erro e TeleportInitFailed ativos" or "desligado na configuracao")

task.spawn(function()
    local nextESPRefresh = 0
    while not State.Unloaded do
        if hud.subtitle then
            local autoExecuteState = not Config.PersistOnTeleport and "OFF"
                or (State.AutoExecuteQueued and "QUEUED")
                or (queueApiAvailable and "READY")
                or "N/A"
            hud.subtitle.Text = string.format("AUTO-EXEC %s  /  RECONNECT %s  /  SETTINGS %s",
                autoExecuteState,
                Config.AutoReconnect and "ON" or "OFF",
                State.SettingsPersisted and "SAVED" or "ERROR")
        end
        if hud.collectedValue then
            hud.collectedValue.Text = string.format("%d  /  %d", State.CollectedInServer, State.TotalCollectedSession)
        end
        if hud.targetValue then
            hud.targetValue.Text = tostring(Config.TargetChests)
        end
        if hud.scanValue then
            local scan = State.LastScanDiagnostics
            hud.scanValue.Text = scan and string.format("%d/%d", scan.Active, scan.WithTouch) or "--"
        end
        if hud.statusLbl then
            hud.statusLbl.Text = string.upper(State.StatusMessage)
        end
        if hud.logLbl then
            hud.logLbl.Text = #State.LogEntries > 0 and table.concat(State.LogEntries, "\n") or "Aguardando o primeiro scan..."
        end
        if os.clock() >= nextESPRefresh then
            nextESPRefresh = os.clock() + 0.25
            pcall(updateChestESP)
        end
        task.wait(0.1)
    end
end)

local function waitOnEmptyServer(scan)
    local currentMap = Workspace:FindFirstChild("Map")
    if State.EmptyScanMap ~= currentMap or State.EmptyScanAnchors ~= scan.InMap then
        State.EmptyScanMap = currentMap
        State.EmptyScanAnchors = scan.InMap
        State.EmptySince = nil
    end
    if scan.InMap < Config.MinimumChestAnchors then
        State.EmptySince = nil
        if State.LastGuardReason ~= "NO_CANDIDATES" then
            State.LastGuardReason = "NO_CANDIDATES"
            addLog("WARN", string.format(
                "Scanner encontrou apenas %d/%d anchors Chest1/2/3; hop bloqueado",
                scan.InMap, Config.MinimumChestAnchors
            ))
        end
        State.StatusMessage = "Scanner aguardando anchors do mapa"
        task.wait(1)
        return
    end

    if scan.WithTouch > 0 then
        State.EmptySince = nil
        if State.LastGuardReason ~= "SCAN_MISMATCH" then
            State.LastGuardReason = "SCAN_MISMATCH"
            addLog("ERRO", "Scanner viu TouchTransmitter, mas nao produziu um alvo")
        end
        State.StatusMessage = "Scanner inconsistente; hop bloqueado"
        task.wait(1)
        return
    end

    local warmupFor = State.ScannerReadyAt and (os.clock() - State.ScannerReadyAt) or 0
    if State.ConsecutiveReliableScans < 3 or warmupFor < Config.ScannerWarmup then
        State.EmptySince = nil
        State.LastGuardReason = "SCANNER_WARMUP"
        State.StatusMessage = string.format("Estabilizando scanner... %.0f/%ds",
            math.min(warmupFor, Config.ScannerWarmup), Config.ScannerWarmup)
        task.wait(0.5)
        return
    end

    State.LastGuardReason = nil
    State.EmptySince = State.EmptySince or os.clock()
    local emptyFor = os.clock() - State.EmptySince
    local remaining = math.max(0, math.ceil(Config.EmptyScanGrace - emptyFor))

    if emptyFor < Config.EmptyScanGrace then
        State.StatusMessage = string.format("Confirmando servidor vazio... %ds", remaining)
        task.wait(0.5)
    elseif Config.HopWhenEmpty then
        State.StatusMessage = "Servidor confirmado sem baus"
        doServerHop("Servidor sem baus restantes")
    else
        State.StatusMessage = "Nenhum bau disponivel no servidor"
        task.wait(1)
    end
end

local function runCollectionCycle()
    if State.IsRespawning or not getCharacter(0.2) then
        State.EmptySince = nil
        State.StatusMessage = "Aguardando respawn do personagem..."
        task.wait(0.25)
        return
    end

    if Config.HopAfterTarget and State.CollectedInServer > 0
        and State.CollectedInServer >= Config.TargetChests then
        doServerHop(string.format("Meta de %d baus alcancada!", Config.TargetChests))
        return
    end

    State.StatusMessage = "Escaneando baus no Workspace.Map..."
    local scanOk, availableChests, coolingDown, scan = pcall(scanAllChests)
    if not scanOk then
        error("scanner: " .. tostring(availableChests))
    end

    if #availableChests == 0 then
        if coolingDown > 0 then
            State.EmptySince = nil
            State.LastGuardReason = nil
            State.StatusMessage = string.format("Aguardando %d bau(s) para nova tentativa", coolingDown)
            task.wait(0.5)
        elseif not Workspace:FindFirstChild("Map") then
            State.EmptySince = nil
            State.StatusMessage = "Aguardando Workspace.Map..."
            task.wait(0.5)
        else
            waitOnEmptyServer(scan)
        end
        return
    end

    State.EmptySince = nil
    State.LastGuardReason = nil
    local target = availableChests[1]
    State.CurrentTarget = target
    State.StatusMessage = string.format("Coletando %s (%.0fm)", target.Name, target.Distance)

    local collectOk, collected = pcall(collectChest, target)
    -- O gatilho confirmado ja desapareceu; nao levanta o personagem novamente.
    releaseMotionSupport()
    State.CurrentTarget = nil
    if not collectOk then
        State.FailedUntil[target.Part] = os.clock() + Config.FailedChestCooldown
        error("coleta: " .. tostring(collected))
    end
    if not collected and not State.IsHopping and not State.IsRespawning then
        State.StatusMessage = "Coleta nao confirmada; selecionando outro bau"
    end
    task.wait(Config.CollectDelay)
end

-- Atualiza o HUD durante viagens longas; a coleta continua serial no outro loop.
task.spawn(function()
    while not State.Unloaded do
        if Config.Enabled and not State.IsHopping and Workspace:FindFirstChild("Map") then
            local ok, scanError = pcall(scanAllChests)
            if not ok and State.LastRuntimeError ~= tostring(scanError) then
                State.LastRuntimeError = tostring(scanError)
                addLog("ERRO", "Scanner em background: " .. tostring(scanError))
            end
        end
        task.wait(1.5)
    end
end)

task.spawn(function()
    task.wait(0.5)
    while not State.Unloaded and not waitForGameReady(Config.GameReadyTimeout) do
        addLog("WARN", "Personagem ou Workspace.Map ainda nao estao prontos; hop inicial bloqueado")
        State.StatusMessage = "Mapa incompleto; nova verificacao em 2s"
        task.wait(2)
    end
    if State.Unloaded then return end

    addLog("INFO", Config.Enabled and "Mapa pronto; iniciando ciclo de coleta" or "Mapa pronto; configuracao salva esta pausada")
    if not Config.Enabled then State.StatusMessage = "Pausado conforme configuracao salva" end
    while not State.Unloaded do
        task.wait(0.1)
        if Config.Enabled and not State.IsHopping then
            local cycleOk, cycleError = pcall(runCollectionCycle)
            if not cycleOk then
                cancelCurrentMovement()
                local message = tostring(cycleError)
                State.StatusMessage = "Erro recuperavel no ciclo; veja o LOG"
                if State.LastRuntimeError ~= message then
                    State.LastRuntimeError = message
                    addLog("ERRO", message)
                end
                task.wait(1)
            else
                State.LastRuntimeError = nil
            end
        end
    end
end)
