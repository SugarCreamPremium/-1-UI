-- Version 9.22
-- แถบ Auto Farm (วางไว้บนสุด)
--
-- วงจรของสเตจ: สั่งให้มอนเกิด -> ฆ่ามอนครบ -> ของตก -> เก็บ -> ออก
--   ไม่ต้องวาร์ปไปที่สเตจ เกมไม่ได้เช็คตำแหน่งตัวละครในสายทางนี้เลย (ดูหัว runRound)
-- อีกส่วนคือ Auto Train (ตั้งจุดเทรนที่ดีที่สุดโดยไม่ต้องยืนตรงจุด) และ Auto Rebirth
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
--   ออก:  ExitFightBE:Fire(claimOres, skipWarp) -> StageUtils.ExitFight (StageUtils.lua:175-198)
--         claimOres = true  เก็บของที่เหลือบนพื้น (ClaimedAllOreRE:FireServer)
--         skipWarp  = true  ไม่วาร์ปกลับจุดเกิด (ไม่งั้นโดน ToSpawn เสมอ)
--         -> OreUtils.CleanOres()
--         -> TranslateUtils.ToSpawn()      วาร์ปกลับจุดเกิด (ถ้า skipWarp = false)
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

-- ดึง RemoteEvent ของฝั่งเซิร์ฟเวอร์ (ต่างจาก getBindable ตรงบนที่เป็น BindableEvent ในเครื่อง)
local function getRemote(folderName, remoteName)
    local root = ReplicatedStorage:FindFirstChild("Remote")
    if not root then return nil end
    local folder = root:FindFirstChild(folderName)
    if not folder then return nil end
    return folder:FindFirstChild(remoteName)
end

local TryRebirthRE = getRemote("Rebirth", "TryRebirthRE")

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
-- ออกจากสเตจ
-- ============================================
-- ExitFightBE ส่งต่ออาร์กิวเมนต์ให้ครบทั้งสองตัว
--   (StageManager.client.lua:51-54 -> StageUtils.ExitFight(p1, p2))
--   p1 = true  เก็บของที่เหลือบนพื้น (ClaimedAllOreRE:FireServer)
--   p2 = true  ไม่วาร์ปกลับจุดเกิด
-- ค่า p2 สำคัญมาก เพราะ ExitFight ลงท้ายด้วย TranslateUtils.ToSpawn เสมอ
--   (StageUtils.lua:195-197) ถ้าไม่กด p2 = true เราจะโดนวาร์ปกลับทันทีหลังออก
local function exitFight(claimOres, skipWarp)
    ExitFightBE:Fire(claimOres == true, skipWarp == true)
end

-- ============================================
-- เข้าสเตจ
-- ============================================
-- ต้องล้างค่าเก่าก่อน ไม่งั้นตั้งค่าเดิมซ้ำ = Roblox ไม่ยิง signal = ไม่เกิด StartFight
-- หมายเหตุ: ต้องไม่ ExitFight ตรงนี้ เพราะมันวาร์ปกลับจุดเกิดทันที
--   ถ้าอยู่ในสเตจอื่นอยู่ ให้ clearStage จัดการก่อนวาร์ป (ดู runRound ข้อ 2)
local function enterStage(stageName)
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
    if not folder then return end
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
                EnemyHitBE:Fire(enemy.Name, damage, {
                    SkillID = "K_ATK_1",
                    IsCrit = false,
                    Damage = damage,
                })
            end)
        end
    end
end

-- มอนตายครบแล้วหรือยัง = ดูว่าของเริ่มตกบนพื้นหรือยัง
--   (FinishStage เป็นคนเรียก CreateOres หลังรอ FinishedOreTab จากเซิร์ฟเวอร์)
local function stageDone()
    local cache = getOreCache()
    if not cache then return false end
    return #cache:GetChildren() > 0
end

-- ตอนนี้มีมอนกี่ตัวในสเตจ (ใช้เช็คว่าเข้าสเตจสำเร็จหรือยัง)
local function countEnemies()
    local folder = getEnemyFolder()
    if not folder then return 0 end
    local count = 0
    for _, enemy in ipairs(folder:GetChildren()) do
        if enemy:IsA("Model") then count = count + 1 end
    end
    return count
end

