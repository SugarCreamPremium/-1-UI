-- Version 10.38
-- แถบคราฟ (Forge)
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   Forge.ForgeRF:InvokeServer({ConfigType, UUIDList})
--     ConfigType = "Weapon" หรือ "Armor" เท่านั้น  หมวกอยู่ในฝั่ง Armor
--     UUIDList   = {[oreUUID] = จำนวน}  ต้องมีแร่รวม >= 4 ชิ้น
--     คืนค่า     = {ชิ้นที่ได้, BigType}   ชิ้นแรกมี .ID กับ .Type (ไม่มี UUID)
--       (GuiUtils/ForgeGUI.lua:147-148  ยิงแล้วส่งให้ PlayForgeAnim)
--       (Utils/ForgeUtils.lua:20-26  คืน v6, v7 = GetBigType(v6))
--
--   จำนวนแร่ที่ใส่ ไม่ได้มีแค่ขั้นต่ำ 4 แต่มันคือ "สวิตช์เลือกชนิดของที่จะได้"
--     Config/Weapon/ForgePercent.lua  มี index 4..13   (4=คัทานา 100%, 13=เกรท 100%)
--     Config/Armor/ForgePercent.lua   มี index 4..23   (4=หมวกไลท์ 100%, 23=เกราะเฮฟ์ 100%)
--     เกิน index สูงสุดแล้วเซิร์ฟเวอร์ clamp ที่ขีดสุดท้าย ใส่เพิ่มก็เปล่าประโยชน์
--       (Config/Weapon/Helper.lua:112-121  GetForgePercentByNumber เลยมี if u31 < a1 then a1 = u31)
--
--   เลยเลือกจำนวนเป๊ะกับที่ให้ได้ของดีสุดของแต่ละสาย
--     หมวก  4 แร่  -> Hat_Light 100%  -> ของดีสุดคือ LHat_16
--     อาวุธ 13 แร่ -> Great 100%      -> ของดีสุดคือ G_26
--     เกราะ 23 แร่ -> Armor_Heave 100%-> ของดีสุดคือ HArmor_14
--
--   ยิ่งแร่เก่ดียิ่งได้ของเลเวลสูง
--     Utils/ForgeUtils.lua:170-229  GetForgeOreResult
--       v7 = Qualityเฉลี่ย + (Rarity - 1) * 0.25   แล้วแปลงเป็นเลเวล 1..4
--       v9 = กลุ่มของ Rarity  {1,2}=1 {3,4}=2 {5,6,7,8}=3 {9,10}=4
--       ช่วงที่คราฟได้ = min(v7,v9) .. max(v7,v9)   TLevel ของชิ้นที่ได้ต้องอยู่ในช่วงนี้
--     ถ้าใส่แร่ชนิดเดียว Rarity จะถูกหยิบมาแบบสุ่มไม่ได้อีก -> ได้เลเวลเดิมทุกครั้ง คาดเดาได้
--     และแร่ที่เป็นชนิดเดียวกันยังทำให้ค่าเฉลี่ยสูงสุดอีกด้วย
--       (ค่าเฉลี่ยคือศูนย์กลางของการสุ่มแบบ gauss ใน GetEquipmentWeightTable)
local Forge = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- ============================================
-- ดึง remote โดยไม่ต้อง require
-- ============================================
-- ห้าม require(CommunicationUtils / BackpackData / ProfileData) เด็ดขาด
--   executor ที่ require ModuleScript จะได้ตารางที่ไม่มี member
local function getRemote(folderName, remoteName)
    local root = ReplicatedStorage:FindFirstChild("Remote")
    if not root then return nil end
    local folder = root:FindFirstChild(folderName)
    if not folder then return nil end
    return folder:FindFirstChild(remoteName)
end

local ForgeRF = getRemote("Forge", "ForgeRF")
local EquipRE = getRemote("Backpack", "TryEquipItemRE")
local GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
local UpdateDataRE = getRemote("Profile", "UpdateDataRE")

-- โฟลเดอร์ Remote อาจยังไม่ทันมาตอนสคริปต์รัน ดึงใหม่ได้ถ้ายังไม่มี
local function refreshRemotes()
    ForgeRF = ForgeRF or getRemote("Forge", "ForgeRF")
    EquipRE = EquipRE or getRemote("Backpack", "TryEquipItemRE")
    GetTotalDataRF = GetTotalDataRF or getRemote("Profile", "GetTotalDataRF")
    UpdateDataRE = UpdateDataRE or getRemote("Profile", "UpdateDataRE")
end

