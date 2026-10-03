-- Version 5.11
-- แถบขายของ (มี 2 ตัวเลือก ใช้คนละเรื่องกัน)
--
--   1) "ขายแร่จนกว่าจะอัปเกรดครบ"  ขายเฉพาะแร่ และหยุดเองเมื่ออัปครบทั้ง 3 สถิติ
--   2) "ขายของอัตโนมัติ"          ขายของทุกชิ้นในกระเป๋า แต่เลี่ยงของที่ต้องเก็บไว้
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   ขาย:  Backpack.TrySellItemRE:FireServer(uuid, จำนวน)
--         (LocalData/BackpackData.lua:126-134  TrySellItem(p1, p2) -> u26:FireServer(p1, p2))
--         p1 = key ของชิ้นนั้นใน Backpack.have ไม่ใช่ field UUID
--         p2 = จำนวน  ปุ่ม "ขาย 1" ส่ง 1  ปุ่ม "ขายทั้งกอง" ส่ง 9999
--         (GuiUtils/SellGUI.lua:137,140)
--   ขายทั้งหมด: Backpack.TrySellAllRE:FireServer()  = ขายทุกชิ้นรวมทั้งที่ใส่อยู่
--         (BackpackData.lua:136-138  SellAll -> u30:FireServer())
--         อันนี้ไม่มีตัวกรอง ใช้ไม่ได้ ถ้าอยากเลี่ยงของที่ใส่อยู่
--   รายการของ: Backpack = { have = { [uuid] = {...} }, equiped = { [ช่อง] = uuid } }
--         (BackpackData.lua:51 GetItemData -> u13.have[p1]
--          BackpackData.lua:58 GetEquipUUIDByIndex(p1) -> u13.equiped[p1])
--         ช่องที่ใส่ได้ = "Weapon" / "Armor" / "Hat"  (GetWeaponSkillIDByIndex ใช้ "Weapon")
--   ของที่ใส่อยู่: สร้างชุด uuid จากค่าใน equiped แล้วเทียบ (BackpackData.lua:107 IsEquipedUUID)
--   จำนวนของแต่ละชิ้น: entry.Number  ถ้าไม่มีฟิลด์นี้แปลว่าเป็นชิ้นเดียว
--         (BackpackData.lua:167-175  GetNumberByIDType -> v1.Number หรือ 1)
--   ราคาขาย: Config[ID].Price เหมือนกันหมดทั้งอาวุธ/เกราะ/หมวก/แร่
--         (Config/Ore/Helper.lua:88 GetSellPrice -> Config[p1].Price
--          Config/Armor/Helper.lua:78 GetSellPrice -> Config[p1].Price
--          Config/Weapon/Helper.lua:107 GetSellPrice -> Config[p1].Price)
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

-- ชิ้นในกระเป๋าเก็บ Type เป็นชนิดย่อย ไม่ใช่ชื่อโฟลเดอร์ Config
--   อาวุธ -> "Katana" (ดาบ) / "Great" (ธนู)      เกราะ -> "Light" / "Heave"
--   หมวก  -> "Hat"   (หมวกไปอยู่ใน Config "Armor" ตาม GetConfigType)
--   (BackpackGUI.lua:71-82 GetConfigType, Weapon/Helper.lua:26-34 ตั้ง j.Type เป็น Katana/Great/Light)
--   (BackpackData.lua:140 GetConfigType -> "Hat" กับ "Armor" แยกเป็นคนละช่อง แต่ใช้ Config เดียวกัน)
-- ตารางนี้แปลง entry.Type -> ช่องที่ใส่ เพื่อไม่ขายของที่ผู้ใช้ใส่อยู่
local SLOT_OF_TYPE = {
    Katana = "Weapon",
    Great  = "Weapon",
    Light  = "Armor",
    Heave  = "Armor",
    Hat    = "Hat",
}

-- ช่องที่ใส่ได้ทั้ง 3 ช่อง (ใช้เช็คว่าต้องระวังของใส่อยู่หรือไม่)
local EQUIP_SLOTS = {Weapon = true, Armor = true, Hat = true}

-- ============================================
-- เลเวลสูงสุดของแต่ละสถิติ
-- ============================================
-- เลขสุดท้ายในตารางราคา = เลเวลที่อัปไม่ได้อีกแล้ว
--   (Config/Upgrade/Helper.lua:28-31  ไม่มีแถวถัดไป = ตัน)
-- ค่านี้ต้องตรงกับ PRICE ใน Upgrade.lua ถ้าเกมอัปเวอร์ชันใหม่ให้ตรวจทั้งสองไฟล์
local MAX_LEVEL = {OrePack = 12, Train = 12, Luck = 12}
local STATS = {"OrePack", "Train", "Luck"}

-- ============================================
-- อ่านข้อมูลผู้เล่น
-- ============================================
-- แคชข้อมูลจาก GetTotalDataRF ไว้ แล้วอัปเดตจาก UpdateDataRE ที่เซิร์ฟเวอร์ส่งมา
--   ProfileData.lua:27-37  UpdateDataRE.OnClientEvent -> u26[key] = value
local total = nil

local function readLevel(data, statName)
    local store = data and data.Upgrade
    local entry = store and store[statName]
    local lv = entry and tonumber(entry.Level)
    return lv or 0
end

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
--   (BackpackData.lua:107-116  IsEquipedUUID ไล่ค่าใน equiped ทั้งหมด)
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