-- ============================================
-- ราคาขายของแร่ (Config/Ore/Config.lua)
-- ============================================
-- เกมแสดงราคาบน Billboard ของของแต่ละชิ้น (OreDropUtils.lua:98-104)
--   -> ถ้าจะเก็บเรียงจากแพงสุด ต้องรู้ราคาจริง ซึ่งอยู่ใน ModuleScript ที่อ่านไม่ได้
--   (require ไม่ได้ เหมือนที่อธิบายไว้ข้างบน)
-- ตารางนี้คัดลอกค่า Price มาจาก Config/Ore/Config.lua ตรง ๆ
--   และค่ามันเรียงจากน้อยไปมากตามเลข 8 .. 80000 พอดี
--   ถ้าเจอแร่ที่ไม่รู้จัก ให้คิดเป็น 0 = ไปเก็บทีหลังสุด (ไม่ทำให้สติปั๊บ)
local ORE_PRICE = {
    [1] = 8, [2] = 14, [3] = 21, [4] = 35, [5] = 40, [6] = 55, [7] = 60,
    [8] = 82, [9] = 125, [10] = 150, [11] = 175, [12] = 200, [13] = 225,
    [14] = 777, [15] = 932, [16] = 1120, [17] = 1340, [18] = 1610, [19] = 1930,
    [20] = 2320, [21] = 2780, [22] = 3531, [23] = 4823, [24] = 5524, [25] = 6120,
    [26] = 6950, [27] = 7230, [28] = 7990, [29] = 8250, [30] = 9100, [31] = 11200,
    [32] = 12528, [33] = 13420, [34] = 14555, [35] = 16230, [36] = 18800,
    [37] = 21000, [38] = 23250, [39] = 25539, [40] = 27980, [41] = 30000,
    [42] = 32420, [43] = 36732, [44] = 42000, [45] = 47000, [46] = 53200,
    [47] = 60000, [48] = 80000,
}

local function getOrePrice(name)
    return ORE_PRICE[tonumber(name:match("^Ore_(%d+)$"))] or 0
end

-- ============================================
-- ยิง ProximityPrompt
-- ============================================
-- path ที่ยืนยันแล้ว: workspace.OreCache.Ore_47.MAIN.ProximityPrompt
--   ตรวจจาก Assets/Ore ทั้ง 48 แบบ -> PrimaryPart ชื่อ "MAIN" ทั้งหมด
--   และ MAIN ใน asset ไม่มี ProximityPrompt ติดมา -> ตัวที่เจอในเกมชิ้นเดียว
--   ที่เกมสร้างตอนรันด้วย Instance.new("ProximityPrompt", Model.PrimaryPart)
--     (OreDropUtils.lua:123)
--
-- วิธียิง: global function "fireproximityprompt" ที่ executor เขียนมาให้
--   นี่แหละคือตัวที่ Infinite Yield ใช้ ไม่ใช่เมธอด Fire ของ ProximityPrompt
--   ProximityPrompt มีแค่ InputHoldBegin/InputHoldEnd ไม่มีเมธอด Fire เลย
--   (:Fire() เป็นของ BindableEvent ที่เราเรียกตอนฆ่ามอน/ออกสเตจ)
--
--   อาร์กิวเมนต์: fireproximityprompt(prompt, holdDuration, skipDistanceCheck)
--     holdDuration = 0   ยิงทันที ไม่ต้องกดค้าง 0.5 วิ ตามที่เกมตั้งไว้
--                      (OreDropUtils.lua:133  HoldDuration = 0.5)
--     3 ตัวที่ 3 = true  ไม่เช็คระยะ เพราะแร่ตกอยู่ไกลจากจุดวาร์ป
--                      (OreDropUtils.lua:132 MaxIndicatorDistance = 10)
--
--   ถ้า executor ไม่มีตัวนี้ ค่อยใช้วิธีกดค้างจริงแบบเดียวกับ MainScript.lua:2462-2467
-- fireError เก็บ error ครั้งแรกไว้ เพื่อให้ collectOres เลิกยิงต่อทันทีที่พัง
local fireError = nil

local function firePrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        local ok, err = pcall(fireproximityprompt, prompt, 0, true)
        if not ok and not fireError then
            fireError = tostring(err)
        end
        return ok
    end

    -- executor ไม่มี global ตัวนี้ -> กดค้างเอง แต่ตัดเวลาค้างออกให้เป็น 0 ก่อน
    local ok, err = pcall(function()
        prompt.HoldDuration = 0
        prompt:InputHoldBegin()
        task.wait(0.05)
        prompt:InputHoldEnd()
    end)
    if not ok and not fireError then
        fireError = tostring(err)
    end
    return ok
end

-- รอสัญญาณว่าเกมรับของแล้ว -> คืน true ถ้าของหายไปจาก cache แล้ว
--   เกมสั่ง FlyToPlayer แล้ว DestroyOre ทิ้งโมดเดลท้ายสุด (OreDropUtils.lua:130-132)
--   ถ้ากระเป๋าเต็ม callback ของเกมจะ return ออกก่อน ไม่ได้ไปแตะ FlyToPlayer
--     (OreUtils.lua:62-66) ของก็ยังอยู่ prompt ก็ยัง Enabled
--   -> กระเป๋าเต็มต้องเช็คจาก getPack() ข้างล่าง ไม่ใช่รอสัญญาณตรงนี้
local function waitOreGone(ore, limit)
    local waited = 0
    while waited < limit do
        if not ore.Parent then return true end
        task.wait(0.1)
        waited = waited + 0.1
    end
    return not ore.Parent
end