-- ============================================
-- ตารางตัวเลขที่ต้องคัดมาเอง (require Config ไม่ได้)
-- ============================================
-- ตารางทั้งสามคัดจาก Dump/Game/ReplicatedStorage/Config
-- ตัวเลขตรงเป๊ะ แก้ตารางตรงนี้ถ้าเกมอัปเวอร์ชันใหม่เพิ่มไอเทม

-- แร่: ID -> {Rarity, Quality, Power, เลเวลต่ำสุดที่คราฟได้}
--   เลเวลต่ำสุด = max(เลเวลจาก Quality, กลุ่มของ Rarity)
--   (คำนวณตาม GetForgeOreResult ใน Utils/ForgeUtils.lua:170-229)

local ORE = {
    ["Ore_1"] = {1, 1, 1.2, 1},
    ["Ore_2"] = {1, 2, 1.5, 1},
    ["Ore_3"] = {1, 2, 2, 1},
    ["Ore_4"] = {2, 4, 2.6, 2},
    ["Ore_5"] = {2, 4, 3.4, 2},
    ["Ore_6"] = {2, 4, 4, 2},
    ["Ore_7"] = {3, 4, 5, 3},
    ["Ore_8"] = {3, 4, 6, 3},
    ["Ore_9"] = {3, 4, 7, 3},
    ["Ore_10"] = {4, 3.8, 8, 3},
    ["Ore_11"] = {4, 3.8, 10, 3},
    ["Ore_12"] = {4, 3.8, 12, 3},
    ["Ore_13"] = {4, 4, 11, 3},
    ["Ore_14"] = {5, 4, 12, 3},
    ["Ore_15"] = {5, 4, 13, 3},
    ["Ore_16"] = {5, 4, 19, 3},
    ["Ore_17"] = {5, 4, 20, 3},
    ["Ore_18"] = {5, 5, 23, 4},
    ["Ore_19"] = {5, 5, 25, 4},
    ["Ore_20"] = {6, 5, 27, 4},
    ["Ore_21"] = {6, 5, 30, 4},
    ["Ore_22"] = {6, 6, 31, 4},
    ["Ore_23"] = {6, 7, 35, 4},
    ["Ore_24"] = {6, 8, 38, 4},
    ["Ore_25"] = {6, 8, 42, 4},
    ["Ore_26"] = {7, 5, 45, 4},
    ["Ore_27"] = {7, 6, 48, 4},
    ["Ore_28"] = {7, 6, 52, 4},
    ["Ore_29"] = {7, 6, 57, 4},
    ["Ore_30"] = {7, 6, 63, 4},
    ["Ore_31"] = {7, 6, 60, 4},
    ["Ore_32"] = {8, 6, 60, 4},
    ["Ore_33"] = {8, 4, 60, 4},
    ["Ore_34"] = {8, 4, 65, 4},
    ["Ore_35"] = {8, 5, 68, 4},
    ["Ore_36"] = {8, 5, 70, 4},
    ["Ore_37"] = {8, 6, 73, 4},
    ["Ore_38"] = {8, 6, 76, 4},
    ["Ore_39"] = {8, 6, 75, 4},
    ["Ore_40"] = {9, 6, 78, 4},
    ["Ore_41"] = {9, 6, 80, 4},
    ["Ore_42"] = {9, 6, 85, 4},
    ["Ore_43"] = {9, 6, 93, 4},
    ["Ore_44"] = {9, 6, 99, 4},
    ["Ore_45"] = {9, 6, 102, 4},
    ["Ore_46"] = {9, 6, 114, 4},
    ["Ore_47"] = {9, 7, 128, 4},
    ["Ore_48"] = {10, 7, 140, 4},
}

