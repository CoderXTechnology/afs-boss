-- =========================================================================
--  AFS · BOSS AUTO-JOINER + AUTO-FARM  ·  v1.1.0
-- =========================================================================
--  Faithful port of adrielemir208-eng/Steal-a-brainrot-auto-joiner,
--  rewritten for Anime Fighting Simulator (universe 10321202755).
--
--  COPIED FROM THE GITHUB REPO
--    · Notifier  — HttpService POST of {placeId, jobId, bosses[]} to your
--                  Node server (/data), 30s dedup, x-notifier-token auth.
--    · fetchRealServers — Roblox games API
--                  (games.roblox.com/v1/games/{universe}/servers/Public)
--                  to enumerate PUBLIC servers (no cookie needed).
--    · joinServer — TeleportService:TeleportToPlaceInstance(placeId, jobId).
--    · Hop loop   — walks the server list hunting for a wanted boss,
--                  teleporting to the next server when none spawns.
--
--  AFS-SPECIFIC
--    · Detection is EVENT-DRIVEN only (CollectionService isBoss signal) —
--      zero workspace scans, so it stays under AFS anticheat.
--    · Farm uses our OWN always-on camera aimbot (points the camera at the
--      boss every frame) plus a real special-key press — no AimHandler hook.
--    · Targets: LOW = HandDemon / SeaBeast / Shukaku
--                HIGH = FoundingTitan (Dimension 2 ONLY) / Mada["Phase-1"]
--
--  DEFAULTS: auto-join ON, farm ON. No test mode.
--  You MUST have a SPECIAL equipped for the farm to deal damage.
--
--  NOTE ON SERVER HOPPING: AFS's universe (10321202755) is REJECTED by the
--  public server-listing API ("The place is invalid"), so the automatic
--  universe scan cannot fetch a server list for this game. The hop loop and
--  "Hop Now" button still try it (and will work if the API ever resolves),
--  but the reliable way to move between Dimension 2 servers is the manual
--  "paste JobId → Join" box in the UI (uses TeleportToPlaceInstance).
-- =========================================================================

local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TeleportService   = game:GetService("TeleportService")
local MarketplaceService= game:GetService("MarketplaceService")
local VIM               = game:GetService("VirtualInputManager")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local CoreGui           = game:GetService("CoreGui")
local LocalPlayer       = Players.LocalPlayer
local PLACE_ID          = game.PlaceId

-- ── http helper (prefer executor request(), fall back to HttpService) ──────
local function http(method, url, headers, body)
    if type(request) == "function" then
        local ok, res = pcall(request, { Url = url, Method = method, Headers = headers or {}, Body = body })
        if ok and type(res) == "table" then
            return true, res.StatusCode or 200, res.Body
        end
        return false, nil, tostring(res)
    end
    if method == "GET" then
        local ok, r = pcall(HttpService.GetAsync, HttpService, url)
        return ok, ok and 200 or nil, r
    else
        local ok, r = pcall(HttpService.RequestAsync, HttpService,
            { Url = url, Method = method, Headers = headers or {}, Body = body })
        if ok and type(r) == "table" then return true, r.StatusCode, r.Body end
        return false, nil, tostring(r)
    end
end

-- ── bootstrap source (re-execute after teleport) ──────────────────────────
local BOOTSTRAP_SOURCE = nil
if type(isfile) == "function" and type(readfile) == "function"
   and pcall(isfile, "AFS_BossAutoFarm.luau") then
    local ok, src = pcall(readfile, "AFS_BossAutoFarm.luau")
    if ok and type(src) == "string" and #src > 100 then BOOTSTRAP_SOURCE = src end
end
if not BOOTSTRAP_SOURCE and getgenv().AFS_BOSS_SRC then
    BOOTSTRAP_SOURCE = getgenv().AFS_BOSS_SRC
end

-- ─────────────────────────────────────────────────────────────────────────
--  CONFIG
-- ─────────────────────────────────────────────────────────────────────────
local Config = {
    Enabled = true,                 -- master auto-joiner switch
    FarmEnabled = true,             -- attack detected bosses
    PlaceId = 122385531796312,      -- Dimension 2
    UniverseId = 10321202755,
    ScanSecondsPerServer = 40,      -- seconds to wait on a server before hopping
    MaxServersToScan = 50,
    AttackInterval = 1.1,           -- seconds between special presses
    SpecialKeys = { "Z" },          -- keys that fire your special (Z/X/C/V)
    Notifier = { Url = "", Secret = "" }, -- your Node server /data
}

