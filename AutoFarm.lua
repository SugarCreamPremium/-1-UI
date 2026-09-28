-- Version 10.31
-- แถบ Auto Farm (วางไว้บนสุด)
--
-- วงจร: เข้าสเตจ -> ฆ่ามอนครบ -> เก็บของ -> กลับจุดเกิด -> วนต่อ
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   เข้า:  HumanoidRootPart ทับ part ใน StageMap.AreaPart -> Touched
--         -> LocalPlayer:SetAttribute("StageID", ชื่อPart)  (StageUtils.lua:92-98)
--         -> StageManager.client.lua:33 -> StartFight(ชื่อ)
--         -> StartStage -> CreateStageEnemys (StageUtils.lua:292)
--            มอนเกิดที่ StageMap.EnemyPoint.<ชื่อสเตจ>.<เลข> ตาม StageEnemyConfig
--            และ InvokeServer("Stage/StageFinishedRF") ไปขอตารางของก่อน
--   ตาย:  EnemyHitBE:Fire(uuid, ดาเมจ, opts) -> StageUtils.HurtEnemy
--         -> EnemyCTRL.HurtEnemy -> HPCTRL.DamageOnce -> Value <= 0
--         -> CheckStageFinishedOnce -> FinishStage -> OreUtils.CreateOres ทิ้งของลงพื้น
--   ออก:  ExitFightBE:Fire(true) -> StageUtils.ExitFight (StageUtils.lua:175-198)
--         -> ClaimedAllOreRE:FireServer()  เก็บของทั้งหมดบนพื้น
--         -> OreUtils.CleanOres()
--         -> TranslateUtils.ToSpawn()      วาร์ปกลับจุดเกิด
local AutoFarm = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local MAP_PATH = {workspace, "WorldModel", "StageMap"}
local ENEMY_FOLDER_NAME = "EnemyFolder"
local ORE_CACHE_NAME = "OreCache"

-- ============================================
-- ดึง BindableEvent โดยไม่ต้อง require
-- ============================================
-- ห้าม require(CommunicationUtils) เด็ดขาด
--   executor ที่ require ModuleScript จะได้ตารางที่ไม่มี member
--   (error: "TryGetBindableEvent is not a valid member of ModuleScript")
--   ทั้งที่ฟังก์ชันมีอยู่จริง เพราะ Roblox ไม่ให้ sandbox อ่าน member ของ ModuleScript
-- ทางแก้: ดึง instance โดยตรงจาก path แล้วเรียก :Fire() ได้เลย เพราะเป็น instance จริง
--   ReplicatedStorage.Remote.<โฟลเดอร์>.<ชื่อ>
-- ถ้ายังไม่มี (เกมสร้างตอน require ครั้งแรก) ให้สร้างเอง ซึ่งเกมทำแบบเดียวกัน
--   CommunicationUtils.Create:40-49 สร้าง BindableEvent ได้ทั้งฝั่ง client
--   (มีแค่ RemoteEvent/RemoteFunction ที่ถูกห้ามสร้าง)
local function getBindable(folderName, eventName)
    local root = ReplicatedStorage:FindFirstChild("Remote")
    if not root then
        root = Instance.new("Folder")
        root.Name = "Remote"
        root.Parent = ReplicatedStorage
    end
    local folder = root:FindFirstChild(folderName)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = folderName
        folder.Parent = root
    end
    local ev = folder:FindFirstChild(eventName)
    if not ev then
        ev = Instance.new("BindableEvent")
        ev.Name = eventName
        ev.Parent = folder
    end
    return ev
end

local EnemyHitBE = getBindable("Attack", "EnemyHitBE")
local ExitFightBE = getBindable("Stage", "ExitFightBE")