-- หา ProximityPrompt ของแร่ 1 ชิ้น
--   path ที่ยืนยันแล้ว: workspace.OreCache.Ore_47.MAIN.ProximityPrompt
--     ตรวจจาก Assets/Ore ทั้ง 48 แบบ -> PrimaryPart ชื่อ "MAIN" ทั้งหมด
--     และ MAIN ใน asset ไม่มี prompt ติดมา -> ตัวที่เจอมีชิ้นเดียว
--   ไล่จาก PrimaryPart -> MAIN -> Main -> ทั้งโมเดล กันโครงสร้างเปลี่ยน
local function findOrePrompt(ore)
    local primary = ore.PrimaryPart
    if primary then
        local prompt = primary:FindFirstChildOfClass("ProximityPrompt")
        if prompt then return prompt end
    end
    local main = ore:FindFirstChild("MAIN") or ore:FindFirstChild("Main")
    if main then
        local prompt = main:FindFirstChildOfClass("ProximityPrompt")
        if prompt then return prompt end
    end
    -- สำรอง: ไล่ทั้งโมเดล (โครงสร้างเปลี่ยนไปจากนี้ก็ยังเจอ)
    for _, desc in ipairs(ore:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then return desc end
    end
    return nil
end

-- ระยะที่ถือว่าอยู่ใกล้พอ ไม่ต้องดึงของมาวางใหม่
--   OreDropUtils.lua:110-111 ตั้ง MaxIndicatorDistance = 10
--     และไม่ได้แตะ MaxActivationDistance ซึ่งค่าเริ่มต้นของ ProximityPrompt คือ 10
--   เผื่อไว้หน่อยเพราะ prompt วัดจากขอบโมดเดล ไม่ใช่จุดกึ่งกลาง
local ORE_NEAR_RANGE = 12

-- ============================================
-- ดึงของมาวางข้างตัวละคร เพื่อให้กด prompt ได้โดยไม่ต้องวาร์ปไปหา
-- ============================================
-- ของตกที่จุดที่มอนตาย ซึ่งอยู่ที่ EnemyPoint ของสเตจ ไม่ใช่ที่เรายืน
--   (StageUtils.HurtEnemy:308 เก็บ DeadCF จากจุดตายของมอน)
-- แต่ตัวที่อยู่ใน OreCache เป็นแค่ clone ฝั่ง client ที่เกมสร้างเอง
--   (OreDropUtils.lua:52-56  Model:Clone() -> PivotTo -> Parent = OreCache)
-- เกมไม่เคยเช็คตำแหน่งของตอนให้ของ มันเอาแค่ UUID ไปขอ
--   (OreUtils.lua:59-74  callback -> PickupOreBE:Fire() -> GetOreRF:InvokeServer(uuid))
-- ย้ายโมดเดลมาวางใกล้ตัวละคร ก็เท่ากับ "ไปเก็บของด้วยตัวเอง" โดยไม่ต้องขยับตัวละครเลย
local function pullOreNear(ore)
    local hrp = getHRP()
    if not hrp then return false end
    return pcall(function()
        -- ต้อง anchor ก่อน ไม่งั้นแรงโน้มถ่วงจะดึงมันตกกลับไปที่เดิม
        --   CreateOneDrop:63-65 ใส่ AssemblyLinearVelocity ไว้ = ตอนนั้นยังไม่ anchor
        for _, desc in ipairs(ore:GetDescendants()) do
            if desc:IsA("BasePart") then
                desc.Anchored = true
            end
        end
        local target = hrp.CFrame * CFrame.new(0, 0, -3)
        ore:PivotTo(target)
        local primary = ore.PrimaryPart
        if primary then
            primary.CFrame = target
        end
    end)
end

local function oreIsNear(ore)
    local hrp = getHRP()
    if not hrp then return false end
    local pos = ore.PrimaryPart and ore.PrimaryPart.Position or ore:GetPivot().Position
    return (pos - hrp.Position).Magnitude <= ORE_NEAR_RANGE
end

-- ============================================
-- เก็บของ 1 ชิ้น -> คืน true ถ้าของเข้าตัวจริง
-- ============================================
-- ลอง fireproximityprompt ก่อน แต่ตัวนี้ข้ามระยะได้หรือไม่ขึ้นอยู่กับ executor
--   ถ้ามันมีอยู่แต่ทำงานเงียบ ๆ ไม่มี error -> ทางแรกใน firePrompt จะไม่ throw
--     และทางสำรอง (กด prompt เอง) ก็ไม่ถูกเรียก ของก็เลยไม่เข้าตัวโดยไม่มีอะไรฟ้อง
--   -> ยิงเสร็จต้องเช็คว่าของหายไปจริงไหม ถ้ายังอยู่ค่อยลองวิธีที่สองเอง
local function pickOre(ore)
    local prompt = findOrePrompt(ore)
    if not prompt or not prompt.Enabled then return false end

    firePrompt(prompt)
    if waitOreGone(ore, 0.4) then return true end

    -- วิธีที่สอง: กด prompt เอง ต้องอยู่ใกล้พอถึงจะผ่าน (เราดึงมาใกล้แล้ว)
    local ok = pcall(function()
        prompt.HoldDuration = 0
        prompt:InputHoldBegin()
        task.wait(0.05)
        prompt:InputHoldEnd()
    end)
    if not ok then
        if not fireError then fireError = "InputHoldBegin" end
        return false
    end

    return waitOreGone(ore, 0.6)
end

-- อ่านจำนวนของในกระเป๋า / ขนาดกระเป๋า -> count, max
-- ============================================
-- ตัวเลขจริงอยู่ในตัวแปร module-local ของ LeftInfoGUI (u66) อ่านตรง ๆ ไม่ได้
--   (LeftInfoGUI.lua:64  UpdateOrePack เป็นคนเขียน u66 แล้วเอาไปแสดงที่ HUD)
--   จึงต้องอ่านจาก HUD ที่เกมวาดไว้ คือ
--       PlayerGui.Hud.LeftInfos.OrePack.Title.Text  =  "3/4"
--   (LeftInfoGUI.lua:76  Title.Text = ("%*/%*"):format(count, max))
--   ตัวเลขทั้งสองเป็นจำนวนเต็มเล็ก ๆ (สูงสุด 16) จึงไม่ถูกย่อด้วย AbbreviateNumber
--   เหมือนของ coin ที่ใช้ AbbreviateNumber ต่างกัน
local function getPack()
    local gui = player:FindFirstChild("PlayerGui")
    local hud = gui and gui:FindFirstChild("Hud")
    local infos = hud and hud:FindFirstChild("LeftInfos")
    local pack = infos and infos:FindFirstChild("OrePack")
    local title = pack and pack:FindFirstChild("Title")
    if not title or not title:IsA("TextLabel") and not title:IsA("TextButton") then
        return nil, nil
    end
    local count, max = tostring(title.Text):match("^(%d+)%s*/%s*(%d+)$")
    if not count then return nil, nil end
    return tonumber(count), tonumber(max)
end

-- ============================================
-- เก็บของ
-- ============================================
-- เกมทิ้งแร่ไว้ใน workspace.OreCache แต่ละชิ้นคือ clone ของ Assets.Ore.<ID>
--   ชื่อจึงเป็น "Ore_1".."Ore_48" เหมือนกันหมด ใช้ชื่อหา ID ได้เลย
--   (OreDropUtils.lua:55-65)
--
-- การเก็บจริงทำผ่าน ProximityPrompt ที่เกมแปะไว้ และ callback ของมันปิด UUID ไว้ข้างใน
--   (OreUtils.lua:59-74) เรียก callback นั้นได้ด้วย firePrompt ด้านบน
--   แล้วมันจะทำงานครบวงจร:
--       ตรวจกระเป๋าว่าเต็มไหม -> FlyToPlayer -> UpdateOrePack(count+1)
--       -> PickupOreBE:Fire() -> GetOreRF:InvokeServer(uuid) ให้เซิร์ฟเวอร์จองของ
-- UUID อยู่ในตารางภายในของ OreDropUtils อ่านตรง ๆ ไม่ได้ แต่ไม่ต้องรู้ก็ได้
--
-- กระเป๋าเต็ม = callback ของเกม return ออกก่อน ไม่ได้ไปแตะ FlyToPlayer
--   (OreUtils.lua:62-66  if UpgradeData.GetMaxNum("OrePack") <= v1 then ... return end)
--   แปลว่า prompt ยัง Enabled อยู่ = ยิงซ้ำก็ไม่มีอะไรเกิดขึ้น
--   -> ต้องเช็คจำนวนในกระเป๋าก่อนยิงทุกชิ้น ไม่งั้นจะยิงเปล่า 1.5 วิ ทีละชิ้นจนครบ
--
-- ข้อความเตือนว่าเก็บของไม่ได้ ส่งออกไปโชว์ทีเดียว ไม่งั้นจะขึ้นทุกรอบ
local collectWarned = false
local collectWarnMsg = nil

local function collectOres()
    local cache = getOreCache()
    if not cache then return 0 end

    -- 1) รวบรวมแร่ที่ตกอยู่ แล้วเรียงจากราคาแพงสุดไปถูกสุด
    local ores = {}
    for _, model in ipairs(cache:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^Ore_%d+$") then
            ores[#ores + 1] = model
        end
    end
    if #ores == 0 then return 0 end

    table.sort(ores, function(a, b)
        return getOrePrice(a.Name) > getOrePrice(b.Name)
    end)

    -- 2) ดึงแร่ที่อยู่ไกลทั้งหมดมาวางใกล้ในรอบเดียว (ลด task.wait ต่อชิ้น)
    for _, ore in ipairs(ores) do
        local count, max = getPack()
        if count and max and count >= max then break end
        if not oreIsNear(ore) then
            pullOreNear(ore)
        end
    end
    task.wait(0.05)

    -- 3) เก็บทีละชิ้นจากแพงสุด
    local picked = 0
    for _, ore in ipairs(ores) do
        local count, max = getPack()
        if count and max and count >= max then break end

        if pickOre(ore) then
            picked = picked + 1
        else
            break
        end
    end

    if picked == 0 and #ores > 0 and not collectWarned then
        collectWarned = true
        collectWarnMsg = fireError
            and ("เก็บของไม่ได้: " .. tostring(fireError))
            or "เก็บของไม่ได้ ทั้งที่ของตกแล้ว (ลองสลับ executor ดู)"
    end

    return picked
