-- Version 1.00
-- ============================================================
-- Tower (ไต่หอ) — โหลดหลัง AutoFarm
-- ============================================================
-- อ่านโค้ดจาก Dump/New แล้ว สรุปกลไกที่โมดูลนี้ใช้:
--
--   DungeonManager.client.lua
--     ทางเข้าหอมี 2 ทาง
--       (1) DungeonGUI กดปุ่ม -> DungeonData.TryIntoDungeon(floor)
--           -> server ตอบ true -> u0.StartDungeon()
--       (2) attribute IntoFight ถูกเซ็ตเป็น "Dungeon" (server เซ็ต แล้ว replicate ลงมา)
--           -> StartDungeon()
--     StartDungeon(round):
--       SetAttribute("StageID", -1)                 <-- บอกว่าเป็นดันเจี้ยน (สำคัญมาก)
--       TranslateUtils.TranslateStartVFX / ToDungeon / DungeonFightGUI.Open
--       u144.IsReady = true ; u144.Fighting = true
--       TranslateUtils.TranslateEndVFX ; task.wait(1) -> StartRound(round)
--     StartRound(round):
--       DungeonData.StartRound(round) -> StartRoundRE:FireServer(round)
--       CreateRoundEnemys(round)      -> EnemyCTRL.CreateOneEnemy(StageID = -1, Round = round)
--     FinishRound():   (เรียกจาก HurtEnemy -> CheckFinishedOnce เมื่อมอนตายครบ)
--       DungeonData.CompleteRound(round) -> CompleteRoundRF:InvokeServer(round)   = รับของ
--       RewardUtils.CreateOres(...)      -> OreDropUtils.CreateOneDrop{StageID = -1}
--       task.delay(3, StartRound(round + 1) หรือ ExitDungeon())
--     ExitDungeon():
--       DungeonFightGUI.ShowDungeonResult / DungeonData.ExitDungeon() / Close / ToSpawn
--     RegistPreRender(nil, 1, ...)  : ตัวจับเวลา 80 วิ — PassTime เกิน 80 -> ExitDungeon()
--     RegistPreRender(nil, nil, ...): ถ้า IntoFight == "Dungeon" -> วาร์ปผู้เล่นคนอื่นไป DungeonBin
--
-- *** ทำไม "ไม่เสียตั๋วซ้ำ" ได้ ***
--   ตัวจับเวลา 80 วิ และการวาร์ปเพื่อน ทำงานเมื่อ LocalPlayer:GetAttribute("IntoFight")
--   == "Dungeon" เท่านั้น -> ถ้าเราบังคับ attribute นี้ให้กลับเป็น nil ทันทีที่เห็นเป็น "Dungeon"
--   ตัวจับเวลาจะไม่เดิน และหอจะไม่ถูกเตะออก
--   แต่ฝั่ง client ยังถือว่า u144.Fighting = true -> FinishRound -> StartRound(round + 1)
--   ยังทำงานได้ครบ -> ได้รางวัลทุกชั้น และตัวหอ "อยู่ทั้ง session" ไม่ต้อง TryIntoDungeonRF ซ้ำ
--   => จ่ายตั๋วแค่ครั้งแรกครั้งเดียว พอเปิด toggle อีกครั้งใน session เดิมก็ยังไต่ต่อได้เลย
--
-- *** เก็บของที่ดรอป ***
--   ดันเจี้ยนสร้างของผ่าน RewardUtils.CreateOres -> OreDropUtils.CreateOneDrop{StageID = -1}
--   ของจะไปอยู่ workspace.OreCache พร้อม task.delay(1.2, FlyToPlayer) อัตโนมัติ
--   แต่ FlyToPlayer ไม่กรอง StageID เลย (index ที่เก็บคือ UUID) -> เรียกเองได้
--   และ LeftInfoGUI.UpdateOrePack ฝั่ง client คือค่าที่ AutoFarm/CleanOres ใช้ตัดสินใจ
--   -> เราจึง FlyToPlayer จริง + อัปเดต OrePack + ยิง PickupOreBE / Stage/GetOreRF ให้ครบ
--      เหมือนที่ OreUtils ทำตอนกด ProximityPrompt เก็บของ (กันของหายไปเฉย ๆ)
--
-- *** ความปลอดภัย ***
--   ไม่แตะ remote ต้องห้ามเลย (ไม่มี Dev/*, Profile/UpdateDataRE, Stage/LostAllOreRF)
--   remote ที่ยิงมีแค่ Dungeon/TryIntoDungeonRF : InvokeServer(ตั๋วครั้งแรกครั้งเดียว)
--   ส่วนที่เหลือเป็น BindableEvent ฝั่ง client ล้วน ๆ (Attack/EnemyHitBE, Stage/PickupOreBE)
--   และ Stage/GetOreRF (ดึง OrePack ตาม UUID ที่เราขอเก็บ) ซึ่งเป็นตัวเดียวกับเกมใช้จริง
--
-- *** ห้ามรันพร้อม AutoFarm ***
--   ทั้งคู่แย่ง EnemyHitBE, PlayerGui.Main.*, workspace.OreCache และ StageID/Dungeon
--   -> ในฟังก์ชันเปิดหอ จะหยุดโมดูลฟาร์มให้ก่อน (context.stopFarm) แล้วค่อยเริ่มไต่หอ
-- ============================================================

local Tower = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local ENEMY_FOLDER_NAME = "EnemyFolder"

-- ============================================================
-- helper: ดึง remote/bindable โดยไม่ require CommunicationUtils
-- ============================================================
local ROOT = ReplicatedStorage:FindFirstChild("Remote")
if not ROOT then
    ROOT = Instance.new("Folder")
    ROOT.Name = "Remote"
    ROOT.Parent = ReplicatedStorage
end

local function getFolder(name)
    local f = ROOT:FindFirstChild(name)
    if not f then
        f = Instance.new("Folder")
        f.Name = name
        f.Parent = ROOT
    end
    return f
end

local function getRemote(folderName, remoteName, className)
    local folder = getFolder(folderName)
    local inst = folder:FindFirstChild(remoteName)
    if not inst then
        inst = Instance.new(className)
        inst.Name = remoteName
        inst.Parent = folder
    end
    return inst
end

local function getBindable(folderName, eventName)
    return getRemote(folderName, eventName, "BindableEvent")
end

local EnemyHitBE = getBindable("Attack", "EnemyHitBE")
local PickupOreBE = getBindable("Stage", "PickupOreBE")
local TryIntoDungeonRF = getRemote("Dungeon", "TryIntoDungeonRF", "RemoteFunction")
local StartRoundRE = getRemote("Dungeon", "StartRoundRE", "RemoteEvent")
local GetOreRF = getRemote("Stage", "GetOreRF", "RemoteFunction")

local EnemyFolder = workspace:FindFirstChild(ENEMY_FOLDER_NAME)
if not EnemyFolder then
    EnemyFolder = workspace:WaitForChild(ENEMY_FOLDER_NAME, 30)
end

-- ============================================================
-- config
-- ============================================================
local MAX_FLOOR = 50 -- เผื่ออ่าน Config ไม่ได้
local DEFAULT_FLOOR = 50
local KILL_GAP = 0.12 -- เว้นจังหวะสแกน/ยิงมอน
local WAIT_ENTER = 12 -- รอให้เข้าชั้นก่อน (วินาที)
local WAIT_READY = 30 -- รอให้ "หอถูกถือไว้ + ชั้นตรง" ก่อนล่ามอน (วินาที)
local WAIT_ROUND = 90 -- ล่ามอนชั้นหนึ่งได้นานสุด (วินาที)
local WAIT_EMPTY = 6 -- ไม่เจอมอนเลยนานเท่านี้ = ชั้นนี้จบ (วินาที)

-- ============================================================
-- state
-- ============================================================
local recordOn = false -- toggle "ไต่หอ วนชั้นที่เลือก"
local allOn = false -- toggle "ไต่ทีเดียวทั้งหมด 1 → MAX_FLOOR"
local running = false -- มี toggle ใดเปิดอยู่ -> หอถูกถือไว้
local allLoopToken = 0 -- token ของ allLoop (แยกจาก token หลัก เพื่อรีสตาร์ตได้โดยไม่ทับกัน)
local recordLoopToken = 0 -- token ของ recordLoop
local floor = DEFAULT_FLOOR -- ชั้นเป้าหมายของโหมดเลือกชั้น
local currentTarget = 0 -- ชั้นที่กำลังทำอยู่
local pending = {} -- [enemyName] = true (ยิงไปแล้ว รอผล)

local killedTotal = 0
local roundDone = 0
local lastErr = nil

-- ============================================================
-- อ่าน config หอ (จำนวนชั้นจริง)
-- ============================================================
do
    local ok, cfg = pcall(function()
        return require(ReplicatedStorage.Config.Dungeon.Config.Config)
    end)
    if ok and type(cfg) == "table" then
        local n = 0
        for _ in pairs(cfg) do
            n = n + 1
        end
        if n > 0 then
            MAX_FLOOR = n
            DEFAULT_FLOOR = n
        end
    end
end

-- ============================================================
-- สถานะที่โชว์ใน UI
-- ============================================================
local statLabel
local miniLabel

local function fmt(n)
    if type(n) ~= "number" then
        return tostring(n)
    end
    if n ~= n then
        return "0"
    end
    if n >= 1e9 then
        return ("%.2fB"):format(n / 1e9)
    end
    if n >= 1e6 then
        return ("%.2fM"):format(n / 1e6)
    end
    if n >= 1e3 then
        return ("%.1fK"):format(n / 1e3)
    end
    return tostring(math.floor(n))
end

local function currentRound()
    local r = player:GetAttribute("CurrentRound")
    if type(r) == "number" then
        return r
    end
    return 0
end

local function modeText()
    if allOn and recordOn then
        return "ไต่ทั้งหมด + วนชั้น"
    end
    if allOn then
        return "ไต่ทั้งหมด"
    end
    if recordOn then
        return "วนชั้น " .. floor
    end
    return "ปิด"
end

local function refreshStat()
    if statLabel and not statLabel.__destroyed then
        local state = "ปิดอยู่"
        if running then
            state = ("%s → ชั้น %d"):format(modeText(), currentTarget)
        elseif lastErr then
            state = "หยุด: " .. lastErr
        end
        pcall(function()
            statLabel:Set(("หอ: ชั้น %d · ผ่าน %d ชั้น · ฆ่า %s · %s"):format(
                currentRound(), roundDone, fmt(killedTotal), state))
        end)
    end
    if miniLabel and not miniLabel.__destroyed then
        pcall(function()
            miniLabel:Set(("หอถูกถือไว้: %s · ชั้นปัจจุบัน %d"):format(
                running and "อยู่" or "ปิด", currentRound()))
        end)
    end
end

-- ============================================================
-- patch VFX / GUI ให้ "เงียบ" (ไม่วาร์ป ไม่เด้ง GUI)
-- ============================================================
-- TranslateStartVFX / TranslateEndVFX ของเดิม:
--   HumanoidRootPart.Anchored = true แล้ว task.wait(...) -> ตัวค้างกลางอากาศ + เล่น VFX
--   (จริง ๆ ไม่มีการวาร์ปตำแหน่งเลย มีแค่อนิเมชันกับ VFX)
-- DungeonFightGUI.Open ของเดิม:
--   ซ่อน Hud.Left/LeftInfos/RightTop/Right/Race
--   -> AutoFarm ใช้ Hud.LeftInfos.OrePack อยู่ ต้องไม่ให้ถูกซ่อน
-- แก้ที่ "ตัวโมดูลที่ instance ซ้ำกัน" (โมดูลถูก cache -> ของเกมก็เห็นค่าเดียวกัน)
-- ============================================================
local translateSaved = nil
local guiSaved = nil

local function patchTranslate()
    if translateSaved then
        return true
    end
    local ok, mod = pcall(function()
        return require(ReplicatedStorage.Utils.TranslateUtils)
    end)
    if not ok or type(mod) ~= "table" then
        return false
    end
    translateSaved = {
        mod = mod,
        TranslateStartVFX = mod.TranslateStartVFX,
        TranslateEndVFX = mod.TranslateEndVFX,
    }
    local function noop()
        return true
    end
    mod.TranslateStartVFX = noop
    mod.TranslateEndVFX = noop
    return true
end

local function restoreTranslate()
    if not translateSaved then
        return
    end
    local mod = translateSaved.mod
    pcall(function()
        mod.TranslateStartVFX = translateSaved.TranslateStartVFX
    end)
    pcall(function()
        mod.TranslateEndVFX = translateSaved.TranslateEndVFX
    end)
    translateSaved = nil
end

local function patchFightGUI()
    if guiSaved then
        return true
    end
    local ok, mod = pcall(function()
        return require(ReplicatedStorage.GuiUtils.DungeonFightGUI)
    end)
    if not ok or type(mod) ~= "table" then
        return false
    end
    guiSaved = {
        mod = mod,
        Open = mod.Open,
        OpenDungeonUI = mod.OpenDungeonUI,
        Close = mod.Close,
        CloseDungeonUI = mod.CloseDungeonUI,
        ShowDungeonResult = mod.ShowDungeonResult,
    }
    -- ห้ามซ่อน Hud (AutoFarm ใช้ LeftInfos อยู่) และห้ามเด้ง UI ดันเจี้ยน
    mod.Open = function() end
    mod.OpenDungeonUI = function() end
    mod.CloseDungeonUI = function() end
    mod.ShowDungeonResult = function() end
    return true
end

local function restoreFightGUI()
    if not guiSaved then
        return
    end
    local mod = guiSaved.mod
    for _, key in ipairs({ "Open", "OpenDungeonUI", "Close", "CloseDungeonUI", "ShowDungeonResult" }) do
        local fn = guiSaved[key]
        pcall(function()
            mod[key] = fn
        end)
    end
    guiSaved = nil
end

-- ============================================================
-- "ถือหอ" — บังคับ IntoFight ให้กลับเป็น nil ทันทีที่เห็นค่าเป็น "Dungeon"
--   ใช้ task.defer เพื่อให้ DungeonManager ตัวจริง (attribute changed -> StartDungeon) ทำงานก่อน 1 รอบ
-- ============================================================
local savedIntoFight = nil
local holdConn = nil

local function holdOnce()
    pcall(function()
        if player:GetAttribute("IntoFight") == "Dungeon" then
            savedIntoFight = savedIntoFight or "Dungeon"
            player:SetAttribute("IntoFight", nil)
        end
    end)
end

local function startHolder()
    if holdConn then
        return
    end
    holdConn = (player:GetAttributeChangedSignal("IntoFight")):Connect(function()
        task.defer(holdOnce)
        refreshStat()
    end)
end

local function stopHolder()
    if holdConn then
        holdConn:Disconnect()
        holdConn = nil
    end
end

-- ============================================================
-- เริ่มชั้น (ทางเดียวที่ต้องแตะ remote Dungeon)
-- ============================================================
-- DungeonManager.StartRound() มี guard `IntoFight ~= "Dungeon" -> return`
-- จึงต้องปล่อยให้เห็นเป็น "Dungeon" 1 จังหวะ แล้วคืน nil ทันที
local function fireStartRound(round)
    pcall(function()
        if player:GetAttribute("IntoFight") ~= "Dungeon" then
            player:SetAttribute("IntoFight", "Dungeon")
        end
    end)
    task.wait()
    pcall(function()
        StartRoundRE:FireServer(round)
    end)
    holdOnce()
end

-- ============================================================
-- ฆ่ามอนชั้นปัจจุบัน
-- ============================================================
local function hurtEnemy(model)
    local name = model.Name
    if pending[name] then
        return
    end
    local hp = model:FindFirstChild("HPValue")
    local dmg = 1
    if hp and hp:IsA("NumberValue") then
        local maxHP = hp:GetAttribute("MaxHP") or hp.Value
        if type(maxHP) ~= "number" or maxHP ~= maxHP or maxHP == math.huge then
            lastErr = "MaxHP แปลก: " .. tostring(maxHP)
            return
        end
        if maxHP < 1 then
            maxHP = 1
        end
        -- DamageOnce = current - dmg -> ตายเมื่อ <= 0
        -- ใช้ MaxHP + 1 ให้ตายชัวร์แม้ HP จะเป็น 1e18
        dmg = math.min(maxHP + 1, 1e15)
    end
    pending[name] = true
    pcall(function()
        EnemyHitBE:Fire(name, dmg, { SkillID = "K_ATK_1", IsCrit = false, Damage = dmg })
    end)
end

local function isDungeonEnemy(model)
    if not model:IsA("Model") then
        return false
    end
    if model:GetAttribute("Dead") then
        return false
    end
    if pending[model.Name] then
        return false
    end
    -- มอนที่หมดเลือดแล้วรอ DestroyEnemyData (task.delay 3) -> ข้าม
    local hp = model:FindFirstChild("HPValue")
    if not hp or not hp:IsA("NumberValue") or hp.Value <= 0 then
        return false
    end
    -- มอนหอ: StageID = -1
    local stage = hp:GetAttribute("StageID")
    if stage ~= nil then
        return stage == -1
    end
    return model:GetAttribute("StageID") == -1
end

local function sweep()
    local n = 0
    for _, model in ipairs(EnemyFolder:GetChildren()) do
        if isDungeonEnemy(model) then
            hurtEnemy(model)
            n = n + 1
        end
    end
    return n
end

-- ============================================================
-- เก็บของที่ดรอปใน workspace.OreCache
-- ============================================================
local oreUtils = nil
local oreCache = nil
local oreConn = nil
local oreHandled = {}

local function getOreUtils()
    if oreUtils then
        return oreUtils
    end
    local ok, mod = pcall(function()
        return require(ReplicatedStorage.Utils.OreDropUtils)
    end)
    if ok and type(mod) == "table" then
        oreUtils = mod
    end
    return oreUtils
end

local function getPackNow()
    local ok, text = pcall(function()
        return player.PlayerGui.Hud.LeftInfos.OrePack.Title.Text
    end)
    if ok and type(text) == "string" then
        return tonumber(text) or 0
    end
    return nil
end

local function bumpPack(before)
    -- LeftInfoGUI.UpdateOrePack คือค่าที่ AutoFarm/CleanOres อ่านอยู่
    local ok = pcall(function()
        require(ReplicatedStorage.GuiUtils.LeftInfoGUI).UpdateOrePack(before + 1)
    end)
    if not ok then
        pcall(function()
            player.PlayerGui.Hud.LeftInfos.OrePack.Title.Text = tostring(before + 1)
        end)
    end
end

local function onOreAdded(drop)
    if type(drop) ~= "userdata" or not drop:IsA("Model") then
        return
    end
    local uuid = drop.Name
    if oreHandled[uuid] then
        return
    end
    oreHandled[uuid] = true
    local utils = getOreUtils()
    if not utils then
        return
    end
    -- ทำตามแบบ OreUtils (ตอนกด ProximityPrompt เก็บของ) ให้ครบทุกขั้น
    local before = getPackNow()
    pcall(function()
        utils.FlyToPlayer(uuid)
    end)
    if before ~= nil then
        bumpPack(before)
    end
    pcall(function()
        PickupOreBE:Fire()
    end)
    pcall(function()
        GetOreRF:InvokeServer(uuid)
    end)
end

local function startOreWatch()
    if oreConn then
        return
    end
    getOreUtils()
    if not oreCache then
        oreCache = workspace:FindFirstChild("OreCache")
    end
    if not oreCache then
        return
    end
    for _, drop in ipairs(oreCache:GetChildren()) do
        onOreAdded(drop)
    end
    oreConn = oreCache.ChildAdded:Connect(function(drop)
        task.defer(onOreAdded, drop)
    end)
end

local function stopOreWatch()
    if oreConn then
        oreConn:Disconnect()
        oreConn = nil
    end
end

-- ============================================================
-- loop หลัก
-- ============================================================
-- recordOn = true -> ล่ามอนที่ชั้น `floor` แล้ววนซ้ำไม่จำกัด
-- allOn    = true -> ไล่ชั้น 1 -> MAX_FLOOR ตามลำดับ (FinishRound ของเกมเป็นคนเลื่อนชั้นให้)
-- เปิดทั้งคู่ -> allLoop เป็นคนคุม (ไล่ไปจนสุดหอ แล้ววนชั้นบนสุดต่อ)
-- แต่ละ loop มี token ของตัวเอง เพื่อให้สั่งรีสตาร์ตได้โดยไม่ต้องแตะโหมดอื่น
-- ============================================================
local function alive(myToken, isRecord)
    if not running or not player.Character then
        return false
    end
    if isRecord then
        return recordOn and recordLoopToken == myToken
    end
    return allOn and allLoopToken == myToken
end

local function waitForNotRound(round, myToken, isRecord)
    local waited = 0
    while alive(myToken, isRecord) and currentRound() == round and waited < 5 do
        task.wait(0.2)
        waited = waited + 0.2
    end
end

local function enterTarget(target, myToken, isRecord)
    -- ขอ StartRound ให้ DungeonManager สร้างมอนของชั้นนี้
    local waited = 0
    while alive(myToken, isRecord) and currentRound() < target and waited < WAIT_ENTER do
        fireStartRound(target)
        task.wait(0.5)
        waited = waited + 0.5
    end
    -- รอให้หอถูกถือกลับเป็น nil (holdOnce ทำงาน) และชั้นตรงเป้า
    waited = 0
    while alive(myToken, isRecord) and waited < WAIT_READY do
        if currentRound() >= target and player:GetAttribute("IntoFight") ~= "Dungeon" then
            break
        end
        task.wait(0.2)
        waited = waited + 0.2
    end
end

local function recordLoop(myToken)
    -- โหมดวนชั้นที่เลือก: เป้าคือ `floor` เสมอ
    while alive(myToken, true) do
        -- ถ้าโหมดไต่ทั้งหมดเปิดอยู่ ให้ allLoop เป็นคนคุมแทน
        if allOn then
            task.wait(0.3)
        else
            local target = math.clamp(floor, 1, MAX_FLOOR)
            currentTarget = target
            refreshStat()
            if currentRound() < target then
                enterTarget(target, myToken, true)
            end
            if not alive(myToken, true) then
                break
            end
            if currentRound() < target then
                lastErr = ("เข้าชั้น %d ไม่ได้ (CurrentRound = %d)"):format(target, currentRound())
                task.wait(1)
            else
                -- ล่ามอนชั้นนี้ให้จบ แล้ววนกลับมาใหม่
                local elapsed = 0
                while alive(myToken, true) and not allOn and elapsed < WAIT_ROUND do
                    local n = sweep()
                    if n > 0 then
                        killedTotal = killedTotal + n
                    end
                    task.wait(KILL_GAP)
                    elapsed = elapsed + KILL_GAP
                    if currentRound() > target then
                        roundDone = roundDone + 1
                        break
                    end
                end
                waitForNotRound(target, myToken, true)
                pending = {}
                refreshStat()
            end
        end
    end
end

local function allLoop(myToken)
    -- โหมดไต่ทั้งหมด: ไล่ 1 -> MAX_FLOOR แล้ววนชั้นบนสุด
    local target = math.clamp(currentRound(), 1, MAX_FLOOR)
    while alive(myToken, false) do
        currentTarget = target
        refreshStat()
        if currentRound() < target then
            enterTarget(target, myToken, false)
        end
        if not alive(myToken, false) then
            break
        end
        if currentRound() < target then
            lastErr = ("เข้าชั้น %d ไม่ได้ (CurrentRound = %d)"):format(target, currentRound())
            task.wait(1)
        else
            local elapsed = 0
            local empty = 0
            while alive(myToken, false) and elapsed < WAIT_ROUND do
                local n = sweep()
                if n > 0 then
                    killedTotal = killedTotal + n
                    empty = 0
                else
                    empty = empty + KILL_GAP
                end
                task.wait(KILL_GAP)
                elapsed = elapsed + KILL_GAP
                local nr = currentRound()
                if nr > target then
                    roundDone = roundDone + 1
                    break
                end
                -- ไม่เจอมอนเลย -> ชั้นนี้อาจจบไปแล้ว (รอ DestroyEnemyData) -> เลื่อนชั้นถัดไป
                if empty > WAIT_EMPTY then
                    break
                end
            end
            local nr = currentRound()
            if nr > target then
                target = math.min(nr, MAX_FLOOR)
            elseif nr == target and empty > WAIT_EMPTY then
                if target >= MAX_FLOOR then
                    -- สุดหอแล้ว -> วนชั้นบนสุดไปเรื่อย ๆ
                    pending = {}
                    waitForNotRound(target, myToken, false)
                else
                    -- ค้างที่เดิม ไม่มีมอน -> ขอเริ่มชั้นถัดไป (server อนุญาตเฉพาะชั้นที่ปลดล็อก)
                    fireStartRound(math.min(target + 1, MAX_FLOOR))
                    task.wait(0.5)
                end
            end
            pending = {}
            refreshStat()
        end
    end
end

-- ============================================================
-- lifecycle
-- ============================================================
local function clearState()
    pending = {}
    oreHandled = {}
end

local function startModes()
    if running then
        return
    end
    running = true
    killedTotal = 0
    roundDone = 0
    lastErr = nil
    savedIntoFight = nil
    clearState()
    patchTranslate()
    patchFightGUI()
    startHolder()
    startOreWatch()
    refreshStat()
    if allOn then
        allLoopToken = allLoopToken + 1
        task.spawn(allLoop, allLoopToken)
    end
    if recordOn then
        recordLoopToken = recordLoopToken + 1
        task.spawn(recordLoop, recordLoopToken)
    end
end

local function stopModes()
    running = false
    allLoopToken = allLoopToken + 1
    recordLoopToken = recordLoopToken + 1
    stopHolder()
    stopOreWatch()
    clearState()
    -- คืน IntoFight ที่บันทึกไว้ ให้ session กลับสู่สภาพปกติของเกม
    if savedIntoFight ~= nil then
        pcall(function()
            player:SetAttribute("IntoFight", savedIntoFight)
        end)
    end
    savedIntoFight = nil
    refreshStat()
end

local function restartAllLoop()
    allLoopToken = allLoopToken + 1
    if allOn then
        task.spawn(allLoop, allLoopToken)
    end
end

local function restartRecordLoop()
    recordLoopToken = recordLoopToken + 1
    if recordOn then
        task.spawn(recordLoop, recordLoopToken)
    end
end

local function getFirstEnterableFloor()
    local cr = currentRound()
    if cr >= 1 then
        return math.clamp(cr, 1, MAX_FLOOR)
    end
    return 1
end

local function enterTower(target)
    -- คืน ok, err
    local ok, entered = pcall(function()
        return TryIntoDungeonRF:InvokeServer(target)
    end)
    if ok and entered then
        return true
    end
    return false, tostring(entered)
end

-- ============================================================
-- register
-- ============================================================
function Tower.register(context)
    local tab = context.Tab
    local WindUI = context.WindUI
    if not tab then
        return
    end

    local function notify(title, desc, dur)
        if not WindUI then
            return
        end
        pcall(function()
            WindUI:Notify({ Title = title, Content = desc, Duration = dur or 3 })
        end)
    end

    -- ปิดโมดูลฟาร์มก่อนเริ่มไต่หอ (กันแย่ง EnemyHitBE / OreCache / Hud)
    local function pauseFarm()
        if type(context.stopFarm) == "function" then
            pcall(context.stopFarm)
        end
    end

    local section = tab:Section({ Title = "ไต่หอ (Dungeon Tower)", Opened = true })
    if not section then
        return
    end

    miniLabel = section:Paragraph({
        Title = "หอถูกถือไว้",
        Desc = "เปิดโหมดใดโหมดหนึ่งเพื่อเริ่ม",
    })

    statLabel = section:Paragraph({
        Title = "สถานะ",
        Desc = "รอเริ่ม...",
        Buttons = { { Title = "รีเฟรช", Icon = "refresh-cw", Callback = refreshStat } },
    })

    -- ------------------------------------------------------------
    -- โหมด 1: ไต่หอแบบเลือกชั้น แล้ววนซ้ำไม่จำกัด
    -- ------------------------------------------------------------
    local floorSection = tab:Section({ Title = "ไต่หอ — เลือกชั้น (วนไม่จำกัด)", Opened = true })
    floorSection:Slider({
        Title = "ชั้นเป้าหมาย",
        Desc = "ชั้นที่จะขึ้นไปแล้วย้ำวนชั้นนี้ไปเรื่อย ๆ (1 - " .. MAX_FLOOR .. ")",
        Value = { Min = 1, Max = MAX_FLOOR, Default = DEFAULT_FLOOR },
        Step = 1,
        Callback = function(value)
            floor = math.clamp(math.floor(value), 1, MAX_FLOOR)
            refreshStat()
        end,
    })

    local floorToggle
    local allToggle
    local syncing = false

    -- ปิดโหมดไต่ทั้งหมด (ไม่แตะ toggle ของโหมดวนชั้น)
    local function disableAll()
        allOn = false
        allLoopToken = allLoopToken + 1
        if not recordOn then
            stopModes()
        else
            restartRecordLoop()
        end
        refreshStat()
    end

    -- ปิดโหมดวนชั้น (ไม่แตะ toggle ของโหมดไต่ทั้งหมด)
    local function disableRecord()
        recordOn = false
        recordLoopToken = recordLoopToken + 1
        if not allOn then
            stopModes()
        else
            restartAllLoop()
        end
        refreshStat()
    end

    floorToggle = floorSection:Toggle({
        Title = "เปิด: ไต่หอ วนชั้นที่เลือก",
        Desc = "ล่ามอนชั้นที่เลือกทับไปเรื่อย ๆ รับรางวัลไม่จำกัด · หอจะถูกถือไว้ทั้ง session (ไม่เสียตั๋วซ้ำ)",
        Value = false,
        Callback = function(value)
            if syncing then
                return
            end
            if value then
                pauseFarm()
                -- เข้าครั้งแรก = ใช้ตั๋ว 1 ใบ (ถ้ายังไม่อยู่ในหอ / ยังไม่ถึงชั้นนั้น)
                if currentRound() < floor then
                    local ok, err = enterTower(floor)
                    if not ok then
                        lastErr = ("เข้าชั้น %d ไม่สำเร็จ (%s)"):format(floor, err)
                        notify("เข้าไต่หอไม่สำเร็จ", "ตั๋วอาจไม่พอ หรือชั้น " .. floor .. " ยังไม่ถูกปลดล็อก", 5)
                        syncing = true
                        pcall(function()
                            floorToggle:Set(false)
                        end)
                        syncing = false
                        refreshStat()
                        return
                    end
                end
                recordOn = true
                if not running then
                    startModes()
                elseif not allOn then
                    restartRecordLoop()
                end
                notify("ไต่หอ: เปิด", ("วนชั้น %d ไปเรื่อย ๆ · หอถูกถือไว้ทั้ง session"):format(floor), 4)
            else
                disableRecord()
                notify("ไต่หอ: ปิด", "จบโหมดวนชั้น", 3)
            end
            refreshStat()
        end,
    })

    -- ------------------------------------------------------------
    -- โหมด 2: ไต่ทีเดียวทั้งหมด 1 -> MAX_FLOOR
    -- ------------------------------------------------------------
    local allSection = tab:Section({ Title = "ไต่ทีเดียวทั้งหมด (1 → " .. MAX_FLOOR .. ")", Opened = true })
    allToggle = allSection:Toggle({
        Title = "เปิด: ไล่รับรางวัลตั้งแต่ชั้น 1 ถึง " .. MAX_FLOOR,
        Desc = "ทยอยขึ้นทีละชั้นจนสุดหอ · จบแล้ววนชั้นบนสุดให้เอง · หอถูกถือไว้ทั้ง session",
        Value = false,
        Callback = function(value)
            if syncing then
                return
            end
            if value then
                pauseFarm()
                local first = getFirstEnterableFloor()
                if currentRound() < first then
                    local ok, err = enterTower(first)
                    if not ok then
                        lastErr = ("เข้าหอเพื่อไต่ทั้งหมดไม่สำเร็จ (%s)"):format(err)
                        notify("เข้าไต่หอไม่สำเร็จ", "ตั๋วอาจไม่พอ หรือยังไม่ปลดล็อกชั้นเป้าหมาย", 5)
                        syncing = true
                        pcall(function()
                            allToggle:Set(false)
                        end)
                        syncing = false
                        refreshStat()
                        return
                    end
                end
                allOn = true
                if not running then
                    startModes()
                else
                    restartAllLoop()
                end
                notify("ไต่ทีเดียวทั้งหมด: เปิด", ("ไล่ชั้น %d → %d แล้ววนชั้นบนสุด"):format(first, MAX_FLOOR), 4)
            else
                disableAll()
                notify("ไต่ทีเดียวทั้งหมด: ปิด", recordOn and "ยังวนชั้นที่เลือกต่อ" or "จบโหมดไต่ทั้งหมด", 3)
            end
            refreshStat()
        end,
    })

    -- ------------------------------------------------------------
    -- เครื่องมือ
    -- ------------------------------------------------------------
    local util = tab:Section({ Title = "เครื่องมือ", Opened = false })
    util:Button({
        Title = "ไปชั้นนี้เดี๋ยวนี้",
        Desc = "สั่งขึ้นชั้นเป้าหมายทันที (เสียตั๋วถ้ายังไม่อยู่ในหอ)",
        Callback = function()
            pauseFarm()
            if currentRound() < floor then
                local ok = enterTower(floor)
                if not ok then
                    notify("เข้าชั้น " .. floor .. " ไม่สำเร็จ", "ตั๋วอาจไม่พอ หรือยังไม่ปลดล็อกชั้นนี้", 5)
                    return
                end
            end
            recordOn = true
            if not running then
                startModes()
            else
                restartRecordLoop()
            end
            fireStartRound(math.clamp(floor, 1, MAX_FLOOR))
            notify("ขึ้นชั้น " .. floor, "กำลังพยายามเข้าชั้นเป้าหมาย", 3)
            refreshStat()
        end,
    })
    util:Button({
        Title = "อ่านค่าจริงจากหอ",
        Desc = "อ่านข้อมูลดันเจี้ยนในเครื่อง (ชั้นสูงสุดที่ปลดล็อก / ชั้นปัจจุบัน)",
        Callback = function()
            local maxR = "?"
            pcall(function()
                local DungeonData = require(ReplicatedStorage.LocalData.DungeonData)
                maxR = DungeonData.GetMaxRound()
            end)
            notify("ข้อมูลหอ", ("ปลดล็อกถึงชั้น %s · CurrentRound = %d"):format(tostring(maxR), currentRound()), 5)
        end,
    })
    util:Button({
        Title = "รีเซ็ตตัวนับ",
        Desc = "ล้างยอดนับฆ่า/ผ่านชั้นที่แสดงผล",
        Callback = function()
            killedTotal = 0
            roundDone = 0
            refreshStat()
        end,
    })

    refreshStat()
end

return Tower
