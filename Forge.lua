-- Version 2.06
-- แถบคราฟ (Forge)
--
-- ใช้ ForgeRF เพื่อคราฟของจากแร่
-- ForgeRF:InvokeServer({ConfigType, UUIDList})
-- ConfigType = "Weapon" หรือ "Armor" เท่านั้น (หมวกอยู่ใน Armor)
-- UUIDList = {[oreUUID] = count} ต้องมีแร่รวม >= 4 ชิ้น
local Forge = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local function getRemote(folderName, remoteName)
    local root = ReplicatedStorage:FindFirstChild("Remote")
    if not root then return nil end
    local folder = root:FindFirstChild(folderName)
    if not folder then return nil end
    return folder:FindFirstChild(remoteName)
end

local function getRemoteSafe(folderName, remoteName)
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
    local ev = folder:FindFirstChild(remoteName)
    if not ev then return nil end
    return ev
end

local ForgeRF = nil
local EquipRE = nil
local GetTotalDataRF = nil
local UpdateDataRE = nil

local function refreshRemotes()
    ForgeRF = ForgeRF or getRemote("Forge", "ForgeRF")
    EquipRE = EquipRE or getRemote("Backpack", "TryEquipItemRE")
    GetTotalDataRF = GetTotalDataRF or getRemote("Profile", "GetTotalDataRF")
end

-- อ่านข้อมูลโปรไฟล์
local totalData = nil

local function refreshData()
    if not GetTotalDataRF then
        GetTotalDataRF = getRemote("Profile", "GetTotalDataRF")
    end
    if not GetTotalDataRF then return false end
    local ok, data = pcall(function() return GetTotalDataRF:InvokeServer() end)
    if not ok or type(data) ~= "table" then return false end
    totalData = data
    return true
end

if UpdateDataRE == nil then
    UpdateDataRE = getRemoteSafe("Profile", "UpdateDataRE")
end
if UpdateDataRE then
    UpdateDataRE.OnClientEvent:Connect(function(key, value)
        if type(totalData) ~= "table" or type(value) ~= "table" then return end
        totalData[key] = value
    end)
end

local function getBackpackHave()
    if type(totalData) ~= "table" then return nil end
    local bp = totalData.Backpack
    if type(bp) ~= "table" then return nil end
    if type(bp.have) ~= "table" then return nil end
    return bp.have
end

local function getEquipped()
    if type(totalData) ~= "table" then return nil end
    local bp = totalData.Backpack
    if type(bp) ~= "table" then return nil end
    if type(bp.equiped) ~= "table" then return nil end
    return bp.equiped
end

local forgeEnabled = false
local forgeRunning = false
local forgeEquipBetter = true
local forgeTargets = {Weapon = true, Hat = true, Armor = true}

local function pickBestOres(have)
    local selected = {}
    local total = 0
    if type(have) ~= "table" then return selected, total end
    for uuid, it in pairs(have) do
        if type(it) == "table" and it.Type == "Ore" and not selected[uuid] then
            local num = tonumber(it.Number) or 1
            if num > 0 then
                local take = num
                if total + take > 4 then
                    take = 4 - total
                end
                if take > 0 then
                    selected[uuid] = take
                    total = total + take
                end
                if total >= 4 then
                    break
                end
            end
        end
    end
    return selected, total
end

local function getItemPower(item)
    if type(item) ~= "table" then return 0 end
    local itype = item.Type
    if itype == "Weapon" then
        return tonumber(item.Train) or 0
    elseif itype == "Armor" or itype == "Hat" then
        return tonumber(item.AttriNum) or 0
    end
    return 0
end

local function isBetter(newItem, oldItem)
    if type(newItem) ~= "table" then return false end
    if type(oldItem) ~= "table" then return true end
    local np = getItemPower(newItem)
    local op = getItemPower(oldItem)
    if np > op then return true end
    return false
end

local function findEquippedOfType(slotType)
    local eq = getEquipped()
    if type(eq) ~= "table" then return nil end
    local uuid = eq[slotType]
    if not uuid then return nil end
    local have = getBackpackHave()
    if type(have) ~= "table" then return nil end
    return have[uuid]
