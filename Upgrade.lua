-- Version 1.50
-- แถบ Upgrade (อัปเกรดอัตโนมัติ)
--
-- กลไกของเกมที่ใช้ (อ่านจากดัมป์):
--   ซื้อ:  UpgradeOnceRE:FireServer(ชื่อสถิติ)  อาร์กิวเมนต์เดียว ไม่มีอื่น
--         (LocalData/UpgradeData.lua:60-62  UpgradeOnce(p1) -> u21:FireServer(p1))
--         ปุ่มใน UI ของเกมก็เรียกตัวนี้ตัวเดียวกัน (GuiUtils/UpgradeGUI.lua:47-49)
--   3 สถิติ: ชื่อเฟรมในหน้าอัปเกรดของเกม = ชื่อที่ส่งได้พอดี
--         PlayerGui.Main.Upgrade.zheng.ScrollingFrame.<Luck | OrePack | Train>
--   เลเวล:  ProfileData store key "Upgrade" = { [ชื่อ] = { Level = n, Number = n } }
--         (LocalData/UpgradeData.lua:46-51  GetLevel -> u22[p1].Level)
--         อ่านได้โดย InvokeServer Profile.GetTotalDataRF (ProfileData.lua:54)
--         และเซิร์ฟเวอร์ส่งค่าใหม่มาทาง Profile.UpdateDataRE ทุกครั้งที่อัปจริง
--   เงิน:  LocalPlayer.Eco.coin.Value  (เป็น NumberValue จึงอ่านสดได้ตลอด)
--         ใช้แบบเดียวกับ UI ของเกม (GuiUtils/PlayerInfoGUI.lua:35, LeftInfoGUI.lua:23)
--   ราคา: ตาราง Config/Upgrade/Config/<ชื่อ>.lua คัดลอกมาไว้ในไฟล์นี้
--         ราคาของเลเวลถัดไป = PRICE[ชื่อ][เลเวลปัจจุบัน + 1]
--         (Config/Upgrade/Helper.lua:41-47  GetPrice(p1, p2) -> Config[p1][p2].Price)
--   ตัน:   ไม่มีแถวถัดไปในตาราง = อัปไม่ได้แล้ว
--         (Config/Upgrade/Helper.lua:28-31  CheckIsMax -> ไม่มี Config[p1][level+1])
local Upgrade = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- ============================================
-- ดึง remote โดยไม่ต้อง require
-- ============================================
-- ห้าม require(CommunicationUtils / UpgradeData) เด็ดขาด
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

local UpgradeOnceRE = getRemote("Upgrade", "UpgradeOnceRE")
local GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
local UpdateDataRE = getRemote("Profile", "UpdateDataRE")

-- ============================================
-- ตารางราคา (คัดจาก Config/Upgrade/Config)
-- ============================================
-- index = เลเวลปัจจุบัน  ->  ราคาที่ต้องจ่ายเพื่อขึ้นเลเวลถัดไป = PRICE[x][index + 1]
local PRICE = {
    -- Config/Upgrade/Config/Train.lua  (ดาเมจเทรน)
    Train = {
        [0] = 0,
        [1] = 2500,
        [2] = 8000,
        [3] = 15000,
        [4] = 48000,
        [5] = 200000,
        [6] = 880000,
        [7] = 2500000,
        [8] = 8000000,
        [9] = 15000000,
        [10] = 75800000,
        [11] = 220000000,
        [12] = 1550000000,
    },
    -- Config/Upgrade/Config/Luck.lua  (โชค)
    Luck = {
        [0] = 0,
        [1] = 2500,
        [2] = 8000,
        [3] = 15000,
        [4] = 48000,
        [5] = 200000,
        [6] = 880000,
        [7] = 2500000,
        [8] = 8000000,
        [9] = 15000000,
        [10] = 75800000,
        [11] = 220000000,
        [12] = 1550000000,
    },
    -- Config/Upgrade/Config/OrePack.lua  (ขนาดกระเป๋า)
    OrePack = {
        [0] = 0,
        [1] = 200,
        [2] = 1000,
        [3] = 5000,
        [4] = 30000,
        [5] = 150000,
        [6] = 280000,
        [7] = 1250000,
        [8] = 3900000,
        [9] = 5000000,
        [10] = 8832700,
        [11] = 25800000,
        [12] = 60000000,
    },
}

-- ลำดับที่กดอัพ: ถ้าเปิดทั้ง 3 ตัว ให้ไล่ตามลำดับนี้
--   OrePack ก่อน เพราะถูกที่สุดและได้ผลต่อเนื่อง (เก็บของได้มากขึ้นทุกรอบ)
--   แล้วค่อย Train -> Luck ที่แพงกว่า
local STATS = {"OrePack", "Train", "Luck"}
local STAT_NAME = {Train = "พลังโจมตี", Luck = "โชค", OrePack = "ขนาดกระเป๋า"}

