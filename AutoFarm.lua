-- Version 6.59
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
--   p1 = true  บอกเซิร์ฟเวอร์ว่าออกจากสเตจแล้ว (ClaimedAllOreRE:FireServer)
--   p2 = true  ไม่วาร์ปกลับจุดเกิด
--
--   ตอนออกเกมจะเรียก OreUtils.CleanOres() เสมอ ไม่ว่า p1 จะเป็นอะไร
--     ซึ่ง (1) ลบแร่ที่ยังอยู่บนพื้น และ (2) รีเซ็ตจำนวนช่องที่ใช้เป็น 0
--       (StageUtils.lua:157  OreUtils.lua:95-98  LeftInfoGUI.UpdateOrePack(0))
--     = กระเป๋าว่าง พร้อมรับของรอบถัดไป
--   ของที่ตกลงพื้นต้องเก็บเองด้วย collectOres ให้เสร็จก่อน
--     เพราะ CleanOres() มาทันทีหลัง ClaimedAllOreRE แล้วลบสิ่งที่เหลือทิ้ง
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

-- นับเฉพาะมอนที่ยังมีชีวิตอยู่ ไม่นับซากที่ตายแล้วแต่ยังไม่ถูกลบ
--   ตายแล้วเกมตั้ง Model:SetAttribute("Dead", true) แล้วหน่วงลบอีก 3 วินาที
--     (EnemyCTRL.lua:222  Model:SetAttribute("Dead", true)
--      EnemyCTRL.lua:232  task.delay(3, u0.DestroyEnemyData, a1))
--   ถ้านับรวมซากด้วย killWave จะรอค้าง 3 วินาทีทุกรอบมอนเปล่า ๆ
--   นอกจากนี้มอนที่ยังไม่ตายก็ต้องนับ จะได้รู้ว่ารอบมอนจบแล้วหรือยัง
local function countEnemies()
    local folder = getEnemyFolder()
    if not folder then return 0 end
    local count = 0
    for _, enemy in ipairs(folder:GetChildren()) do
        if enemy:IsA("Model") and not enemy:GetAttribute("Dead") then
            count = count + 1
        end
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
        task.wait(0.03)
        waited = waited + 0.03
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
-- ดึงของมาวางข้างตัวละคร (ใช้เป็นทางสำรองเท่านั้น)
-- ============================================
-- ของตกที่จุดที่มอนตาย ซึ่งอยู่ที่ EnemyPoint ของสเตจ ไม่ใช่ที่เรายืน
--   (StageUtils.HurtEnemy:308 เก็บ DeadCF จากจุดตายของมอน)
-- แต่ตัวที่อยู่ใน OreCache เป็นแค่ clone ฝั่ง client ที่เกมสร้างเอง
--   (OreDropUtils.lua:52-56  Model:Clone() -> PivotTo -> Parent = OreCache)
--
-- เดิมใช้วิธีนี้เป็นทางหลัก แต่ไม่จำเป็น เพราะ callback ของเกมไม่เช็คระยะเลย
--   (OreUtils.lua:59-74  ไล่ FlyToPlayer -> PickupOreBE:Fire() -> GetOreRF:InvokeServer(uuid)
--    เอาแค่ UUID ไปขอของ ไม่มีการเทียบตำแหน่งตัวละครที่ไหนเลย)
--   ทางหลักตอนนี้คือ prepPrompt ข้างล่าง ย้ายของแค่เผื่อกรณีที่เอนจินคุมระยะตัวเอง
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
-- ทางจริง ๆ ที่ไม่มีระยะ: เรียก callback ของเกมตรง ๆ ไม่ผ่าน ProximityPrompt เลย
-- ============================================
-- เกมต่อ callback ไว้บน prompt.Triggered ตอนสร้างของทิ้ง
--   (OreDropUtils.lua:104  v2.Triggered:Connect(a1.PPButtonCallback))
-- getconnections(signal) คืน callback ทั้งหมดที่ต่ออยู่กับ signal นั้น
--   เอามาเรียกตรง ๆ = ข้ามระบบ prompt ทั้งระบบ
--   ไม่มีระยะ ไม่มี HoldDuration ไม่มี Enabled ไม่มีอะไรมาตรวจอีก
--   เก็บจากไกลแค่ไหนก็ได้ ไม่ต้องขยับอะไรทั้งสิ้น
local function getTriggerHandlers(signal)
    -- ปกติ executor จะมีเป็น global ตรง ๆ (Synapse / Fluxus / Delta / Solara ฯลฯ)
    --   อ่านแบบเป็น global ปกติ ไม่ใช่ rawget(_G, ...) เพราะบางตัวอยู่ในสภาพแวดล้อมอื่น
    local getter = nil
    if type(getconnections) == "function" then
        getter = getconnections
    end
    if not getter and type(getgenv) == "function" then
        local okG, g = pcall(getgenv)
        if okG and type(g) == "table" then
            if type(g.getconnections) == "function" then
                getter = g.getconnections
            elseif type(g.hook) == "table" and type(g.hook.getconnections) == "function" then
                getter = g.hook.getconnections
            end
        end
    end
    if type(getter) ~= "function" then return nil end

    local ok, conns = pcall(getter, signal)
    if not ok or type(conns) ~= "table" then return nil end

    local out = {}
    for _, c in ipairs(conns) do
        if type(c) == "table" then
            local fn = c.Function or c.f
            if type(fn) == "function" then
                out[#out + 1] = fn
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

-- เรียก callback ทั้งหมดของ prompt -> คืน true ถ้ามีตัวไหนถูกเรียกสำเร็จ
local function fireTriggerHandlers(prompt)
    local signal = prompt.Triggered
    if not signal then return false end
    local handlers = getTriggerHandlers(signal)
    if not handlers then return false end
    local called = false
    for _, fn in ipairs(handlers) do
        if pcall(fn) then called = true end
    end
    return called
end

-- ============================================
-- ขยายระยะ prompt (ทางสำรอง สำหรับ executor ที่ไม่มี getconnections)
-- ============================================
-- callback ของเกมไม่เช็คระยะเลย เอาแค่ UUID ไปขอของ
--   (OreUtils.lua:59-74  LeftInfoGUI.GetOrePack -> FlyToPlayer -> PickupOreBE:Fire()
--    -> GetOreRF:InvokeServer(uuid))
-- ตัวเดียวที่ต้องผ่านคือ "prompt ยังถือว่า active อยู่ไหม"
--   ซึ่งเอนจินวัดจาก MaxActivationDistance (ค่าปริยาย 10)
--   เกมตั้งแค่ MaxIndicatorDistance = 10 และ HoldDuration = 0.5
--     (OreDropUtils.lua:98-103)  ไม่ได้แตะ MaxActivationDistance เลย
--
-- ดังนั้นแค่ดันค่าพวกนี้ขึ้นไป = prompt ยิงได้จากที่เรายืนอยู่ตรง ๆ
--   ไม่ต้องย้ายโมดเดลแร่ ไม่ต้องวาร์ป ไม่มีอะไรขยับเลย
--   (Roblox จะตัดค่าให้เหลือเท่าที่อนุญาตเอง ไม่ error)
local PROMPT_MAX_RANGE = 9999

local function prepPrompt(prompt)
    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt.MaxActivationDistance = PROMPT_MAX_RANGE
        prompt.MaxIndicatorDistance = PROMPT_MAX_RANGE
    end)