end

local function forgeOnce(targetType)
    if not ForgeRF then refreshRemotes() end
    if not ForgeRF then return false end
    refreshData()
    local have = getBackpackHave()
    local selected, total = pickBestOres(have)
    if total < 4 then return false end
    local before = {}
    if type(have) == "table" then
        for uuid, _ in pairs(have) do
            before[uuid] = true
        end
    end
    local cfgType = "Weapon"
    if targetType == "Weapon" then
        cfgType = "Weapon"
    elseif targetType == "Hat" or targetType == "Armor" then
        cfgType = "Armor"
    else
        cfgType = "Weapon"
    end
    local ok, res = pcall(function()
        return ForgeRF:InvokeServer({ConfigType = cfgType, UUIDList = selected})
    end)
    if not ok or type(res) ~= "table" or type(res[1]) ~= "table" then
        return false
    end
    task.wait(1)
    refreshData()
    have = getBackpackHave()
    if type(have) == "table" then
        for uuid, it in pairs(have) do
            if not before[uuid] and type(it) == "table" and it.ID == res[1].ID and it.Type == res[1].Type then
                equipIfBetter(res)
                break
            end
        end
    end
    return true
end

local function forgeLoop()
    while forgeEnabled do
        refreshData()
        if forgeTargets.Weapon then
            pcall(function() forgeOnce("Weapon") end)
            task.wait(0.5)
        end
        if forgeTargets.Hat then
            pcall(function() forgeOnce("Hat") end)
            task.wait(0.5)
        end
        if forgeTargets.Armor then
            pcall(function() forgeOnce("Armor") end)
            task.wait(0.5)
        end
        if not forgeTargets.Weapon and not forgeTargets.Hat and not forgeTargets.Armor then
            task.wait(1)
            continue
        end
        task.wait(0.3)
    end
    forgeRunning = false
end

local function setForgeEnabled(value)
    forgeEnabled = value == true
    if forgeEnabled and not forgeRunning then
        forgeRunning = true
        task.spawn(forgeLoop)
    end
end

local function setForgeEquipBetter(value)
    forgeEquipBetter = value == true
end

local function setForgeTarget(t, value)
    if t == "Weapon" then forgeTargets.Weapon = value == true end
    if t == "Hat" then forgeTargets.Hat = value == true end
    if t == "Armor" then forgeTargets.Armor = value == true end
end

-- ============================================
-- register: ผูกกับแถบของ WindUI
-- ============================================
function Forge.register(context)
    local tab = context.Tab
    if not tab then return end

    refreshRemotes()

    local section = tab:Section({Title = "คราฟอัตโนมัติ", Opened = true})
    if not section then
        tab:Paragraph({Title = "คราฟอัตโนมัติ", Desc = "ไม่สามารถสร้างส่วนควบคุมได้"})
        return
    end

    section:Toggle({
        Title = "เริ่ม Auto คราฟ",
        Desc = "คราฟของตามที่เลือก (เลือกได้หลายแบบพร้อมกัน)",
        Value = false,
        Callback = setForgeEnabled,
    })

    section:Toggle({
        Title = "สวมใส่ของใหม่ถ้าดีกว่าอันเก่า",
        Desc = "ถ้าอันที่คราฟมาใหม่ดีกว่าอันที่ใส่อยู่ จะเปลี่ยนทันที",
        Value = true,
        Callback = setForgeEquipBetter,
    })

    section:Divider({Text = "ประเภทที่ต้องการคราฟ"})

    section:Toggle({
        Title = "ดาบ (Weapon)",
        Desc = "คราฟประเภทดาบ",
        Value = true,
        Callback = function(v) setForgeTarget("Weapon", v) end,
    })

    section:Toggle({
        Title = "หมวก (Hat)",
        Desc = "คราฟประเภทหมวก",
        Value = true,
        Callback = function(v) setForgeTarget("Hat", v) end,
    })

    section:Toggle({
        Title = "เกราะ (Armor)",
        Desc = "คราฟประเภทเกราะ",
        Value = true,
        Callback = function(v) setForgeTarget("Armor", v) end,
    })
end

return Forge