-- ============================================
-- อ่านข้อมูลผู้เล่น
-- ============================================
-- เงิน = LocalPlayer.Eco.coin (NumberValue) อ่านสดได้ ไม่ต้องยิง remote
local function getCoin()
    local eco = player:FindFirstChild("Eco")
    local coin = eco and eco:FindFirstChild("coin")
    if not coin then return nil end
    return tonumber(coin.Value) or 0
end

-- แคชเลเวลไว้ แล้วอัปเดตจาก UpdateDataRE ที่เซิร์ฟเวอร์ส่งมา
--   ProfileData.lua:27-37  UpdateDataRE.OnClientEvent -> u26[key] = value
--   ค่า value คือ store ทั้งก้อนของ key นั้น (เช่น "Upgrade")
local levels = {}

local function storeLevel(store, statName)
    if type(store) ~= "table" then return end
    local entry = store[statName]
    if type(entry) ~= "table" then return end
    local lv = tonumber(entry.Level)
    if lv then levels[statName] = lv end
end

local function applyStore(data)
    if type(data) ~= "table" then return end
    for _, name in ipairs(STATS) do
        storeLevel(data.Upgrade, name)
    end
end

if UpdateDataRE then
    UpdateDataRE.OnClientEvent:Connect(function(key, value)
        if key == "Upgrade" then
            storeLevel(value, "OrePack")
            storeLevel(value, "Train")
            storeLevel(value, "Luck")
        end
    end)
end

-- ดึงเลเวลสดจากเซิร์ฟเวอร์ ใช้ตอนเริ่มลูป และตอนกดรีเฟรชเอง
--   ProfileData.init ก็เรียกตัวนี้ตอนแรกเหมือนกัน (ProfileData.lua:54)
local function refreshLevels()
    -- โฟลเดอร์ Remote อาจยังไม่ทันมาตอนสคริปต์รัน ดึงใหม่ได้ถ้ายังไม่มี
    if not GetTotalDataRF then
        GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
    end
    if not GetTotalDataRF then return false end
    local ok, data = pcall(function() return GetTotalDataRF:InvokeServer() end)
    if not ok then return false end
    applyStore(data)
    return true
end

local function getLevel(statName)
    return levels[statName] or 0
end

-- ราคาเลเวลถัดไป -> nil = อัปได้แล้ว
local function nextPrice(statName)
    local table_ = PRICE[statName]
    if not table_ then return nil end
    return table_[getLevel(statName) + 1]
end

local function isMax(statName)
    return nextPrice(statName) == nil
end

-- ============================================
-- วงจรอัป
-- ============================================
-- อัปต่อได้เรื่อย ๆ ตราบใดที่เงินยังพอ
--   เงินไม่พอ -> ไม่ยิง แล้วรอรอบถัดไป (เงินได้จากการขุด มาเรื่อย ๆ ตอนฟาร์ม)
--   เงินพอแล้วอีก -> อัปต่อในรอบถัดไปเอง ไม่ต้องกดซ้ำ
-- ยิงทีละชิ้นแล้วรอให้เลเวลขยับจริง ไม่ยิงรัว ๆ
--   เพราะเซิร์ฟเวอร์มีโอกาสปฏิเสธถ้ายิงถี่เกิน และเราต้องรู้ว่าของที่ซื้อสำเร็จแล้ว
local autoEnabled = false
local autoRunning = false
local statEnabled = {OrePack = true, Train = true, Luck = true}
local label = nil

-- นับครั้งที่ยิงแล้วเลเวลไม่ขยับ ถ้าพัง 3 ครั้งติดก็แสดงว่าเราอ่านเลเวลไม่ได้
--   (หรือเซิร์ฟเวอร์ปฏิเสธ) ถ้าไม่หยุด มันจะยิงซ้ำราคาเดิมไปเรื่อย ๆ เปลืองเงิน
local failCount = {OrePack = 0, Train = 0, Luck = 0}
local FAIL_LIMIT = 3

local function buyOnce(statName)
    local remote = UpgradeOnceRE or getRemote("Upgrade", "UpgradeOnceRE")
    if not remote then return false end
    UpgradeOnceRE = remote

    local price = nextPrice(statName)
    if not price then return false end

    local coin = getCoin()
    if not coin or coin < price then return false end

    local before = getLevel(statName)
    pcall(function() remote:FireServer(statName) end)

    -- รอให้เลเวลขยับจริง (สูงสุด 1.5 วิ) ถ้าไม่ขยับแปลว่าไม่สำเร็จ อย่ายิงซ้ำ
    local waited = 0
    while waited < 1.5 do
        task.wait(0.1)
        waited = waited + 0.1
        if getLevel(statName) > before then
            failCount[statName] = 0
            return true
        end
    end

    failCount[statName] = failCount[statName] + 1
    if failCount[statName] >= FAIL_LIMIT then
        -- อ่านเลเวลใหม่ 1 ครั้ง ถ้ายังไม่ขยับก็ถือว่าตัวนี้ซื้อไม่ได้ ข้ามไปก่อน
        refreshLevels()
    end
    return false