-- ============================================
-- รายชื่อสเตจ
-- ============================================
-- อ่านจาก StageMap.EnemyPoint แทนที่จะ require(Config.Stage.Helper) ด้วยเหตุผลเดียวกันข้างบน
-- EnemyPoint คือแหล่งที่ StageUtils ใช้ตรวจเองว่าสเตจนี้รันได้หรือไม่
--   (StageUtils.lua:298  if not EnemyPoint:FindFirstChild(p1) then return end)
-- จึงเป็นรายชื่อที่ตรงกับสิ่งที่เล่นได้จริงเสมอ และไม่ต้องพึ่ง require
local function getStageNames()
    local points = nil
    local map = workspace:FindFirstChild("WorldModel")
    local stageMap = map and map:FindFirstChild("StageMap")
    points = stageMap and stageMap:FindFirstChild("EnemyPoint")

    if points then
        local names = {}
        for _, child in ipairs(points:GetChildren()) do
            if child:IsA("Folder") or child:IsA("Model") then
                table.insert(names, child.Name)
            end
        end
        if #names > 0 then
            -- เรียงตามเลขในชื่อ ไม่งั้นลำดับจะสุ่ม
            table.sort(names, function(a, b)
                return (tonumber(a:match("_(%d+)")) or 0) < (tonumber(b:match("_(%d+)")) or 0)
            end)
            return names
        end
    end

    -- สำรอง: ยังไม่ได้โหลดแมพเสร็จ หรือโครงสร้างเปลี่ยน
    local names = {}
    for i = 1, 27 do table.insert(names, "Stage_" .. i) end
    return names
end

local STAGE_NAMES = getStageNames()

-- ============================================
-- ตัวช่วยหา object
-- ============================================
local function getMapChild(name)
    local node = MAP_PATH[1]
    for i = 2, #MAP_PATH do
        node = node and node:FindFirstChild(MAP_PATH[i])
        if not node then return nil end
    end
    return node and node:FindFirstChild(name)
end

local function getEnemyFolder()
    return workspace:FindFirstChild(ENEMY_FOLDER_NAME)
end

local function getOreCache()
    return workspace:FindFirstChild(ORE_CACHE_NAME)
end

local function getHRP()
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- ============================================
-- วาร์ปไปยืนใกล้สเตจนั้น
-- ============================================
-- ใช้ EnemyPoint ของสเตจนั้นเป็นจุดหมาย เพราะเป็นจุดเดียวกับที่มอนของสเตจนั้นเกิด
-- AreaPart มีแค่ Stage_1..Stage_7 แต่ EnemyPoint มีครบ 27 สเตจ
--   -> สเตจที่ 8 ขึ้นไปไม่มีพื้นที่ให้เหยียบ ใช้ EnemyPoint แทนจึงได้ครบ
local function warpToStage(stageName)
    local char = player.Character
    local hrp = getHRP()
    if not char or not hrp then return false end

    local target = nil
    local points = getMapChild("EnemyPoint")
    local stagePoints = points and points:FindFirstChild(stageName)
    if stagePoints then
        local first = stagePoints:GetChildren()[1]
        if first then target = first.CFrame end
    end
    if not target then
        local areas = getMapChild("AreaPart")
        local area = areas and areas:FindFirstChild(stageName)
        if area then target = area.CFrame end
    end
    if not target then return false end

    return pcall(function()
        -- +5 ขึ้นไปกันตกทะลุพื้น การเขียน CFrame โดยตรงสั่นนิดหน่อยแต่จบในบล็อกเดียว
        char:PivotTo(CFrame.new(target.Position + Vector3.new(0, 5, 0)) * target.Rotation)
    end)
end

-- ============================================
-- เข้าสเตจ
-- ============================================
-- ตั้ง attribute เองแทนการเดินทับ AreaPart เพราะ AreaPart มีแค่ 7 พื้นที่
--   แต่ StartFight/StartStage รับชื่อสเตจได้ทั้ง 27 ตามคีย์ใน u140
-- ต้องล้างค่าเก่าก่อน ไม่งั้นตั้งค่าเดิมซ้ำ = Roblox ไม่ยิง signal = ไม่เกิด StartFight
local function enterStage(stageName)
    if player:GetAttribute("IntoFight") then
        -- ค้างอยู่ในสเตจอื่นอยู่ -> ออกก่อน
        ExitFightBE.Event:Fire(true)
        task.wait(1.5)
    end
    player:SetAttribute("StageID", nil)
    player:SetAttribute("StageID", stageName)
end