-- names = lower-cased substrings matched against the boss entity Name
-- tier  = 1 HIGH (routed to WEBHOOK_HIGH) | 2 LOW (WEBHOOK_LOW)
-- dim2Only = only hunt in the "Dimension 2" place
local BOSS_TARGETS = {
    FoundingTitan = { names = { "foundingtitan", "founding titan" }, tier = 1, dim2Only = true,  enabled = true },
    Mada          = { names = { "mada", "phase-1", "phase1" },        tier = 1, dim2Only = false, enabled = true },
    HandDemon     = { names = { "handdemon", "hand demon" },          tier = 2, dim2Only = false, enabled = true },
    SeaBeast      = { names = { "seabeast", "sea beast" },            tier = 2, dim2Only = false, enabled = true },
    Shukaku       = { names = { "shukaku", "sand demon" },            tier = 2, dim2Only = false, enabled = true },
}

-- ─────────────────────────────────────────────────────────────────────────
--  RUNTIME STATE
-- ─────────────────────────────────────────────────────────────────────────
local active    = setmetatable({}, { __mode = "k" }) -- [model] = targetKey
local dead      = false
local hunting   = false
local state     = "IDLE"        -- IDLE | HUNTING | FARMING
local visited   = getgenv().AFS_BOSS_VISITED or {}
getgenv().AFS_BOSS_VISITED = visited
local aimTarget = nil
local UI = nil
local enumBlocked = false       -- set true once the games API rejects the universe

-- ─────────────────────────────────────────────────────────────────────────
--  HELPERS
-- ─────────────────────────────────────────────────────────────────────────
local function notify(title, content)
    print(("[BAF] %s — %s"):format(title, content))
    if UI and UI.status then
        UI.status.Text = ("Status: %s · %s"):format(title, content)
    end
end

local function currentDimension()
    local ok, name = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId).Name
    end)
    return ok and name or "?"
end

local function classify(model)
    local n = (model.Name or ""):lower()
    for key, t in pairs(BOSS_TARGETS) do
        if not t.enabled then continue end
        if t.dim2Only and currentDimension() ~= "Dimension 2" then continue end
        for _, sub in ipairs(t.names) do
            if n:find(sub, 1, true) then return key, t end
        end
    end
    return nil
end

local function chooseTarget()
    local best, bestKey, bestTier = nil, nil, 99
    for model, key in pairs(active) do
        if model and model.Parent then
            local t = BOSS_TARGETS[key]
            if t and t.tier < bestTier then
                best, bestKey, bestTier = model, key, t.tier
            end
        end
    end
    return best, bestKey
end

local function bossPosition(model)
    local box = model:FindFirstChild("_AimHitbox", true)
        or model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
    if box and box:IsA("BasePart") then return box.Position end
    if model:IsA("BasePart") then return model.Position end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────
