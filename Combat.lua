-- Version 12.15
-- หมวดต่อสู้
local Combat = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local ENEMY_FOLDER_NAME = "EnemyFolder"

-- ============================================
-- ดึง BindableEvent โดยไม่ต้อง require (เหมือนใน AutoFarm)
-- ============================================
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

-- ============================================
-- เลือดมอนสเตอร์ใน workspace.EnemyFolder = 0
-- ============================================
-- EnemyCTRL.HurtEnemy -> HPCTRL.DamageOnce -> UpdateHPValue (ReplicatedStorage/CTRL/HPCTRL.lua:139)
--   HPValue.Value = HPValue.Value - ดาเมจ   (ไม่ clamp)
--   คืน true เมื่อ HPValue.Value <= 0 -> ฝั่ง client เรียก DeadEnemyData -> ได้ของแล้ว
--
-- EnemyCTRL._CreateEnemyModel เอาโมเดลไป Parent ใน EnemyFolder ก่อน
--   แล้วค่อยเรียก RegistEnemyHP ที่ EnemyCTRL.lua:227
--   -> ตอน ChildAdded ยังไม่มี HPValue ต้องมีลูปคอยอีกชั้น
--
-- มอนที่ HP = 0 จะตายตอนถูกโจมตีครั้งถัดไป ไม่ใช่ตายทันทีที่ตั้งค่า
--   เพราะ DeadEnemyData ถูกเรียกจาก HurtEnemy ทางเดียว
--   (มอนที่ยังไม่ถูกโจมตีเลยก็ยังไม่ตาย แถบเลือดจะเห็นเป็น 0)

local enemyZeroEnabled = false
local enemyZeroRunning = false
local enemyChildConn = nil

local function zeroEnemyHP(enemy)
    local hp = enemy:FindFirstChild("HPValue")
    if not hp or not hp:IsA("NumberValue") then return false end
    pcall(function()
        if hp.Value ~= 0 then hp.Value = 0 end
    end)
    return true
end

-- คืนจำนวนมอนที่มี HPValue (ไม่นับตัวที่เกมยังไม่ได้ RegistEnemyHP)
local function sweepEnemies()
    local folder = workspace:FindFirstChild(ENEMY_FOLDER_NAME)
    if not folder then return 0 end
    local count = 0
    for _, enemy in ipairs(folder:GetChildren()) do
        if zeroEnemyHP(enemy) then
            count = count + 1
        end
    end
    return count
end

local function enemyZeroLoop()
    while enemyZeroEnabled do
        local folder = workspace:FindFirstChild(ENEMY_FOLDER_NAME)
        if folder then
            if not enemyChildConn then
                -- มอนใหม่ที่โผล่มา = เขียนทันที ไม่ต้องรอรอบถัดไป
                enemyChildConn = folder.ChildAdded:Connect(function(enemy)
                    if enemyZeroEnabled then
                        zeroEnemyHP(enemy)
                    end
                end)
            end
            sweepEnemies()
        end
        task.wait(0.5)
    end
    if enemyChildConn then enemyChildConn:Disconnect() end
    enemyChildConn = nil
    enemyZeroRunning = false
end

local function setEnemyZero(value)
    enemyZeroEnabled = value == true
    if enemyZeroEnabled and not enemyZeroRunning then
        enemyZeroRunning = true
        task.spawn(enemyZeroLoop)
    end
end

-- ============================================
-- Kill Aura (ตีรัศมี)
-- ============================================
-- ยิง EnemyHitBE ใส่มอนทุกตัวที่อยู่ในระยะ โดยไม่ต้องหันตัวหรือเดินเข้าไป
--   EnemyHitBE:Fire(uuid, ดาเมจ, opts) -> StageUtils.HurtEnemy
--     -> EnemyCTRL.HurtEnemy -> HPCTRL.DamageOnce -> HPValue <= 0 -> ตาย
--
-- ดาเมจ = HP ของมอนเอง +1 (ห้ามใช้ค่าคงที่ เพราะเลือดมอนโตแบบทวีคูญ)
--   และห้ามใช้ math.huge เพราะ HPCTRL.DamageOnce เอา 1e18 ไปลบ inf
--   ได้ inf ซึ่งไม่ <= 0 = ไม่ตาย
local function hitEnemy(enemy)
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

local function getHRP()
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local auraEnabled = false
local auraRange = 25
local auraRunning = false

-- ยิงมอนทุกตัวที่อยู่ในระยะ -> คืนจำนวนที่โดน
local function auraSweep()
    local hrp = getHRP()
    local folder = workspace:FindFirstChild(ENEMY_FOLDER_NAME)
    if not hrp or not folder then return 0 end

    local origin = hrp.Position
    local hit = 0
    for _, enemy in ipairs(folder:GetChildren()) do
        if enemy:IsA("Model") then
            local primary = enemy.PrimaryPart or enemy:FindFirstChild("HumanoidRootPart")
            if primary and (primary.Position - origin).Magnitude <= auraRange then
                hitEnemy(enemy)
                hit = hit + 1
            end
        end
    end
    return hit
end

local function auraLoop()
    while auraEnabled do
        auraSweep()
        task.wait(0.1)
    end
    auraRunning = false
end

local function setAura(value)
    auraEnabled = value == true
    if auraEnabled and not auraRunning then
        auraRunning = true
        task.spawn(auraLoop)
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Combat.register(context)
    local tab = context.Tab
    local WindUI = context.WindUI
    if not tab then return end

    local function notify(title, desc)
        if not WindUI then return end
        pcall(function()
            WindUI:Notify({Title = title, Content = desc, Duration = 3})
        end)
    end

    local section = tab:Section({Title = "เลือดมอนสเตอร์", Opened = true})
    if section then
        section:Toggle({
            Title = "เซ็ต HP มอนสเตอร์เป็น 0",
            Desc = "ตั้งเลือดมอนสเตอร์ทุกตัวเป็น 0 ตลอดเวลา",
            Value = false,
            Callback = setEnemyZero,
        })
        section:Button({
            Title = "เซ็ตครั้งเดียว",
            Desc = "ตั้งเลือดมอนสเตอร์ทุกตัวเป็น 0 แค่รอบเดียว",
            Callback = function()
                local count = sweepEnemies()
                notify("เซ็ต HP มอนสเตอร์แล้ว", "ตั้งเป็น 0 ให้ " .. count .. " ตัว")
            end,
        })
    end

    local auraSection = tab:Section({Title = "Kill Aura", Opened = true})
    if auraSection then
        auraSection:Toggle({
            Title = "เปิด Kill Aura",
            Desc = "ฆ่ามอนอัตโนมัติทุกตัวที่อยู่ในระยะ ไม่ต้องเดินเข้าไปหรือหันตัวเอง",
            Value = false,
            Callback = setAura,
        })
        auraSection:Slider({
            Title = "ระยะ",
            Desc = "หน่วย stud วัดจากตัวละคร",
            Value = {Min = 5, Max = 500, Default = 25},
            Step = 1,
            Callback = function(value) auraRange = math.clamp(value, 5, 80) end,
        })
        auraSection:Button({
            Title = "ยิงครั้งเดียว",
            Desc = "ฆ่ามอนในระยะ 1 รอบ",
            Callback = function()
                local hit = auraSweep()
                notify("ยิงแล้ว", hit .. " ตัว ในระยะ " .. auraRange)
            end,
        })
    end
end

return Combat