-- อัปครบทุกตัวหรือยัง = ครบแล้วก็ไม่ต้องขายอีก เพราะเงินไม่มีที่ใช้
local function allStatsMaxed()
    if not total then return false end
    for _, name in ipairs(STATS) do
        if readLevel(total, name) < MAX_LEVEL[name] then
            return false
        end
    end
    return true
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

-- ---------- ตัวที่ 1: ขายแร่ จนกว่าจะอัปเกรดครบ ----------
local function oreKeys()
    local list = have()
    if not list then return nil end
    local keys = {}
    for key, entry in pairs(list) do
        -- แร่เท่านั้น ไม่แตะอาวุธ/เกราะ/หมวก เพราะผู้ใช้อาจจะเก็บไว้ใช้
        if type(entry) == "table" and entry.Type == "Ore" then
            keys[#keys + 1] = key
        end
    end
    return keys
end

local function sellOres()
    local keys = oreKeys()
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

-- ---------- ตัวที่ 2: ขายของทั้งหมด แต่เลี่ยงของที่ควรเก็บ ----------
-- แร่และของชนิดอื่นที่มีราคาขาย -> ขายหมดทุกชิ้น ไม่ต้องเก็บไว้
-- อาวุธ/เกราะ/หมวก               -> เก็บไว้แค่ชิ้นเดียวของแต่ละ ID
--   1) ชิ้นที่ใส่อยู่ตอนนี้        -> เก็บ (นับเป็นชิ้นที่เก็บไว้ของ ID นั้นเลย)
--   2) ของที่แพงกว่าของที่ใส่อยู่  -> เก็บ ไว้ให้ผู้ใช้เอาไปเปลี่ยนเอง
--   3) ถ้ามีหลายชิ้นของ ID เดียวกัน -> เก็บชิ้นแรก ที่เหลือขายเป็นตัวสำรอง
--   4) ของที่ไม่มีราคาขาย        -> เซิร์ฟเวอร์ปฏิเสธอยู่ดี (Material/Buff/Potion) ไม่ยิงรัว
local function sellableKeys()
    local list = have()
    if not list then return nil end

    local worn = equipedSet()
    local kept = {}
    local keys = {}

    -- นับชิ้นที่ใส่อยู่ก่อน เพื่อไม่ให้เก็บตัวสำรองของ ID เดียวกับที่ใส่อยู่
    for slot in pairs(EQUIP_SLOTS) do
        local entry = equipedItem(slot)
        if entry and entry.ID then
            kept[entry.ID] = true
        end
    end

    for key, entry in pairs(list) do
        if type(entry) == "table" then
            local price = priceOf(entry)

            if price and price > 0 then
                local slotName = SLOT_OF_TYPE[entry.Type]
                local isEquipSlot = slotName and EQUIP_SLOTS[slotName] or false

                if entry.Type == "Ore" then
                    -- แร่ -> ขายให้หมด ไม่ต้องเก็บไว้
                    keys[#keys + 1] = key
                elseif not isEquipSlot then
                    -- ของอื่นที่ไม่มีช่องใส่ (ถ้ามี) ให้ขายตามปกติ
                    keys[#keys + 1] = key
                elseif not worn[key] then
                    -- ของที่ยังไม่ได้ใส่ และยังไม่เคยเก็บ ID นี้ไว้
                    if kept[entry.ID] then
                        keys[#keys + 1] = key
                    else
                        kept[entry.ID] = true
                        -- แพงกว่าของที่ใส่อยู่ = เก็บไว้ ไม่ขาย
                        local theirs = priceOf(equipedItem(slotName))
                        if not (theirs and price > theirs) then
                            keys[#keys + 1] = key
                        end
                    end
                end
            end
        end
    end
    return keys
end

local function sellAll()
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
-- ลูปของแต่ละตัว (คนละลูปกัน เปิด-ปิดได้อิสระ)
-- ============================================
local SELL_EVERY = 1.5

local sellEnabled = false
local sellRunning = false

local function sellLoop()
    while sellEnabled do
        if not refresh() then
            task.wait(1)
        else
            -- อัปครบแล้ว = เงินไม่มีที่ใช้ ขายต่อก็เปล่า ๆ
            if not allStatsMaxed() then
                sellOres()
            end
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

local allEnabled = false
local allRunning = false

local function sellAllLoop()
    while allEnabled do
        if not refresh() then
            task.wait(1)
        else
            sellAll()
            task.wait(SELL_EVERY)
        end
    end
    allRunning = false
end

local function setSellAll(value)
    allEnabled = value == true
    if allEnabled then
        refresh()
        if not allRunning then
            allRunning = true
            task.spawn(sellAllLoop)
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
            Title = "ขายแร่จนกว่าจะอัปเกรดครบ",
            Desc = "ขายแร่ในกระเป๋าอัตโนมัติ ถ้าอัปเกรดครบทั้ง 3 จนตันแล้วจะไม่ขาย",
            Value = false,
            Callback = setSell,
        })
        section:Toggle({
            Title = "ขายของอัตโนมัติ",
            Desc = "ขายแร่หมด ขายอาวุธ/เกราะ/หมวกที่ซ้ำกันเหลือชิ้นเดียว เว้นเฉพาะที่ใส่อยู่และที่ดีกว่าของที่ใส่อยู่",
            Value = false,
            Callback = setSellAll,
        })
    end

    refresh()
end

return Sell