local WEAPON_STAT = {
    ["G_1"] = {2, nil, false},
    ["G_2"] = {6, nil, false},
    ["G_3"] = {15, nil, false},
    ["G_4"] = {36, nil, false},
    ["G_5"] = {59, nil, false},
    ["G_6"] = {148, nil, false},
    ["G_7"] = {354, nil, false},
    ["G_8"] = {590, nil, false},
    ["G_9"] = {1475, nil, false},
    ["G_10"] = {3658, nil, false},
    ["G_11"] = {5900, nil, false},
    ["G_12"] = {14750, nil, false},
    ["G_13"] = {82600, nil, false},
    ["G_14"] = {177000, nil, false},
    ["G_15"] = {354000, nil, false},
    ["G_16"] = {885000, nil, false},
    ["G_17"] = {2218400, nil, false},
    ["G_18"] = {4720000, nil, false},
    ["G_19"] = {11800000, nil, false},
    ["G_20"] = {29500000, nil, false},
    ["G_21"] = {59000000, nil, false},
    ["G_22"] = {118000000, nil, false},
    ["G_23"] = {177000000, nil, false},
    ["G_24"] = {236000000, nil, false},
    ["G_25"] = {472000000, nil, false},
    ["G_26"] = {708000000, nil, false},
    ["G_1001"] = {750, nil, false},
    ["G_1002"] = {2.2, 838400000, true},
    -- G_1003 เป็นของธรรมดา Mythic ไม่ใช่ของดันเจอรี (Config/Weapon/Config.lua:540)
    --   เดิมใส่ค่าของ K_1101 ผิด ทำให้ของจริงที่มี Train แค่ 900,000
    --   ถูกคิดเป็น 708,400,000 = เท่าดาบ G_26 ที่ดีที่สุด ทำให้ของแย่มากแย่งที่จะสวมใส่
    ["G_1003"] = {900000, nil, false},
    ["K_1"] = {1, nil, false},
    ["K_2"] = {5, nil, false},
    ["K_3"] = {12, nil, false},
    ["K_4"] = {30, nil, false},
    ["K_5"] = {50, nil, false},
    ["K_6"] = {125, nil, false},
    ["K_7"] = {300, nil, false},
    ["K_8"] = {500, nil, false},
    ["K_9"] = {1250, nil, false},
    ["K_10"] = {3100, nil, false},
    ["K_11"] = {5000, nil, false},
    ["K_12"] = {12500, nil, false},
    ["K_13"] = {70000, nil, false},
    ["K_14"] = {150000, nil, false},
    ["K_15"] = {300000, nil, false},
    ["K_16"] = {750000, nil, false},
    ["K_17"] = {1880000, nil, false},
    ["K_18"] = {4000000, nil, false},
    ["K_19"] = {10000000, nil, false},
    ["K_20"] = {25000000, nil, false},
    ["K_21"] = {50000000, nil, false},
    ["K_22"] = {100000000, nil, false},
    ["K_23"] = {150000000, nil, false},
    ["K_24"] = {200000000, nil, false},
    ["K_25"] = {400000000, nil, false},
    ["K_26"] = {600000000, nil, false},
    ["K_1001"] = {1.1, 165000, true},
    ["K_1002"] = {1.65, 247500000, true},
    -- K_1101 / G_1101 เป็นของดันเจอรีสายเอกซ์คลูซีฟ เดิมไม่มีในตาราง
    --   itemValue คืน 0 ให้ -> ของแพงที่สุดในเกมกลับไม่มีวันได้ถูกสวมใส่
    --   G_1101 ไม่มีเพดาน คูณค่าฐานที่ดีที่สุดเต็ม 1.95 -> แพงกว่า G_26 เสมอ
    ["K_1101"] = {1.2, 708400000, true},
    ["G_1101"] = {1.95, nil, true},
}

local ARMOR_STAT = {
    ["HHat_1"] = {0.12, nil, false},
    ["HArmor_1"] = {0.06, nil, false},
    ["HHat_2"] = {0.18, nil, false},
    ["HArmor_2"] = {0.07, nil, false},
    ["HHat_3"] = {0.24, nil, false},
    ["HArmor_3"] = {0.08, nil, false},
    ["HHat_4"] = {0.24, nil, false},
    ["HArmor_4"] = {0.12, nil, false},
    ["HHat_5"] = {0.36, nil, false},
    ["HArmor_5"] = {0.17, nil, false},
    ["HHat_6"] = {0.36, nil, false},
    ["HArmor_6"] = {0.24, nil, false},
    ["HHat_7"] = {0.42, nil, false},
    ["HArmor_7"] = {0.3, nil, false},
    ["HHat_8"] = {0.48, nil, false},
    ["HArmor_8"] = {0.36, nil, false},
    ["HHat_9"] = {0.48, nil, false},
    ["HArmor_9"] = {0.43, nil, false},
    ["HHat_10"] = {0.54, nil, false},
    ["HArmor_10"] = {0.49, nil, false},
    ["HHat_11"] = {0.59, nil, false},
    ["HArmor_11"] = {0.54, nil, false},
    ["HHat_12"] = {0.65, nil, false},
    ["HArmor_12"] = {0.59, nil, false},
    ["HHat_13"] = {0.71, nil, false},
    ["HArmor_13"] = {0.65, nil, false},
    ["HHat_14"] = {0.83, nil, false},
    ["HArmor_14"] = {0.7, nil, false},
    ["HHat_1001"] = {1.4, 0.83, true},
    ["HArmor_1001"] = {1.4, 0.83, true},
    ["HHat_1002"] = {2.1, 1.3, true},
    ["HArmor_1002"] = {2.1, 1.3, true},
    ["HHat_1101"] = {1.85, nil, true},
    ["HArmor_1101"] = {1.85, nil, true},
    ["LHat_1"] = {0.1, nil, false},
    ["LArmor_1"] = {0.05, nil, false},
    ["LHat_2"] = {0.15, nil, false},
    ["LArmor_2"] = {0.055, nil, false},
    ["LHat_3"] = {0.2, nil, false},
    ["LArmor_3"] = {0.06, nil, false},
    ["LHat_4"] = {0.2, nil, false},
    ["LArmor_4"] = {0.1, nil, false},
    ["LHat_5"] = {0.3, nil, false},
    ["LArmor_5"] = {0.14, nil, false},
    ["LHat_6"] = {0.3, nil, false},
    ["LArmor_6"] = {0.2, nil, false},
    ["LHat_7"] = {0.35, nil, false},
    ["LArmor_7"] = {0.25, nil, false},
    ["LHat_8"] = {0.4, nil, false},
    ["LArmor_8"] = {0.3, nil, false},
    ["LHat_9"] = {0.4, nil, false},
    ["LArmor_9"] = {0.36, nil, false},
    ["LHat_10"] = {0.45, nil, false},
    ["LArmor_10"] = {0.41, nil, false},
    ["LHat_11"] = {0.5, nil, false},
    ["LArmor_11"] = {0.45, nil, false},
    ["LHat_12"] = {0.55, nil, false},
    ["LArmor_12"] = {0.5, nil, false},
    ["LHat_13"] = {0.6, nil, false},
    ["LArmor_13"] = {0.55, nil, false},
    ["LHat_14"] = {0.7, nil, false},
    ["LArmor_14"] = {0.59, nil, false},
    ["LHat_15"] = {0.75, nil, false},
    ["LArmor_15"] = {0.62, nil, false},
    ["LHat_16"] = {0.85, nil, false},
    ["LArmor_16"] = {0.65, nil, false},
    ["LHat_1101"] = {1.2, 1.45, true},
    ["LArmor_1101"] = {1.2, 1.45, true},
}