-- ============================================
-- ฆ่ามอนทุกตัว
-- ============================================
-- ดาเมจเอาจาก HP ของมอนเอง +1 แทนการใช้เลขกลาง
--   เกมนี้เลือดมันโตแบบทวีคูณ ตัวเลขคงที่จะพัดเมื่อเลือดมอนเกิน
--   (หมายเหตุ: ห้ามใช้ math.huge - HPCTRL.DamageOnce เอา 1e18 ไปลบ inf
--    แล้วได้ inf ซึ่ง <= 0 เป็น false = มอนไม่ตาย)
local function killAllEnemies()
    local folder = getEnemyFolder()
    if not folder then return 0 end
    local hit = 0
    for _, enemy in ipairs(folder:GetChildren()) do
        if enemy:IsA("Model") then
            local hp = enemy:FindFirstChild("HPValue")
            local damage = 1
            if hp and hp:IsA("NumberValue") then
                damage = (tonumber(hp.Value) or 0) + 1
            end
            if damage < 1 then damage = 1 end
            -- ต้องส่ง 3 อาร์กิวเมนต์: SuperLootManager.client.lua:78 ทำ p3.Damage = ...
            -- ถ้าส่งแค่ 2 จะ error ตรงนั้น
            pcall(function()
                EnemyHitBE.Event:Fire(enemy.Name, damage, {
                    SkillID = "K_ATK_1",
                    IsCrit = false,
                    Damage = damage,
                })
            end)
            hit = hit + 1
        end
    end
    return hit
end

-- มอนตายครบแล้วหรือยัง = ดูว่าของเริ่มตกบนพื้นหรือยัง
--   (FinishStage เป็นคนเรียก CreateOres หลังรอ FinishedOreTab จากเซิร์ฟเวอร์)
local function stageDone()
    local cache = getOreCache()
    if not cache then return false end
    return #cache:GetChildren() > 0
end

-- ============================================
-- ลูปหลัก
-- ============================================
local running = false
local selectedStage = STAGE_NAMES[1]
local roundDelay = 3
local shouldWarp = true

-- รอจนกว่าเงื่อนไขจะเป็นจริง แต่ไม่เกิน timeout -> คืน true ถ้าสำเร็จ
local function waitUntil(check, timeout, step)
    local waited = 0
    while running and waited < timeout do
        if check() then return true end
        task.wait(step or 0.25)
        waited = waited + (step or 0.25)
    end
    return false
end

-- หนึ่งรอบของการฟาร์ม คืนทุกทางที่ "รอบนี้ไม่สำเร็จ"
-- แยกจาก farmLoop เพื่อใช้ return แทน continue (continue เป็นคีย์เวิร์ดเฉพาะ Luau)
local function runRound()
    -- 1) รอจนฟื้นฟู (ถ้าตายอยู่ ไม่ต้องทำอะไรรอบนี้)
    if player:GetAttribute("Dead") then
        waitUntil(function() return not player:GetAttribute("Dead") end, 30)
        return
    end
    -- 2) รอตัวละครพร้อม
    if not waitUntil(function() return getHRP() ~= nil end, 15) then return end

    -- 3) วาร์ปไปที่สเตจที่เลือก
    if shouldWarp then
        warpToStage(selectedStage)
        task.wait(0.4)
    end

    -- 4) เข้าสเตจ
    enterStage(selectedStage)

    -- 5) ฆ่ามอนวนจนของเริ่มตก = สเตจจบแล้ว
    --    ต้องยิงไปเรื่อย ๆ ไม่ใช่ยิงรอบเดียว เพราะ FinishStage
    --    จะสร้างของต่อเมื่อทุกตัวใน EnemyTab ตายครบเท่านั้น
    --    (ยิงครั้งเดียวแล้วไปรอของ = ค้างจน timeout เพราะมอนที่เหลือยังไม่ตาย)
    --    timeout 60 วิ เผื่อเซิร์ฟเวอร์ไม่ยอมให้ของ (StageUtils.FinishStage
    --    จะค้างที่ repeat task.wait() until FinishedOreTab ถ้าเซิร์ฟไม่ตอบ)
    local hit, done, waited = 0, false, 0
    local TIMEOUT = 60
    while running and waited < TIMEOUT do
        hit = hit + killAllEnemies()
        if stageDone() then
            done = true
            break
        end
        task.wait(0.2)
        waited = waited + 0.2
    end

    if not done then
        -- hit == 0 = มอนไม่เกิดเลย (สตา��ต์ยังไม่ปลด หรือเข้าไม่ได้)
        -- hit > 0 = ฆ่าแล้วแต่ของไม่ตก = เซิร์ฟเวอร์ไม่ยอมให้ของสตา��ต์นี้
        ExitFightBE.Event:Fire(true)
        task.wait(2)
        return
    end

    -- 7) เก็บของ + กลับจุดเกิด
    task.wait(0.5)
    ExitFightBE.Event:Fire(true)
    task.wait(roundDelay)