end

-- ไล่ทีละสถิติในลำดับ ถ้าเงินไม่พอจะหยุดที่ตัวนั้นแล้วขยับไปตัวถัดไป
--   ตัวถัดไปอาจถูกกว่า (เช่น OrePack ยังไม่ตัน แต่ Train แพงเกิน) -> ยังซื้อได้
local function autoPass()
    local bought = 0
    for _, name in ipairs(STATS) do
        if not autoEnabled then break end
        if statEnabled[name] and failCount[name] < FAIL_LIMIT and not isMax(name) then
            if buyOnce(name) then
                bought = bought + 1
            end
        end
    end
    return bought
end

-- ย่อเลขให้สั้นลง เหลือที่เหลือเป็นหนึ่งหลัก
--   ราคาของเลเวลบนสุดไปถึง 1.55 พันล้าน ถ้าเขียนเต็มบรรทัดจะยาวเกินกรอบแล้วถูกตัด
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

local function updateLabel()
    if not label then return end

    -- แยกทีละบรรทัด อย่ายัดไว้บรรทัดเดียว ไม่งั้นข้อความยาวเกินแล้วโดนตัดทิ้ง
    local parts = {}
    local coin = getCoin()
    if coin then
        parts[#parts + 1] = "เหรียญ " .. fmt(coin)
    end
    for _, name in ipairs(STATS) do
        local price = nextPrice(name)
        local levelText = STAT_NAME[name] .. " Lv." .. getLevel(name)
        if price then
            parts[#parts + 1] = levelText .. " -> " .. fmt(price)
        else
            parts[#parts + 1] = levelText .. " (ตัน)"
        end
    end

    local text = table.concat(parts, "\n")
    label.Desc = text
    -- Paragraph ไม่มี SetValue แต่มี SetDesc ของตัวเฟรมข้างใน (components/window/Element.lua:482)
    pcall(function() label.ParagraphFrame:SetDesc(text) end)
end

-- รีเฟรชข้อมูลทุก 2 วิ ไม่ต้องกดเอง
--   ปกติเลเวลจะมากับ UpdateDataRE อยู่แล้ว รอบนี้เป็นตาข่ายนิรภัย
--   กันกรณี push ตกหล่น แล้วเลเวลที่แคชไว้จะค้างทำให้คิดราคาผิด
--   ทำงานตลอดอายุโมดูล ไม่ว่าจะเปิดอัปอัตโนมัติหรือไม่ก็ตาม
local REFRESH_EVERY = 2

local function statusLoop()
    while true do
        refreshLevels()
        updateLabel()
        task.wait(REFRESH_EVERY)
    end
end

local function autoLoop()
    refreshLevels()
    while autoEnabled do
        local bought = autoPass()
        -- ซื้อได้ -> วนต่อทันทีไม่ต้องหน่วง ให้ได้มากที่สุดตามเงินที่มี
        -- ซื้อไม่ได้เลย (เงินไม่พอ/ตันหมด) -> หน่วงรอเงินเข้ามา
        if bought == 0 then
            updateLabel()
            task.wait(1)
        end
    end
    autoRunning = false
end

local function setAuto(value)
    autoEnabled = value == true
    if autoEnabled then
        refreshLevels()
        if not autoRunning then
            autoRunning = true
            task.spawn(autoLoop)
        end
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Upgrade.register(context)
    local tab = context.Tab
    if not tab then return end

    local section = tab:Section({Title = "อัปเกรดอัตโนมัติ", Opened = true})
    if section then
        section:Toggle({
            Title = "เปิดอัปเกรดอัตโนมัติ",
            Desc = "อัปทีละเลเวลไปเรื่อยๆ",
            Value = false,
            Callback = setAuto,
        })

        local status = section:Paragraph({
            Title = "สถานะ",
            Desc = "กำลังอ่านข้อมูล...",
        })
        label = status
    end

    local pick = tab:Section({Title = "เลือกว่าจะอัพตัวไหน", Opened = true})
    if pick then
        pick:Toggle({
            Title = "พลังโจมตี (Train)",
            Desc = "ดาเมจที่ใช้ตีมอนและเทรน",
            Value = true,
            Callback = function(value) statEnabled.Train = value == true end,
        })
        pick:Toggle({
            Title = "โชค (Luck)",
            Desc = "เพิ่มโอกาสดรอปของ",
            Value = true,
            Callback = function(value) statEnabled.Luck = value == true end,
        })
        pick:Toggle({
            Title = "ขนาดกระเป๋า (OrePack)",
            Desc = "กระเป๋าเก็บแร่",
            Value = true,
            Callback = function(value) statEnabled.OrePack = value == true end,
        })
    end

    -- รีเฟรชทุก 2 วิตลอดอายุโมดูล ไม่ต้องกดปุ่ม
    task.spawn(statusLoop)
end

return Upgrade
