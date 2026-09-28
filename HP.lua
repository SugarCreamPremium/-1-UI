-- Version 1.00
-- โมดูลนี้ไม่ require อะไรจากเกม ใช้แค่ Players + workspace
-- เพราะเกมนี้ไม่มี require(player.PlayerScripts.Client) แบบเกมอื่น
local HP = {}

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local ENEMY_FOLDER_NAME = "EnemyFolder"
-- เลือดผู้เล่น = Inf
local INF_HP = math.huge

-- ============================================
-- เลือดผู้เล่น = Inf
-- ============================================
-- HPCTRL (ReplicatedStorage/CTRL/HPCTRL.lua) เป็นตัวกลางเลือดทั้งเกม
--   DamageOnce -> UpdateHPValue -> HPValue.Value = HPValue.Value - ดาเมจ   (ไม่ clamp)
--   คืน true เมื่อ Value <= 0  แล้วฝั่ง client เรียก PlayerDead()
-- ดังนั้นถ้า Value เป็น Inf: Inf - ดาเมจ = Inf เสมอ -> ไม่มีวัน <= 0 -> ไม่ตาย
--   (PlrManager.client.lua:260 เป็นคนเช็ค HPValue แล้วสั่ง PlayerDead)
--
-- ไม่ต้องแตะ MaxHP: แถบเลือดคำนวณ math.clamp(Value/MaxHP, 0, 1) -> clamp(inf,0,1) = 1 = เต็ม
--   แต่ข้อความเลขเลือดเรียก AbbreviateNumber(math.round(inf)) -> ขึ้น "nan"
--   (PlayerInfoGUI.lua:311) แถบยังเต็มปกติ แค่ตัวเลขเพี้ยน
--
-- HPValue ถูกสร้างตอนผู้เล่นพร้อม (PlrManager.client.lua:246) อาจยังไม่มีตอนสคริปต์รัน
-- และตอนเกิดใหม่ PlayerRebirth เรียก SetCurrentHP = รีเซ็ตค่าทันที
-- -> ต้องมีลูปคอยเขียนทับกลับ ไม่ใช่ตั้งครั้งเดียวจบ

local playerInfEnabled = false
local playerInfRunning = false
local playerInfConn = nil
local playerInfTarget = nil
local playerInfBackup = nil

local function getPlayerHP()
    local hp = player:FindFirstChild("HPValue")
    if not hp or not hp:IsA("NumberValue") then return nil end
    return hp
end

local function applyInfHP()
    -- เช็ค flag ด้วย ไม่งั้นรอบที่กำลังวิ่งอยู่จะเขียนค่าทับหลังที่ผู้ใช้กดปิด toggle ไปแล้ว
    if not playerInfEnabled then return false end
    local hp = getPlayerHP()
    if not hp then return false end
    pcall(function()
        if hp.Value ~= INF_HP then
            if playerInfBackup == nil then
                playerInfBackup = hp.Value
            end
            hp.Value = INF_HP
        end
    end)
    return true
end

local function playerInfLoop()
    while playerInfEnabled do
        if applyInfHP() then
            local hp = getPlayerHP()
            -- ต่อ signal ไว้ด้วย: ตอนเกมเขียน HPValue ทับ (เช่นตอนเกิดใหม่)
            -- ให้เขียนกลับทันที ไม่ต้องรอรอบของลูป
            -- ตั้งค่าเดิมซ้ำ = Roblox ไม่ยิง signal กลับ -> ไม่เกิด recursion
            if playerInfConn and playerInfTarget ~= hp then
                playerInfConn:Disconnect()
                playerInfConn = nil
            end
            if not playerInfConn then
                playerInfTarget = hp
                playerInfConn = hp:GetPropertyChangedSignal("Value"):Connect(function()
                    if playerInfEnabled and hp.Value ~= INF_HP then
                        pcall(function() hp.Value = INF_HP end)
                    end
                end)
            end
        elseif playerInfConn then
            -- ยังไม่มี HPValue (เกมสร้างตอนผู้เล่นพร้อม) -> ถอด signal รอรอบถัดไป
            playerInfConn:Disconnect()
            playerInfConn = nil
            playerInfTarget = nil
        end
        task.wait(0.5)
    end
    if playerInfConn then playerInfConn:Disconnect() end
    playerInfConn = nil
    playerInfTarget = nil
    playerInfRunning = false