end

-- สัญญาณว่าเกมรับของแล้ว = จำนวนในกระเป๋าเพิ่มขึ้น
--   ดูจากตรงนี้ ไม่ใช่จากโมดเดลที่หาย เพราะของยังลอยเข้าตัวอยู่
--   (OreDropUtils.lua:128-134  TWScale 0.5 วิ -> SwimFly -> ค่อย DestroyOre ทีหลัง)
--   ถ้ารอจากโมดเดลแล้วเผลอไปทางถัดไป = เรียก callback ซ้ำ = ของเข้ากระเป๋าซ้ำ
local function waitPickup(before, limit)
    local waited = 0
    while waited < limit do
        local count = getPack()
        if count and before and count > before then return true end
        task.wait(0.02)
        waited = waited + 0.02
    end
    return false
end

-- ============================================
-- เก็บของ 1 ชิ้น -> คืน true ถ้าของเข้าตัวจริง
-- ============================================
-- ทางที่ 1 เรียก callback ตรง = ไม่มีระยะเลยจริง ๆ (ทางหลัก)
-- ทางที่ 2-3 ขยายระยะ prompt ให้สุด แล้วกดตามปกติ (สำรอง: executor ไม่มี getconnections)
-- สุดท้ายค่อยดึงของมาวางข้างตัว ถ้าเอนจินบังคับระยะจริง ๆ
local function pickOre(ore)
    local prompt = findOrePrompt(ore)
    if not prompt or not prompt.Enabled then return false end

    -- จำนวนของก่อนยิง ใช้เป็นสัญญาณว่าเข้าตัวสำเร็จ
    local before = select(1, getPack())

    -- ทางที่ 1: เรียก callback ของเกมตรง ๆ ไม่ผ่าน prompt
    if fireTriggerHandlers(prompt) then
        if waitPickup(before, 0.6) then return true end
        -- ยิงไปแล้ว ห้ามยิงซ้ำเด็ดขาด ไม่งั้นของจะเข้ากระเป๋าสองชิ้น
        return waitOreGone(ore, 0.2)
    end

    -- ทางที่ 2: ขยายระยะ prompt ให้สุด แล้วกดตามปกติ
    prepPrompt(prompt)
    firePrompt(prompt)
    if waitPickup(before, 0.5) then return true end

    -- ทางที่ 3: กด prompt เอง (executor บางตัวไม่มี fireproximityprompt)
    prepPrompt(prompt)
    local ok = pcall(function()
        prompt:InputHoldBegin()
        task.wait(0.05)
        prompt:InputHoldEnd()
    end)
    if not ok then
        if not fireError then fireError = "InputHoldBegin" end
    elseif waitPickup(before, 0.6) then
        return true
    end

    -- ทางสำรอง: เอนจินคุมระยะเอง -> ดึงของมาวางข้างตัวแล้วลองอีกครั้ง
    if oreIsNear(ore) then return false end
    pullOreNear(ore)
    prepPrompt(prompt)
    firePrompt(prompt)
    if waitPickup(before, 0.5) then return true end
    return waitOreGone(ore, 0.3)
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

    -- 2) เก็บทีละชิ้นจากแพงสุด
    --    ไม่ต้องดึงของมาก่อนแล้ว (เดิมเป็นขั้นตอนแยก) เพราะ pickOre ขยายระยะ prompt ให้เอง
    --    และย้ายของต่อก็เหลือแค่ทางสำรอง ตอนนี้เกิดแค่กรณีที่เอนจินคุมระยะตัวเอง
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
local TRAIN_EVERY = 0.2

