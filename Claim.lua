-- Version 1.00
-- แถบรับของ (รับรางวัลที่เกมแจกให้อัตโนมัติทุกอย่าง)
--
-- 4 ที่มีให้รับ และแต่ละที่ใช้ remote กับเงื่อนไขต่างกัน:
--
--   1) Update Log   UpdateLog/TryClaimUPDRewardRE:FireServer(เลขเวอร์ชัน)
--         ของแจกทุกเวอร์ชัน เคยรับแล้วหรือยังดูจาก Pem "UPDRD_<เวอร์ชัน>"
--         (GuiUtils/UpdateLogGUI.lua:68-74 ยิง, :96-100 จุดขายว่ายังไม่รับ)
--
--   2) Online       Online/TryClaimRE:FireServer(เลขขั้น)
--         ของแจกตามเวลาออนไลน์สะสม ตั้งแต่ 1 นาทีไปจนถึง 90 นาที (12 ขั้น)
--         รับได้เมื่อ เวลาที่เล่นมา >= เวลาที่ขั้นนั้นต้องใช้
--         เคยรับแล้วหรือยังดูจาก Online.Reward[ขั้น]
--         (LocalData/OnlineData.lua:45-47 ยิง, GuiUtils/OnlineGift/OnlineGift.lua:103-112 เงื่อนไข)
--
--   3) Index        Index/TryClaimIndexExpRF:InvokeServer(ชนิด, ID)   รับ EXP ของแต่ละชิ้นก่อน
--                   Index/TryClaimLevelRewardRF:InvokeServer()         แล้วค่อยรับรางวัลระดับ
--         EXP ของชิ้นนั้นรับได้เมื่อ ปลดล็อกแล้ว (Index.unlocked[id]) และยังไม่เคยรับ (Index.claimed[id])
--         รางวัลระดับรับได้เมื่อ EXP ถึงเกณฑ์ของเลเวลถัดไป
--         (LocalData/IndexData.lua:71-77, GuiUtils/IndexGUI.lua:310-321)
--         ลำดับสำคัญ: ต้องรับ EXP ให้หมดก่อน แล้วรางวัลระดับถึงจะปลดล็อก
--
--   4) Offline      Offline/TryClaimOfflineRewardRE:FireServer()   ไม่มีอาร์กิวเมนต์
--         เกมแจ้งผ่าน attribute OfflineRewardValue ว่ามีของค้างให้รับ
--         (GuiUtils/OfflineReward.lua:64-72 เช็ค attribute แล้วยิง)
--
-- ข้อมูลทั้งหมดมาจาก store "Pem" / "Online" / "Index" ในโปรไฟล์ผู้เล่น
--   ดึงมาทั้งก้อนด้วย Profile/GetTotalDataRF แล้วอัปเดตตาม Profile/UpdateDataRE
local Claim = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- ============================================
-- ดึง remote โดยไม่ต้อง require
-- ============================================
-- ห้าม require(CommunicationUtils / IndexData / OnlineData / PemData) เด็ดขาด
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

local TryClaimUPDRewardRE = getRemote("UpdateLog", "TryClaimUPDRewardRE")
local TryClaimOnlineRE = getRemote("Online", "TryClaimRE")
local TryClaimIndexExpRF = getRemote("Index", "TryClaimIndexExpRF")
local TryClaimLevelRewardRF = getRemote("Index", "TryClaimLevelRewardRF")
local TryClaimOfflineRewardRE = getRemote("Offline", "TryClaimOfflineRewardRE")

-- ============================================
-- ตารางตัวเลขที่ต้องคัดมาเอง (require ไม่ได้)
-- ============================================
-- เวลาออนไลน์ขั้นละกี่วินาทีจึงรับได้  Config/Online/Helper.lua:21-34
local ONLINE_TIME = {
    ["1"] = 60, ["2"] = 180, ["3"] = 300, ["4"] = 480, ["5"] = 600, ["6"] = 900,
    ["7"] = 1200, ["8"] = 1500, ["9"] = 1800, ["10"] = 2400, ["11"] = 3000, ["12"] = 5400,
}

-- EXP ที่ต้องมีถึงจึงรับรางวัลระดับถัดไปได้  Config/Index/Config.lua
--   เกมเช็คที่ GetNeedExp(level + 1) ค่าที่ไม่มีในตาราง = เลเวลสูงสุด รับไม่ได้แล้ว
local INDEX_NEED_EXP = {
    [0] = 0, [1] = 50, [2] = 75, [3] = 100, [4] = 125, [5] = 150, [6] = 175,
    [7] = 200, [8] = 225, [9] = 250, [10] = 300, [11] = 325, [12] = 350,
    [13] = 375, [14] = 400, [15] = 425, [16] = 450,
}

-- เวลาหน่วงระหว่างชิ้น กันยิงรัวจนเซิร์ฟเวอร์ปฏิเสธ
local CLAIM_GAP = 0.15

-- ============================================
-- ข้อมูลผู้เล่น
-- ============================================
local GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
local total = nil