end

-- ============================================
-- Auto Train (ยืนเทรนในจุดที่ดีที่สุดที่เราเข้าได้)
-- ============================================
-- จุดเทรนอยู่ที่ workspace.TOUCHED.AutoTrainArea.<เลข>  เป็น Part ชื่อเป็นเลข 1..11
--   (GuiUtils/AutoTrainAreaGUI.lua:21,37-39 ไล่ GetChildren แล้วเอา tonumber(ชื่อ) ไปใช้)
--   จุดที่ 1 คือจุดแรกที่เกมชี้ให้ผู้เล่นใหม่ไปยืน (新手引导.client.lua:317-321)
--
-- เข้าจุดได้เมื่อ จำนวน Rebirth ที่มี >= Rebirth ที่จุดนั้นต้องใช้
--   (AutoTrainAreaGUI.lua:67-80  CheckCanIntoTrainArea: GetNeedRebirth(n) <= Eco.rebirth.Value)
--   จุดที่ต้องซื้อเงินจริง (IsPay) ไม่เช็คว่าซื้อแล้วหรือยัง เข้าได้เลยถ้าเข้าเงื่อนไข Rebirth
--   จุด 9 คือจุด x100 (Basic = 100) ซึ่งใหญ่ที่สุดในตาราง = ไปจุดนี้เลย ไม่ต้องเช็คอะไร
--
-- ยืนถึงแค่ไหน = จุดที่ Basic สูงสุดที่เข้าได้ (ไม่ใช่เลขจุดสูงสุด เพราะ 9,10,11 ไม่เรียงตาม Basic)
--   (Utils/BalanceUtils.lua:163  GetTrainAreaBasic เอา Basic ของจุดที่ยืนอยู่ไปคูณดาเมจ)
-- คัดลอกจาก Config/TrainArea/Config.lua ตรง ๆ (require ไม่ได้ ดูหัวไฟล์)
--   จุดที่ 9,10,11 ซื้อด้วย Robux (Monetization.lua:8-10) ไม่ใช่ด้วย Rebirth
local TRAIN_AREA = {
    {Basic = 1.5, NeedRebirth = 0},
    {Basic = 2, NeedRebirth = 2},
    {Basic = 4, NeedRebirth = 5},
    {Basic = 6, NeedRebirth = 9},
    {Basic = 8, NeedRebirth = 12},
    {Basic = 10, NeedRebirth = 15},
    {Basic = 15, NeedRebirth = 18},
    {Basic = 25, NeedRebirth = 21},
    {Basic = 100, NeedRebirth = 0, IsPay = true},
    {Basic = 10, NeedRebirth = 0, IsPay = true},
    {Basic = 20, NeedRebirth = 0, IsPay = true},
}

