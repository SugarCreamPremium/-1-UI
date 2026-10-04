-- Version 9.26
-- แถบขายของอัตโนมัติ (ขายเฉพาะอาวุธ/เกราะ/หมวก ไม่ขายแร่)
--
-- กติกาที่ใช้
--   1) ขายเฉพาะอาวุธ/เกราะ/หมวก   แร่และของชนิดอื่นไม่แตะเลย
--   2) ห้ามขายชิ้นที่ดีที่สุด       คำนวณพลังทุกชิ้นก่อน แล้วเก็บชิ้นที่แรงที่สุดของแต่ละช่องไว้เสมอ
--   3) เว้นของที่ใส่อยู่           ของที่ใส่อยู่ขายไม่ได้อยู่แล้ว
--   4) เว้นชิ้นที่แรงกว่าของที่ใส่อยู่  เก็บไว้ให้ผู้ใช้เอาไปเปลี่ยนเอง
--   ที่เหลือ (รวมถึงตัวสำรองของ ID เดียวกัน) -> ขายหมด
--
-- "พลัง" ของชิ้นหนึ่ง คำนวณตามสูตรของเกม ไม่ใช้ราคาขายเป็นตัวตัดสิน
--   อาวุธ      พลัง = Train(ID)    x (1 + Boost(Level))
--   เกราะ/หมวก พลัง = AttriNum(ID) x (1 + Boost(Level))
--     (Utils/BalanceUtils.lua:305-353  GetWeaponTrainValue / GetArmorValue)
--   Level คือระดับตีบวง Enhance อยู่ที่ entry.Level
--   Boost มาจาก Config/Enhant/Config.lua ระดับ 0..20
--
-- ทำไมต้องเทียบพลัง ไม่เทียบราคา
--   ราคากับพลังไม่ได้ไปพร้อมกัน เช่น
--     HHat_3     ราคา     25   AttriNum 0.24
--     HHat_4     ราคา     95   AttriNum 0.24   แพงกว่า 4 เท่า แต่พลังเท่ากันเป๊ะ
--     LArmor_15  ราคา 98000   AttriNum 0.62
--     LArmor_16  ราคา 140000  AttriNum 0.65   แพงกว่า 43% แต่พลังต่างกันแค่ 5%
--   ถ้าเทียบราคา ของแพงแต่อ่อนกว่าจะถูกเก็บไว้ ส่วนของถูกแต่แรงกว่าจะถูกขายทิ้ง
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   ขาย:  Backpack.TrySellItemRE:FireServer(uuid, จำนวน)
--         (LocalData/BackpackData.lua:109-114  TrySellItem(p1, p2) -> u26:FireServer(p1, p2))
--         p1 = key ของชิ้นนั้นใน Backpack.have ไม่ใช่ field UUID
--         p2 = จำนวน  ปุ่ม "ขาย 1" ส่ง 1  ปุ่ม "ขายทั้งกอง" ส่ง 9999
--         (GuiUtils/SellGUI.lua:105,109)
--   ขายทั้งหมด: Backpack.TrySellAllRE:FireServer()  = ขายทุกชิ้นรวมทั้งที่ใส่อยู่
--         (BackpackData.lua:116-118  SellAll -> u30:FireServer())
--         อันนี้ไม่มีตัวกรอง ใช้ไม่ได้ ถ้าอยากเลี่ยงของที่ใส่อยู่
--   รายการของ: Backpack = { have = { [uuid] = {...} }, equiped = { [ช่อง] = uuid } }
--         (BackpackData.lua:35-40  GetItemData -> u13.have[p1]
--          BackpackData.lua:42-47  GetEquipUUIDByIndex(p1) -> u13.equiped[p1])
--   ช่องที่ใส่ได้ = "Weapon" / "Armor" / "Hat" และ entry.Type ก็เป็นค่านี้เป๊ะ
--         ปุ่ม Equip ส่ง entry.Type ไปเลย (BackpackGUI.lua:97-102)
--         (GetWeaponSkillIDByIndex ใช้ "Weapon")
--   ของที่ใส่อยู่: สร้างชุด uuid จากค่าใน equiped แล้วเทียบ (BackpackData.lua:90-99 IsEquipedUUID)
--   จำนวนของแต่ละชิ้น: entry.Number  ถ้าไม่มีฟิลด์นี้แปลว่าเป็นชิ้นเดียว
--         (BackpackData.lua:144-153  GetNumberByIDType -> v1.Number หรือ 1)
--   ราคาขาย: Config[ID].Price เหมือนกันหมดทั้งอาวุธ/เกราะ/หมวก
--         (Config/Ore/Helper.lua:88 GetSellPrice -> Config[p1].Price
--          Config/Armor/Helper.lua:61 GetSellPrice -> Config[p1].Price
--          Config/Weapon/Helper.lua:87 GetSellPrice -> Config[p1].Price)
--         ID ในกระเป๋าคือ key ของ Config เป๊ะ ๆ เช่น "K_5", "LHat_3", "Ore_12"
--         เก็บราคาไว้ในตาราง PRICE ด้านล่าง เพราะ require Config ไม่ได้ (ดูหัวไฟล์ Upgrade.lua)
local Sell = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ============================================
-- ดึง remote โดยไม่ต้อง require
-- ============================================
-- ห้าม require(CommunicationUtils / BackpackData / ProfileData) เด็ดขาด
--   executor ที่ require ModuleScript จะได้ตารางที่ไม่มี member
--   (error: "TryGetBindableEvent is not a valid member of ModuleScript")
-- RemoteEvent/RemoteFunction สร้างฝั่ง client ไม่ได้ แต่ดึง instance ที่มีอยู่แล้วมาเรียกได้
local function getRemote(folderName, remoteName)
    local root = ReplicatedStorage:FindFirstChild("Remote")
    if not root then return nil end
    local folder = root:FindFirstChild(folderName)
    if not folder then return nil end
    return folder:FindFirstChild(remoteName)
