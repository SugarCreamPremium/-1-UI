-- Version 1.00
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

return Forge