local function getEcoValue(name)
    local eco = player:FindFirstChild("Eco")
    local value = eco and eco:FindFirstChild(name)
    if not value then return nil end
    return tonumber(value.Value)
end

-- Eco.rebirth เป็น NumberValue อ่านสดได้ ไม่ต้องยิง remote
--   (AutoTrainAreaGUI.lua:22  rebirth = Eco:WaitForChild("rebirth"))
local function getRebirth()
    return getEcoValue("rebirth")
end

local function getLevel()
    return getEcoValue("level")
end

-- จุดที่ดีที่สุดที่เข้าได้ คืนเลขจุด หรือ nil ถ้าไม่มีจุดไหนเข้าได้เลย
-- ไม่เช็คว่าจุดนั้นต้องซื้อเงินจริงไหม เข้าได้เลยทุกจุดที่เงื่อนไข Rebirth ผ่าน
local function bestTrainArea(rebirth)
    if not rebirth then return nil end
    local bestIndex = nil
    local bestBasic = -1
    for index = 1, #TRAIN_AREA do
        local area = TRAIN_AREA[index]
        if area.NeedRebirth <= rebirth then
            local basic = area.Basic or 0
            if bestIndex == nil or basic > bestBasic or (basic == bestBasic and index > bestIndex) then
                bestBasic = basic
                bestIndex = index
            end
        end
    end
    return bestIndex
end

-- ไม่ต้องวาร์ปแล้ว (เดินออกมา Train ได้อยู่)
-- ฟังก์ชันนี้ทิ้งไว้เฉย ๆ ไม่ถูกเรียกใช้งาน
local function warpToTrain(areaId)
    return true
