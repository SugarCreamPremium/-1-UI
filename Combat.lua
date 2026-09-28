-- Version 9.36
-- หมวดต่อสู้
local Combat = {}

local ENEMY_FOLDER_NAME = "EnemyFolder"

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
end

return Combat
