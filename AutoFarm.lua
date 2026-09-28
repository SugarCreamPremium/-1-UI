-- Version 12.32
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
                EnemyHitBE:Fire(enemy.Name, damage, {
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
-- วิธียิง: :Fire() เหมือนที่ Infinite Yield ใช้ และใช้วิธีนี้อย่างเดียว
--   ไม่มี fallback เป็น InputHoldBegin ถ้าเรียกไม่ได้จะพิมพ์ error ออกมาให้เห็น
--   แทนที่จะสลับไปเรียกวิธีอื่นเงียบ ๆ แล้วเข้าใจผิดว่า Fire ใช้ได้
local promptMethod = "Fire"
local fireError = nil

local function firePrompt(prompt)
    local ok, err = pcall(function() prompt:Fire() end)
    if not ok and not fireError then
        -- พิมพ์ครั้งเดียว ไม่ต้องรกทุกชิ้น
        fireError = tostring(err)
        print("[Auto Farm] prompt:Fire() ใช้ไม่ได้ -> " .. fireError)
    end
    return ok
end

-- ยิงแล้วรอจนกว่าเกมจะรับ -> คืน true ถ้าได้ของ
-- สัญญาณว่าเกมรับแล้ว: prompt ถูกปิด (เกมสั่งใน FlyToPlayer) หรือโมเดลถูกทำลาย
--   (OreDropUtils.lua:157-159) ถ้ากระเป๋าเต็ม prompt จะยัง Enabled เพราะ callback
--   ของเกม return ออกก่อน -> ใช้สัญญาณนี้แทนการอ่าน HUD ได้เลย
local function fireAndWait(prompt, ore)
    firePrompt(prompt)
    -- callback ของเกมยังต้องทำงานจนเสร็จ จึงต้องรอสัญญาณ ไม่ใช่ยิงทิ้งเลย
    if not prompt.Enabled or not ore.Parent then return true end

    local waited = 0
    while waited < 1.5 do
        task.wait(0.1)
        waited = waited + 0.1
        if not prompt.Enabled or not ore.Parent then return true end
    end
    return false
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
-- สัญญาณว่าเกมรับของแล้ว: FlyToPlayer สั่ง prompt.Enabled = false ทันทีที่ถูกเก็บ
--   (OreDropUtils.lua:157-159) ส่วนตัวโมเดลถูกทำลายหลังจากนั้นอีก 3 วิตอนลอยเข้าตัว
--   ถ้ากระเป๋าเต็ม prompt จะยัง Enabled อยู่ เพราะ callback ของเกม return ออกก่อน
--   -> ใช้สัญญาณนี้แทนการอ่าน HUD ได้เลย ไม่ต้องพึ่งขนาดกระเป๋า
local function collectOres()
    local cache = getOreCache()
    if not cache then return 0, 0 end

    -- 1) รวบรวมแร่ที่ตกอยู่ แล้วเรียงจากราคาแพงสุดไปถูกสุด
    --    ของที่ไม่ใช่แร่ (เช่นก้อนเสริม) ชื่อไม่ตรง Ore_ตัวเลข -> ข้ามไป
    --    เพราะมันถูกเกมดูดเข้าตัวเองอยู่แล้วใน 1.2 วิ (OreUtils.lua:89-99)
    local ores = {}
    for _, model in ipairs(cache:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^Ore_%d+$") then
            ores[#ores + 1] = model
        end
    end
    if #ores == 0 then return 0, 0 end

    table.sort(ores, function(a, b)
        return getOrePrice(a.Name) > getOrePrice(b.Name)
    end)

    -- 2) เก็บทีละชิ้นจากแพงสุด หยุดทันทีที่กระเป๋าเต็ม
    --    ถ้ากระเป๋าพอทั้งหมดจะเก็บครบทุกชิ้นเท่ากัน
    local taken, noPrompt = 0, 0
    local loggedPath = false
    for _, ore in ipairs(ores) do
        local prompt = findOrePrompt(ore)
        if not prompt then
            noPrompt = noPrompt + 1
        elseif prompt.Enabled then
            -- พิสูจน์ path จริงที่หาเจอ ครั้งเดียวต่อรอบ
            if not loggedPath then
                loggedPath = true
                print("[Auto Farm] path: " .. prompt:GetFullName())
            end
            if fireAndWait(prompt, ore) then
                taken = taken + 1
            end
            if fireError then
                -- Fire ใช้ไม่ได้ = วิธีเดียวที่สั่งให้ใช้ ไม่ต้องรอ 1.5 วิ ให้ครบทุกชิ้นแล้ว
                -- ตัวนับ taken ข้างบนคือผลจริง ปล่อยให้รอบนี้จบเร็วแล้วไปรอบต่อไป
                break
            end
        end
    end
    if noPrompt > 0 then
        print("[Auto Farm] หา ProximityPrompt ไม่เจอ " .. noPrompt .. " ชิ้น")
    end
    if fireError then
        print("[Auto Farm] :Fire() ไม่มีเมธอดนี้บน ProximityPrompt -> ไม่มีทางเก็บของ")
    else
        print("[Auto Farm] ยิง ProximityPrompt ด้วย :" .. promptMethod .. "() ได้ผล")
    end
    return taken, #ores
end

-- ============================================
-- ลูปหลัก
-- ============================================
local running = false
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
local function runRound()
    local function log(msg)
        print("[Auto Farm] " .. msg)
    end

    -- 1) รอจนฟื้นฟู (ถ้าตายอยู่ ไม่ต้องทำอะไรรอบนี้)
    if player:GetAttribute("Dead") then
        waitUntil(function() return not player:GetAttribute("Dead") end, 30)
        return
    end
    -- 2) รอตัวละครพร้อม
    if not waitUntil(function() return getHRP() ~= nil end, 15) then return end

    -- 3) เคลียร์สเตจเก่าก่อนวาร์ป
    --    ExitFight ล้าง EnemyTab ของทุกสเตจ (StageUtils.lua:186-188)
    --      ถ้าค้างค่าไว้แล้วเข้าสเตจใหม่ EnemyTab จะถูกล้างทับตอน ExitFight
    --      ทำให้ EnemyHitBE ยิงแล้วไม่มีใครรับ = ไม่มีดาเมจเลย
    --    ส่ง skipWarp = true เพื่อไม่ให้โดนวาร์ปกลับจุดเกิดตรงนี้
    --    เพราะเรากำลังจะวาร์ปไปสเตจอยู่ดี
    if player:GetAttribute("IntoFight") then
        log("ออกจากสเตจเดิมก่อน")
        exitFight(true, true)
        task.wait(1.5)
    end

    -- 4) วาร์ปไปที่สเตจที่เลือก
    if not warpToStage(selectedStage) then
        log("วาร์ปไม่ได้ (แมปยังไม่โหลด?) -> รอ 1 วิ")
        task.wait(1)
    end
    task.wait(0.4)
    log("วาร์ปไป " .. tostring(selectedStage))

    -- 5) เข้าสเตจ
    enterStage(selectedStage)

    -- 6) รอมอนเกิด (สูงสุด 10 วิ)
    --    ถ้าไม่มีมอนเกิด = สเตจนี้เล่นไม่ได้ เช่น ยังไม่ปลดล็อก
    --    (CreateStageEnemys จะเตือน "缺少敌人点位" แล้ว return ถ้าไม่มี EnemyPoint)
    if not waitUntil(function() return countEnemies() > 0 end, 10) then
        log("ไม่มีมอนเกิดที่ " .. tostring(selectedStage) .. " (ยังไม่ปลด หรือชื่อผิด?)")
        if player:GetAttribute("IntoFight") then
            exitFight(false, true)
        end
        task.wait(2)
        return
    end
    log("มอนเกิด " .. countEnemies() .. " ตัว")

    -- 7) ฆ่ามอนวนจนของเริ่มตก = สเตจจบแล้ว
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
        -- hit == 0 = มอนตายแล้วแต่ของไม่ตก = เซิร์ฟเวอร์ไม่ยอมให้ของ
        -- hit > 0  = ยิงไม่เข้า = EnemyTab ถูกล้าง หรือ UUID ไม่ตรง
        log("ฆ่าไม่จบ (ยิงไป " .. hit .. " ครั้ง) ของไม่ตก")
        if player:GetAttribute("IntoFight") then
            exitFight(false, false)
        end
        task.wait(2)
        return
    end
    log("ฆ่าครบ (ยิง " .. hit .. " ครั้ง) ของตกแล้ว")

    -- 8) เก็บของ: แพงสุดก่อน จนกว่ากระเป๋าจะเต็ม (หรือเก็บครบถ้าพอ)
    local taken, total = collectOres()
    log("เก็บของได้ " .. taken .. " / " .. total .. " ชิ้น")
    task.wait(0.5)

    -- 9) ออกจากสเตจ -> ExitFight เก็บของที่เหลือให้เอง แล้ววาร์ปกลับจุดเกิด
    --    (StageUtils.lua:189-197: ClaimedAllOreRE:FireServer -> CleanOres -> ToSpawn)
    if player:GetAttribute("IntoFight") then
        exitFight(true, false)
    end
    log("กลับจุดเกิดแล้ว")

    -- 10) หน่วง 3 วิ ก่อนเริ่มรอบใหม่
    task.wait(3)
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
        Desc = "เลือกสเตจ -> เปิดสวิตช์ -> ตัวละครจะวาร์ปไปที่สเตจ ฆ่ามอนให้ครบ "
            .. "เก็บแร่จากอันแพงสุดไปจนกระเป๋าเต็ม แล้วกลับจุดเกิดวนต่อ",
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
end

return AutoFarm