end

local function farmLoop()
    while running do
        runRound()
        -- กันหลุดลูกตอนผู้ใช้กดปิดสวิตช์ครั้งแรก (ยังไม่ได้ทำอะไรเลย)
        if running then task.wait(0.5) end
    end
end

local function setRunning(value)
    running = value == true
    if running then
        task.spawn(farmLoop)
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function AutoFarm.register(context)
    local tab = context.Tab
    local WindUI = context.WindUI
    if not tab then return end

    local function notify(title, desc)
        if not WindUI then return end
        pcall(function()
            WindUI:Notify({Title = title, Content = desc, Duration = 3})
        end)
    end

    -- อ่านซ้ำตอนเปิดหน้าต่าง เพราะตอนโหลดโมดูลแมพอาจยังไม่เข้า workspace เต็ม
    -- ถ้าได้รายชื่อจริงมา ให้ใช้ของจริงแทนรายการสำรอง
    local names = getStageNames()
    if #names > 0 then
        STAGE_NAMES = names
        if selectedStage == nil or not table.concat(STAGE_NAMES, ","):find(selectedStage, 1, true) then
            selectedStage = STAGE_NAMES[1]
        end
    end

    -- ชื่อที่แสดง "Stage 1" แต่ค่าจริงต้องเป็น "Stage_1" ที่เกมรู้จัก
    local display = {}
    for i, name in ipairs(STAGE_NAMES) do
        display[i] = (name:gsub("_", " "))
    end

    local section = tab:Section({Title = "Auto Farm", Opened = true})
    if not section then
        tab:Paragraph({Title = "Auto Farm", Desc = "ไม่สามารถสร้างส่วนควบคุมได้"})
        return
    end

    section:Paragraph({
        Title = "วิธีใช้",
        Desc = "เลือกสเตจ -> เปิดสวิตช์ -> ตัวละครจะวิ่งเข้าไปฆ่ามอนทั้งสเตจ "
            .. "เก็บของอัตโนมัติ แล้วกลับจุดเกิดวนต่อ",
    })

    section:Dropdown({
        Title = "เลือกสเตจ",
        Desc = "มีทั้งหมด " .. #STAGE_NAMES .. " สเตจ",
        Values = display,
        Value = display[1],
        Callback = function(value)
            for i, name in ipairs(STAGE_NAMES) do
                if display[i] == value then
                    selectedStage = name
                    break
                end
            end
        end,
    })

    section:Toggle({
        Title = "เริ่ม Auto Farm",
        Desc = "หยุดกลางคันได้ แต่ถ้าหยุดตอนกำลังอยู่ในสเตจ ตัวละครจะยังอยู่ในนั้น "
            .. "กดปุ่มกลับ (Return) เองถ้าจะออก",
        Value = false,
        Callback = function(value)
            if value then
                notify("Auto Farm เริ่มทำงาน", "กำลังฟาร์ม " .. (selectedStage or ""):gsub("_", " "))
            end
            setRunning(value)
        end,
    })

    local optionSection = tab:Section({Title = "ตัวเลือก", Opened = true})
    if optionSection then
        optionSection:Toggle({
            Title = "วาร์ปไปที่สเตจก่อนตี",
            Desc = "ปิดไว้ถ้าอยากอยู่ที่เดิมแล้วตีเอง (ฆ่าได้ทุกระยะเหมือนกัน ไม่ต้องเดินเข้าไป)",
            Value = true,
            Callback = function(value) shouldWarp = value == true end,
        })
        optionSection:Slider({
            Title = "หน่วงเวลาระหว่างรอบ",
            Desc = "วินาทีระหว่างเก็บของกับรอบถัดไป",
            Value = {Min = 1, Max = 30, Default = 3},
            Step = 1,
            Callback = function(value) roundDelay = math.clamp(value, 1, 30) end,
        })
    end
end

return AutoFarm