local function store(name)
    if type(total) ~= "table" then return nil end
    local value = total[name]
    return type(value) == "table" and value or nil
end

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
        if type(total) ~= "table" or type(value) ~= "table" then return end
        total[key] = value
    end)
end

-- ============================================
-- หาเฟรมในหน้าต่างของเกม
-- ============================================
-- เกมสร้างเฟรมของรายการที่รับได้ไว้ล่วงหน้าแล้ว
--   Update Log: เฟรมชื่อ = key ของ Config (เลขล้วน เรียงตามเวอร์ชัน)
--     (UpdateLogGUI.lua:52-57  ไล่ Config แล้ว Clone เทมเพลต ใส่ชื่อ = key)
--   Index:       เฟรมชื่อ = GetIndexID(ชนิด, ID) และมี attribute "Type" เป็นชนิด
--     (IndexGUI.lua:113-117  v5.Name = GetIndexID(...), SetAttribute("Type", ...))
--   การอ่านชื่อจากเฟรม ทำให้เวอร์ชันใหม่ที่เกมเพิ่มเข้ามาก็ใช้ได้เอง ไม่ต้องแก้โค้ด
local function findGui(...)
    local node = player:FindFirstChild("PlayerGui")
    for i = 1, select("#", ...) do
        if not node then return nil end
        node = node:FindFirstChild((select(i, ...)))
    end
    return node
end

local function listFrames(...)
    local folder = findGui(...)
    if not folder then return nil end
    local frames = {}
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("Frame") then
            frames[#frames + 1] = child
        end
    end
    return frames
end

-- GetIndexID คือ ("%*-%*"):format(ชนิด, ID) -> "Weapon-K_5"  (Config/Index/Helper.lua:12-14)
--   ชื่อชิ้นของเกมมี "_" แต่ไม่มี "-" ตัดที่ขีดแรกก็ได้ชนิดกับ ID กลับมา
local function splitIndexId(indexId)
    local itemType, itemId = tostring(indexId):match("^([^-]+)%-(.+)$")
    if not itemType then return nil, nil end
    return itemType, itemId
end

-- ============================================
-- 1) Update Log
-- ============================================
local function claimUpdateLog()
    local frames = listFrames("Main", "UpdateLog", "zheng", "wuqi", "Left", "ScrollingFrame")
    if not frames then return 0 end

    local remote = TryClaimUPDRewardRE or getRemote("UpdateLog", "TryClaimUPDRewardRE")
    if not remote then return 0 end
    TryClaimUPDRewardRE = remote

    local pem = store("Pem")
    local claimed = 0
    for _, frame in ipairs(frames) do
        -- ใน ScrollingFrame ยังมีเฟรม "Temple" ที่เกมใช้เป็นต้นแบบอยู่ด้วย
        --   เฟรมของแต่ละเวอร์ชันชื่อเป็นเลขล้วน เพราะ key ของ Config เป็นเลข
        --   (UpdateLogGUI.lua:52-57) เฟรมนอกจากนี้ไม่ต้องแตะ
        local version = tonumber(frame.Name)
        -- Pem เก็บด้วยชื่อ "UPDRD_" .. key (UpdateLogGUI.lua:96,148)
        if version and not (pem and pem["UPDRD_" .. version]) then
            pcall(function() remote:FireServer(version) end)
            claimed = claimed + 1
            task.wait(CLAIM_GAP)
        end
    end
    return claimed
end

-- ============================================
-- 2) Online
-- ============================================
-- เวลาที่เล่นมาจริง = เวลาเซิร์ฟเวอร์ + PassTime - StartTick
--   (OnlineGift.lua:146-157  ใช้สูตรเดียวกับปุ่มใน UI)
local function onlineSeconds()
    local online = store("Online")
    if not online then return 0 end
    local now = workspace:GetAttribute("ServerTime")
    if not now then
        now = os.time()
    end
    local start = tonumber(online.StartTick) or now
    return math.floor((tonumber(online.PassTime) or 0) + now - start)
end

local function claimOnline()
    local online = store("Online")
    if not online then return 0 end
    local reward = type(online.Reward) == "table" and online.Reward or {}

    local remote = TryClaimOnlineRE or getRemote("Online", "TryClaimRE")
    if not remote then return 0 end
    TryClaimOnlineRE = remote

    local played = onlineSeconds()
    local claimed = 0
    -- ไล่จากขั้นเวลาน้อยสุด เพราะถ้าข้ามขั้นไป เกมจะไม่ให้ของขั้นที่หลุด
    for _, need in ipairs({"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"}) do
        local seconds = ONLINE_TIME[need]
        if seconds and played >= seconds and not reward[need] then
            pcall(function() remote:FireServer(need) end)
            reward[need] = true
            claimed = claimed + 1
            task.wait(CLAIM_GAP)
        end
    end
    return claimed
end