--  NOTIFIER  (port of GitHub sendNotifier)
-- ─────────────────────────────────────────────────────────────────────────
local notifDedup = {}
local function sendNotifier()
    if not Config.Notifier.Url or Config.Notifier.Url == "" then return end
    local bosses = {}
    for model, key in pairs(active) do
        if model and model.Parent then
            local t = BOSS_TARGETS[key]
            local dk = game.JobId .. "_" .. model.Name
            local now = os.clock()
            if not notifDedup[dk] or now - notifDedup[dk] > 30 then
                notifDedup[dk] = now
                table.insert(bosses, {
                    name = model.Name,
                    tier = t.tier,
                    hp = model:GetAttribute("Health"),
                    players = #Players:GetPlayers(),
                })
            end
        end
    end
    if #bosses == 0 then return end
    local payload = { placeId = Config.PlaceId, jobId = game.JobId, bosses = bosses }
    local headers = { ["Content-Type"] = "application/json" }
    if Config.Notifier.Secret and Config.Notifier.Secret ~= "" then
        headers["x-notifier-token"] = Config.Notifier.Secret
    end
    task.spawn(function()
        local ok, code = http("POST", Config.Notifier.Url, headers, HttpService:JSONEncode(payload))
        if not ok then warn("[BAF] notifier failed:", code) end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────
--  SERVER ENUMERATION  (port of GitHub fetchRealServers)
-- ─────────────────────────────────────────────────────────────────────────
local function getUniverseIdFromPlaceId(placeId)
    local ok, r = http("GET", ("https://apis.roblox.com/universes/v1/places/%s/universe"):format(placeId))
    if ok and r then
        local d = HttpService:JSONDecode(r)
        if d and d.universeId then return d.universeId end
    end
    return nil
end

local function fetchRealServers()
    local uni = Config.UniverseId
    if not uni then uni = getUniverseIdFromPlaceId(Config.PlaceId) end
    if not uni then return {} end
    local ok, r = http("GET",
        ("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Desc&limit=100"):format(uni))
    if not ok then
        if not enumBlocked then
            enumBlocked = true
            notify("ENUM", "Roblox server API rejected this universe — auto-hop disabled. Use the JobId box to hop.")
        end
        return {}
    end
    local out = {}
    if r then
        local d = HttpService:JSONDecode(r)
        if d and d.data then
            for _, s in ipairs(d.data) do
                if s.placeId == Config.PlaceId then
                    table.insert(out, {
                        jobId = s.id, players = s.playing,
                        maxPlayers = s.maxPlayers, ping = s.ping or 0, placeId = s.placeId,
                    })
                end
            end
        end
    end
    return out
end

local function queueBootstrap()
    if type(queue_on_teleport) == "function" and BOOTSTRAP_SOURCE then
        pcall(queue_on_teleport, BOOTSTRAP_SOURCE)
    end
end

local function joinServer(jobId, placeId)
    if jobId == game.JobId then return false end
    queueBootstrap()
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId or Config.PlaceId, jobId, LocalPlayer)
    end)
    if not ok then warn("[BAF] join failed: " .. tostring(err)) end
    return ok
end