end

local function setPlayerInf(value)
    playerInfEnabled = value == true
    if playerInfEnabled then
        applyInfHP()
        if not playerInfRunning then
            playerInfRunning = true
            task.spawn(playerInfLoop)
        end
    else
        -- คืนค่าเดิมที่จำไว้ตอนเปิด toggle (แบบ gfxSaved ในโมดูล Other)
        local hp = getPlayerHP()
        if hp and playerInfBackup ~= nil then
            local backup = playerInfBackup
            pcall(function() hp.Value = backup end)
        end
        playerInfBackup = nil
    end
end

-- ============================================
-- เลือดมอนสเตอร์ใน workspace.EnemyFolder = 0
-- ============================================
-- EnemyCTRL.HurtEnemy -> HPCTRL.DamageOnce -> UpdateHPValue
--   คืน true เมื่อ HPValue.Value <= 0 -> ฝั่ง client เรียก DeadEnemyData (ได้ของแล้ว)
--   EnemyFolder มีแค่ตัวละครมอน ตัวละครผู้เล่นอยู่ที่ Players/<ชื่อ>/HPValue
--   (ผู้เล่นไม่ได้อยู่ใน EnemyFolder จึงไม่โดนแตะ)
--
-- มอนที่ HP = 0 จะตายตอนถูกโจมตีครั้งถัดไป ไม่ใช่ตายทันทีที่ตั้งค่า
--   เพราะ DeadEnemyData ถูกเรียกจาก HurtEnemy เท่านั้น
-- มอนที่ยังไม่ถูกโจมตีเลยก็ยังไม่ตาย แถบเลือดจะเห็นเป็น 0

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
                -- แต่ EnemyCTRL เรียก RegistEnemyHP หลัง Parent เสร็จ
                -- -> ตอน ChildAdded ยังไม่มี HPValue ต้องมีลูปคอยอีกชั้น
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
    if enemyZeroEnabled then
        if not enemyZeroRunning then
            enemyZeroRunning = true
            task.spawn(enemyZeroLoop)
        end
    end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function HP.register(context)
    local tab = context.Tab
    local WindUI = context.WindUI
    if not tab then return end

    local function notify(title, desc)
        if not WindUI then return end
        pcall(function()
            WindUI:Notify({Title = title, Content = desc, Duration = 3})
        end)
    end

    local selfSection = tab:Section({Title = "เลือดผู้เล่น", Opened = true})
    if selfSection then
        selfSection:Toggle({
            Title = "เลือดไม่จำกัด (Inf)",
            Desc = "ตั้ง HPValue ของตัวเองเป็น Inf เลือดไม่มีวันหมด "
                .. "(ตัวเลขบนแถบเลือดจะขึ้น nan แต่แถบยังเต็มปกติ)",
            Value = false,
            Callback = setPlayerInf,
        })
    end

    local enemySection = tab:Section({Title = "เลือดมอนสเตอร์", Opened = true})
    if enemySection then
        enemySection:Toggle({
            Title = "เซ็ต HP มอนสเตอร์เป็น 0",
            Desc = "ตั้ง HPValue ใน workspace.EnemyFolder ทุกตัวเป็น 0 "
                .. "มอนจะตายทันทีที่ถูกโจมตีครั้งถัดไป (ปิดแล้วมอนที่เหลือคงค่า 0 ไว้)",
            Value = false,
            Callback = setEnemyZero,
        })
        enemySection:Button({
            Title = "เซ็ตครั้งเดียว",
            Desc = "ทำหนึ่งรอบแล้วเลิด ไม่ต้องเปิดค้างไว้",
            Callback = function()
                local count = sweepEnemies()
                notify("เซ็ต HP มอนสเตอร์แล้ว", "ตั้งเป็น 0 ให้ " .. count .. " ตัว")
            end,
        })
    end
end

return HP