-- ============================================
-- 3) Index
-- ============================================
-- ขั้นที่ 1: รับ EXP ของทุกชิ้นที่ปลดล็อกแล้วแต่ยังไม่เคยรับ
local function claimIndexExp()
    local frames = listFrames("Main", "Index", "zheng", "wuqi", "Bg", "ScrollingFrame")
    if not frames then return 0 end

    local remote = TryClaimIndexExpRF or getRemote("Index", "TryClaimIndexExpRF")
    if not remote then return 0 end
    TryClaimIndexExpRF = remote

    local index = store("Index")
    if not index then return 0 end
    local unlocked = type(index.unlocked) == "table" and index.unlocked or {}
    local claimed = type(index.claimed) == "table" and index.claimed or {}

    local count = 0
    for _, frame in ipairs(frames) do
        local itemType, itemId = splitIndexId(frame.Name)
        local indexId = frame.Name
        if itemType and unlocked[indexId] and not claimed[indexId] then
            local ok = pcall(function() remote:InvokeServer(itemType, itemId) end)
            if ok then
                claimed[indexId] = true
                count = count + 1
                task.wait(CLAIM_GAP)
            end
        end
    end
    return count
end

-- ขั้นที่ 2: EXP ที่รับมาแล้วอาจดันเลเวลให้ถึงเกณฑ์ ค่อยมารับรางวัลระดับต่อ
local function claimIndexLevel()
    local remote = TryClaimLevelRewardRF or getRemote("Index", "TryClaimLevelRewardRF")
    if not remote then return false end
    TryClaimLevelRewardRF = remote

    local index = store("Index")
    if not index then return false end
    local need = INDEX_NEED_EXP[(tonumber(index.level) or 0) + 1]
    if not need then return false end
    if (tonumber(index.exp) or 0) < need then return false end

    return (pcall(function() remote:InvokeServer() end))
end

-- ============================================
-- 4) Offline
-- ============================================
-- เกมใส่ attribute นี้ไว้ตอนคนออกเกมแล้วกลับมา แปลว่ามีของค้างให้รับ
--   (OfflineReward.lua:41-67 ฟัง attribute แล้วเปิดหน้าต่าง)
-- ยิงเสร็จเกมจะลบ attribute ทิ้งเอง แต่กันเหนียวไว้ด้วยการจำค่าที่ยิงไปล่าสุด
--   ไม่งั้นถ้าเกมยังไม่ลบ เราจะยิงซ้ำทุก 3 วิไปเรื่อย ๆ
local lastOfflineTried = nil

local function claimOffline()
    local value = player:GetAttribute("OfflineRewardValue")
    if not value or value == lastOfflineTried then return false end
    lastOfflineTried = value

    local remote = TryClaimOfflineRewardRE or getRemote("Offline", "TryClaimOfflineRewardRE")
    if not remote then return false end
    TryClaimOfflineRewardRE = remote
    return (pcall(function() remote:FireServer() end))
end

-- ============================================
-- ลูปหลัก
-- ============================================
local CLAIM_EVERY = 3

local claimEnabled = false
local claimRunning = false

local function claimOnce()
    -- อัปเดตข้อมูลก่อนทุกรอบ เพราะทุกอย่างตัดสินจาก store
    --   เคยรับแล้วหรือยัง / EXP ถึงเกณฑ์หรือยัง  ถ้าใช้ค่าค้างจะยิงซ้ำทุกรอบ
    if not refresh() then return false end

    -- เรียงตามที่ผู้ใช้บอก: Index ต้องรับ EXP ให้หมดก่อนค่อยรับรางวัลระดับ
    local gotIndexExp = claimIndexExp()
    local gotLevel = claimIndexLevel()
    if gotLevel then
        -- รางวัลระดับทำให้ EXP เพิ่ม รอข้อมูลใหม่ก่อนไปรับระดับถัดไปในรอบหน้า
        refresh()
    end

    claimUpdateLog()
    claimOnline()
    claimOffline()

    return gotIndexExp > 0 or gotLevel
end

local function claimLoop()
    while claimEnabled do
        if not claimOnce() then
            -- รอบนี้ไม่มีอะไรให้รับ ไม่ต้องรีเฟรชบ่อย
            task.wait(CLAIM_EVERY)
        else
            -- มีอะไรรับได้ รีบรอบถัดไป เผื่อรับ EXP แล้วเลเวลเพิ่มขึ้นต่อ
            task.wait(1)
        end
    end
    claimRunning = false
end

local function setClaim(value)
    claimEnabled = value == true
    if claimEnabled and not claimRunning then
        claimRunning = true
        task.spawn(claimLoop)
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Claim.register(context)
    local tab = context.Tab
    if not tab then return end

    local section = tab:Section({Title = "รับของอัตโนมัติ", Opened = true})
    if not section then
        tab:Paragraph({Title = "รับของอัตโนมัติ", Desc = "ไม่สามารถสร้างส่วนควบคุมได้"})
        return
    end

    section:Toggle({
        Title = "เริ่ม Auto รับของ",
        Desc = "รับให้หมดทั้ง Update Log, ของออนไลน์, EXP ของ Index "
            .. "และรางวัลระดับ รวมถึงของที่ค้างจากตอนออกเกม",
        Value = false,
        Callback = setClaim,
    })
end

return Claim