-- เลเวลอัปเกรดของชิ้นนั้น -> ตัวคูณที่คูณค่าสถิติ
--   ค่าที่เห็นในเกมคือ ค่าพื้นฐาน * (1 + Boost[เลเวล])
--   (Config/Enhant/Config.lua และ Utils/BalanceUtils.lua:319-326 / :428-435)
local ENHANT_BOOST = {
    [0] = 0, [1] = 0.05, [2] = 0.1, [3] = 0.15, [4] = 0.2, [5] = 0.25, [6] = 0.4, [7] = 0.55,
    [8] = 0.7, [9] = 0.85, [10] = 1, [11] = 1.15, [12] = 1.3, [13] = 1.5, [14] = 1.7, [15] = 1.9,
    [16] = 2.1, [17] = 2.3, [18] = 2.6, [19] = 2.9, [20] = 3.2,
}

-- จำนวนแร่สูงสุดที่คุ้มค่าสำหรับแต่ละเป้าหมาย
--   เอาค่าสูงสุดของ index ใน ForgePercent เป๊ะ ๆ จะได้ของดีสุดของสายนั้น
--   ใส่เกินจากนี้เซิร์ฟเวอร์ clamp ทิ้ง แร่ที่เกินก็เปล่าประโยชน์
local MAX_ORE = {Weapon = 13, Hat = 4, Armor = 23}

-- ยิงคำขอสวมใส่กี่ครั้งถ้าเซิร์ฟเวอร์ยังไม่ตอบรับ
--   FireServer ไม่คืนผล ถ้ายิงทีเดียวแล้วไม่ติด ของดีก็จะค้างไม่ถูกสวมใส่
local EQUIP_TRY = 2

-- ForgeRF เอาแค่สองชนิดนี้  หมวกกับเกราะใช้ตัวเดียวกันแยกกันทีหลังด้วยจำนวนแร่
local CONFIG_TYPE = {Weapon = "Weapon", Hat = "Armor", Armor = "Armor"}

-- ช่องอุปกรณ์ที่สวมใส่ได้ ชื่อเดียวกับช่องใน Backpack.equiped
--   ใช้ไล่สวมใส่ และไล่เป้าหมายการคราฟ (ลำดับตรงนี้คือลำดับที่คราฟ)
local TARGETS = {"Weapon", "Hat", "Armor"}



-- ============================================
-- อ่านข้อมูลโปรไฟล์
-- ============================================
local totalData = nil

-- สัญญาณว่ากระเป๋าเพิ่งเปลี่ยน ใช้รอแทนการนอนตายตัว
--   เวลาคราฟเสร็จ เกมจะยิง UpdateDataRE("Backpack", ...) มา
--   (LocalData/ProfileData.lua:27-37  UpdateDataRE.OnClientEvent -> u26[key] = value)
--   พอได้สัญญาณค่อยไปต่อ = เร็วที่สุดโดยไม่เดา
local packChanged = nil