end

-- อ่านค่าจุดที่ยืนอยู่เป็นตัวเลขเสมอ
--   เกมตั้ง attribute นี้เป็น string (มาจากชื่อ Part) ดูได้จาก BalanceUtils.lua:99
--     ที่ต้อง tonumber(Attribute) ก่อนเอาไปคำนวณ
--   ถ้าเอามาเทียบตรง ๆ กับเลข แล้ว "9" ~= 9 จะทำให้วาร์ปซ้ำทุกรอบ
local function currentTrainArea()
    return tonumber(player:GetAttribute("AutoTrainAreaID"))
end

-- เข้าเกมจะเริ่มเทรนให้เองเมื่อ attribute นี้เป็นเลขจุดที่ยืนอยู่
--   TrainCTRL.lua:55-66 ฟัง GetAttributeChangedSignal("AutoTrainAreaID")
--     ได้ค่า -> StartAutoTrain() ยิง Train/IntoAutoTrainRE แล้วล็อกตัวละครไว้บน DUMMY เอง
--   BalanceUtils.lua:163 ใช้ attribute เดียวกันนี้คิดตัวคูณดาเมจตอนเทรน
--   (AutoTrainAreaGUI.lua:50  Rebirth_4:WaitForChild("Allow"))
--
-- ไม่ต้องวาร์ปแล้ว เพราะเกมคำนวณตัวคูณจาก AutoTrainAreaID แม้ยืนอยู่นอกจุดก็ตาม
local function enterTrainArea(areaId)
    if currentTrainArea() ~= areaId then
        -- ต้องตั้งเป็น string ไม่ใช่ตัวเลข
        --   เกมเก็บค่านี้เป็นชื่อ Part (string) มาตั้งแต่แรก ดูจาก BalanceUtils.lua:99
        --     ที่ต้อง tonumber(Attribute) ก่อนคำนวณ แปลว่าค่าที่เกมอ่านเป็น string
        --   ถ้าส่งตัวเลขเข้าไป เซิร์ฟเวอร์จะมองไม่ออกว่าจุดไหน แล้วล้าง attribute ทิ้งทันที
        player:SetAttribute("AutoTrainAreaID", tostring(areaId))
    end
    return true
end

local trainEnabled = false
local trainRunning = false
local currentArea = nil
-- ตรวจถี่แค่ไหน = ตอนเกมล้าง attribute เราจะได้ตั้งคืนได้เร็ว ชะงักน้อยลง
-- แต่ไม่ต้องถี่เกินนี้ เพราะตอนตั้งค่าใหม่ เกมเริ่มนับการเทรนใหม่จากศูนย์
local TRAIN_EVERY = 0.5
local lastTrainChange = 0
local TRAIN_CHANGE_COOLDOWN = 0.4

local function trainLoop()
    while trainEnabled do
        if not getHRP() then
            task.wait(1)
        else
            local best = bestTrainArea(getRebirth())
            if best then
                local cur = currentTrainArea()
                if cur ~= best then
                    -- ตั้ง AutoTrainAreaID เฉย ๆ ไม่ต้องวาร์ป
                    --   เกมยังคำนวณตัวคูณตามจุดนั้น แม้ยืนอยู่นอกจุดก็ตาม
                    local t = os.clock()
                    if (t - lastTrainChange) >= TRAIN_CHANGE_COOLDOWN then
                        enterTrainArea(best)
                        currentArea = best
                        lastTrainChange = t
                    end
                end
            end
            task.wait(TRAIN_EVERY)
        end
    end
    trainRunning = false
end