-- ============================================
-- กันภาพเบลอ
-- ============================================
-- ขอแก้ก่อน เพราะเดิมใส่ชื่อ instance ผิดตัว
--   เบลอตอน Auto Train มาจาก Lighting:TrainDOF ไม่ใช่ Lighting:Blur
--     TrainCTRL.StartAutoTrain:139-140  ->  Lighting:WaitForChild("TrainDOF").Enabled = true
--     TrainCTRL.ExitAutoTrain:158-159   ->  TrainDOF.Enabled = false
--   ส่วน Lighting:Blur เป็นของ UIController เปิดตอนเปิดหน้าเมนู ไม่เกี่ยวกับการเทรน
--     (UIController.lua:10-17, 69, 74)
--   ตัว DeepField ชื่อ TrainDOF เป็นตัวเดียวที่เกิดพร้อม Auto Train
--     ทำให้เดิมไล่แค่ Blur/DepthOfField แล้วเลยไม่เคยได้ผล
--
-- วิธีกัน: ไล่ปิดทุกอินสแตนซ์ใน Lighting ที่ทำให้ภาพเบลอ (BlurEffect / DepthOfFieldEffect)
--   ชื่ออะไรก็ได้ ไม่ต้องเดาชื่อ -> ต่อ RenderStepped ค้างไว้ตอนเปิด Auto Train
--   ปิดเมื่อกด Auto Train ออก (ไม่งั้นเมนูของเกมจะไม่เบลอตามปกติ)
--
-- วางไว้ก่อน trainLoop เพราะ Lua มองไม่เห็น local function ที่ประกาศ "หลัง" จุดที่เรียก
--   (ถ้าเรียกก่อนประกาศ จะได้ nil แล้ว error "attempt to call a nil value"
--    ทำให้ task.spawn(trainLoop) ตายทันที = กด Auto Train แล้วไม่เกิดอะไรเลย)
local function clearBlur()
    pcall(function()
        local Lighting = game:GetService("Lighting")
        for _, obj in ipairs(Lighting:GetChildren()) do
            -- ไล่ตามคลาส (ครอบคลุม Blur/DepthOfField ทุกชื่อ รวมถึงตัวที่เกมสร้างใหม่)
            if obj:IsA("BlurEffect") or obj:IsA("DepthOfFieldEffect") then
                if obj.Enabled then
                    obj.Enabled = false
                end
            elseif obj.Name == "TrainDOF" and obj.Enabled then
                -- กันเหนือ: ถ้าวันหนึ่งเกมเปลี่ยนคลาส ไม่ให้หลุด
                obj.Enabled = false
            end
        end
    end)