end

local TrySellItemRE = getRemote("Backpack", "TrySellItemRE")
local GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")

-- ============================================
-- ราคาขายต่อชิ้น คัดจาก Config ทั้งสามชนิด
-- ============================================
-- key = ID ที่ตรงกับ entry.ID ใน Backpack.have
--   แร่   Ore_1 .. Ore_48          (48)
--   อาวุธ G_/K_/L_               (52)
--   เกราะ/หมวก HArmor_/HArmor… (60)
-- ราคาของแร่ตรงกับ ORE_PRICE ใน AutoFarm.lua ทุกตัว (เช็คแล้ว)
local PRICE = {
    ["G_1"] = 48, ["G_2"] = 71, ["G_3"] = 95, ["G_4"] = 118, ["G_5"] = 142, ["G_6"] = 189, ["G_7"] = 708,
    ["G_8"] = 1062, ["G_9"] = 1593, ["G_10"] = 6490, ["G_11"] = 9676, ["G_12"] = 11800, ["G_13"] = 16520, ["G_14"] = 66080,
    ["G_15"] = 115640, ["G_16"] = 165200, ["G_17"] = 295000, ["G_18"] = 1180000, ["G_19"] = 2312800, ["G_20"] = 2478000, ["G_21"] = 5900000,
    ["G_22"] = 9251200, ["G_23"] = 11800000, ["G_24"] = 14160000, ["G_25"] = 64900000, ["G_26"] = 97350000, ["HArmor_1"] = 10, ["HArmor_2"] = 17,
    ["HArmor_3"] = 25, ["HArmor_4"] = 95, ["HArmor_5"] = 142, ["HArmor_6"] = 189, ["HArmor_7"] = 708, ["HArmor_8"] = 1062, ["HArmor_9"] = 1593,
    ["HArmor_10"] = 6490, ["HArmor_11"] = 9676, ["HArmor_12"] = 11800, ["HArmor_13"] = 16520, ["HArmor_14"] = 66080, ["HHat_1"] = 10, ["HHat_2"] = 17,
    ["HHat_3"] = 25, ["HHat_4"] = 95, ["HHat_5"] = 142, ["HHat_6"] = 189, ["HHat_7"] = 708, ["HHat_8"] = 1062, ["HHat_9"] = 1593,
    ["HHat_10"] = 6490, ["HHat_11"] = 9676, ["HHat_12"] = 11800, ["HHat_13"] = 16520, ["HHat_14"] = 66080, ["K_1"] = 40, ["K_2"] = 60,
    ["K_3"] = 80, ["K_4"] = 100, ["K_5"] = 120, ["K_6"] = 160, ["K_7"] = 600, ["K_8"] = 900, ["K_9"] = 1350,
    ["K_10"] = 5500, ["K_11"] = 8200, ["K_12"] = 10000, ["K_13"] = 14000, ["K_14"] = 56000, ["K_15"] = 98000, ["K_16"] = 140000,
    ["K_17"] = 250000, ["K_18"] = 1000000, ["K_19"] = 1960000, ["K_20"] = 2100000, ["K_21"] = 5000000, ["K_22"] = 7840000, ["K_23"] = 10000000,
    ["K_24"] = 12000000, ["K_25"] = 55000000, ["K_26"] = 82500000, ["LArmor_1"] = 8, ["LArmor_2"] = 14, ["LArmor_3"] = 21, ["LArmor_4"] = 80,
    ["LArmor_5"] = 120, ["LArmor_6"] = 160, ["LArmor_7"] = 600, ["LArmor_8"] = 900, ["LArmor_9"] = 1350, ["LArmor_10"] = 5500, ["LArmor_11"] = 8200,
    ["LArmor_12"] = 10000, ["LArmor_13"] = 14000, ["LArmor_14"] = 56000, ["LArmor_15"] = 98000, ["LArmor_16"] = 140000, ["LHat_1"] = 8, ["LHat_2"] = 14,
    ["LHat_3"] = 21, ["LHat_4"] = 80, ["LHat_5"] = 120, ["LHat_6"] = 160, ["LHat_7"] = 600, ["LHat_8"] = 900, ["LHat_9"] = 1350,
    ["LHat_10"] = 5500, ["LHat_11"] = 8200, ["LHat_12"] = 10000, ["LHat_13"] = 14000, ["LHat_14"] = 56000, ["LHat_15"] = 98000, ["LHat_16"] = 140000,
    ["Ore_1"] = 8, ["Ore_2"] = 14, ["Ore_3"] = 21, ["Ore_4"] = 35, ["Ore_5"] = 40, ["Ore_6"] = 55, ["Ore_7"] = 60,
    ["Ore_8"] = 82, ["Ore_9"] = 125, ["Ore_10"] = 150, ["Ore_11"] = 175, ["Ore_12"] = 200, ["Ore_13"] = 225, ["Ore_14"] = 777,
    ["Ore_15"] = 932, ["Ore_16"] = 1120, ["Ore_17"] = 1340, ["Ore_18"] = 1610, ["Ore_19"] = 1930, ["Ore_20"] = 2320, ["Ore_21"] = 2780,
    ["Ore_22"] = 3531, ["Ore_23"] = 4823, ["Ore_24"] = 5524, ["Ore_25"] = 6120, ["Ore_26"] = 6950, ["Ore_27"] = 7230, ["Ore_28"] = 7990,
    ["Ore_29"] = 8250, ["Ore_30"] = 9100, ["Ore_31"] = 11200, ["Ore_32"] = 12528, ["Ore_33"] = 13420, ["Ore_34"] = 14555, ["Ore_35"] = 16230,
    ["Ore_36"] = 18800, ["Ore_37"] = 21000, ["Ore_38"] = 23250, ["Ore_39"] = 25539, ["Ore_40"] = 27980, ["Ore_41"] = 30000, ["Ore_42"] = 32420,
    ["Ore_43"] = 36732, ["Ore_44"] = 42000, ["Ore_45"] = 47000, ["Ore_46"] = 53200, ["Ore_47"] = 60000, ["Ore_48"] = 80000,
}