-- ============================================
-- Auto Rebirth
-- ============================================
-- ปุ่มรีเบิร์ธของเกมเช็คแค่ 2 อย่าง (GuiUtils/RebirthGUI.lua:81-93)
--   1) ยังไม่ครบเพดาน  2) เลเวล >= เลเวลที่ต้องใช้ของระดับถัดไป แล้วยิง TryRebirthRE
--     Rebirth/TryRebirthRE:FireServer()  ไม่มีอาร์กิวเมนต์
-- เลเวลที่ต้องใช้ = 25 * จำนวนรีเบิร์ธที่จะไปถึง  ตรงกับ Config/Rebirth/Config.lua ทุกแถว
--   (NeedLevel ไล่ 0, 25, 50, ... 1125 = 25 คูณเลข index พอดี)
-- เพดาน = 45  (Config/Rebirth/Helper.lua:17  #Config - 1)
local MAX_REBIRTH = 45
local NEED_LEVEL_STEP = 25
local REBIRTH_EVERY = 0.5

local function canRebirth()
    local rebirth = getRebirth()
    local level = getLevel()
    if not rebirth or not level then return false end
    if rebirth >= MAX_REBIRTH then return false end
    return level >= NEED_LEVEL_STEP * (rebirth + 1)
end

local rebirthEnabled = false
local rebirthRunning = false

local function rebirthLoop()
    while rebirthEnabled do
        if canRebirth() then
            local remote = TryRebirthRE or getRemote("Rebirth", "TryRebirthRE")
            if remote then
                TryRebirthRE = remote
                local before = getRebirth()
                pcall(function() remote:FireServer() end)
                -- รอให้ตัวเลขขยับจริง กันยิงซ้ำถ้าเซิร์ฟเวอร์ช้า
                local waited = 0
                while waited < 3 and getRebirth() == before do
                    task.wait(0.1)
                    waited = waited + 0.1
                end
            end
        end
        task.wait(REBIRTH_EVERY)
    end
    rebirthRunning = false
end

-- ============================================
-- ลูปหลัก
-- ============================================
local running = false
local farmRunning = false
local selectedStage = STAGE_NAMES[1]

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
--
-- ไม่วาร์ปไปที่สเตจเลย เพราะเกมไม่ได้เช็คตำแหน่งตัวละครในสายทางนี้เลย:
--   1) เข้า:  StageManager.client.lua:67 ฟังแค่ attribute "StageID" เปลี่ยน
--           แล้วเรียก StartFight -> StartStage -> CreateStageEnemys เรียงอ่านจากนั้น
--   2) เกิด: CreateStageEnemys:253-258 เอาพิกัดมาจาก EnemyPoint.<สเตจ>.<เลข>.CFrame
--           ตายตัว ไม่เคยอ้างตำแหน่งผู้เล่น -> มอนเกิดได้แม้เรายืนที่ไหนก็ตาม
--   3) ตี:   EnemyHitBE เป็น BindableEvent ฝั่ง client -> StageUtils.HurtEnemy:287
--           -> EnemyCTRL.HurtEnemy:188 -> HPCTRL.DamageOnce ไม่มีเช็คระยะเลย
--   4) ของ: HurtEnemy:308 เก็บ DeadCF = ตำแหน่งที่มอนตาย (จุดเกิดมอน)
--           ของจึงตกที่นั่น ไม่ใช่ที่เรายืน
-- ผลคือไม่ต้องเดินไปไหนเลย ทั้งรอบอยู่ที่เดิม ไม่มีจังหวะกระตุกจากการวาร์ป
-- ============================================
-- แจ้งเตือนผู้ใช้
-- ============================================
-- ต้องอยู่ระดับ module ไม่ใช่ใน register เพราะ runRound จะเรียกใช้ด้วย
--   local function ใน register มองจากข้างนอกไม่เห็น (upvalue ไม่หลุดออกมา)
local windUI = nil

local function notify(title, desc)
    if not windUI then return end
    pcall(function()
        windUI:Notify({Title = title, Content = desc, Duration = 3})
    end)
end