end

local blurConn = nil

-- ปิดทุกเฟรม ไม่ใช่ทุก 0.2 วินาที
--   เพราะเกมสั่ง TrainDOF.Enabled = true ตอนเปลี่ยนจุดเทรน ซึ่งเกิดพร้อมตัวละครวาร์ป
--   ถ้ารอจนลูปรอบถัดไป ภาพจะเบลอค้างให้เห็นก่อนอย่างน้อย 1 เฟรมถึงหลายเฟรม
local function startBlurGuard()
    if blurConn then return end
    pcall(function()
        local RunService = game:GetService("RunService")
        blurConn = RunService.RenderStepped:Connect(clearBlur)
    end)
    if not blurConn then
        -- สำรอง: บาง executor ต่อ RenderStepped ไม่ได้ ใช้ Heartbeat แทน
        pcall(function()
            local RunService = game:GetService("RunService")
            blurConn = RunService.Heartbeat:Connect(clearBlur)
        end)
    end
    clearBlur()
end

local function stopBlurGuard()
    if not blurConn then return end
    pcall(function() blurConn:Disconnect() end)
    blurConn = nil
end

local function trainLoop()
    while trainEnabled do
        clearBlur()
        if not getHRP() then
            task.wait(1)
        else
            local best = bestTrainArea(getRebirth())
            if best then
                local cur = currentTrainArea()
                if cur ~= best then
                    -- ตั้ง AutoTrainAreaID เฉย ๆ ไม่ต้องวาร์ป
                    --   เกมยังคำนวณตัวคูณตามจุดนั้น แม้ยืนอยู่นอกจุดก็ตาม
                    enterTrainArea(best)
                    currentArea = best
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
-- ปุ่มรีเบิร์ธของเกมเช็คแค่ 2 อย่าง แล้วยิงทันที (GuiUtils/RebirthGUI.lua:82-97)
--   1) Helper.CheckIsMax(Value)              -> ถึงเพดานแล้วไม่ยิง
--   2) Helper.GetNeedLevel(Value + 1) <= level -> ยิง
--     Rebirth/TryRebirthRE:FireServer()   ไม่มีอาร์กิวเมนต์
--   เกณฑ์เลเวล = 25 * ลำดับ  ตรงกับทุกแถวของ Config/Rebirth/Config.lua
--     ไล่จากแถวแรก NeedLevel 0 แล้ว +25 ทีละแถว จนแถวสุดท้าย 1025
--   ค่าที่อ่านมาตรง ๆ ได้คือ LocalPlayer.Eco.level และ LocalPlayer.Eco.rebirth
--     (RebirthGUI.lua:35-37  NumberValue ทั้งคู่ อ่านค่าได้สดโดยไม่ต้องยิง remote)
--
-- เพดาน = 41  ไม่ใช่ 42
--   Config.lua มี 42 แถว (แถวแรกมี [0] ที่เหลือเรียงตามลำดับสุดท้าย NeedLevel 1025)
--     Helper.lua:3  u15 = getTableLegth(Config) - 1 = 42 - 1 = 41
--   CheckIsMax คืน true เมื่อ rebirth == 41 พอดี ช่วงนั้นห้ามยิงอีก
--
-- วิธีทำให้ "ถึงเกณฑ์แล้วรีเบิร์ธทันที"
--   ออกจากสเตจก่อนยิงทุกครั้งที่ถึงเกณฑ์ แล้วยิงเดี๋ยวนั้น
--     เดิมยิงจากในสเตตั้งแต่แรก แล้วค่อยลองออกทีหลังเมื่อยิงไม่ขึ้นหลายครั้ง
--     ผลคือต้องรอเปล่าหลายสิบวินาทีก่อนจะรู้ว่าต้องออกก่อน
--   การออกจากสเตจครั้งเดียวต่อหนึ่งการรีเบิร์ธ ไม่กินเวลาฟาร์ม เพราะเกณฑ์นี้ผ่านบ่อย
--     (ExitFight(false, true) = ออกแบบไม่วาร์ป  StageUtils.lua:143-163)
local MAX_REBIRTH = 41
local NEED_LEVEL_STEP = 25
local REBIRTH_EVERY = 0.5      -- รอบล่าสุดแล้วเช็คเงื่อนไขใหม่
local REBIRTH_WAIT = 0.8      -- รอให้เลขขยับหลังยิง สั้นพอ ไม่งั้นลูปจะค้าง