local function applyStore(data)
    if type(data) ~= "table" then return end
    totalData = data
end

local function refreshData()
    if not GetTotalDataRF then
        GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
    end
    if not GetTotalDataRF then return false end
    local ok, data = pcall(function() return GetTotalDataRF:InvokeServer() end)
    if not ok or type(data) ~= "table" then return false end
    applyStore(data)
    return true
end

-- ต่อ event แค่ครั้งเดียว ไม่ว่าจะมาจากตอนโหลดไฟล์หรือตอน register
local updateConnected = false

local function connectUpdate()
    if updateConnected then return end
    if not UpdateDataRE then return end
    updateConnected = true
    UpdateDataRE.OnClientEvent:Connect(function(key, value)
        if type(value) ~= "table" then return end
        totalData[key] = value
        if key == "Backpack" and packChanged then packChanged() end
    end)
end

connectUpdate()

-- รอให้กระเป๋าอัปเดต แต่ไม่รอนานเกินไป (กันค้างถ้าเกมไม่ยิงมาให้)
local function waitPackChange(timeout)
    local signal
    local done = false
    signal = function() done = true end
    packChanged = signal
    local waited = 0
    local step = 0.05
    while not done and waited < (timeout or 3) do
        task.wait(step)
        waited = waited + step
    end
    packChanged = nil
    return done
end

local function getHave()
    if type(totalData) ~= "table" then return nil end
    local bp = totalData.Backpack
    if type(bp) ~= "table" then return nil end
    if type(bp.have) ~= "table" then return nil end
    return bp.have
end

local function getEquiped()
    if type(totalData) ~= "table" then return nil end
    local bp = totalData.Backpack
    if type(bp) ~= "table" then return nil end
    if type(bp.equiped) ~= "table" then return nil end
    return bp.equiped
end

-- ============================================
-- เลือกแร่
-- ============================================
-- ใช้แร่ชนิดเดียวทั้งชุด และเอาชนิดที่ดีที่สุดที่มี
--   เหตุผลที่ "ชนิดเดียว" สำคัญที่สุด
--     GetForgeOreResult สุ่มเลเวลจากรายการระดับของแร่ที่ใส่ (ForgeUtils.lua:189-193)
--     ถ้ามีแร่หลายชนิด จะสุ่มได้เลเวลที่ต่ำกว่าที่ควร ทำให้คราฟออกของต่ำกว่าจริง
--     ใส่ชนิดเดียว = ได้เลเวลเดิมทุกครั้ง และยังได้ค่าเฉลี่ยสูงสุดอีกด้วย
--
-- จัดอันดับแร่: เลเวลขั้นต่ำ (จาก Quality+Rarity) สูงสุดก่อน แล้วค่อย Power
--   เลขเลเวลในตาราง ORE คือเลเวลขั้นต่ำที่คราฟด้วยแร่ชิ้นนั้น
--   แร่ที่เลเวลขั้นต่ำเท่ากัน ค่า Power ยิ่งสูงยิ่งดี เพราะ Power คือศูนย์กลางของการสุ่ม
local function oreRank(id)
    local st = ORE[id]
    if not st then return nil end
    return st[4] * 1000000 + st[3] * 100 + st[2]
end