local function runRound()
    -- 1) รอจนฟื้นฟู (ถ้าตายอยู่ ไม่ต้องทำอะไรรอบนี้)
    if player:GetAttribute("Dead") then
        waitUntil(function() return not player:GetAttribute("Dead") end, 30)
        return
    end
    -- 2) รอตัวละครพร้อม
    if not waitUntil(function() return getHRP() ~= nil end, 15) then return end

    -- 3) เคลียร์สเตจเก่าก่อนเข้าใหม่
    --    ExitFight ล้าง EnemyTab ของทุกสเตจ (StageUtils.lua:186-188)
    --      ถ้าค้างค่าไว้แล้วเข้าสเตจใหม่ EnemyTab จะถูกล้างทับตอน ExitFight
    --      ทำให้ EnemyHitBE ยิงแล้วไม่มีใครรับ = ไม่มีดาเมจเลย
    --    ส่ง skipWarp = true เพราะเราไม่วาร์ปไปไหนแล้ว ไม่ต้องโดนลากกลับจุดเกิด
    if player:GetAttribute("IntoFight") then
        exitFight(true, true)
        task.wait(1.5)
    end

    -- 4) เข้าสเตจ (ตั้ง attribute อย่างเดียว ไม่วาร์ป)
    enterStage(selectedStage)

    -- 5) รอมอนเกิด (สูงสุด 10 วิ)
    --    ถ้าไม่มีมอนเกิด = สเตจนี้เล่นไม่ได้ เช่น ยังไม่ปลดล็อก
    --    (CreateStageEnemys จะเตือน "缺少敌人点位" แล้ว return ถ้าไม่มี EnemyPoint)
    if not waitUntil(function() return countEnemies() > 0 end, 10) then
        if player:GetAttribute("IntoFight") then
            exitFight(false, true)
        end
        task.wait(2)
        return
    end

    -- 6) ฆ่ามอนวนจนของเริ่มตก = สเตจจบแล้ว
    --    ยิงจากไหนก็ได้ EnemyHitBE ไม่เช็คระยะ (ดูหัว runRound)
    --    ต้องยิงไปเรื่อย ๆ ไม่ใช่ยิงรอบเดียว เพราะ FinishStage
    --    จะสร้างของต่อเมื่อทุกตัวใน EnemyTab ตายครบเท่านั้น
    --    (ยิงครั้งเดียวแล้วไปรอของ = ค้างจน timeout เพราะมอนที่เหลือยังไม่ตาย)
    --    timeout 60 วิ เผื่อเซิร์ฟเวอร์ไม่ยอมให้ของ (StageUtils.FinishStage
    --    จะค้างที่ repeat task.wait() until FinishedOreTab ถ้าเซิร์ฟไม่ตอบ)
    local done, waited = false, 0
    local TIMEOUT = 60
    while running and waited < TIMEOUT do
        killAllEnemies()
        if stageDone() then
            done = true
            break
        end
        task.wait(0.2)
        waited = waited + 0.2
    end

    if not done then
        -- หมดเวลาแล้วของยังไม่ตก = เซิร์ฟเวอร์ไม่ยอมให้ของ หรือ EnemyTab ถูกล้างจนยิงไม่เข้า
        if player:GetAttribute("IntoFight") then
            exitFight(false, true)
        end
        task.wait(2)
        return
    end

    -- 7) เก็บของ: ดึงมอนที่ตกมาวางข้างตัว แล้วกด prompt เอง เรียงจากราคาแพงสุดก่อน
    --    ไม่ต้องวาร์ปไปหาของ เพราะโมดเดลใน OreCache ย้ายไปวางที่ไหนก็ได้
    local picked = collectOres()
    task.wait(0.3)

    if picked == 0 and collectWarnMsg then
        notify("เก็บของไม่ได้", collectWarnMsg)
        collectWarned = false
        collectWarnMsg = nil
    end

    -- 8) ออกจากสเตจ -> ExitFight ยิง ClaimedAllOreRE ให้เซิร์ฟเวอร์
    --    แล้วล้างของที่เหลือทิ้ง (StageUtils.lua:189-197)
    --    ของที่เก็บเองไม่ทันจะถูก ClaimedAllOreRE เก็บให้ทั้งหมด
    --    skipWarp = true เพราะเราไม่วาร์ปไปไหน ไม่ต้องโดนลากกลับจุดเกิด
    if player:GetAttribute("IntoFight") then
        exitFight(true, true)
    end

    -- 9) หน่วง 1 วิ ก่อนเริ่มรอบใหม่
    task.wait(1)
end

local function farmLoop()
    while running do
        runRound()
        -- กันหลุดลูกตอนผู้ใช้กดปิดสวิตช์ครั้งแรก (ยังไม่ได้ทำอะไรเลย)
        if running then task.wait(0.5) end
    end
    farmRunning = false
end

local function setRunning(value)
    running = value == true
    if running and not farmRunning then
        farmRunning = true
        task.spawn(farmLoop)
    end
end

-- เปิด/ปิด Auto Train
local function setTrain(value)
    trainEnabled = value == true
    if trainEnabled and not trainRunning then
        trainRunning = true
        task.spawn(trainLoop)
    end
end

-- เปิด/ปิด Auto Rebirth
local function setRebirth(value)
    rebirthEnabled = value == true
    if rebirthEnabled and not rebirthRunning then
        rebirthRunning = true
        task.spawn(rebirthLoop)
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function AutoFarm.register(context)
    local tab = context.Tab
    windUI = context.WindUI
    if not tab then return end

    local names = getStageNames()
    if #names > 0 then
        STAGE_NAMES = names
        if selectedStage == nil or not table.concat(STAGE_NAMES, ","):find(selectedStage, 1, true) then
            selectedStage = STAGE_NAMES[1]
        end
    end

    local display = {}
    for i, name in ipairs(STAGE_NAMES) do
        display[i] = (name:gsub("_", " "))
    end

    local trainSection = tab:Section({Title = "Train", Opened = true})
    if trainSection then
        trainSection:Toggle({Title = "เริ่ม Auto Train", Desc = "ฟาร์ม x100 โดยไม่ต้องไปยืนตรงจุด Train", Value = false, Callback = setTrain})
        trainSection:Toggle({Title = "Auto Rebirth", Desc = "รีเบิร์ธอัตโนมัติเมื่อถึงเกณฑ์", Value = false, Callback = setRebirth})
    end

    local farmSection = tab:Section({Title = "Farm", Opened = true})
    if farmSection then
        farmSection:Dropdown({Title = "เลือก Stage", Desc = "เลือกด่านที่ต้องการฟาร์ม", Options = display, Callback = function(val)
            local idx = 0
            for i, d in ipairs(display) do if d == val then idx = i; break end end
            if idx ~= 0 then selectedStage = STAGE_NAMES[idx] end
        end})
        farmSection:Toggle({Title = "เริ่ม Auto Farm", Desc = "ฟาร์มรอบอัตโนมัติ (ไม่วาร์ปไปหาของ)", Value = false, Callback = setRunning})
    end
end

return AutoFarm