local function canRebirth()
    local rebirth = getRebirth()
    local level = getLevel()
    if rebirth == nil or level == nil then return false end
    if rebirth >= MAX_REBIRTH then return false end
    return level >= NEED_LEVEL_STEP * (rebirth + 1)
end

-- ออกจากสเตจแล้วรอสัญญาณว่าออกจริง -> คืน true ถ้าออกได้
local function leaveStage(timeout)
    if not player:GetAttribute("IntoFight") then return true end
    exitFight(false, true)
    local waited = 0
    while waited < (timeout or 5) and player:GetAttribute("IntoFight") do
        task.wait(0.02)
        waited = waited + 0.02
    end
    return not player:GetAttribute("IntoFight")
end

local rebirthEnabled = false
local rebirthRunning = false

local function rebirthLoop()
    while rebirthEnabled do
        -- ครอบทั้งรอบไว้ ถ้ามีอะไรพังจะได้ไม่ทำให้ลูปตายค้าง
        --   เดิม error ครั้งเดียวก็ทำให้ coroutine ตาย แล้ว rebirthRunning ค้างเป็น true
        --   ตั้งแต่นั้นสวิตช์จะเปิดลูปใหม่ไม่ได้อีก
        pcall(function()
            if not rebirthEnabled then return end
            if not canRebirth() then return end

            -- ออกจากสเตจก่อน แล้วค่อยยิงทันทีในรอบเดียวกัน
            leaveStage(5)

            local remote = TryRebirthRE or getRemote("Rebirth", "TryRebirthRE")
            if not remote then return end
            TryRebirthRE = remote

            local before = getRebirth()
            pcall(function() remote:FireServer() end)

            -- รอให้เลขขยับจริง กันยิงซ้ำถ้าเซิร์ฟเวอร์ช้า
            local waited = 0
            while waited < REBIRTH_WAIT and getRebirth() == before do
                task.wait(0.05)
                waited = waited + 0.05
            end
        end)
        task.wait(REBIRTH_EVERY)
    end
    -- คืนค่าให้แน่นอนเสมอ ไม่ว่าจะออกจากลูปด้วยเหตุใดก็ตาม
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

-- รอจนสถานะเปลี่ยนจริง แทนการนอนตายตัว
--   ExitFight ตั้ง IntoFight = nil ให้เอง (StageUtils.lua:163) พอได้สัญญาณค่อยเข้าใหม่
--   เดิมนอน 1.5 วิทุกรอบ = เสียเวลาเปล่าตอนที่จริง ๆ ใช้แค่ไม่กี่เฟรม
local function waitOutOfFight(timeout)
    return waitUntil(function() return not player:GetAttribute("IntoFight") end, timeout or 10, 0.02)
end

-- ============================================
-- กันจอซูมตอนเข้า-จบสเตจ
-- ============================================
-- ตอนสเตจจบ เกมยิง tween ซูมเข้า 95 แล้ว 2.5 วิหลังซูมกลับมา 70
--   (StageUtils.lua:213-218)
--     CharUtils.SetWalkSpeedPercent(Character, 1.5, 100, "StageFinished")
--     CameraUtils.TWFOV(TweenInfo.new(0.25), 95)
--     task.delay(2.5, function() ... CameraUtils.TWFOV(TweenInfo.new(0.5), 70) end)
--   ตัว tween คือ TweenService:Create(camera, {FieldOfView = v}):Play()
--     (CameraUtils.lua:36-38)
--   ค่าปกติ = 70 (CameraUtils.lua:41  ResetFOV ตั้งกลับเป็น 70)
--
-- tween ถูกสร้างในโมดูลของเกม เราหยุดหรือยกเลิกมันไม่ได้
--   วิธีเดียวคือเขียนค่ากลับทุกเฟรมให้ทัน
--   ผูกไว้ที่ priority สูงสุด = รันหลัง tween ของเกม เลยเห็นเป็น 70 ตลอด
local DEFAULT_FOV = 70
local fovLocked = false

