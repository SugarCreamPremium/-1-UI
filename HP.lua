-- Version 9.25
-- หมวดผู้เล่น
-- โมดูลนี้ไม่ require อะไรจากเกม ใช้แค่ Players + workspace
-- เพราะเกมนี้ไม่มี require(player.PlayerScripts.Client) แบบเกมอื่น
local Player = {}

local Players = game:GetService("Players")
local player = Players.LocalPlayer

-- เลือดผู้เล่น = Inf
local INF_HP = math.huge

-- ความเร็วเดิน: 16 (ค่าปกติของเกม) ไปจนถึง 150
local WALK_MIN, WALK_MAX, WALK_DEFAULT = 16, 150, 16

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
-- ความเร็วเดิน = ล็อคค่า เกมเขียนทับไม่ได้
-- ============================================
-- เกมเขียน Humanoid.WalkSpeed โดยตรง ไม่ผ่านตัวควบคุมกลาง:
--   CharUtils.UpdatePlrWalkSpeed (SkillSystemNew/Utils/CharUtils.lua:98,101)
--   -> v1.WalkSpeed = v2[v3].Speed
-- เรียกจาก debuff กับสกิล เช่น Ice (DebuffEffect.lua:38), Freezen (:113),
--   Boss S1 ทั้งหมด และ SetWalkSpeedPercent(1.5) ตอนจบเวท (StageUtils.lua:259)
--
-- วิธีล็อค: ฟัง GetPropertyChangedSignal("WalkSpeed") แล้วเขียนค่าที่ตั้งไว้กลับทันที
--   ตั้งค่าเดิมซ้ำ = Roblox ไม่ยิง signal กลับ -> ไม่เกิด recursion
--   ไม่ต้องไปแก้ตาราง modifier ของเกม เพราะสคริปต์อื่นอาจเขียนทับอีก
--
-- ผลข้างเคียงที่ตั้งใจให้: ล็อคแล้ว debuff ที่ลดความเร็ว (น้ำแข็ง/ติดแข็ง) จะไม่มีผล
--   ถ้าอยากให้ debuff ยังทำงาน ต้องปลดล็อค (เลื่อนสไลเดอร์) ซึ่งก็คือค่าปกติของเกมอยู่แล้ว
local walkValue = nil
local walkConn = nil
local walkHum = nil
local walkRunning = false

local function getHumanoid()
    local char = player.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function applyWalk()
    local hum = getHumanoid()
    if hum and walkValue and hum.WalkSpeed ~= walkValue then
        pcall(function() hum.WalkSpeed = walkValue end)
    end
end

-- ผูก signal ใหม่ทุกครั้งที่ตัว Humanoid เปลี่ยน (respawn แล้วเป็นตัวใหม่)
local function bindWalk()
    local hum = getHumanoid()
    if hum and hum ~= walkHum then
        if walkConn then walkConn:Disconnect() end
        walkHum = hum
        walkConn = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(applyWalk)
    end
end

local function setWalk(value)
    walkValue = math.clamp(math.floor(value + 0.5), WALK_MIN, WALK_MAX)
    bindWalk()
    applyWalk()
    -- ถ้ายังไม่มีลูปคอยอยู่ ให้เปิด (ลูปนี้ทำหน้าที่จับกรณีเกมเปลี่ยนตัว Humanoid
    -- โดยไม่ผ่าน CharacterAdded เช่นระหว่างตาย/เกิดใหม่)
    if not walkRunning then
        walkRunning = true
        task.spawn(function()
            while walkValue do
                bindWalk()
                applyWalk()
                task.wait(1)
            end
            walkRunning = false
        end)
    end
end

-- respawn แล้ว Humanoid มาใหม่ ต้องผูก signal ใหม่
-- WaitForChild กันกรณี Humanoid ยังไม่ถูกสร้างตอน CharacterAdded ยิง
player.CharacterAdded:Connect(function(char)
    if not walkValue then return end
    local hum = char:WaitForChild("Humanoid", 10)
    if hum then
        bindWalk()
        applyWalk()
    end
end)

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Player.register(context)
    local tab = context.Tab
    if not tab then return end

    local hpSection = tab:Section({Title = "เลือดผู้เล่น", Opened = true})
    if hpSection then
        hpSection:Toggle({
            Title = "เลือดไม่จำกัด (Inf)",
            Desc = "ตั้ง HPValue ของตัวเองเป็น Inf เลือดไม่มีวันหมด "
                .. "(ตัวเลขบนแถบเลือดจะขึ้น nan แต่แถบยังเต็มปกติ)",
            Value = false,
            Callback = setPlayerInf,
        })
    end

    local moveSection = tab:Section({Title = "การเคลื่อนที่", Opened = true})
    if moveSection then
        moveSection:Slider({
            Title = "ความเร็วเดิน",
            Desc = "ล็อคค่าไว้ เกมจะเปลี่ยนกลับไม่ได้ (รวมถึง debuff ที่ลดความเร็วด้วย)",
            Value = {Min = WALK_MIN, Max = WALK_MAX, Default = WALK_DEFAULT},
            Step = 1,
            Callback = setWalk,
        })
    end
end

return Player