-- คืน UUIDList สำหรับ ForgeRF พร้อมจำนวนแร่รวม
local function pickOres(have, target)
    if type(have) ~= "table" then return nil, 0 end

    -- ไล่แร่ทุกกองในกระเป๋า จัดอันดับจากดีไปแย่
    local stacks = {}
    for uuid, entry in pairs(have) do
        if type(entry) == "table" and entry.Type == "Ore" then
            local num = tonumber(entry.Number) or 1
            local rank = oreRank(entry.ID)
            if num > 0 and rank then
                stacks[#stacks + 1] = {uuid = uuid, number = num, rank = rank}
            end
        end
    end
    if #stacks == 0 then return nil, 0 end

    table.sort(stacks, function(a, b) return a.rank > b.rank end)

    local want = MAX_ORE[target] or 4
    local list = {}
    local total = 0

    -- เอาจากกองที่ดีที่สุดก่อน ใช้กองเดียวให้หมดถ้าพอ
    for _, st in ipairs(stacks) do
        if total >= want then break end
        local take = st.number
        if total + take > want then take = want - total end
        if take > 0 then
            list[st.uuid] = take
            total = total + take
        end
    end

    -- กองเดียวไม่พอขั้นต่ำ 4 ชิ้น -> เติมจากกองถัดไปไปจนพอ (ยังเรียงจากดีไปแย่อยู่)
    if total < 4 then
        for _, st in ipairs(stacks) do
            if total >= 4 then break end
            if not list[st.uuid] then
                local take = st.number
                if total + take > 4 then take = 4 - total end
                if take > 0 then
                    list[st.uuid] = take
                    total = total + take
                end
            end
        end
    end

    if total < 4 then return nil, total end
    return list, total
end

-- ============================================
-- คำนวณค่าของจริงตามสูตรของเกม
-- ============================================
-- ไม่ใช้แค่ตัวเลขดิบ เพราะของที่ได้จากดันเจอรีมีตัวคูณพิเศษที่ทำให้แพงกว่าของปกติทันที
--   (Utils/BalanceUtils.lua:305-327  GetWeaponTrainValue / :412-436  GetArmorValue)
--   คืน nil ถ้าเป็นไอเทมที่ไม่มีในตาราง  อย่าคืน 0
--     ถ้าคืน 0 ของที่ไม่รู้จักจะดูเหมือน "แย่ที่สุด" แล้วไปตัดสินใจแทนของจริงได้

-- ค่าฐานของอาวุธที่ดีที่สุดในกระเป๋า (ตัวที่ไม่ใช่ของดันเจอรี)
--   BalanceUtils.lua:148-163  GetBestWeaponValue
local function bestWeaponBase(have)
    local best = 1
    for _, entry in pairs(have) do
        if type(entry) == "table" and entry.Type == "Weapon" then
            local st = WEAPON_STAT[entry.ID]
            if st and not st[3] and st[1] > best then best = st[1] end
        end
    end
    return best
end

-- ค่าฐานของเกราะ/หมวกที่ดีที่สุดในกระเป๋า แยกตามช่อง
--   BalanceUtils.lua:232-248  GetBestArmorValue
local function bestArmorBase(have, slotType)
    local best = 0.1
    for _, entry in pairs(have) do
        if type(entry) == "table" and entry.Type == slotType then
            local st = ARMOR_STAT[entry.ID]
            if st and not st[3] and st[1] > best then best = st[1] end
        end
    end
    return best
end

-- ค่าเกราะ/หมวกที่ใส่อยู่จริง
--   ช่อง Weapon -> พลังโจมตี (Train)
--   ช่อง Hat     -> พลังโจมตีเป็น % (Power)
--   ช่อง Armor   -> กันชนเป็น % (Defence)
local function itemValue(entry, have)
    if type(entry) ~= "table" then return nil end
    local boost = ENHANT_BOOST[tonumber(entry.Level) or 0] or 0

    if entry.Type == "Weapon" then
        local st = WEAPON_STAT[entry.ID]
        if not st then return nil end
        local train = st[1]
        if not st[3] then
            return train * (1 + boost)
        end
        -- ของดันเจอรี: คูณค่าฐานที่ดีที่สุดในกระเป๋า แล้วโดนเพดานไว้ที่ MaxTrain
        local base = bestWeaponBase(have) * train
        if st[2] then base = math.min(base, st[2]) end
        return base * (1 + boost)
    end

    if entry.Type == "Armor" or entry.Type == "Hat" then
        local st = ARMOR_STAT[entry.ID]
        if not st then return nil end
        local attri = st[1]
        if not st[3] then
            return attri * (1 + boost)
        end
        local base = bestArmorBase(have, entry.Type) * attri
        if st[2] then base = math.min(base, st[2]) end
        return base * (1 + boost)
    end

    return nil
end

-- คืน uuid กับ entry ของชิ้นที่ใส่อยู่ในช่องนั้น
--   ช่องที่ใส่ได้คือ Weapon / Armor / Hat  (Backpack.equiped[ช่อง] = uuid)
local function equipedItem(slot)
    local eq = getEquiped()
    if type(eq) ~= "table" then return nil, nil end
    local uuid = eq[slot]
    if type(uuid) ~= "string" then return nil, nil end
    local have = getHave()
    if type(have) ~= "table" then return nil, nil end
    local entry = have[uuid]
    if type(entry) ~= "table" then return nil, nil end
    return uuid, entry
end

-- รอจนกว่าช่องที่ใส่อยู่จะเปลี่ยนเป็น uuid ที่ต้องการจริงๆ
--   FireServer ไม่บอกผล ถ้าเซิร์ฟเวอร์ปฏิเสธ (ของยังไม่ทันซิงก / จังหวะชนกัน) ต้องรอสัญญาณแล้วลองใหม่
local function waitEquiped(slot, uuid, timeout)
    local function landed()
        local eq = getEquiped()
        return type(eq) == "table" and eq[slot] == uuid
    end
    if landed() then return true end

    local done = false
    packChanged = function() done = true end
    local waited = 0
    local step = 0.05
    while not done and waited < (timeout or 1) do
        task.wait(step)
        waited = waited + step
        if landed() then done = true break end
    end
    packChanged = nil
    return done
end

-- ไล่ทั้งกระเป๋า หาชิ้นที่ดีที่สุดของช่องนั้น
--   ไม่ดูแค่ชิ้นที่เพิ่งคราฟได้ เพราะของดีที่สุดของตัวอาจเป็นของที่มีอยู่ก่อนแล้ว
--     เช่นตอนเปิดสวิตช์ครั้งแรก หรือหลังผู้ใช้ถอดของทิ้งเอง
--   preferUuid คือชิ้นที่ใส่อยู่แล้ว ใช้ตัดสินเมื่อค่าเท่ากัน ไม่งั้นจะสลับของฟรีๆ
local function bestInSlot(have, slotType, preferUuid)
    if type(have) ~= "table" then return nil, nil, nil end
    local bestUuid, bestEntry, bestVal = nil, nil, nil
    for uuid, entry in pairs(have) do
        if type(entry) == "table" and entry.Type == slotType then
            local v = itemValue(entry, have)
            -- ของที่ไม่รู้จัก (v = nil) ข้ามไป ไม่ให้มาแย่งเป็นตัวที่ดีที่สุด
            if v and (not bestVal or v > bestVal or (v == bestVal and uuid == preferUuid)) then
                bestVal, bestUuid, bestEntry = v, uuid, entry
            end
        end
    end
    return bestUuid, bestEntry, bestVal
end

-- สวมใส่ชิ้นที่ดีที่สุดของช่องนั้น แล้วรอยืนยันว่าเซิร์ฟเวอร์รับจริง
--   คืน true เมื่อยิงคำขอสวมใส่ออกไปจริง (ไม่รวมกรณีช่องนั้นดีอยู่แล้ว)
local function equipBestSlot(slotType)
    local have = getHave()
    if type(have) ~= "table" then return false end

    local oldUuid, old = equipedItem(slotType)
    local uuid, entry, val = bestInSlot(have, slotType, oldUuid)
    if not uuid then return false end
    if uuid == oldUuid then return false end

    -- ของที่ใส่อยู่คืนค่าไม่ได้ (ID ไม่รู้จัก) ให้ถือว่ามันแย่กว่า แล้วสลับให้
    local oldVal = itemValue(old, have)
    if oldVal and val <= oldVal then return false end

    local remote = EquipRE or getRemote("Backpack", "TryEquipItemRE")
    if not remote then return false end
    EquipRE = remote

    for _ = 1, EQUIP_TRY do
        pcall(function() remote:FireServer(uuid, entry.Type) end)
        if waitEquiped(slotType, uuid, 0.8) then return true end
    end
    return false
end

-- ไล่ทีละช่อง สวมใส่ของที่ดีที่สุดที่มีในกระเป๋าจริงๆ
--   คืนจำนวนช่องที่เพิ่งสั่งสวมใส่
local function equipAllBest()
    local changed = 0
    for _, slot in ipairs(TARGETS) do
        if equipBestSlot(slot) then changed = changed + 1 end
    end
    return changed
end

-- ============================================
-- สถานะของโมดูล
-- ============================================
local forgeEnabled = false
local forgeRunning = false
local forgeEquipBest = true
local forgeTargets = {Weapon = true, Hat = true, Armor = true}

local function anyTargetOn()
    for _, name in ipairs(TARGETS) do
        if forgeTargets[name] then return true end
    end
    return false
end


-- ============================================
-- คราฟหนึ่งครั้ง
-- ============================================
local function forgeOnce(target)
    if not ForgeRF then refreshRemotes() end
    if not ForgeRF then return false end
    if not refreshData() then return false end

    local have = getHave()
    local ores, total = pickOres(have, target)
    if not ores or total < 4 then return false end

    local ok, res = pcall(function()
        return ForgeRF:InvokeServer({ConfigType = CONFIG_TYPE[target], UUIDList = ores})
    end)
    -- ForgeRF คืน {ชิ้นที่ได้, BigType} ชิ้นแรกต้องมี .ID
    --   (GuiUtils/ForgeGUI.lua:706-715 เอา a1[1].ID ไปหาโมเดลใน Assets)
    if not ok or type(res) ~= "table" or type(res[1]) ~= "table" or type(res[1].ID) ~= "string" then
        return false
    end

    -- รอสัญญาณว่ากระเป๋าเปลี่ยนแล้วค่อยไปต่อ แทนการนอนตายตัว
    waitPackChange(3)
    refreshData()

    -- ไล่สวมใส่ของที่ดีที่สุดของทุกช่องจากทั้งกระเป๋า
    --   ไม่ใช่แค่ชิ้นที่เพิ่งคราฟได้ เพราะ ForgeRF ไม่คืน UUID
    --   การเดา UUID จากกระเป๋าเป็นไปได้ว่าจะได้ชิ้นเก่าที่ใส่อยู่แล้ว
    --   แล้วของใหม่ที่เพิ่งได้มาก็ไม่มีวันถูกสวมใส่
    if forgeEquipBest then
        equipAllBest()
    end

    return true
end

-- ============================================
-- วงจรคราฟ
-- ============================================
-- ไล่ทีละเป้าหมายที่เปิดไว้ วนไปเรื่อยๆ ไม่มีคิวรอ ไม่มีการหน่วงเพิ่ม
--   แต่ละเป้าหมายใช้จำนวนแร่คนละแบบกัน จึงไล่ทีละอันไม่ใช่ยิงพร้อมกัน
--   (ยิง ForgeRF ซ้อนกันแล้วเซิร์ฟเวอร์จะปฏิเสธ แล้วแร่ก็หักไปเปล่าๆ)
local function forgeLoop()
    while forgeEnabled do
        local worked = false
        if anyTargetOn() then
            for _, name in ipairs(TARGETS) do
                if not forgeEnabled then break end
                if forgeTargets[name] then
                    local ok, did = pcall(function() return forgeOnce(name) end)
                    if ok then
                        worked = did or worked
                    else
                        task.wait(0.5)
                    end
                end
            end
        end
        -- ไม่มีแร่พอ หรือเซิร์ฟเวอร์ยังไม่พร้อม -> หยุดแป๊บเดียวแล้วลองต่อ
        if not worked then
            task.wait(0.4)
        end
    end
    forgeRunning = false
end

local function setForgeEnabled(value)
    forgeEnabled = value == true
    if forgeEnabled then
        refreshRemotes()
        refreshData()
        -- เปิดสวิตช์ครั้งแรกก็ต้องสวมใส่ของที่ดีที่สุดที่มีอยู่แล้ว ไม่ใช่รอคราฟของใหม่
        if forgeEquipBest then pcall(equipAllBest) end
        if not forgeRunning then
            forgeRunning = true
            task.spawn(forgeLoop)
        end
    end
end

local function setForgeEquipBest(value)
    forgeEquipBest = value == true
    -- เปิดสวมใส่อัตโนมัติตอนนั้นเลย = สวมใส่ของที่ดีที่สุดให้หน่อย ไม่งั้นรอคราฟของใหม่
    if forgeEquipBest and refreshData() then pcall(equipAllBest) end
end

local function setForgeTarget(name, value)
    forgeTargets[name] = value == true
end


-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Forge.register(context)
    local tab = context.Tab
    if not tab then return end

    refreshRemotes()
    connectUpdate()
    refreshData()

    local section = tab:Section({Title = "คราฟอัตโนมัติ", Opened = true})
    if not section then
        tab:Paragraph({Title = "คราฟอัตโนมัติ", Desc = "ไม่สามารถสร้างส่วนควบคุมได้"})
        return
    end

    section:Toggle({
        Title = "Auto Forge",
        Desc = "คราฟไปเรื่อยๆ ตามที่เลือกไว้ข้างล่าง เลือกได้หลายแบบพร้อมกัน",
        Value = false,
        Callback = setForgeEnabled,
    })

    section:Toggle({
        Title = "สวมใส่อุปกรณ์ที่ดีที่สุด",
        Desc = "ไล่ทั้งกระเป๋าทุกครั้งที่คราฟเสร็จ แล้วสวมใส่ของที่ดีที่สุดของแต่ละช่องให้อัตโนมัติ",
        Value = true,
        Callback = setForgeEquipBest,
    })

    section:Divider({Text = "ประเภทที่ต้องการคราฟ"})

    section:Toggle({
        Title = "อาวุธ (Weapon)",
        Desc = "ใช้แร่ 13 ชิ้นในการสร้างอาวุธที่ดีที่สุด",
        Value = true,
        Callback = function(value) setForgeTarget("Weapon", value) end,
    })

    section:Toggle({
        Title = "หมวก (Hat)",
        Desc = "ใช้แร่ 4 ชิ้นในการสร้างหมวกที่ดีที่สุด",
        Value = true,
        Callback = function(value) setForgeTarget("Hat", value) end,
    })

    section:Toggle({
        Title = "เกราะ (Armor)",
        Desc = "ใช้แร่ 23 ชิ้นในการสร้างเกราะที่ดีที่สุด",
        Value = true,
        Callback = function(value) setForgeTarget("Armor", value) end,
    })
end

return Forge