local function lockFov()
    if fovLocked then return end
    fovLocked = true
    local RunService = game:GetService("RunService")
    RunService:BindToRenderStep("SugarNoFov", 9999, function()
        local cam = workspace.CurrentCamera
        if cam and cam.FieldOfView ~= DEFAULT_FOV then
            cam.FieldOfView = DEFAULT_FOV
        end
    end)
end

-- ============================================
-- ฆ่ามอนให้หมดทั้งเซต แล้วเก็บของ
-- ============================================
-- ยิงทุกเฟรม ไม่ใช่ทุก 0.2 วิ เพราะมอนเลือดโตแบบทวีคูณ
--   ยิงช้ากว่านี้คือเสียเวลาในช่วงที่ต้องรอมอนตาย (ดูหัว killAllEnemies)
-- รอบนี้จบเมื่อมอนหมดจากโฟลเดอร์ 2 เฟรมติด หรือมีของตกแล้ว
--   ไม่ใช่ "รอของตก" ล้วน ๆ เพราะถ้าเซิร์ฟเวอร์ไม่ยอมให้ของ จะค้างจนหมดเวลาทุกรอบ
-- ซากมอนที่ตายแล้วไม่ถูกนับ เพราะเกมหน่วงลบอีก 3 วินาที (ดูหัว countEnemies)
local function killStageEnemies(limit)
    local mark = os.clock()
    local empty = 0
    while running do
        local alive = countEnemies()
        if alive > 0 then
            empty = 0
            killAllEnemies()
        else
            empty = empty + 1
            if empty >= 2 or stageDone() then return true end
        end
        if os.clock() - mark > limit then return false end
        task.wait()  -- ครั้งละเฟรม
    end
    return false
end

local function runRound()
    -- 1) รอจนฟื้นฟู (ถ้าตายอยู่ ไม่ต้องทำอะไรรอบนี้)
    clearBlur()
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
        exitFight(false, true)
        if not waitOutOfFight(10) then return end
    end

    -- 4) เข้าสเตจ (ตั้ง attribute อย่างเดียว ไม่วาร์ป)
    --    StageManager ฟังแค่ attribute "StageID" เปลี่ยน (StageManager.client.lua:67)
    --    ตั้งเป็น nil ก่อนเสมอ ไม่งั้น Roblox ไม่ยิง signal = ไม่เกิด StartFight
    enterStage(selectedStage)

    -- 5) รอมอนเกิด (สูงสุด 10 วิ)
    --    ถ้าไม่มีมอนเกิด = สเตจนี้เล่นไม่ได้ เช่น ยังไม่ปลดล็อก
    --    (CreateStageEnemys จะเตือน "缺少敌人点位" แล้ว return ถ้าไม่มี EnemyPoint)
    if not waitUntil(function() return countEnemies() > 0 end, 10, 0.01) then
        if player:GetAttribute("IntoFight") then
            exitFight(false, true)
            waitOutOfFight(10)
        end
        return
    end

    -- 6) ฆ่ามอนทั้งเซตจนหมด
    --    ต้องยิงไปเรื่อย ๆ ไม่ใช่ยิงรอบเดียว เพราะ FinishStage
    --    จะสร้างของต่อเมื่อทุกตัวใน EnemyTab ตายครบเท่านั้น
    --    timeout 30 วิ เผื่อ EnemyTab ถูกล้างจนยิงไม่เข้า
    if not killStageEnemies(30) then
        if player:GetAttribute("IntoFight") then
            exitFight(false, true)
            waitOutOfFight(10)
        end
        return
    end

    -- ของยังไม่ตกทันทีที่มอนตาย
    --   FinishStage รอคำตอบจากเซิร์ฟเวอร์ก่อนค่อยสร้างของทิ้งพื้น
    --     (StageUtils.lua:206-208  repeat task.wait() until FinishedOreTab
    --      StageUtils.lua:212      OreUtils.CreateOres)
    --   ถ้าไม่รอ จะไปเก็บตอนที่ยังไม่มีของเลย = เสียของทั้งรอบนั้น
    waitUntil(function() return stageDone() end, 3, 0.02)

    -- 7) เก็บของทุกชิ้นด้วยตัวเองก่อนเสมอ
    --    ของเข้ากระเป๋าทันทีที่กดปุ่ม Collect ไม่มีขั้นตอนยืนยันทีหลัง
    --      (OreUtils.lua:69  u70:InvokeServer(i)  = GetOreRF เข้ากระเป๋าเลย)
    --    และเก็บได้แค่ทีละจำนวนช่องที่อัป OrePack ไว้ ถ้าช่องเต็มเกมจะไม่เก็บให้
    --      (OreUtils.lua:60-62  if GetMaxNum("OrePack") <= v1 then showMessage("Pack is full.") return end)
    local picked = collectOres()
    if picked == 0 and collectWarnMsg and not collectWarned then
        notify("เก็บของไม่ได้", collectWarnMsg)
    end

    -- 8) บอกเซิร์ฟเวอร์ว่า "กลับมาแล้ว" แล้วเข้าสเตจใหม่ในรอบถัดไป
    --    ส่ง claimOres = true คือยิง Stage.ClaimedAllOreRE ให้เซิร์ฟเวอร์รู้ว่ารอบนี้จบแล้ว
    --      (StageUtils.lua:154-156  if a1 then u131:FireServer() end)
    --    ExitFight จะเรียก OreUtils.CleanOres() ต่อทันที ซึ่งรีเซ็ตจำนวนช่องที่ใช้เป็น 0
    --      (OreUtils.lua:95-98  CleanOres -> LeftInfoGUI.UpdateOrePack(0))
    --    = กระเป๋าว่างพอจะเก็บของรอบถัดไป
    --    ต้องเก็บของให้เสร็จก่อนยิง ไม่งั้นของที่ยังอยู่บนพื้นจะโดน CleanOres ทิ้ง
    --    skipWarp = true เพราะเราไม่วาร์ปไปไหน ไม่ต้องโดนลากกลับจุดเกิด
    if player:GetAttribute("IntoFight") then
        exitFight(true, true)
        waitOutOfFight(10)
    end