local function hopToNext()
    local servers = fetchRealServers()
    if #servers == 0 then
        if not enumBlocked then
            notify("HUNT", "No servers found to hop to (is the game public?)")
        else
            notify("HUNT", "Enumeration blocked — paste a JobId in the UI to hop manually")
        end
        return
    end
    local candidates = {}
    for _, s in ipairs(servers) do
        if s.jobId ~= game.JobId and not visited[s.jobId] then
            table.insert(candidates, s)
        end
    end
    if #candidates == 0 then
        visited = {}
        for _, s in ipairs(servers) do
            if s.jobId ~= game.JobId then table.insert(candidates, s) end
        end
    end
    if #candidates == 0 then
        notify("HUNT", "No unvisited servers to hop to")
        return
    end
    local pick = candidates[math.random(1, #candidates)]
    visited[pick.jobId] = true
    local n = 0; for _ in pairs(visited) do n += 1 end
    if n > 40 then visited = {} end
    notify("HUNT", ("Hopping -> server %s (%d/%d players)"):format(
        string.sub(pick.jobId, 1, 6), pick.players, pick.maxPlayers))
    joinServer(pick.jobId, pick.placeId)
end

-- ─────────────────────────────────────────────────────────────────────────
--  DETECTION  (event-driven only)
-- ─────────────────────────────────────────────────────────────────────────
local espObjects = setmetatable({}, { __mode = "k" })
local function addESP(model, t)
    if espObjects[model] then return end
    local hl = Instance.new("Highlight")
    hl.Name = "BAF_ESP"; hl.Adornee = model
    hl.FillColor = t.tier == 1 and Color3.fromRGB(255, 80, 80) or Color3.fromRGB(80, 160, 255)
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency = 0.5; hl.OutlineTransparency = 0
    hl.Parent = model
    local bb = Instance.new("BillboardGui")
    bb.Name = "BAF_Label"; bb.Adornee = model; bb.Size = UDim2.new(0, 200, 0, 50)
    bb.StudsOffset = Vector3.new(0, 4, 0); bb.AlwaysOnTop = true; bb.Parent = model
    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.new(1, 0, 1, 0); tl.BackgroundTransparency = 1
    tl.Text = model.Name .. (t.tier == 1 and " [HIGH]" or " [LOW]")
    tl.TextColor3 = t.tier == 1 and Color3.fromRGB(255, 120, 120) or Color3.fromRGB(120, 180, 255)
    tl.TextStrokeTransparency = 0.4; tl.TextScaled = true; tl.Font = Enum.Font.GothamBold
    tl.Parent = bb
    espObjects[model] = { hl, bb }
end
local function removeESP(model)
    local t = espObjects[model]
    if t then
        for _, o in ipairs(t) do pcall(function() o:Destroy() end) end
        espObjects[model] = nil
    end
end

local function onBossAdded(model)
    if dead or not model:HasTag("isBoss") or active[model] then return end
    local key, t = classify(model)
    if not key then return end
    active[model] = key
    addESP(model, t)
    notify("BOSS", ("%s detected (%s)"):format(model.Name, t.tier == 1 and "HIGH" or "low"))
    sendNotifier()
    if Config.Enabled and state == "HUNTING" then state = "FARMING" end
end

local function onBossRemoved(model)
    if active[model] then
        active[model] = nil
        removeESP(model)
        notify("BOSS GONE", (model.Name ~= nil and model.Name or "?") .. " despawned")
        if next(active) == nil and Config.Enabled then state = "HUNTING" end
    end
end

-- ─────────────────────────────────────────────────────────────────────────
--  FARM  (own camera aimbot + special key press)
-- ─────────────────────────────────────────────────────────────────────────
local function farmTick()
    local target = chooseTarget()
    if not target or not target.Parent then return end
    aimTarget = target
    local pos = bossPosition(target)
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if pos and root then
        if (pos - root.Position).Magnitude > 25 then
            root.CFrame = CFrame.new(pos + Vector3.new(0, 6, 10))
        end
    end
    for _, k in ipairs(Config.SpecialKeys) do
        local kc = Enum.KeyCode[k]
        if kc then
            pcall(function() VIM:SendKeyEvent(true, kc, false, nil) end)
            task.wait(0.03)
            pcall(function() VIM:SendKeyEvent(false, kc, false, nil) end)
            task.wait(0.05)
        end
    end
end

-- always-on camera aimbot: point the camera at the current target every frame
local function startAimbot()
    local cam = workspace.CurrentCamera
    RunService.Heartbeat:Connect(function()
        if dead or not (Config.FarmEnabled and aimTarget and aimTarget.Parent) then return end
        local pos = bossPosition(aimTarget)
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if pos and root then
            cam.CFrame = CFrame.lookAt(root.Position + Vector3.new(0, 1.6, 0), pos)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────
--  HUNT LOOP
-- ─────────────────────────────────────────────────────────────────────────
local function hunt()
    if hunting then return end
    hunting = true
    state = "HUNTING"
    notify("HUNT", ("Watching this server %ds for a target boss"):format(Config.ScanSecondsPerServer))
    local waited = 0
    while waited < Config.ScanSecondsPerServer and state == "HUNTING" and not dead do
        task.wait(1); waited += 1
        if next(active) ~= nil then break end
    end
    hunting = false
    if dead or state ~= "HUNTING" then return end
    hopToNext()
end

local function ensureHunting()
    if Config.Enabled and state == "HUNTING" and not hunting then
        task.spawn(hunt)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
--  SHUTDOWN (re-exec replaces previous instance cleanly)
-- ─────────────────────────────────────────────────────────────────────────
if getgenv().AFS_BOSS_SHUTDOWN then pcall(getgenv().AFS_BOSS_SHUTDOWN) end
getgenv().AFS_BOSS_SHUTDOWN = function()
    dead = true
    for m in pairs(active) do active[m] = nil; removeESP(m) end
    if UI and UI.window then pcall(function() UI.window:Destroy() end) end
    UI = nil
    print("[BAF] previous instance shut down")
end

-- ─────────────────────────────────────────────────────────────────────────
--  UI  (compact neon, no external deps)
-- ─────────────────────────────────────────────────────────────────────────
local function buildUI()
    local sg = Instance.new("ScreenGui")
    sg.Name = "BAF_UI"; sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; sg.Parent = CoreGui

    local circle = Instance.new("TextButton")
    circle.Size = UDim2.new(0, 46, 0, 46); circle.Position = UDim2.new(0, 15, 0.5, -23)
    circle.BackgroundColor3 = Color3.fromRGB(10, 10, 10); circle.BorderSizePixel = 0
    circle.Text = "🎯"; circle.TextSize = 22; circle.Font = Enum.Font.GothamBold
    circle.TextColor3 = Color3.fromRGB(255, 0, 255); circle.Parent = sg
    local cs = Instance.new("UIStroke"); cs.Color = Color3.fromRGB(255, 0, 255); cs.Thickness = 3; cs.Parent = circle
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(1, 0); cc.Parent = circle

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 300, 0, 500); frame.Position = UDim2.new(0.5, -150, 0.5, -250)
    frame.BackgroundColor3 = Color3.fromRGB(5, 5, 5); frame.BorderSizePixel = 0
    frame.Visible = false; frame.Parent = sg
    local fs = Instance.new("UIStroke"); fs.Color = Color3.fromRGB(255, 0, 255); fs.Thickness = 3; fs.Parent = frame
    local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(0, 12); fc.Parent = frame

    local header = Instance.new("TextLabel")
    header.Size = UDim2.new(1, 0, 0, 30); header.BackgroundTransparency = 1
    header.Text = "AFS BOSS AUTOJOIN + FARM"; header.TextColor3 = Color3.fromRGB(255, 0, 255)
    header.TextSize = 13; header.Font = Enum.Font.GothamBold; header.TextXAlignment = Enum.TextXAlignment.Center
    header.Parent = frame

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -16, 0, 20); status.Position = UDim2.new(0, 8, 0, 34)
    status.BackgroundTransparency = 1; status.Text = "Status: IDLE"
    status.TextColor3 = Color3.fromRGB(220, 220, 220); status.TextSize = 12
    status.Font = Enum.Font.Gotham; status.TextXAlignment = Enum.TextXAlignment.Left; status.Parent = frame

    local y = 60
    local listFrame = nil

    local function button(text, pos, color, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -16, 0, 26); b.Position = pos
        b.BackgroundColor3 = color; b.Text = text; b.TextColor3 = Color3.fromRGB(255, 255, 255)
        b.TextSize = 11; b.Font = Enum.Font.GothamBold; b.BorderSizePixel = 0; b.Parent = frame
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = b
        if cb then b.MouseButton1Click:Connect(cb) end
        return b
    end

    -- refresh the server list (declared before use by the Scan button)
    local function updateServerList()
        if not listFrame then return end
        for _, c in ipairs(listFrame:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
        local servers = fetchRealServers()
        if #servers == 0 then
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, -8, 0, 30); lbl.BackgroundTransparency = 1
            lbl.Text = enumBlocked and "Enumeration blocked — use JobId box" or "No servers found"
            lbl.TextColor3 = Color3.fromRGB(200, 120, 120); lbl.TextSize = 11; lbl.Font = Enum.Font.Gotham
            lbl.TextWrapped = true; lbl.Parent = listFrame
            return
        end
        for i, s in ipairs(servers) do
            local card = Instance.new("Frame")
            card.Size = UDim2.new(1, -8, 0, 34); card.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
            card.BorderSizePixel = 0; card.Parent = listFrame
            local cc2 = Instance.new("UICorner"); cc2.CornerRadius = UDim.new(0, 6); cc2.Parent = card
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, -60, 1, 0); lbl.Position = UDim2.new(0, 6, 0, 0)
            lbl.BackgroundTransparency = 1; lbl.Text = ("#%d  %d/%d"):format(i, s.players, s.maxPlayers)
            lbl.TextColor3 = Color3.fromRGB(210, 210, 210); lbl.TextSize = 11; lbl.Font = Enum.Font.Gotham
            lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = card
            local jb = Instance.new("TextButton")
            jb.Size = UDim2.new(0, 50, 0, 24); jb.Position = UDim2.new(1, -54, 0, 5)
            jb.BackgroundColor3 = Color3.fromRGB(138, 43, 226); jb.Text = "Join"; jb.TextColor3 = Color3.fromRGB(255, 255, 255)
            jb.TextSize = 11; jb.Font = Enum.Font.GothamBold; jb.BorderSizePixel = 0; jb.Parent = card
            local jbc = Instance.new("UICorner"); jbc.CornerRadius = UDim.new(0, 6); jbc.Parent = jb
            jb.MouseButton1Click:Connect(function() joinServer(s.jobId, s.placeId) end)
        end
        listFrame.CanvasSize = UDim2.new(0, 0, 0, #servers * 40)
    end

    local enableBtn = button("🟢 Auto-Join: ON", UDim2.new(0, 8, 0, y), Color3.fromRGB(50, 205, 50))
    enableBtn.MouseButton1Click:Connect(function()
        Config.Enabled = not Config.Enabled
        enableBtn.Text = Config.Enabled and "🟢 Auto-Join: ON" or "🔴 Auto-Join: OFF"
        enableBtn.BackgroundColor3 = Config.Enabled and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(220, 50, 50)
        status.Text = "Status: " .. (Config.Enabled and "HUNTING" or "IDLE")
        if Config.Enabled then ensureHunting() end
    end)
    y = y + 30

    local farmBtn = button("🟢 Farm: ON", UDim2.new(0, 8, 0, y), Color3.fromRGB(50, 205, 50))
    farmBtn.MouseButton1Click:Connect(function()
        Config.FarmEnabled = not Config.FarmEnabled
        farmBtn.Text = Config.FarmEnabled and "🟢 Farm: ON" or "🔴 Farm: OFF"
        farmBtn.BackgroundColor3 = Config.FarmEnabled and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(220, 50, 50)
    end)
    y = y + 34

    local title2 = Instance.new("TextLabel")
    title2.Size = UDim2.new(1, -16, 0, 16); title2.Position = UDim2.new(0, 8, 0, y)
    title2.BackgroundTransparency = 1; title2.Text = "Targets"
    title2.TextColor3 = Color3.fromRGB(138, 43, 226); title2.TextSize = 12
    title2.Font = Enum.Font.GothamBold; title2.TextXAlignment = Enum.TextXAlignment.Left; title2.Parent = frame
    y = y + 18

    for key, t in pairs(BOSS_TARGETS) do
        local b = button((t.enabled and "✅ " or "❌ ") .. key .. (t.dim2Only and " (Dim2)" or ""),
            UDim2.new(0, 8, 0, y),
            t.enabled and Color3.fromRGB(40, 40, 45) or Color3.fromRGB(60, 30, 30))
        b.MouseButton1Click:Connect(function()
            t.enabled = not t.enabled
            b.Text = (t.enabled and "✅ " or "❌ ") .. key .. (t.dim2Only and " (Dim2)" or "")
        end)
        y = y + 24
    end
    y = y + 4

    local notiLabel = Instance.new("TextLabel")
    notiLabel.Size = UDim2.new(1, -16, 0, 14); notiLabel.Position = UDim2.new(0, 8, 0, y)
    notiLabel.BackgroundTransparency = 1; notiLabel.Text = "Notifier URL (/data):"
    notiLabel.TextColor3 = Color3.fromRGB(180, 180, 180); notiLabel.TextSize = 10
    notiLabel.Font = Enum.Font.Gotham; notiLabel.TextXAlignment = Enum.TextXAlignment.Left; notiLabel.Parent = frame
    y = y + 16
    local notiBox = Instance.new("TextBox")
    notiBox.Size = UDim2.new(1, -16, 0, 24); notiBox.Position = UDim2.new(0, 8, 0, y)
    notiBox.BackgroundColor3 = Color3.fromRGB(40, 40, 45); notiBox.Text = Config.Notifier.Url
    notiBox.TextColor3 = Color3.fromRGB(255, 255, 255); notiBox.TextSize = 10; notiBox.Font = Enum.Font.Gotham
    notiBox.PlaceholderText = "https://your-host.onrender.com/data"; notiBox.ClearTextOnFocus = false
    notiBox.BorderSizePixel = 0; notiBox.Parent = frame
    local nbc = Instance.new("UICorner"); nbc.CornerRadius = UDim.new(0, 6); nbc.Parent = notiBox
    y = y + 28
    button("💾 Save Notifier URL", UDim2.new(0, 8, 0, y), Color3.fromRGB(138, 43, 226), function()
        Config.Notifier.Url = notiBox.Text
        notify("NOTIFIER", "URL saved: " .. (notiBox.Text ~= "" and notiBox.Text or "(empty)"))
    end)
    y = y + 32

    button("🔄 Scan Servers", UDim2.new(0, 8, 0, y), Color3.fromRGB(30, 90, 200), updateServerList)
    y = y + 30
    button("🦘 Hop Now", UDim2.new(0, 8, 0, y), Color3.fromRGB(200, 100, 0), function()
        if Config.Enabled then hopToNext() else notify("HOP", "Enable Auto-Join first") end
    end)
    y = y + 30

    -- manual hop by JobId (the reliable method when the games API blocks enumeration)
    local jobBox = Instance.new("TextBox")
    jobBox.Size = UDim2.new(1, -66, 0, 26); jobBox.Position = UDim2.new(0, 8, 0, y)
    jobBox.BackgroundColor3 = Color3.fromRGB(40, 40, 45); jobBox.Text = ""
    jobBox.TextColor3 = Color3.fromRGB(255, 255, 255); jobBox.TextSize = 10; jobBox.Font = Enum.Font.Gotham
    jobBox.PlaceholderText = "paste server JobId"; jobBox.ClearTextOnFocus = false
    jobBox.BorderSizePixel = 0; jobBox.Parent = frame
    local jbc = Instance.new("UICorner"); jbc.CornerRadius = UDim.new(0, 6); jbc.Parent = jobBox
    local jobBtn = Instance.new("TextButton")
    jobBtn.Size = UDim2.new(0, 50, 0, 26); jobBtn.Position = UDim2.new(1, -58, 0, y)
    jobBtn.BackgroundColor3 = Color3.fromRGB(138, 43, 226); jobBtn.Text = "Join"
    jobBtn.TextColor3 = Color3.fromRGB(255, 255, 255); jobBtn.TextSize = 11; jobBtn.Font = Enum.Font.GothamBold
    jobBtn.BorderSizePixel = 0; jobBtn.Parent = frame
    local jobbc = Instance.new("UICorner"); jobbc.CornerRadius = UDim.new(0, 6); jobbc.Parent = jobBtn
    jobBtn.MouseButton1Click:Connect(function()
        local j = jobBox.Text:match("%S+")
        if j then joinServer(j, Config.PlaceId) else notify("JOIN", "enter a JobId first") end
    end)
    y = y + 34

    listFrame = Instance.new("ScrollingFrame")
    listFrame.Name = "ServerList"; listFrame.Size = UDim2.new(1, -16, 0, 70)
    listFrame.Position = UDim2.new(0, 8, 0, y); listFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    listFrame.BorderSizePixel = 0; listFrame.ScrollBarThickness = 6; listFrame.Parent = frame
    local lc = Instance.new("UICorner"); lc.CornerRadius = UDim.new(0, 6); lc.Parent = listFrame
    local ll = Instance.new("UIListLayout"); ll.Padding = UDim.new(0, 4); ll.Parent = listFrame

    circle.MouseButton1Click:Connect(function()
        frame.Visible = not frame.Visible
    end)

    UI = { window = sg, status = status }
end

-- ─────────────────────────────────────────────────────────────────────────
--  MAIN LOOPS
-- ─────────────────────────────────────────────────────────────────────────
local function startLoops()
    startAimbot()
    task.spawn(function()
        while not dead do
            if Config.FarmEnabled and next(active) ~= nil then
                state = "FARMING"
                pcall(farmTick)
            else
                aimTarget = nil
                state = (Config.Enabled and "HUNTING") or "IDLE"
                ensureHunting()
            end
            task.wait(Config.AttackInterval + math.random() * 0.3)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────
--  BOOT
-- ─────────────────────────────────────────────────────────────────────────
if BOOTSTRAP_SOURCE then getgenv().AFS_BOSS_SRC = BOOTSTRAP_SOURCE end

buildUI()
for _, model in ipairs(CollectionService:GetTagged("isBoss")) do
    task.spawn(onBossAdded, model)
end
CollectionService:GetInstanceAddedSignal("isBoss"):Connect(onBossAdded)
CollectionService:GetInstanceRemovedSignal("isBoss"):Connect(onBossRemoved)
startLoops()

print(("[BAF] v1.1.0 loaded · place %d (%s) · job %s"):format(
    PLACE_ID, currentDimension(), game.JobId))
notify("READY", ("Dim: %s · autoJoin=%s · farm=%s"):format(
    currentDimension(), tostring(Config.Enabled), tostring(Config.FarmEnabled)))

if next(active) ~= nil then
    state = "FARMING"
elseif Config.Enabled then
    task.spawn(hunt)
end
