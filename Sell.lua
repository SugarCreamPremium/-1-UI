-- Version 2.18
-- แถบขายของ
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   ขาย:  Backpack.TrySellItemRE:FireServer(uuid, จำนวน)
--         (LocalData/BackpackData.lua:126-134  TrySellItem(p1, p2) -> u26:FireServer(p1, p2))
--         p1 = key ของชิ้นนั้นใน Backpack.have  ไม่ใช่ field UUID
--         p2 = จำนวน  ปุ่ม "ขาย 1" ส่ง 1  ปุ่ม "ขายทั้งกอง" ส่ง 9999
--         (GuiUtils/SellGUI.lua:137,140)
--   ขายทั้งหมด: Backpack.TrySellAllRE:FireServer()  = ขายทุกชิ้นที่ยังไม่ได้ใส่
--         (BackpackData.lua:136-138  SellAll -> u30:FireServer())
--         อันนี้ขายอาวุธ/เกราะด้วย จึงไม่ใช้ในโมดูลนี้
--   รายการของ: Backpack.have = { [key] = { Type = "Ore", ID = 12, Number = 5, ... } }
--         ของทุกอย่างรวมทั้งแร่ อยู่ใน store "Backpack"
--         (LocalData/BackpackData.lua:51  GetItemData -> u13.have[p1])
--   หน้าขายของเกมไม่ได้กรองชนิด: SellGUI.update() วนทุก key ใน have
--         แล้วสร้างเฟรมขายให้ทั้งหมด (SellGUI.lua:56-70)
--         -> แร่ก็ขายผ่านทางเดียวกันได้ ไม่ต้องหา remote ขายแร่แยก
--   ราคาขาย: Config/Ore/Config.lua ตัว Price เดียวกับที่ AutoFarm ใช้จัดลำดับ
--         (Config/Ore/Helper.lua:88-92  GetSellPrice(p1) -> Config[p1].Price)
--   เงิน:  LocalPlayer.Eco.coin.Value
local Sell = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

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
-- เลเวลสูงสุดของแต่ละสถิติ
-- ============================================
-- เลขสุดท้ายในตารางราคา = เลเวลที่อัปไม่ได้อีกแล้ว
--   (Config/Upgrade/Helper.lua:28-31  ไม่มีแถวถัดไป = ตัน)
--   OrePack มี 13 แถว (0..12) / Train และ Luck มี 13 แถว (0..12)
-- ค่านี้ต้องตรงกับ PRICE ใน Upgrade.lua ถ้าเกมอัปเวอร์ชันใหม่ให้ตรวจทั้งสองไฟล์
local MAX_LEVEL = {OrePack = 12, Train = 12, Luck = 12}
local STAT_NAME = {Train = "พลังโจมตี", Luck = "โชค", OrePack = "ขนาดกระเป๋า"}
local STATS = {"OrePack", "Train", "Luck"}

-- ============================================
-- อ่านข้อมูลผู้เล่น
-- ============================================
local function getCoin()
    local eco = player:FindFirstChild("Eco")
    local coin = eco and eco:FindFirstChild("coin")
    if not coin then return nil end
    return tonumber(coin.Value) or 0
end

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

-- กุญแจของชิ้นที่เป็นแร่ ทั้งหมดในกระเป๋า
local function oreKeys()
    local have = total and total.Backpack and total.Backpack.have
    if type(have) ~= "table" then return nil end
    local keys = {}
    for key, entry in pairs(have) do
        -- แร่เท่านั้น ไม่แตะอาวุธ/เกราะ/หมวก เพราะผู้ใช้อาจจะเก็บไว้ใช้
        if type(entry) == "table" and entry.Type == "Ore" then
            keys[#keys + 1] = key
        end
    end
    return keys
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
-- ขายแร่ทิ้งทีละกอง (ส่ง 9999 = ทั้งกอง)
--   เว้นจังหวะเล็กน้อยระหว่างชิ้น กันยิงรัวจนเซิร์ฟเวอร์ปฏิเสธ
local SELL_GAP = 0.1

local function sellOres()
    local keys = oreKeys()
    if not keys or #keys == 0 then return 0 end

    local remote = TrySellItemRE or getRemote("Backpack", "TrySellItemRE")
    if not remote then return 0 end
    TrySellItemRE = remote

    local sold = 0
    for _, key in ipairs(keys) do
        pcall(function() remote:FireServer(key, 9999) end)
        sold = sold + 1
        task.wait(SELL_GAP)
    end
    return sold
end

-- ย่อเลขให้สั้นลง ราคาของแร่แพงมากถ้าเขียนเต็มบรรทัดจะยาวเกินกรอบ
local function fmt(n)
    if not n then return "?" end
    n = math.floor(n)
    local abs = math.abs(n)
    if abs >= 1e9 then
        return string.format("%.2fB", n / 1e9)
    end
    if abs >= 1e6 then
        return string.format("%.2fM", n / 1e6)
    end
    if abs >= 1e3 then
        return string.format("%.1fK", n / 1e3)
    end
    return tostring(n)
end

local sellEnabled = false
local sellRunning = false
local labels = {}
local SELL_EVERY = 1.5

-- เขียนข้อความลง Paragraph หนึ่งอัน
--   Paragraph ไม่มี SetValue แต่มี SetDesc ของตัวเฟรมข้างใน (components/window/Element.lua:482)
local function setDesc(entry, text)
    if not entry then return end
    entry.Desc = text
    pcall(function() entry.ParagraphFrame:SetDesc(text) end)
end

-- สถานะแยกทีละบรรทัด เป็นคนละ Paragraph กัน
--   Desc ของ Paragraph เป็นบรรทัดเดียว ถ้าใส่ \n แล้วยาวเกินกรอบจะถูกตัดทิ้ง
local function updateLabel()
    setDesc(labels.Coin, "เหรียญ " .. fmt(getCoin()))

    for _, name in ipairs(STATS) do
        local lv = readLevel(total or {}, name)
        if lv >= MAX_LEVEL[name] then
            setDesc(labels[name], "ครบแล้ว (" .. lv .. "/" .. MAX_LEVEL[name] .. ")")
        else
            setDesc(labels[name], lv .. "/" .. MAX_LEVEL[name])
        end
    end

    if allStatsMaxed() then
        setDesc(labels.Status, "อัปครบทุกสถิติแล้ว ไม่ขายอีก")
    else
        setDesc(labels.Status, "กำลังขายแร่ในกระเป๋า")
    end
end

local function sellLoop()
    while sellEnabled do
        if not refresh() then
            task.wait(1)
        else
            -- อัปครบแล้ว = เงินไม่มีที่ใช้ ขายต่อก็เปล่า ๆ
            if not allStatsMaxed() then
                sellOres()
            end
            updateLabel()
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
            Title = "เปิดขายอัตโนมัติ",
            Desc = "ขายแร่ทิ้งเรื่อย ๆ จนกว่าจะอัปเกรดครบทั้ง 3 สถิติ แล้วจะหยุดขายเอง",
            Value = false,
            Callback = setSell,
        })

        labels.Coin = section:Paragraph({Title = "เหรียญ", Desc = "..."})
        for _, name in ipairs(STATS) do
            labels[name] = section:Paragraph({Title = STAT_NAME[name], Desc = "..."})
        end
        labels.Status = section:Paragraph({Title = "สถานะ", Desc = "..."})
    end

    refresh()
    updateLabel()
end

return Sell