end

local function farmLoop()
    while running do
        clearBlur()
        -- ไม่หน่วงท้ายรอบ runRound จบที่การออกจากสเตจแล้ว
        --   ซึ่งรอสัญญาณ IntoFight = nil จริง ๆ อยู่ข้างใน (ดู waitOutOfFight)
        --   หน่วงเพิ่มตรงนี้คือเสียเวลาเปล่าเปลี่ยวรอบถัดไปช้าลงเท่านั้น
        runRound()
    end
    farmRunning = false
end

local function setRunning(value)
    running = value == true
    if running then
        if not farmRunning then
            farmRunning = true
            task.spawn(farmLoop)
        end
    else
        farmRunning = false
    end
end

-- เปิด/ปิด Auto Train
local function setTrain(value)
    trainEnabled = value == true
    if trainEnabled then
        if not trainRunning then
            trainRunning = true
            -- ค้างกันเบลอไว้ตลอดช่วงที่ Auto Train เปิดอยู่
            startBlurGuard()
            pcall(function() notify("Auto Train เริ่มทำงาน", "จะใช้จุดเทรนที่ดีที่สุด") end)
            task.spawn(trainLoop)
        end
    else
        trainRunning = false
        stopBlurGuard()
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

    -- กันจอซูมเข้าออกตอนเข้า-จบสเตจ ตั้งครั้งเดียวตลอดอายุโมดูล
    lockFov()

    local trainSection = tab:Section({Title = "Train", Opened = true})
    if trainSection then
        trainSection:Toggle({Title = "เริ่ม Auto Train", Desc = "ฟาร์ม x100 โดยไม่ต้องไปยืนตรงจุด Train", Value = false, Callback = setTrain})
        trainSection:Toggle({Title = "Auto Rebirth", Desc = "รีเบิร์ธอัตโนมัติเมื่อถึงเกณฑ์", Value = false, Callback = setRebirth})
    end

    local farmSection = tab:Section({Title = "Farm", Opened = true})
    if farmSection then
        farmSection:Dropdown({
            Title = "เลือก Stage",
            Desc = "เลือกด่านที่ต้องการฟาร์ม",
            Values = display,
            Value = 1,
            Callback = function(val)
                local idx = 0
                for i, d in ipairs(display) do
                    if d == val then
                        idx = i
                        break
                    end
                end
                if idx ~= 0 then
                    selectedStage = STAGE_NAMES[idx]
                end
            end,
        })
        farmSection:Toggle({Title = "เริ่ม Auto Farm", Desc = "ฟาร์มรอบอัตโนมัติ (ไม่วาร์ปไปหาของ)", Value = false, Callback = setRunning})
    end

end

return AutoFarm