-- ============================================
-- พลังของแต่ละ ID (ตัวคูณหลัก ไม่รวมระดับตีบวง)
-- ============================================
--   อาวุธ G_/K_        -> Config/Weapon/Config.lua .Train
--   เกราะ/หมวก LArmor_/HArmor_/LHat_/HHat_ -> Config/Armor/Config.lua .AttriNum
--     (BalanceUtils.lua:320 GetMainAffix -> Weapon.Helper .Train
--                   BalanceUtils.lua:337 GetMainAffix -> Armor.Helper  .AttriNum)
-- เฉพาะ ID ที่มีราคาขาย เพราะพวก *_1001/*_1002/*_1101 (BestPercent) ไม่มีราคา
--   และคิดพลังตามคราฟของผู้เล่น ซึ่งดึงมาไม่ได้จาก GetTotalDataRF ตอนนี้
--   ชิ้นพวกนั้นอยู่ใน PRICE ว่างเปล่าอยู่แล้ว จึงไม่มีทางถูกขาย
local POWER = {
    ["G_1"] = 2, ["G_2"] = 6, ["G_3"] = 15, ["G_4"] = 36,
    ["G_5"] = 59, ["G_6"] = 148, ["G_7"] = 354, ["G_8"] = 590,
    ["G_9"] = 1475, ["G_10"] = 3658, ["G_11"] = 5900, ["G_12"] = 14750,
    ["G_13"] = 82600, ["G_14"] = 177000, ["G_15"] = 354000, ["G_16"] = 885000,
    ["G_17"] = 2218400, ["G_18"] = 4720000, ["G_19"] = 11800000, ["G_20"] = 29500000,
    ["G_21"] = 59000000, ["G_22"] = 118000000, ["G_23"] = 177000000, ["G_24"] = 236000000,
    ["G_25"] = 472000000, ["G_26"] = 708000000,
    ["K_1"] = 1, ["K_2"] = 5, ["K_3"] = 12, ["K_4"] = 30,
    ["K_5"] = 50, ["K_6"] = 125, ["K_7"] = 300, ["K_8"] = 500,
    ["K_9"] = 1250, ["K_10"] = 3100, ["K_11"] = 5000, ["K_12"] = 12500,
    ["K_13"] = 70000, ["K_14"] = 150000, ["K_15"] = 300000, ["K_16"] = 750000,
    ["K_17"] = 1880000, ["K_18"] = 4000000, ["K_19"] = 10000000, ["K_20"] = 25000000,
    ["K_21"] = 50000000, ["K_22"] = 100000000, ["K_23"] = 150000000, ["K_24"] = 200000000,
    ["K_25"] = 400000000, ["K_26"] = 600000000,
    ["LArmor_1"] = 0.05, ["LArmor_2"] = 0.055, ["LArmor_3"] = 0.06, ["LArmor_4"] = 0.1,
    ["LArmor_5"] = 0.14, ["LArmor_6"] = 0.2, ["LArmor_7"] = 0.25, ["LArmor_8"] = 0.3,
    ["LArmor_9"] = 0.36, ["LArmor_10"] = 0.41, ["LArmor_11"] = 0.45, ["LArmor_12"] = 0.5,
    ["LArmor_13"] = 0.55, ["LArmor_14"] = 0.59, ["LArmor_15"] = 0.62, ["LArmor_16"] = 0.65,
    ["LHat_1"] = 0.1, ["LHat_2"] = 0.15, ["LHat_3"] = 0.2, ["LHat_4"] = 0.2,
    ["LHat_5"] = 0.3, ["LHat_6"] = 0.3, ["LHat_7"] = 0.35, ["LHat_8"] = 0.4,
    ["LHat_9"] = 0.4, ["LHat_10"] = 0.45, ["LHat_11"] = 0.5, ["LHat_12"] = 0.55,
    ["LHat_13"] = 0.6, ["LHat_14"] = 0.7, ["LHat_15"] = 0.75, ["LHat_16"] = 0.85,
    ["HArmor_1"] = 0.06, ["HArmor_2"] = 0.07, ["HArmor_3"] = 0.08, ["HArmor_4"] = 0.12,
    ["HArmor_5"] = 0.17, ["HArmor_6"] = 0.24, ["HArmor_7"] = 0.3, ["HArmor_8"] = 0.36,
    ["HArmor_9"] = 0.43, ["HArmor_10"] = 0.49, ["HArmor_11"] = 0.54, ["HArmor_12"] = 0.59,
    ["HArmor_13"] = 0.65, ["HArmor_14"] = 0.7,
    ["HHat_1"] = 0.12, ["HHat_2"] = 0.18, ["HHat_3"] = 0.24, ["HHat_4"] = 0.24,
    ["HHat_5"] = 0.36, ["HHat_6"] = 0.36, ["HHat_7"] = 0.42, ["HHat_8"] = 0.48,
    ["HHat_9"] = 0.48, ["HHat_10"] = 0.54, ["HHat_11"] = 0.59, ["HHat_12"] = 0.65,
    ["HHat_13"] = 0.71, ["HHat_14"] = 0.83,
}

-- ตัวคูณจากระดับตีบวง Enhance (Config/Enhant/Config.lua ช่อง Boost)
--   index = entry.Level  เกิน 20 ให้ถือว่าเป็น 0 ตามที่ Enhant.Helper.GetBoost ทำ
local ENHANT_BOOST = {
    [0] = 0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.4, 0.55, 0.7, 0.85, 1,
    1.15, 1.3, 1.5, 1.7, 1.9, 2.1, 2.3, 2.6, 2.9, 3.2,
}

-- ช่องที่ใส่ของได้ ใช้แยกชิ้นที่จะขาย และเทียบกับของที่ใส่อยู่
--   ค่าใน entry.Type ตรงกับชื่อช่องใน Backpack.equiped เป๊ะ
local EQUIP_SLOTS = {Weapon = true, Armor = true, Hat = true}

-- ============================================
-- อ่านข้อมูลผู้เล่น
-- ============================================
-- แคชข้อมูลจาก GetTotalDataRF ไว้ แล้วอัปเดตจาก UpdateDataRE ที่เซิร์ฟเวอร์ส่งมา
--   ProfileData.lua:27-37  UpdateDataRE.OnClientEvent -> u26[key] = value
local total = nil

-- ดึงข้อมูลทั้งก้อนมาใหม่ ได้ทั้งรายการของและเลเวลอัปในรอบเดียว
--   ProfileData.init ก็เรียกตัวนี้ตอนแรกเหมือนกัน (ProfileData.lua:54)
local function refresh()
    if not GetTotalDataRF then
        GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
    end
    if not GetTotalDataRF then return false end
    local ok, data = pcall(function() return GetTotalDataRF:InvokeServer() end)
    if not ok or type(data) ~= "table" then return false end
    total = data
    return true
end

local UpdateDataRE = getRemote("Profile", "UpdateDataRE")
if UpdateDataRE then
    UpdateDataRE.OnClientEvent:Connect(function(key, value)
        if not total then return end
        if key == "Backpack" or key == "Upgrade" then
            total[key] = value
        end
    end)
end

-- ============================================
-- ตัวช่วยอ่านกระเป๋า
-- ============================================
local function have()
    local pack = total and total.Backpack
    local list = pack and pack.have
    if type(list) ~= "table" then return nil end
    return list
end

-- uuid ที่ใส่อยู่ทั้งหมด เป็นชุด
--   (BackpackData.lua:90-99  IsEquipedUUID ไล่ค่าใน equiped ทั้งหมด)
local function equipedSet()
    local set = {}
    local pack = total and total.Backpack
    local equiped = pack and pack.equiped
    if type(equiped) ~= "table" then return set end
    for _, uuid in pairs(equiped) do
        if type(uuid) == "string" then
            set[uuid] = true
        end
    end
    return set
end

-- ชิ้นที่ใส่อยู่ในช่องนั้น (Weapon / Armor / Hat)
local function equipedItem(slot)
    local pack = total and total.Backpack
    local equiped = pack and pack.equiped
    if type(equiped) ~= "table" then return nil end
    local uuid = equiped[slot]
    if type(uuid) ~= "string" then return nil end
    local list = have()
    return list and list[uuid] or nil
end

local function priceOf(entry)
    if type(entry) ~= "table" then return nil end
    return PRICE[entry.ID]
end

-- พลังของชิ้นหนึ่ง ตามสูตรเดียวกับที่เกมใช้แสดงค่าในกระเป๋า
--   ไม่มีใน POWER (เช่นของที่ขายไม่ได้) -> nil ไม่ต้องขายอยู่แล้ว
local function powerOf(entry)
    local affix = type(entry) == "table" and POWER[entry.ID] or nil
    if not affix then return nil end
    local boost = ENHANT_BOOST[tonumber(entry.Level) or 0] or 0
    return affix * (1 + boost)
end

-- ============================================
-- วงจรขาย
-- ============================================
-- ขายทีละชิ้น (ส่ง 9999 = ทั้งกอง)
--   เว้นจังหวะเล็กน้อยระหว่างชิ้น กันยิงรัวจนเซิร์ฟเวอร์ปฏิเสธ
local SELL_GAP = 0.1

local function fireSell(key)
    local remote = TrySellItemRE or getRemote("Backpack", "TrySellItemRE")
    if not remote then return false end
    TrySellItemRE = remote
    return (pcall(function() remote:FireServer(key, 9999) end))
end

-- ============================================
-- เลือกว่าจะขายอะไร
-- ============================================
-- ขายเฉพาะอาวุธ/เกราะ/หมวกที่ยังไม่ใส่อยู่  แร่และของชนิดอื่นไม่แตะทั้งสิ้น
--   (ของที่ไม่มีราคาขาย เช่น Material/Buff/Potion เซิร์ฟเวอร์ปฏิเสธอยู่ดี ไม่ยิงรัว)
--
-- เก็บไว้เสมอ ไม่ขาย
--   1) ชิ้นที่ดีที่สุดของช่องนั้น      เช็คพลังทุกชิ้นแล้วเลือกอันสูงสุดเป็นอันเดียว
--                                   พลังเท่ากันให้เอาอันที่ราคาสูงกว่า (ของหายากกว่า)
--   2) ชิ้นที่แรงกว่าของที่ใส่อยู่     ไว้ให้ผู้ใช้เอาไปเปลี่ยนเอง ถ้าช่องนั้นยังว่างอยู่จะได้เก็บแค่อันเดียว
--   (ของที่ใส่อยู่อยู่แล้ว ไม่ต้องนับ เพราะขายไม่ได้อยู่แล้ว)
-- ที่เหลือรวมถึงตัวสำรองของ ID เดียวกัน -> ขายหมด
local function sellableKeys()
    local list = have()
    if not list then return nil end

    local worn = equipedSet()
    local bySlot = {}

    -- แยกชิ้นที่ขายได้ของแต่ละช่อง พร้อมคำนวณพลังเก็บไว้เทียบ
    for key, entry in pairs(list) do
        local slot = type(entry) == "table" and EQUIP_SLOTS[entry.Type] and entry.Type or nil
        local price = slot and priceOf(entry) or nil
        local power = price and powerOf(entry) or nil
        if power and power > 0 and not worn[key] then
            local bucket = bySlot[slot]
            if not bucket then
                bucket = {}
                bySlot[slot] = bucket
            end
            bucket[#bucket + 1] = {key = key, power = power, price = price}
        end
    end

    local keep = {}
    local keys = {}

    for slot, bucket in pairs(bySlot) do
        -- ชิ้นที่ดีที่สุดของช่องนี้ เทียบพลังก่อน ถ้าพลังเท่ากันค่อยดูราคา แล้วสุดท้ายเทียบ key
        --   ไม่งั้นชิ้นที่พลังเท่ากันเป๊ะจะได้ผลตามลำดับ pairs() ซึ่งสุ่มทุกครั้งที่เปิดเกม
        local best = bucket[1]
        for i = 2, #bucket do
            local it = bucket[i]
            if it.power > best.power
                or (it.power == best.power and it.price > best.price)
                or (it.power == best.power and it.price == best.price and it.key < best.key)
            then
                best = it
            end
        end
        keep[best.key] = true

        -- ชิ้นที่แรงกว่าของที่ใส่อยู่ เก็บไว้เผื่อผู้ใช้อยากเปลี่ยน
        local theirs = powerOf(equipedItem(slot))
        if theirs then
            for i = 1, #bucket do
                if bucket[i].power > theirs then
                    keep[bucket[i].key] = true
                end
            end
        end

        for i = 1, #bucket do
            if not keep[bucket[i].key] then
                keys[#keys + 1] = bucket[i].key
            end
        end
    end

    return keys
end

local function sellGears()
    local keys = sellableKeys()
    if not keys or #keys == 0 then return 0 end
    local sold = 0
    for _, key in ipairs(keys) do
        if fireSell(key) then
            sold = sold + 1
        end
        task.wait(SELL_GAP)
    end
    return sold
end

-- ============================================
-- ลูปขาย
-- ============================================
local SELL_EVERY = 1.5

local sellEnabled = false
local sellRunning = false

local function sellLoop()
    while sellEnabled do
        if not refresh() then
            task.wait(1)
        else
            sellGears()
            task.wait(SELL_EVERY)
        end
    end
    sellRunning = false
end

local function setSell(value)
    sellEnabled = value == true
    if sellEnabled then
        refresh()
        if not sellRunning then
            sellRunning = true
            task.spawn(sellLoop)
        end
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Sell.register(context)
    local tab = context.Tab
    if not tab then return end

    local section = tab:Section({Title = "ขายของอัตโนมัติ", Opened = true})
    if section then
        section:Toggle({
            Title = "ขายอาวุธ/เกราะ/หมวกอัตโนมัติ",
            Desc = "ขายเฉพาะอาวุธ/เกราะ/หมวก (ไม่ขายแร่) เว้นชิ้นที่ดีที่สุดของแต่ละช่องไว้เสมอ เว้นชิ้นที่ใส่อยู่ และเว้นชิ้นที่ดีกว่าของที่ใส่อยู่",
            Value = false,
            Callback = setSell,
        })
    end

    refresh()
end

return Sell
