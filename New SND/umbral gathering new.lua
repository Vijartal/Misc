---@diagnostic disable: redundant-parameter
--[[

********************************************************************************
*                              Umbral Gathering                                *
********************************************************************************

Does DiademV2 gathering until umbral weather happens, then gathers umbral node
and goes fishing until umbral weather disappears.

********************************************************************************
*                               Version 1.2.4                                 *
********************************************************************************

Created by: pot0to (https://ko-fi.com/pot0to)

    ->  1.2.4   Added an extra check to make sure gathering weapon is fully put
                    away before attempting to fire cannon
                Skip fire cannon if stuck (try again after next node)
                Fixed stuck checks
                Force AutoHook to swap baits
                Credit: anon. Turned off bait purchase if fishing option is
                    turned off, reworked how next node is selected so certain
                    umbral nodes can be commented out, added silex and barbgrass
                    routes
                Fix for UmbralGatheringSlot
                Added UmbralGatheringSlot
                Move SkillCheck out from if statement, so now it checks
                    every time. This is hopefully compatible with Pandora
                Added extra logging around skills
                Fixed DoFish
    ->  1.3.0   very haphazzardly ported to New SND by Vijartal https://github.com/Vijartal/   

********************************************************************************
*                               Required Plugins                               *
********************************************************************************

Plugins that are needed for it to work:

    -> Something Need Doing [Expanded Edition] : Main Plugin for everything to work   (https://puni.sh/api/repository/croizat)
    -> VNavmesh :   For Pathing/Moving    (https://puni.sh/api/repository/veyn)
    -> TextAdvance: For interacting with NPCs
    -> Autohook:    For fishing during umbral weather

********************************************************************************
*                                Optional Plugins                              *
********************************************************************************

This Plugins are optional and not needed unless you have it enabled in the settings:

    -> Teleporter :  (for Teleporting to Ishgard/Firmament if you're not already in that zone)

]]

--#region Settings
---food and potions not working currently - check after fixing GP
Food = ""         --Leave "" Blank if you don't want to use any food. If its HQ include <hq> next to the name "Baked Eggplant <hq>"
Potion = "" --Leave "" Blank if you don't want to use any potions.  Cordial <HQ>

MaxWait = 10
MinWait = 3

SelectedRoute = "BotanistIslands"
RegularGatheringSlot = 7
UmbralGatheringSlot = 1

TargetType = 1

PrioritizeUmbral = false
DoFish = false

CapGP = true

BuffYield2 = true
BuffGift2 = true
BuffGift1 = true
BuffTidings2 = true

ShouldAutoBuyDarkMatter = true

debug = true
-- Toggleable debug flag
DEBUG_FULL = true -- set to false to silence logs


-- timeout for waiting for gather route
timeoutSeconds = 10
--#endregion Settings

if DEBUG_FULL == true then Dalamud.Log("[DEBUG FULL] full debug log active") end
import("System.Numerics")

-- === Global error trap (temporary debug helper) ===
local function _errorHandler(err)
    local trace = debug.traceback(err, 2)
    local firstLine = trace:match("^[^\n]*")
    Dalamud.Log("[LuaError] " .. tostring(firstLine))
    -- Uncomment for full traceback (may spam log):
    Dalamud.Log("[LuaError] " .. tostring(trace))
    return err
end

-- Wrap coroutine.resume so all macro code execution is monitored
do
    local _origCoroutineResume = coroutine.resume
    coroutine.resume = function(co, ...)
        return xpcall(function(...) return _origCoroutineResume(co, ...) end, _errorHandler, ...)
    end
end

-- Safe wrapper generator: wraps any function in xpcall with the debug handler
local function debugWrap(fn, name)
    return function(...)
        return xpcall(function(...) return fn(...) end, function(err)
            local trace = debug.traceback(err, 2)
            local firstLine = trace:match("^[^\n]*")
            yield("/echo [LuaError:" .. (name or "fn") .. "] " .. tostring(firstLine))
            return nil -- ensure caller gets a safe value
        end, ...)
    end
end

-- Example: wrap existing helpers
if rawget(_G, "safeCall") then
    safeCall = debugWrap(safeCall, "safeCall")
end

if rawget(_G, "Gather") then
    Gather = debugWrap(Gather, "Gather")
end

-- Repeat for any other critical helpers you want traced:
-- e.g., IsAddonVisible, isAddonReadySafe, waitForAddon, etc.

-- ================= Compatibility shims for SND v1->v2 =================
-- These protect fragile host calls (IsAddonReady, optional plugin helpers)
local function safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        -- log once per failure to echo channel (keeps debug visible)
        -- note: yield is used per SND script style
        yield("/echo [UmbralGathering] Host call failed: " .. tostring(res))
        return nil
    end
    return res
end

-- === Compatibility shims for addon visibility/ready ===

--------------------------------------------------------------------------------
-- Checks if a specified plugin by name is currently installed and available.
--
---@param pluginName string The exact name of the plugin to check.
---@return boolean True if the plugin is installed, false otherwise.
function HasPlugin(pluginName)
    return IPC.IsInstalled(pluginName)
end

function IsAddonReady(name)
    return Addons.GetAddon(name).Ready
end

function IsAddonVisible(name)
    return Addons.GetAddon(name).Ready
end

local function _pos_component(pos, comp)
    if not pos then return nil end
    -- prefer uppercase fields (Position.X etc), fall back to lowercase or numeric tuple
    local v = pos[comp] or pos[string.lower(comp)]
    if v == nil and type(pos[1]) == "number" then
        if comp == "X" then return pos[1] end
        if comp == "Y" then return pos[2] end
        if comp == "Z" then return pos[3] end
    end
    return v
end

local function _get_localplayer_position()
    local ok, lp = pcall(function()
        return (Svc and Svc.ClientState) and Svc.ClientState.LocalPlayer or nil
    end)
    if ok and lp and lp.Position then
        return lp.Position
    end
    return nil
end

local function _get_gameobject_from_pronoun(pronounId)
    if rawget(_G, "Utils") and type(Utils.GetGameObjectFromPronounID) == "function" then
        local ok, go = pcall(Utils.GetGameObjectFromPronounID, pronounId)
        if ok and go then return go end
    end
    -- fallback: try to find object in Svc.Objects matching Id/ObjectId (best-effort)
    if Svc and Svc.Objects then
        for _, obj in pairs(Svc.Objects) do
            if obj and (obj.Id == pronounId or obj.ObjectId == pronounId) then
                return obj
            end
        end
    end
    return nil
end

local function _find_targetable_by_name(name)
    if not name or name == "" then return nil end
    if Svc and Svc.Objects then
        for _, obj in pairs(Svc.Objects) do
            if obj and obj.IsTargetable and tostring(obj.Name) == tostring(name) then
                return obj
            end
        end
    end
    return nil
end

---nav and character state compatability shims
---getplayer X/Y/Z compatability shim
if rawget(_G, "GetPlayerRawXPos") == nil then
    function GetPlayerRawXPos(character)
        -- empty character => local player
        if not character or character == "" then
            local lpPos = _get_localplayer_position()
            local v = _pos_component(lpPos, "X")
            return (type(v) == "number") and v or -1
        end

        -- pronoun id numeric branch
        local n = tonumber(tostring(character))
        if n then
            local pronId = n + 42
            local go = _get_gameobject_from_pronoun(pronId)
            if go and go.Position then
                local v = _pos_component(go.Position, "X")
                return (type(v) == "number") and v or -1
            end
            return -1
        end

        -- name lookup branch
        local obj = _find_targetable_by_name(character)
        if obj and obj.Position then
            local v = _pos_component(obj.Position, "X")
            return (type(v) == "number") and v or -1
        end

        return -1
    end
end

if rawget(_G, "GetPlayerRawYPos") == nil then
    function GetPlayerRawYPos(character)
        if not character or character == "" then
            local lpPos = _get_localplayer_position()
            local v = _pos_component(lpPos, "Y")
            return (type(v) == "number") and v or -1
        end

        local n = tonumber(tostring(character))
        if n then
            local pronId = n + 42
            local go = _get_gameobject_from_pronoun(pronId)
            if go and go.Position then
                local v = _pos_component(go.Position, "Y")
                return (type(v) == "number") and v or -1
            end
            return -1
        end

        local obj = _find_targetable_by_name(character)
        if obj and obj.Position then
            local v = _pos_component(obj.Position, "Y")
            return (type(v) == "number") and v or -1
        end

        return -1
    end
end

if rawget(_G, "GetPlayerRawZPos") == nil then
    function GetPlayerRawZPos(character)
        if not character or character == "" then
            local lpPos = _get_localplayer_position()
            local v = _pos_component(lpPos, "Z")
            return (type(v) == "number") and v or -1
        end

        local n = tonumber(tostring(character))
        if n then
            local pronId = n + 42
            local go = _get_gameobject_from_pronoun(pronId)
            if go and go.Position then
                local v = _pos_component(go.Position, "Z")
                return (type(v) == "number") and v or -1
            end
            return -1
        end

        local obj = _find_targetable_by_name(character)
        if obj and obj.Position then
            local v = _pos_component(obj.Position, "Z")
            return (type(v) == "number") and v or -1
        end

        return -1
    end
end

---target position compatibility shims
if rawget(_G, "GetTargetRawXPos") == nil then
    function GetTargetRawXPos()
        local tgt = (Svc and Svc.Targets) and Svc.Targets.Target or nil
        if tgt and tgt.Position then
            local v = _pos_component(tgt.Position, "X")
            return (type(v) == "number") and v or 0
        end
        return 0
    end
end

if rawget(_G, "GetTargetRawYPos") == nil then
    function GetTargetRawYPos()
        local tgt = (Svc and Svc.Targets) and Svc.Targets.Target or nil
        if tgt and tgt.Position then
            local v = _pos_component(tgt.Position, "Y")
            return (type(v) == "number") and v or 0
        end
        return 0
    end
end

if rawget(_G, "GetTargetRawZPos") == nil then
    function GetTargetRawZPos()
        local tgt = (Svc and Svc.Targets) and Svc.Targets.Target or nil
        if tgt and tgt.Position then
            local v = _pos_component(tgt.Position, "Z")
            return (type(v) == "number") and v or 0
        end
        return 0
    end
end

--compatability shims for character stautus's
-- IsPlayerCasting()
--
-- Player.Entity.IsCasting wrapper, use to check if player is casting (e.g. using spells,)
function IsPlayerCasting()
    return Player.Entity and Player.Entity.IsCasting
end

function LifestreamIsBusy()
    IPC.Lifestream.IsBusy()
end

-- Emergency stub to avoid nil-index crashes for GatheringRoute
--if type(GatheringRoute) ~= "table" then
--    GatheringRoute = {}
--    GatheringRoute.__was_stub = true
--    yield("/echo [UmbralGathering] WARNING: GatheringRoute was nil at runtime; temporarily stubbed to empty table.")
--end

--[[ -- Simple passthrough shim: provide isinzone / isinzone via Svc.ClientState.TerritoryType
if rawget(_G, "isinzone") == nil then
    function isinzone()
        local ok, terr = pcall(function()
            return (Svc and Svc.ClientState) and Svc.ClientState.TerritoryType or nil
        end)

        -- Debug output: always log what we fetched if enabled
        if DEBUG_FULL then
            if ok then
                Dalamud.Log("[isinzone] TerritoryType = " .. tostring(terr))
            else
                Dalamud.Log("[isinzone] Failed to fetch TerritoryType")
            end
        end

        return ok and terr or nil
    end
end ]]

-- IsInZone / isinzone shim: no-arg -> numeric territory id (or nil), args -> boolean membership
if rawget(_G, "isinzone") == nil then
    function isinzone(...)
        -- read territory safely
        local ok, terr = pcall(function()
            return (Svc and Svc.ClientState) and Svc.ClientState.TerritoryType or nil
        end)

        local nargs = select("#", ...)
        if nargs == 0 then
            -- passthrough numeric behaviour (legacy): return number or nil if unavailable
            return ok and terr or nil
        end

        -- membership boolean: compare terr to any provided numeric id(s)
        if not ok or terr == nil then return false end
        for i = 1, nargs do
            local v = select(i, ...)
            local vn = tonumber(v)
            if vn and terr == vn then return true end
        end
        return false
    end
end

function GetActiveWeatherID()
    return Instances.EnvManager.ActiveWeather
end

-- shim SetSNDProperty if not present (non-fatal; warns)
if SetSNDProperty == nil then
    function SetSNDProperty(key, val)
        -- best-effort: warn the user to set manually
        yield("/echo [UmbralGathering] Warning: SetSNDProperty not available. Please set '" ..
            tostring(key) .. "' manually in SND settings.")
        return false
    end
end



-- GetCharacterCondition(index, expected)
--
-- Player or self conditions service wrapper, use to check your conditions, index is usually a number, returns bool
-- If only 'index' is provided, returns the value of Svc.Condition[index] (as before)
-- If both 'index' and 'expected' are provided, returns true if Svc.Condition[index] equals 'expected', otherwise false.
-- If neither is provided, returns the entire Svc.Condition table.
function GetCharacterCondition(index, expected)
    if index and expected ~= nil then
        return Svc.Condition[index] == expected
    elseif index then
        return Svc.Condition[index]
    else
        return Svc.Condition
    end
end

function GetItemCount(itemID)
    Inventory.GetItemCount(itemID)
end

--- GetInventoryFreeSlotCount()
--- Inventory.GetFreeInventorySlots wrapper
--- @return integer
function GetInventoryFreeSlotCount()
    return Inventory.GetFreeInventorySlots()
end

--- GetDistanceToPoint(x, y, z)
--- Takes coordinates x y z, returns player distance to given x, y, z
--- @return number
function GetDistanceToPoint(x, y, z)
    local p = Entity and Entity.Player and Entity.Player.Position
    if not p then return math.huge end
    local px = p.X or p.x or p[1]
    local py = p.Y or p.y or p[2]
    local pz = p.Z or p.z or p[3]
    if not (px and py and pz) then return math.huge end
    local dx = x - px; local dy = y - py; local dz = z - pz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---@return boolean True if pathfinding is in progress, false otherwise.
function PathfindInProgress()
    if not HasPlugin("vnavmesh") then
        echo(vnavmeshMissingInfo)
        return false
    end
    if DEBUG_FULL == true then
        Dalamud.Log(string.format("[PathfindInProgress] pathfinding active",
            tonumber(X) or -999, tonumber(Y) or -999, tonumber(Z) or -999, tostring(fly)))
    end
    return IPC.vnavmesh.PathfindInProgress()
end
--- NavIsReady()
--- IPC.vnavmesh.IsReady wrapper
--- @return boolean
function NavIsReady()
    if not HasPlugin("vnavmesh") then
        echo('vnavmeshMissingInfo')
        error('vnavmeshMissingInfo')
        return false
    end
    return IPC.vnavmesh.IsReady()
end

-- Player.Available wrapper, use to check if player is available (e.g. cutscenes, loading zones.)
function IsPlayerAvailable()
    return Player.Available
end

--------------------------------------------------------------------------------
-- Checks if vnavmesh is actively running along a path.
--
-- Returns true if currently moving along a path (not necessarily pathfinding).
--
---@return boolean True if currently moving along a path, false otherwise.
function PathIsRunning()
    if not HasPlugin("vnavmesh") then
        echo(vnavmeshMissingInfo)
        return false
    end
    Dalamud.Log("[PathIsRunning] pathfinding is active")
    return IPC.vnavmesh.IsRunning()
end
--------------------------------------------------------------------------------
-- Checks if a value can be converted (coerced) to a number.
--
-- This is a utility function to help verify whether a value (string or
-- otherwise) can be safely converted to a numeric type.
--
-- Useful for input validation before performing numeric operations.
--
---@param v any Value to check for number coercion
---@return boolean True if the value can be converted to a number, false otherwise
function IsCoercibleNumber(v)
    return tonumber(v) ~= nil
end

--------------------------------------------------------------------------------
-- Validates whether three given coordinates are all valid numbers or coercible to numbers.
--
-- This is a utility function intended to ensure X, Y, and Z values are valid before
-- using them in functions that require numeric coordinates.
--
---@param x any X coordinate to check (number or string convertible to number)
---@param y any Y coordinate to check (number or string convertible to number)
---@param z any Z coordinate to check (number or string convertible to number)
---@return boolean True if all coordinates are valid numbers (or coercible), false otherwise
function AreValidCoordinates(x, y, z)
    Dalamud.Log("[AreValidCoordinates] checking coordinates valid")
    return IsCoercibleNumber(x) and IsCoercibleNumber(y) and IsCoercibleNumber(z)
end

--------------------------------------------------------------------------------
-- Starts pathfinding and moves the player to specified coordinates using vnavmesh.
--
-- This function requires the "vnavmesh" plugin to be installed. It validates the
-- input coordinates and attempts to move the player either flying or on ground.
--
---@param X number|string X coordinate to move to (numbers or coercible strings accepted).
---@param Y number|string Y coordinate to move to (numbers or coercible strings accepted).
---@param Z number|string Z coordinate to move to (numbers or coercible strings accepted).
---@param fly boolean|nil Optional. If true, pathfinding will fly; defaults to false (ground movement).
function PathfindAndMoveTo(X, Y, Z, fly)
    if not HasPlugin("vnavmesh") then
        echo(vnavmeshMissingInfo)
        error(vnavmeshMissingInfo)
        return
    end

    if not AreValidCoordinates(X, Y, Z) then
        error("Invalid coordinates passed to PathfindAndMoveTo")
        return
    end

    fly = (type(fly) == "boolean") and fly or false
    -- Log the received coordinates
    if DEBUG_FULL == true then
        Dalamud.Log(string.format("[PathfindAndMoveTo] Received coords: %.2f %.2f %.2f %s",
        tonumber(X) or -999, tonumber(Y) or -999, tonumber(Z) or -999, tostring(fly)))
    end
    local dest = Vector3(X, Y, Z)
    if DEBUG_FULL == true then Dalamud.Log("[PathfindAndMoveTo] pathfinding") end
    IPC.vnavmesh.PathfindAndMoveTo(dest, fly)
end

-- === Target helpers ===
-- Replacement for legacy HasTarget()
local function HasTarget()
    if DEBUG_FULL then
        Dalamud.Log("[HasTarget] check if you have target")
    end
    return Entity and Entity.Target ~= nil
end

-- Replacement for legacy GetTargetName()
local function GetTargetName()
    if Entity and Entity.Target and Entity.Target.Name then
        return Entity.Target.Name
    end
    return nil
end

-- Helper: HasStatus(statusName)
-- resolves statusName -> RowId(s) from Status sheet, then calls HasStatusId()
if rawget(_G, "HasStatusId") == nil then
    function HasStatusId(statusName)
        if not statusName or type(statusName) ~= "string" then
            if DEBUG_FULL then
                Dalamud.Log("[HasStatus] Invalid statusName: " .. tostring(statusName))
            end
            return false
        end

        local sheet = Excel.GetSheet("Status")
        if not sheet then
            if DEBUG_FULL then
                Dalamud.Log("[HasStatus] Failed to get Status sheet.")
            end
            return false
        end

        local lowerName = string.lower(statusName)
        local matchedIds = {}

        -- iterate all rows in the sheet
        local ok, err = pcall(function()
            for _, row in pairs(sheet:GetRows()) do
                local nameProp = row:GetProperty("Name")
                if nameProp and string.lower(tostring(nameProp)) == lowerName then
                    table.insert(matchedIds, row.RowId)
                end
            end
        end)
        if not ok then
            if DEBUG_FULL then
                Dalamud.Log("[HasStatus] Error iterating Status sheet: " .. tostring(err))
            end
            return false
        end

        if #matchedIds == 0 then
            if DEBUG_FULL then
                Dalamud.Log("[HasStatus] No status IDs found for '" .. statusName .. "'.")
            end
            return false
        end

        -- call into HasStatusId with the IDs
        return HasStatusId(matchedIds)
    end
end

-- GetNodeText(addonName, ...)
--
--Example: GetNodeText("_ToDoList", 1, 7001, 2, 2)
--!!Warning!! GetNodeText is no longer the same as it was in v1, any uses of GetNodeText without adjusting the node ID's to be the correct values will return the wrong text!
--GetNodeText used to return based on the ID's in the node list, but it has shifted to using the actual Node ID, same as the old GetNodeVisible.
--To get the nodeID, find the node sequence with the # symbols in xldata or tweaks Debug
function GetNodeText(addonName, ...)
    if (IsAddonReady(addonName)) then
        local node = Addons.GetAddon(addonName):GetNode(...)
        return tostring(node.Text)
    else
        return ""
    end
end



-- GetGp() compatibility helper
if rawget(_G, "GetGp") == nil then
    function GetGp()
        -- Try several likely sources; always return a number (int).
        local candidates = {
            function() return Player and Player.Gp end,
            function() return Player and Player.CurrentGp end,
            function() return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer and
            Svc.ClientState.LocalPlayer.CurrentGp end,
            function() return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer and Svc.ClientState.LocalPlayer.Gp end,
        }
        for _, fn in ipairs(candidates) do
            local ok, val = pcall(fn)
            if ok and type(val) == "number" then
                if DEBUG_FULL then Dalamud.Log("[GetGp] resolved via candidate -> " .. tostring(val)) end
                return math.floor(val)
            end
        end
        if DEBUG_FULL then Dalamud.Log("[GetGp] could not resolve GP; returning 0") end
        return 0
    end
end

-- GetMaxGp() compatibility helper
if rawget(_G, "GetMaxGp") == nil then
    function GetMaxGp()
        -- Try several likely sources; always return a number (int).
        local candidates = {
            function() return Player and Player.MaxGp end,
            function() return Player and Player.MaxGP end,
            function() return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer and
                Svc.ClientState.LocalPlayer.MaxGp end,
            function() return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer and
                Svc.ClientState.LocalPlayer.MaxGP end,
        }

        for _, fn in ipairs(candidates) do
            local ok, val = pcall(fn)
            if ok and type(val) == "number" then
                if DEBUG_FULL then Dalamud.Log("[GetMaxGp] resolved via candidate -> " .. tostring(val)) end
                return math.floor(val)
            end
        end

        if DEBUG_FULL then Dalamud.Log("[GetMaxGp] could not resolve MaxGP; returning 0") end
        return 0
    end
end

-- GetTargetHP() compatibility helper
if rawget(_G, "GetTargetHP") == nil then
    function GetTargetHP()
        -- Attempt multiple host object shapes; return 0 if none available.
        local attempts = {
            function() return Svc and Svc.Targets and Svc.Targets.Target and Svc.Targets.Target.CurrentHp end,
            function() return Svc and Svc.Targets and Svc.Targets.Target and Svc.Targets.Target.HP end,
            function() return Entity and Entity.Target and Entity.Target.CurrentHp end,
            function() return Entity and Entity.Target and Entity.Target.HP end,
            function() -- some runtimes expose a character object with HP as number property named "CurrentHealth" etc
                local t = (Svc and Svc.Targets and Svc.Targets.Target) or (Entity and Entity.Target)
                if not t then return nil end
                return t.CurrentHp or t.CurrentHP or t.HP or t.Hp or t.Health or t.CurrentHealth
            end
        }
        for i, fn in ipairs(attempts) do
            local ok, val = pcall(fn)
            if ok and (type(val) == "number") then
                if DEBUG_FULL then Dalamud.Log("[GetTargetHP] candidate " .. tostring(i) .. " -> " .. tostring(val)) end
                return val
            end
        end
        if DEBUG_FULL then Dalamud.Log("[GetTargetHP] no target HP available; returning 0") end
        return 0
    end
end

function ClearTarget()
    return Entity.Player:ClearTarget()
end

-- GetDistanceToTarget() compatibility helper
if rawget(_G, "GetDistanceToTarget") == nil then
    if DEBUG_FULL == true then Dalamud.Log("[GetDistanceToTarget] checking distance to target raw") end
    local function _pos_to_xyz(pos)
        if not pos then return nil end
        -- try .X/.Y/.Z
        local ok, x = pcall(function() return pos.X end)
        if ok and type(x) == "number" then
            local ok2, y = pcall(function() return pos.Y end)
            local ok3, z = pcall(function() return pos.Z end)
            if ok2 and ok3 and type(y) == "number" and type(z) == "number" then
                return x, y, z
            end
        end
        -- try .x/.y/.z
        ok, x = pcall(function() return pos.x end)
        if ok and type(x) == "number" then
            local ok2, y = pcall(function() return pos.y end)
            local ok3, z = pcall(function() return pos.z end)
            if ok2 and ok3 and type(y) == "number" and type(z) == "number" then
                return x, y, z
            end
        end
        -- try parsing string like "<-1.32, -16.00, 153.65>: 1876450364"
        local okstr, s = pcall(tostring, pos)
        if okstr and type(s) == "string" then
            local sx, sy, sz = s:match("<%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*>")
            if sx and sy and sz then
                local nx, ny, nz = tonumber(sx), tonumber(sy), tonumber(sz)
                if nx and ny and nz then return nx, ny, nz end
            end
        end
        return nil
    end

    function GetDistanceToTarget()
        if DEBUG_FULL == true then Dalamud.Log("[GetDistanceToTarget] checking distance to target") end
        -- player position
        local px, py, pz
        local okp, plpos = pcall(function()
            return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer and Svc.ClientState.LocalPlayer.Position
        end)
        if okp and plpos then
            px, py, pz = _pos_to_xyz(plpos)
            if DEBUG_FULL then Dalamud.Log(
                "[GetDistanceToTarget] got player pos from Svc.ClientState.LocalPlayer.Position -> " ..
                tostring(px) .. "," .. tostring(py) .. "," .. tostring(pz)) end
        end

        if not px then
            local oke, entpos = pcall(function() return Entity and Entity.Player and Entity.Player.Position end)
            if oke and entpos then
                px, py, pz = _pos_to_xyz(entpos)
                if DEBUG_FULL then Dalamud.Log(
                    "[GetDistanceToTarget] fallback player pos from Entity.Player.Position -> " ..
                    tostring(px) .. "," .. tostring(py) .. "," .. tostring(pz)) end
            end
        end

        if not px then
            if DEBUG_FULL then Dalamud.Log("[GetDistanceToTarget] unable to resolve player position; returning 0") end
            return 0
        end

        -- target position (fall back to player pos if no target)
        local tx, ty, tz
        local okt, tpos = pcall(function()
            return Svc and Svc.Targets and Svc.Targets.Target and Svc.Targets.Target.Position
        end)
        if okt and tpos then
            tx, ty, tz = _pos_to_xyz(tpos)
            if DEBUG_FULL then Dalamud.Log("[GetDistanceToTarget] got target pos from Svc.Targets.Target.Position -> " ..
                tostring(tx) .. "," .. tostring(ty) .. "," .. tostring(tz)) end
        end

        if not tx then
            -- try Entity.Target
            local oket, etpos = pcall(function() return Entity and Entity.Target and Entity.Target.Position end)
            if oket and etpos then
                tx, ty, tz = _pos_to_xyz(etpos)
                if DEBUG_FULL then Dalamud.Log(
                    "[GetDistanceToTarget] fallback target pos from Entity.Target.Position -> " ..
                    tostring(tx) .. "," .. tostring(ty) .. "," .. tostring(tz)) end
            end
        end

        if not tx then
            -- fallback: use player pos (matches original C# fallback behavior)
            tx, ty, tz = px, py, pz
            if DEBUG_FULL then Dalamud.Log("[GetDistanceToTarget] no target pos found, using player pos as fallback") end
        end

        -- compute euclidean distance
        local dx = (tx - px)
        local dy = (ty - py)
        local dz = (tz - pz)
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if DEBUG_FULL then Dalamud.Log(string.format("[GetDistanceToTarget] distance = %.4f", dist)) end
        return dist
    end
end

function GetDiademAetherGaugeBarCount()
    local ok, vs = pcall(function()
        return Addons.GetAddon("HWDAetherGauge"):GetAtkValue(1).ValueString
    end)
    if not ok or vs == nil then return 0 end
    local n = tonumber(tostring(vs)) or 0
    local bars = math.floor(n / 200)
    if bars < 0 then bars = 0 end
    if bars > 5 then bars = 5 end
    return bars
end

if rawget(_G, "GetLevel") == nil then
    function GetLevel(expArrayIndex)
        local ok, lp = pcall(function() return Svc and Svc.ClientState and Svc.ClientState.LocalPlayer end)
        if not ok or not lp then
            if DEBUG_FULL then Dalamud.Log("[GetLevel] LocalPlayer unavailable, returning 0") end
            return 0
        end

        -- Default to current class/job if no index provided
        if expArrayIndex == nil or expArrayIndex == -1 then
            expArrayIndex = lp.ClassJob and lp.ClassJob.Value and lp.ClassJob.Value.ExpArrayIndex or 0
        end

        -- Fallback in case UIState or PlayerState isn’t available
        local ok2, level = pcall(function()
            return UIState.Instance() and UIState.Instance().PlayerState.ClassJobLevels[expArrayIndex] or 0
        end)

        if ok2 and type(level) == "number" then
            return level
        else
            if DEBUG_FULL then Dalamud.Log(string.format("[GetLevel] Could not resolve level for index %s, returning 0",
            tostring(expArrayIndex))) end
            return 0
        end
    end
end

-- ================= End compatibility shims =================

--#region Gathering Nodes

UmbralWeatherNodes = {
    flare = {
        weatherName = "Umbral Flare",
        weatherId = 133,
        gatheringNode =
        {
            itemName = "Grade 4 Skybuilders' Umbral Flarerock",
            x = -429.93103,
            y = 330.51987,
            z = -593.2373,
            nodeName = "Clouded Mineral Deposit",
            class = "Miner"
        },
        fishingNode = {
            itemName = "Grade 4 Artisanal Skybuilders' Crimson Namitaro",
            baitName = "Diadem Crane Fly",
            baitId = 30280,
            x = 370.88373,
            y = 255.67848,
            z = 525.73334,
            fishingX = 372.32,
            fishingY = 254.9,
            fishingZ = 521.2,
            autohookPreset =
            "AH4_H4sIAAAAAAAACu1YS2/jNhD+K4YuvZiAHtQrN683cQNk02CdRQ9FD5Q4sgnLopeitusu8t871COWbDneBkEvzU0aDr95aPhxRj+sWaXlnJW6nGcr6+qHdV2wJIdZnltXWlUwtczinSjgsMi7pVt8cqN4aj0oIZXQe+vKQWl5/T3NKw78IDb6Tw3WJynTtQGrH1zzVOME0dRa7B7XCsq1zFHi2PYA+WXoGiMOBzvsi87M19W284A6Nr3gQrdL5jmkurfR6au5l81KxQXLO4DAoQMA2qrdiHJ9vYeyZ8g/8tD3Bx4GXZLZBpZrkekPTNR+GkHZCZaapRtERbA29ae4fdS4RX1gWkCRQs+f4HhfMMyY221V4m+YM918+s7q8W73KN9eu/txzXLBNuUN+yaVARgIunC86VD+GVL5DVDfMUnqbNKBhS5hH8RqwbZ1ZLNilYMqO1S32eqFNj1xdwAVPSHW9XetWHuUTKof5fIvtrstdCW0kMWCiaJLAMFvflcp+ARlyVZo2rKm1n3thHUv8cBNG4T9DiUmEyN4d7LUr8Z7wEBg3EOLWGfWG4v1+sGf5Q6Pg2L5vFIKCv1GUR6hvlmso96eRDxqvda6kSqF+hyhWseFtZAbaV0tththzTWltNRyZ46yKFZLDbjD6UfZlttMvU1wfbja2y+F+FqBwbUCh/vAEk4gdX1COYtJBDYloRfHYex7fub6FuLdiVL/lhkbWP9/NIVsAugcbKM75+NHwThsJ3PFCpjc5HsDeS/VluW/SrkxIB2R/A6sfjdyjOD5eslYXmJOm/d2sZ/sVtRkgDqhIagOc6mVLFZvgGp7PdQ7WEHBmdofrsGfRPgoK1Q+irTRcIP4WeHE7VOVgQ8jWo9K7M5ZCn3Xe1Y5Z2ug9IK1Vs/U9SzToOasWq2xSdiauwaLd6zg6zYCC6a+zMxDj7VH2gov9OPT2/iFi9W0AB1HdWX2Gb5WQgFHU7oy953pMc7U3s/V0uXaeC+BV5XAa795j93c2M9S7gSEUYcT6vkhSTj1SMTt1A4zYGlgW09/dvTW9qFj9IY9LT1PbwuF9Dahk+Vmn1Qi58i2v0wWa7wfJjcMlBjys+kZ38nvnfzevPLf2e5/zXaRb3s8DFwSUA6EJjGQ2A5DQsOAJQH3M06zHts1/IZkNyS62Ax+l4gOe0lRsoLlQ8qbK7EtZTFBbaGZkie0dzZdtxwbapFib405Ms40CrOtrIqe2khbQP34eAjzhhNwZAxXKmN4e+emM2tHVT/2LwybPu4c+Tkx9s/jP/9XcRgXXj0kmM1GMjdJrvPbHxvaYcE8NuKD2lhx9wrRwdPB0ygifpDYhLo4XkSmLrMYIIMs4JnL6kJscFsXv2wTnK1wOmAKJmTy70ut70EQsyhJfJKyGC9+FmYkCSElWBmhnXoQh4Ae/ANZ6dm46xIAAA=="
        }
    },
    duststorms = {
        weatherName = "Umbral Duststorms",
        weatherId = 134,
        gatheringNode =
        {
            itemName = "Grade 4 Skybuilders' Umbral Dirtleaf",
            x = 384.0722,
            y = 294.2122,
            z = 583.4051,
            nodeName = "Clouded Lush Vegetation Patch",
            class = "Botanist"
        },
        fishingNode = {
            itemName = "Grade 4 Artisanal Skybuilders' Marrella",
            baitName = "Diadem Hoverworm",
            baitId = 30281,
            x = 589.21,
            y = 188.84,
            z = -571.89,
            fishingX = 599.23,
            fishingY = 185.36,
            fishingZ = -579.41,
            autohookPreset =
            "AH4_H4sIAAAAAAAACu1YS2/bOBD+K4YuezEBPahXbq6TuAGcbFCn2MNiDxRF2YRl0aWott4i/71DSYwlW46DwNjL5mR6OPPNQ6OPQ/2yJpUSU1Kqcpotratf1k1BkpxN8ty6UrJiY0tvznnB9pup2bqDlRvFY+tRciG52llXDkjLm580r1KW7sVa/7nBuheCrjRYvXD1qsYJorE12z6tJCtXIgeJY9s95Neha4w47FnYZ4OZrqqNiQA7Nj4TgrESec6o6hg6XTX3vFshU05yAxA4uAeAW7VbXq5udqzsOPIPIvT9XoSBKTJZs8WKZ+oT4XWcWlAawUIRugZUAGtLf4zbRY1b1EeiOCso68QTHNoF/Yq5xlTyf9mUqObRG6+H1u5Bvb3W+mlFck7W5S35LqQG6AlMOt64L//CqPjOQN/RRTI+cc+DKdgnvpyRTZ3ZpFjmTJYG1W1MvdDGR+H2oKJnwLr5qSRpXyVd6iex+EG2d4WquOKimBFemAIgeObzSrJ7VpZkCa4ta2w91EFYDwJeuHGDsNuCRFdiAG8uSvVuvEdIhA1HaCHrxH7jsd7fx7PYwusgST6tpGSFulCWB6gXy3Uw2qOMB73XWrdCUla/R6BmuLAWplpad4vtRhBi00oLJbb6VebFcqEYWDjdLNt2m8jLJNeFq6P9WvBvFdO4VmY7mccoRRkmIcKuFyNCPYa8wAYGyryQEGoB3pyX6s9M+4D+/7tpZJ2ACbDN7lSM15ykbDP6rF++H0JuNOQD/JL8sxBrDWKI5C9G6v9aDhm8HC8ZyUuoafO/3ewWuxU1FcBOqAnKYC6UFMXyAqi210GdsyUrUiJ3+2PwjQjXogLlg0wbDTeIXxSOwj5W6cUwoPUk+faUp9B3vReVU756Sq94a/V0X08yxeSUVMsVDAkbfdZAYww1fD1GQMPUh5ledFh7YKzwQj8+Po1fOVj1CGA4yrTZF/at4pKl4EpV+rzTM8aJ3ntbL53vjY8WeFcLvPeZd9gtiTwH27aP/Ih4CMcZRkkW2ChlYeb5mDghyaznfwy9tXPoEL3BTItP09tMAr2N8Gix3iUVz1Ng2z9GsxWcD6NbwiTv87OeGT/I74P8Lt75H2z3v2Y7xtIAx4GLgphECDtBihKPhigMPVh7buDbdoftGn4DsusTXWy/gehgluQlKUjep7x7AoNxnpMjujtZprsUBmlOYaaG2uggGoXJRlRFR21gHMB+fHj58vo330g7rmRG4NTO9UTWXlH92D9zyfTBcuCjxNC3jv/8G8X+mvDuy4E21pKpLnJd3+51ob0k6GUj3qsNNXWnAZ0wSZyIUcT8MEA4dWIU0yREASEOzmInyGhaN2CD24b4dZPAnWp0XcEXJwV3ghEavb3NOt7d0AkpjWzo9yiDw94JUIRZgtwwpTiMUzegkfX8G7s7jfLfEgAA"
        }
    },
    levin = {
        weatherName = "Umbral Levin",
        weatherId = 135,
        gatheringNode =
        {
            itemName = "Grade 4 Skybuilders' Umbral Levinsand",
            x = 620.3156,
            y = 252.7179,
            z = -397.3386,
            nodeName = "Clouded Rocky Outcrop",
            class = "Miner"
        },
        fishingNode = {
            itemName = "Grade 4 Artisanal Skybuilders' Meganeura",
            baitName = "Diadem Red Balloon", -- mooched from Grade 4 Skybuilders' Ghost Faerie
            baitId = 30279,
            x = 365.84,
            y = -193.35,
            z = -222.72,
            fishingX = 369.91,
            fishingY = -195.22,
            fishingZ = -209.88,
            autohookPreset =
            "AH4_H4sIAAAAAAAACu1YS3OjRhD+KyouuYgqHsPLN1lrK66SHZflrRxSOQzQSFNCjHYYnFW2/N+3BxgLJGTFu04u8Y3q6f76QfN1D9+MSSX5lJaynGZL4+KbcVXQOIdJnhsXUlQwNtThnBWwP0z10Q0+OWE0Nu4F44LJnXFho7S8+prkVQrpXqz0nxusW86TlQKrHxz1VOP44diYbR9XAsoVz1FiW1YP+XXoGiMKehbW2WCmq2qjIyC2Rc6EoK14nkMiO4Z2V80575aLlNFcA/g26QGQVu2alaurHZQdR95BhJ7Xi9DXRaZrWKxYJi8pq+NUglILFpIma0RFsLb0x7hd1KhFvaeSQZFAJx7/0M7vV8zRpoL9DVMqm1evvR5aOwf1dlvrxxXNGV2X1/SJCwXQE+h03HFf/gAJfwLUt1WRtE/S86ALdsmWM7qpM5sUyxxEqVGdxtQNLHIUbg8qfEasq69S0PZTUqV+5Iu/6PamkBWTjBczygpdABPf+bwScAtlSZfo2jDGxl0dhHHH8YMbNwi7LUpUJQbw5ryUP4x3j4nAcISGaZw4bzzW5/t4Flv8HATNp5UQUMh3yvIA9d1yHYz2KONB77XWNRcJ1N8RqmkurIWpktbdYjkB8mLTSgvJt+pTZsVyIQEt7G6WbbtNxPsk14Wro/1csC8VKFwjirOMxEFohmlMTBJBZoaxH5uh7YVpFIV2HKYG4s1ZKX/LlA/s/z+aRlYJ6ADb7E7F+InRFDajB0hHlzTPOS8U6B0XG5r/yvlawWgq+R3oej9Z1Clm0q1rK2qSJXaguEgbL6TgRf2ptVov8ymjeYnG/xTVcjuoc1hCkVKxe0tcNcInXqGyTqmn4fjRi8JR2McqvRgGtB4F257yFHiO+6JyyldP6RVvrZ5q4UkmQUxptVzhPrBRYwX7dKi3640Be6OeW+qhQ9ANlXrR8aR9ZWiq8a75RzfQA3ypmIAUsWWlZpnaHw676k3Nc74ZPt75f/rOO8yVZikyVeKauCpRZK4ISYvEnplR1/JJ4AKNwXj+U1NXu2MOURfuq+Q0dc0EUteIjBbrXVyxPEUm/WU0WyH3j64pCNbnXvssrf0kL32w3QfbfbDd/2PCdfc0n4Zu6HkmBIBsZ/uBSePYNz0nBjcIsixzgg7bNfyGZPevEt3JAt2kuB6zBDdlrIpy3yhMNrwqemrIaF50eIdy+xfYUHmqREZxQOeKF9ubphd5Z+6KHloO/FsY+mXxk78ahiDf9Odhv/z/8MqvjJVkqopc17d7CWhXf/XYiPdqQ+3cHbReYmdJSM0kAdsk1A7MOM4sMwv82A8pdiD169ZrcNsQP29ivCmN5vDEipE50s2FlxBW0gJPem12C0taQCVo/3aSAlgUosC0Xd/FGU+IGWZObJLM9QhJApdYifH8HeK2JzeyEgAA"
        }
    },
    tempest = {
        weatherName = "Umbral Tempest",
        weatherId = 136,
        gatheringNode =
        {
            itemName = "Grade 4 Skybuilders' Umbral Galewood",
            x = -604.29,
            y = 333.82,
            z = 442.46,
            nodeName = "Clouded Mature Tree",
            class = "Botanist"
        },
        fishingNode = {
            itemName = "Grade 4 Artisanal Skybuilders' Griffin",
            baitName = "Diadem Hoverworm", -- mooched from Grade 4 Skybuilders' Ghost Faerie
            baitId = 30281,
            x = -417.17,
            y = -206.7,
            z = 165.31,
            fishingX = -411.73,
            fishingY = -207.15,
            fishingZ = 166.06,
            autohookPreset =
            "AH4_H4sIAAAAAAAACu1YS2/bOBD+K4YuezEBvR+5uW7iBnCzQe1iD4seKGloE5ZFl5Laeov89w4lMZZsOW7a7F42J8vDmW8eGn4c6rsxqUoxpUVZTNnKuPpuXOc0zmCSZcZVKSsYG2pxznM4LKZ66Raf7DAaG/eSC8nLvXFlobS4/pZkVQrpQaz0Hxqs90IkawVWP9jqqcbxw7Ex2y3XEoq1yFBimWYP+WnoGiMKehbmxWCm62qrI3At070QgrYSWQZJ2TG0umr2ZbdCppxmGsC33B6A26rd8GJ9vYei48g7itDzehH6ush0A4s1Z+Ubyus4laDQgkVJkw2iIlhb+lPcLmrUot7TkkOeQCce/9jO71fM1qaS/wNTWjavXns9traP6u201ss1zTjdFDf0i5AKoCfQ6TjjvvwDJOILoL6liqR9uj0PumBv+GpGt3Vmk3yVgSw0qt2YOoHpnoTbgwofEOv6Wylpu5VUqZdi8ZXubvOy4iUX+YzyXBeA4DufVxLeQ1HQFbo2jLFxVwdh3AnccOMGYb9DiarEAN5cFOUv491jIjAcoUGMM+uNx3r9EM9ih9tB0mxaSQl5+UJZHqG+WK6D0Z5kPOi91roRMoF6H6Ga5sJamCpp3S2mHWKITSstSrFTW5nnq0UJaGF1s2zbbSJfJrkuXB3tx5x/rkDhGhGkoRVbjDDP84nrxAmJIjMi4Ns2Tf0gpbFnIN6cF+WfTPnA/v+7aWSVgA6wze5cjG85TWE7eqc231chtwryDn9p9k6IjQLRRPIX0M3hXFGrmEe3qq2oSdW1AsVE2nhRSpHXG63VejydGM0KNP5ZVNPpoM5hBXlK5f45cdUIb0WFyjqlnobtR48KJ2GfqvRiGNBaSr475ynwbOdR5ZyvntIT3lo91cATVoKc0mq1xmlgqw4V7IChzq7nBeyM+tRSDx16bojUi07P2SeOTHW4a/bRDfQBPldcQorYZaVOMjU9HHfVs5rncjO8vvP/9J13eIt6LvMixyY0djzixk5AQtMOiBs5cZqkvhmllvHwSRNXO2EOERdOq+554ppJJK6RO1ps9nHFsxR59I/RbI3MP7qhIHmfea2LtPabvPTKdq9s98p2/48TrjulubFtJn5MGAPkOAaMhD7+BbzGWNRMUy9KOmzX8BuS3b9KdGcLdJvicMwTnJOxKsp9ozDZiirvqSGjedHxDcrpX19D5amSjOIBnSlebO+ZXuRduCl6aDnwZWHog8VvfmgYgnzWd4fD6P/LA78yVpKpKnJd3+4VoB381WMjPqgNtXOn9RjQILDCmFjMDYlr+gGhLGEkdlzLsRi1Q9+sW6/BbUP8uI3xnjRawnYH2EFkpNsLLyG8oDmu9RtNcsbwztVzHXjoHMKQYOMCcS1s/YiykOBAxrwYrDhkkfHwAyNEPC6wEgAA"
        }
    }
}

MinerRoutes = {
    MinerIslands = true,
    MinerSilex = true,
    RedRoute = true
}

BotanistRoutes = {
    BotanistIslands = true,
    BotanistBarbgrass = true,
    PinkRoute = true
}

GatheringRoute =
{
    MinerIslands = {
        { x = -570.90, y = 45.80,  z = -242.08, nodeName = "Mineral Deposit" },
        { x = -512.28, y = 35.19,  z = -256.92, nodeName = "Mineral Deposit" },
        { x = -448.87, y = 32.54,  z = -256.16, nodeName = "Mineral Deposit" },
        { x = -403.11, y = 11.01,  z = -300.24, nodeName = "Rocky Outcrop" }, -- Fly Issue #1
        { x = -363.65, y = -1.19,  z = -353.93, nodeName = "Rocky Outcrop" }, -- Fly Issue #2
        { x = -337.34, y = -0.38,  z = -418.02, nodeName = "Mineral Deposit" },
        { x = -290.76, y = 0.72,   z = -430.48, nodeName = "Mineral Deposit" },
        { x = -240.05, y = -1.41,  z = -483.75, nodeName = "Mineral Deposit" },
        { x = -166.13, y = -0.08,  z = -548.23, nodeName = "Mineral Deposit" },
        { x = -128.41, y = -17.00, z = -624.14, nodeName = "Mineral Deposit" },
        { x = -66.68,  y = -14.72, z = -638.76, nodeName = "Rocky Outcrop" },
        { x = 10.22,   y = -17.85, z = -613.05, nodeName = "Rocky Outcrop" },
        { x = 25.99,   y = -15.64, z = -613.42, nodeName = "Mineral Deposit" },
        { x = 68.06,   y = -30.67, z = -582.67, nodeName = "Mineral Deposit" },
        { x = 130.55,  y = -47.39, z = -523.51, nodeName = "Mineral Deposit" }, -- End of Island #1
        { x = 215.01,  y = 303.25, z = -730.10, nodeName = "Rocky Outcrop" }, -- Waypoint #1 on 2nd Island (Issue)
        { x = 279.23,  y = 295.35, z = -656.26, nodeName = "Mineral Deposit" },
        { x = 331.00,  y = 293.96, z = -707.63, nodeName = "Rocky Outcrop" }, -- End of Island #2
        { x = 458.50,  y = 203.43, z = -646.38, nodeName = "Rocky Outcrop" },
        { x = 488.12,  y = 204.48, z = -633.06, nodeName = "Mineral Deposit" },
        { x = 558.27,  y = 198.54, z = -562.51, nodeName = "Mineral Deposit" },
        { x = 540.63,  y = 195.18, z = -526.46, nodeName = "Mineral Deposit" }, -- End of Island #3
        { x = 632.28,  y = 253.53, z = -423.41, nodeName = "Rocky Outcrop" }, -- Sole Node on Island #4
        { x = 714.05,  y = 225.84, z = -309.27, nodeName = "Rocky Outcrop" },
        { x = 678.74,  y = 225.05, z = -268.64, nodeName = "Rocky Outcrop" },
        { x = 601.80,  y = 226.65, z = -229.10, nodeName = "Rocky Outcrop" },
        { x = 651.10,  y = 228.77, z = -164.80, nodeName = "Mineral Deposit" },
        { x = 655.21,  y = 227.67, z = -115.23, nodeName = "Mineral Deposit" },
        { x = 648.83,  y = 226.19, z = -74.00,  nodeName = "Mineral Deposit" }, -- End of Island #5
        { x = 472.23,  y = -20.99, z = 207.56,  nodeName = "Rocky Outcrop" },
        { x = 541.18,  y = -8.41,  z = 278.78,  nodeName = "Rocky Outcrop" },
        { x = 616.091, y = -31.53, z = 315.97,  nodeName = "Mineral Deposit" },
        { x = 579.87,  y = -26.10, z = 349.43,  nodeName = "Rocky Outcrop" },
        { x = 563.04,  y = -25.15, z = 360.33,  nodeName = "Mineral Deposit" },
        { x = 560.68,  y = -18.44, z = 411.57,  nodeName = "Mineral Deposit" },
        { x = 508.90,  y = -29.67, z = 458.51,  nodeName = "Mineral Deposit" },
        { x = 405.96,  y = 1.82,   z = 454.30,  nodeName = "Mineral Deposit" },
        { x = 260.22,  y = 91.10,  z = 530.69,  nodeName = "Rocky Outcrop" },
        { x = 192.97,  y = 95.66,  z = 606.13,  nodeName = "Rocky Outcrop" },
        { x = 90.06,   y = 94.07,  z = 605.29,  nodeName = "Mineral Deposit" },
        { x = 39.54,   y = 106.38, z = 627.32,  nodeName = "Mineral Deposit" },
        { x = -46.11,  y = 116.03, z = 673.04,  nodeName = "Mineral Deposit" },
        { x = -101.43, y = 119.30, z = 631.55,  nodeName = "Mineral Deposit" }, -- End of Island #6?
        { x = -328.20, y = 329.41, z = 562.93,  nodeName = "Rocky Outcrop" },
        { x = -446.48, y = 327.07, z = 542.64,  nodeName = "Rocky Outcrop" },
        { x = -526.76, y = 332.83, z = 506.12,  nodeName = "Rocky Outcrop" },
        { x = -577.23, y = 331.88, z = 519.38,  nodeName = "Mineral Deposit" },
        { x = -558.09, y = 334.52, z = 448.38,  nodeName = "Mineral Deposit" }, -- End of Island #7
        { x = -729.13, y = 272.73, z = -62.52,  nodeName = "Mineral Deposit" }
    },

    BotanistIslands =
    {
        { x = -202, y = -2,  z = -310, nodeName = "Mature Tree" },
        { x = -262, y = -2,  z = -346, nodeName = "Mature Tree" },
        { x = -323, y = -5,  z = -322, nodeName = "Mature Tree" },
        { x = -372, y = 16,  z = -290, nodeName = "Lush Vegetation Patch" },
        { x = -421, y = 23,  z = -201, nodeName = "Lush Vegetation Patch" },
        { x = -471, y = 28,  z = -193, nodeName = "Mature Tree" },
        { x = -549, y = 29,  z = -211, nodeName = "Mature Tree" },
        { x = -627, y = 285, z = -141, nodeName = "Lush Vegetation Patch" },
        { x = -715, y = 271, z = -49,  nodeName = "Mature Tree" },

        { x = -45,  y = -48, z = -501, nodeName = "Lush Vegetation Patch" },
        { x = -63,  y = -48, z = -535, nodeName = "Lush Vegetation Patch" },
        { x = -137, y = -7,  z = -481, nodeName = "Lush Vegetation Patch" },
        { x = -191, y = -2,  z = -422, nodeName = "Mature Tree" },
        { x = -149, y = -5,  z = -389, nodeName = "Mature Tree" },
        { x = 114,  y = -49, z = -515, nodeName = "Mature Tree" },
        { x = 46,   y = -47, z = -500, nodeName = "Mature Tree" },

        { x = 101,  y = -48, z = -535, nodeName = "Lush Vegetation Patch" },
        { x = 58,   y = -37, z = -577, nodeName = "Lush Vegetation Patch" },
        { x = -6,   y = -20, z = -641, nodeName = "Lush Vegetation Patch" },
        { x = -65,  y = -19, z = -610, nodeName = "Mature Tree" },
        { x = -125, y = -19, z = -621, nodeName = "Mature Tree" },
        { x = -169, y = -7,  z = -550, nodeName = "Lush Vegetation Patch" },

        { x = 454,  y = 207, z = -615, nodeName = "Lush Vegetation Patch" },
        { x = 573,  y = 191, z = -513, nodeName = "Mature Tree" },
        { x = 584,  y = 191, z = -557, nodeName = "Lush Vegetation Patch" },
        { x = 540,  y = 199, z = -617, nodeName = "Lush Vegetation Patch" },
        { x = 482,  y = 192, z = -674, nodeName = "Lush Vegetation Patch" },

        { x = 433,  y = -15, z = 274,  nodeName = "Mature Tree" },
        { x = 467,  y = -13, z = 268,  nodeName = "Lush Vegetation Patch" },
        { x = 440,  y = -25, z = 208,  nodeName = "Mature Tree" },
        { x = 553,  y = -32, z = 419,  nodeName = "Lush Vegetation Patch" },
        { x = 564,  y = -31, z = 339,  nodeName = "Lush Vegetation Patch" },
        { x = 529,  y = -10, z = 279,  nodeName = "Lush Vegetation Patch" },
        { x = 474,  y = -24, z = 197,  nodeName = "Lush Vegetation Patch" },
    },
    RedRoute =
    {
        { x = -161.2715, y = -3.5233,  z = -378.8041, nodeName = "Rocky Outcrop",   antistutter = 0 }, -- Start of the route
        { x = -169.3415, y = -7.1092,  z = -518.7053, nodeName = "Mineral Deposit", antistutter = 0 }, -- Around the tree (Rock + Bones?)
        { x = -78.5548,  y = -18.1347, z = -594.6666, nodeName = "Mineral Deposit", antistutter = 0 }, -- Log + Rock (Problematic)
        { x = -54.6772,  y = -45.7177, z = -521.7173, nodeName = "Mineral Deposit", antistutter = 0 }, -- Down the hill
        { x = -22.5868,  y = -26.5050, z = -534.9953, nodeName = "Rocky Outcrop",   antistutter = 0 }, -- up the hill (rock + tree)
        { x = 59.4516,   y = -41.6749, z = -520.2413, nodeName = "Rocky Outcrop",   antistutter = 0 }, -- Spaces out nodes on rock (hate this one)
        { x = 102.3,     y = -47.3,    z = -500.1,    nodeName = "Mineral Deposit", antistutter = 0 }, -- Over the gap
        { x = -209.1468, y = -3.9325,  z = -357.9749, nodeName = "Mineral Deposit", antistutter = 1 },
    },
    PinkRoute =
    {
        { x = -248.6381, y = -1.5664, z = -468.8910, nodeName = "Lush Vegetation Patch", antistutter = 0 },
        { x = -338.3759, y = -0.4761, z = -415.3227, nodeName = "Lush Vegetation Patch", antistutter = 0 },
        { x = -366.2651, y = -1.8514, z = -350.1429, nodeName = "Lush Vegetation Patch", antistutter = 0 },
        { x = -431.2000, y = 27.5000, z = -256.7000, nodeName = "Mature Tree",           antistutter = 0 }, --tree node
        { x = -473.4957, y = 31.5405, z = -244.1215, nodeName = "Mature Tree",           antistutter = 0 },
        { x = -536.5187, y = 33.2307, z = -253.3514, nodeName = "Lush Vegetation Patch", antistutter = 0 },
        { x = -571.2896, y = 35.2772, z = -236.6808, nodeName = "Lush Vegetation Patch", antistutter = 0 },
        { x = -215.1211, y = -1.3262, z = -494.8219, nodeName = "Lush Vegetation Patch", antistutter = 1 }
    },

    MinerSilex = {
        { x = 279.23, y = 295.35, z = -656.26, nodeName = "Mineral Deposit" },
        { x = 331.00, y = 293.96, z = -707.63, nodeName = "Rocky Outcrop" }, -- End of Island #2
        { x = 458.50, y = 203.43, z = -646.38, nodeName = "Rocky Outcrop" },
        { x = 488.12, y = 204.48, z = -633.06, nodeName = "Mineral Deposit" },
        { x = 558.27, y = 198.54, z = -562.51, nodeName = "Mineral Deposit" },
        { x = 540.63, y = 195.18, z = -526.46, nodeName = "Mineral Deposit" }, -- End of Island #3
        { x = 632.28, y = 253.53, z = -423.41, nodeName = "Rocky Outcrop" }, -- Sole Node on Island #4
        { x = 714.05, y = 225.84, z = -309.27, nodeName = "Rocky Outcrop" },
    },

    BotanistBarbgrass = {
        { x = -202, y = -2,  z = -310, nodeName = "Mature Tree" },
        { x = -262, y = -2,  z = -346, nodeName = "Mature Tree" },
        { x = -323, y = -5,  z = -322, nodeName = "Mature Tree" },
        { x = -372, y = 16,  z = -290, nodeName = "Lush Vegetation Patch" },
        { x = -421, y = 23,  z = -201, nodeName = "Lush Vegetation Patch" },
        { x = -471, y = 28,  z = -193, nodeName = "Mature Tree" },
        { x = -549, y = 29,  z = -211, nodeName = "Mature Tree" },
        { x = -627, y = 285, z = -141, nodeName = "Lush Vegetation Patch" },
    },
}

MobTable =
{
    {
        { "Proto-noctilucale" },
        { "Diadem Bloated Bulb" },
        { "Diadem Melia" },
        { "Diadem Icetrap" },
        { "Diadem Werewood" },
        { "Diadem Biast" },
        { "Diadem Ice Bomb" },
        { "Diadem Zoblyn" },
        { "Diadem Ice Golem" },
        { "Diadem Golem" },
        { "Corrupted Sprite" },
    },
    {
        { "Corrupted Sprite" },
    },
    {
        { "Proto-noctilucale" },
        { "Diadem Bloated Bulb" },
        { "Diadem Melia" },
        { "Diadem Icetrap" },
        { "Diadem Werewood" },
        { "Diadem Biast" },
        { "Diadem Ice Bomb" },
        { "Diadem Zoblyn" },
        { "Diadem Ice Golem" },
        { "Diadem Golem" }
    }
}

spawnisland_table =
{
    { x = -605.7039, y = 312.0701, z = -159.7864, antistutter = 0 },
}

local Mender = {
    npcName = "Merchant & Mender",
    x = -639.8871,
    y = 285.3894,
    z = -136.52252
}

--#endregion Gathering Nodes

--#region States
CharacterCondition = {
    mounted = 4,
    gathering = 6,
    casting = 27,
    occupiedInEvent = 31,
    occupiedInQuestEvent = 32,
    occupied = 33,
    boundByDutyDiadem = 34,
    gathering42 = 42,
    fishing = 43,
    betweenAreas = 45,
    jumping48 = 48,
    occupiedSummoningBell = 50,
    betweenAreasForDuty = 51,
    boundByDuty56 = 56,
    mounting57 = 57,
    jumpPlatform = 61,
    mounting64 = 64,
    beingMoved = 70,
    flying = 77
}

function Ready()
    if not isinzone(DiademZoneId) and State ~= CharacterState.diademEntry then
        State = CharacterState.diademEntry
        Dalamud.LogDebug("[UmbralGathering] State Change: Diadem Entry")
    elseif DoFish and (safeCall(GetItemCount, 30279) == nil or safeCall(GetItemCount, 30280) == nil or safeCall(GetItemCount, 30281) == nil) then
        -- if safeCall returned nil for any of these we force buybait path
        State = CharacterState.buyFishingBait
        Dalamud.LogDebug("[UmbralGathering] State Change: BuyFishingBait")
    elseif not HasStatusId(48) and Food ~= "" then
        Dalamud.LogDebug("[UmbralGathering] Attempting food")
        yield("/item " .. Food)
        yield("/wait 1")
    elseif not HasStatusId(49) and Potion ~= "" then
        Dalamud.LogDebug("[UmbralGathering] Attempting potion")
        yield("/item " .. Potion)
        yield("/wait 1")
    else
        local gauge = safeCall(GetDiademAetherGaugeBarCount) or 0
        if gauge > 0 and TargetType > 0 then
            ClearTarget()
            State = CharacterState.fireCannon
            Dalamud.LogDebug("[UmbralGathering] State Change: Fire Cannon")
        else
            State = CharacterState.moveToNextNode
            Dalamud.LogDebug("[UmbralGathering] State Change: MoveToNextNode")
        end
    end
end

-- because there's this one stupid tree on the starting platform between the
-- spawn point and the launch platform that you always get stuck on
function DodgeTree()
    while GetDistanceToPoint(-652.28, 293.78, -176.22) > 5 do
        PathfindAndMoveTo(-652.28, 293.78, -176.22, true)
        yield("/wait 3")
    end
    while GetDistanceToPoint(-628.01, 276.3, -190.51) > 5 and not GetCharacterCondition(CharacterCondition.jumpPlatform) do
        if not PathfindInProgress() and not PathIsRunning() then
            PathfindAndMoveTo(-628.01, 276.3, -190.51, true)
        end
        yield("/wait 1")
    end
    if PathfindInProgress() or PathIsRunning() then
        yield("/vnav stop")
    end
    while GetCharacterCondition(CharacterCondition.jumpPlatform) do
        yield("/wait 1")
    end
end

--#endregion States

--#region Movement
function TeleportTo(aetheryteName)
    yield("/tp " .. aetheryteName)
    yield("/wait 1")
    while safeCall(GetCharacterCondition, CharacterCondition.casting) do
        Dalamud.LogDebug("[UmbralGathering] Casting teleport...")
        yield("/wait 1")
    end
    yield("/wait 1")
    while safeCall(GetCharacterCondition, CharacterCondition.betweenAreas) do
        Dalamud.LogDebug("[UmbralGathering] Teleporting...")
        yield("/wait 1")
    end
    yield("/wait 1")
end

function EnterDiadem()
    UmbralGathered = false
    NextNodeId = 1
    JustEntered = true
    if DEBUG_FULL then
        Dalamud.Log("[EnterDiadem] attempting to enter diadem")
    end
    if isinzone(DiademZoneId) and IsPlayerAvailable() then
        if not NavIsReady() then
            yield("/echo Waiting for navmesh...")
            yield("/wait 1")
        elseif safeCall(GetCharacterCondition, CharacterCondition.betweenAreas) or safeCall(GetCharacterCondition, CharacterCondition.beingMoved) then
            -- wait to instance in
        else
            yield("/wait 3")
            LastStuckCheckTime = os.clock()
            LastStuckCheckPosition = { x = safeCall(GetPlayerRawXPos), y = safeCall(GetPlayerRawYPos), z = safeCall(
            GetPlayerRawZPos) }
            State = CharacterState.ready
            Dalamud.LogDebug("[UmbralGathering] State Change: Ready")
        end
        return
    end

    local aurvael = {
        npcName = "Aurvael",
        x = -18.60,
        y = -16,
        z = 138.99
    }

    if GetDistanceToPoint(aurvael.x, aurvael.y, aurvael.z) > 5 then
        if not (PathfindInProgress() or PathIsRunning()) then
            PathfindAndMoveTo(aurvael.x, aurvael.y, aurvael.z)
        end
        return
    end

    if PathfindInProgress() or PathIsRunning() then
        yield("/vnav stop")
    end

    if IsAddonVisible("ContentsFinderConfirm") then
        yield("/callback ContentsFinderConfirm true 8")
    elseif IsAddonVisible("SelectYesno") then
        yield("/callback SelectYesno true 0")
    elseif IsAddonVisible("SelectString") then
        yield("/callback SelectString true 0")
    elseif IsAddonVisible("Talk") then
        yield("/click Talk Click")
    elseif HasTarget() and Entity.Target.Name == "Aurvael" then
        yield("/interact")
    else
        yield("/target " .. aurvael.npcName)
    end
    yield("/wait 1")
end

function Mount()
    if safeCall(GetCharacterCondition, CharacterCondition.mounted) then
        State = CharacterState.moveToNextNode
        Dalamud.LogDebug("[UmbralGathering] State Change: MoveToNextNode")
    else
        yield('/gaction "mount roulette"')
        yield("/wait 2")
    end
    yield("/wait 1")
end

function AetherCannonMount()
    if safeCall(GetCharacterCondition, CharacterCondition.mounted) then
        State = CharacterState.fireCannon
        Dalamud.LogDebug("[UmbralGathering] State Change: FireCannon")
    else
        yield('/gaction "mount roulette"')
    end
    yield("/wait 1")
end

function Dismount()
    if PathIsRunning() or PathfindInProgress() then
        yield("/vnav stop")
        return
    end

    if safeCall(GetCharacterCondition, CharacterCondition.flying) then
        yield('/ac dismount')

        local now = os.clock()
        if now - LastStuckCheckTime > 1 then
            local x = safeCall(GetPlayerRawXPos)
            local y = safeCall(GetPlayerRawYPos)
            local z = safeCall(GetPlayerRawZPos)

            -- defensive: ensure numeric coords
            x = tonumber(x) or x or 0
            y = tonumber(y) or y or 0
            z = tonumber(z) or z or 0

            if safeCall(GetCharacterCondition, CharacterCondition.flying)
                and GetDistanceToPoint(LastStuckCheckPosition.x, LastStuckCheckPosition.y, LastStuckCheckPosition.z) < 2 then
                if DEBUG_FULL then
                    Dalamud.Log("[UmbralGathering] Unable to dismount here. Attempting to find nearby nav point.")
                end

                -- pick a nearby random candidate
                local random_x, random_y, random_z = RandomAdjustCoordinates(x, y, z, 10)
                local candidate = Vector3(random_x, random_y, random_z)

                if DEBUG_FULL then
                    Dalamud.Log(string.format("[UmbralGathering] Candidate: X=%.3f, Y=%.3f, Z=%.3f",
                        random_x, random_y, random_z))
                end

                local halfExtentXZ, halfExtentY = 100, 100
                local nearestPoint = nil

                -- prefer PointOnFloor(candidate, allowUnlandable=false, halfExtentXZ)
                do
                    local ok, res = pcall(function()
                        if IPC and IPC.vnavmesh and IPC.vnavmesh.PointOnFloor then
                            return IPC.vnavmesh.PointOnFloor(candidate, false, halfExtentXZ)
                        end
                        return nil
                    end)
                    if ok and res then
                        nearestPoint = res
                        if DEBUG_FULL then
                            local nx, ny, nz = nearestPoint.X or nearestPoint.x, nearestPoint.Y or nearestPoint.y,
                                nearestPoint.Z or nearestPoint.z
                            Dalamud.Log(string.format("[UmbralGathering] PointOnFloor -> X=%.3f, Y=%.3f, Z=%.3f", nx, ny,
                                nz))
                        end
                    else
                        if DEBUG_FULL then
                            if not ok then Dalamud.Log("[UmbralGathering] PointOnFloor call raised: " .. tostring(res)) end
                            Dalamud.Log(
                            "[UmbralGathering] PointOnFloor returned nil or unavailable; will fallback to NearestPoint")
                        end
                    end
                end

                -- fallback to NearestPoint if PointOnFloor didn't yield a valid point
                if not nearestPoint then
                    local ok2, res2 = pcall(function()
                        if IPC and IPC.vnavmesh and IPC.vnavmesh.NearestPoint then
                            return IPC.vnavmesh.NearestPoint(candidate, halfExtentXZ, halfExtentY)
                        end
                        return nil
                    end)
                    if ok2 and res2 then
                        nearestPoint = res2
                        if DEBUG_FULL then
                            local nx, ny, nz = nearestPoint.X or nearestPoint.x, nearestPoint.Y or nearestPoint.y,
                                nearestPoint.Z or nearestPoint.z
                            Dalamud.Log(string.format("[UmbralGathering] NearestPoint -> X=%.3f, Y=%.3f, Z=%.3f", nx, ny,
                                nz))
                        end
                    else
                        if DEBUG_FULL then
                            if not ok2 then Dalamud.Log("[UmbralGathering] NearestPoint call raised: " .. tostring(res2)) end
                            Dalamud.Log("[UmbralGathering] NearestPoint returned nil or unavailable.")
                        end
                    end
                end

                if nearestPoint ~= nil then
                    local isFlying = safeCall(GetCharacterCondition, CharacterCondition.flying)
                    -- ensure boolean
                    isFlying = (isFlying == true)

                    -- attempt to call pathfinder using IPC (direct call avoids wrapper mismatch)
                    local ok3, res3 = pcall(function()
                        IPC.vnavmesh.PathfindAndMoveTo(nearestPoint, isFlying)
                    end)
                    if not ok3 then
                        if DEBUG_FULL then
                            Dalamud.Log("[UmbralGathering] IPC.vnavmesh.PathfindAndMoveTo failed: " .. tostring(res3))
                        end
                    else
                        if DEBUG_FULL then
                            local nx, ny, nz = nearestPoint.X or nearestPoint.x, nearestPoint.Y or nearestPoint.y,
                                nearestPoint.Z or nearestPoint.z
                            Dalamud.Log(string.format(
                                "[UmbralGathering] Pathfind issued to X=%.3f, Y=%.3f, Z=%.3f (fly=%s)",
                                nx, ny, nz, tostring(isFlying)))
                        end
                        yield("/wait 1")
                    end
                end
            end

            LastStuckCheckTime = now
            LastStuckCheckPosition = { x = x, y = y, z = z }
        end
    elseif safeCall(GetCharacterCondition, CharacterCondition.mounted) then
        yield('/ac dismount')
    else
        if NextNode and NextNode.isFishingNode then
            State = CharacterState.fishing
            if DEBUG_FULL then Dalamud.Log("[UmbralGathering] State Change: Fishing") end
        else
            State = CharacterState.gathering
            if DEBUG_FULL then Dalamud.Log("[UmbralGathering] State Change: Gathering") end
        end
    end

    yield("/wait 1")
end

function RandomAdjustCoordinates(x, y, z, maxDistance)
    local angle = math.random() * 2 * math.pi
    local x_adjust = maxDistance * math.random()
    local z_adjust = maxDistance * math.random()

    local randomX = x + (x_adjust * math.cos(angle))
    local randomY = y + maxDistance
    local randomZ = z + (z_adjust * math.sin(angle))

    return randomX, randomY, randomZ
end

function RandomWait()
    local duration = math.random() * (MaxWait - MinWait)
    duration = duration + MinWait
    duration = math.floor(duration * 1000) / 1000
    yield("/wait " .. duration)
end

function GetRandomRouteType()
    local routeNames = {}
    for routeName, _ in pairs(GatheringRoute) do
        table.insert(routeNames, routeName)
    end
    local randomIndex = math.random(#routeNames)

    return routeNames[randomIndex]
end

function SelectNextNode()
    if DEBUG_FULL == true then Dalamud.Log("[SelectNextNode] selecting next node") end
    local weather = safeCall(GetActiveWeatherID) or 0
    if DEBUG_FULL == true then Dalamud.Log("[SelectNextNode] weathercheck") end
    if not UmbralGathered and PrioritizeUmbral and (weather >= 133 and weather <= 136) then
        for _, umbralWeather in pairs(UmbralWeatherNodes) do
            if umbralWeather.weatherId == weather then
                umbralWeather.gatheringNode.isUmbralNode = true
                umbralWeather.gatheringNode.isFishingNode = false
                umbralWeather.gatheringNode.umbralWeatherName = umbralWeather.weatherName
                Dalamud.LogDebug("[UmbralGathering] Selected umbral gathering node for " ..
                umbralWeather.weatherName .. ": " .. umbralWeather.gatheringNode.nodeName)
                return umbralWeather.gatheringNode
            end
        end
    elseif PrioritizeUmbral and (weather >= 133 and weather <= 136) then
        if DoFish then
            for _, umbralWeather in pairs(UmbralWeatherNodes) do
                if umbralWeather.weatherId == weather then
                    umbralWeather.fishingNode.isUmbralNode = true
                    umbralWeather.fishingNode.isFishingNode = true
                    umbralWeather.fishingNode.umbralWeatherName = umbralWeather.weatherName
                    Dalamud.LogDebug("[UmbralGathering] Selected umbral fishing node for " .. umbralWeather.weatherName)
                    return umbralWeather.fishingNode
                end
            end
        else
            if DEBUG_FULL == true then Dalamud.Log("[SelectNextNode] leaving duty") end
            LeaveDuty()
            State = CharacterState.diademEntry
            Dalamud.LogDebug("[UmbralGathering] Diadem Entry")
        end
    end

    -- default
    GatheringRoute[RouteType][NextNodeId].isUmbralNode = false
    GatheringRoute[RouteType][NextNodeId].isFishingNode = false
    Dalamud.LogDebug("[UmbralGathering] Selected regular gathering node: " .. GatheringRoute[RouteType][NextNodeId].nodeName)
    return GatheringRoute[RouteType][NextNodeId]
end

function MoveToNextNode()
    if DEBUG_FULL == true then Dalamud.Log("[MoveToNextNode] moving to next node") end
    NextNodeCandidate = SelectNextNode()
    if (NextNodeCandidate == nil) then
        State = CharacterState.ready
        Dalamud.LogDebug("[UmbralGathering] State Change: Ready")
        return
    elseif (NextNodeCandidate.x ~= NextNode.x or NextNodeCandidate.y ~= NextNode.y or NextNodeCandidate.z ~= NextNode.z) then
        yield("/vnav stop")
        NextNode = NextNodeCandidate
        if NextNode.isUmbralNode then
            yield("/echo Umbral weather " .. NextNode.umbralWeatherName .. " detected")
        end
        return
    end

    if not safeCall(GetCharacterCondition, CharacterCondition.mounted) then
        State = CharacterState.nextNodeMount
        Dalamud.LogDebug("[UmbralGathering] State Change: Mounting")
        return
    elseif NextNode.isFishingNode and Player.Job.Id ~= 18 then
        yield("/gs change Fisher")
        yield("/wait 3")
        return
    elseif not NextNode.isUmbralNode and JustEntered then
        DodgeTree()
        JustEntered = false
        return
    end

    JustEntered = false
    if NextNode.isUmbralNode and not NextNode.isFishingNode and
        ((NextNode.class == "Miner" and Player.Job.Id ~= 16) or
            (NextNode.class == "Botanist" and Player.Job.Id ~= 17))
    then
        yield("/gs change " .. NextNode.class)
        yield("/wait 3")
    elseif not NextNode.isUmbralNode and MinerRoutes[RouteType] and Player.Job.Id ~= 16 then
        yield("/gs change Miner")
        yield("/wait 3")
    elseif not NextNode.isUmbralNode and BotanistRoutes[RouteType] and Player.Job.Id ~= 17 then
        yield("/gs change Botanist")
        yield("/wait 3")
    elseif safeCall(GetDistanceToPoint, NextNode.x, NextNode.y, NextNode.z) < 3 then
        if NextNode.isFishingNode then
            State = CharacterState.fishing
            Dalamud.LogDebug("[UmbralGathering] State Change: Fishing")
            return
        else
            State = CharacterState.gathering
            Dalamud.LogDebug("[UmbralGathering] State Change: Gathering")
            return
        end
    elseif safeCall(GetDistanceToPoint, NextNode.x, NextNode.y, NextNode.z) <= 20 then
        if not NextNode.isFishingNode then
            if HasTarget() and Entity.Target.Name == NextNode.nodeName then
                if safeCall(GetCharacterCondition, CharacterCondition.mounted) then
                    yield("/vnav flytarget")
                else
                    yield("/vnav movetarget")
                end

                State = CharacterState.gathering
                Dalamud.LogDebug("[UmbralGathering] State Change: Gathering")
                return
            else
                yield("/target " .. NextNode.nodeName)
            end
        end
    elseif not (PathfindInProgress() or PathIsRunning()) then
        PathfindAndMoveTo(NextNode.x, NextNode.y, NextNode.z, true)
    end

    local now = os.clock()
    if now - LastStuckCheckTime > 10 then
        local x = safeCall(GetPlayerRawXPos)
        local y = safeCall(GetPlayerRawYPos)
        local z = safeCall(GetPlayerRawZPos)

        local randomX, _, randomZ = RandomAdjustCoordinates(x, y, z, 10)

        if GetDistanceToPoint(LastStuckCheckPosition.x, LastStuckCheckPosition.y, LastStuckCheckPosition.z) < 3 then
            yield("/vnav stop")
            yield("/wait 1")
            Dalamud.LogDebug("[UmbralGathering] Antistuck")
            PathfindAndMoveTo(randomX, y, randomZ)
        end

        LastStuckCheckTime = now
        LastStuckCheckPosition = { x = x, y = y, z = z }
    end
end

--#endregion Movement

--#region Gathering

function SkillCheck()
    local class = Player.Job.Id
    if class == 16 then -- Miner Skills
        Yield2 = "\"King's Yield II\""
        Gift2 = "\"Mountaineer's Gift II\""
        Gift1 = "\"Mountaineer's Gift I\""
        Tidings2 = "\"Nald'thal's Tidings\""
        Bountiful2 = "\"Bountiful Yield II\""
    elseif class == 17 then -- Botanist Skills
        Yield2 = "\"Blessed Harvest II\""
        Gift2 = "\"Pioneer's Gift II\""
        Gift1 = "\"Pioneer's Gift I\""
        Tidings2 = "\"Nophica's Tidings\""
        Bountiful2 = "\"Bountiful Harvest II\""
    else
        yield("/echo Cannot find gathering skills for class #" .. tostring(class))
        yield("/snd stop")
    end
end

function UseSkill(SkillName)
    yield("/ac " .. SkillName)
    yield("/wait 1")
end

function Gather()
    local visibleNode = ""
    if IsAddonVisible("_TargetInfoMainTarget") then
        visibleNode = GetNodeText("_TargetInfoMainTarget", 3)
    elseif IsAddonVisible("_TargetInfo") then
        visibleNode = GetNodeText("_TargetInfo", 34)
    end

    if (not HasTarget() or GetTargetName() ~= NextNode.nodeName) and not GetCharacterCondition(CharacterCondition.gathering42) then
        yield("/target "..NextNode.nodeName)
        yield("/wait 1")
        if not HasTarget() then
            -- yield("/echo Could not find "..NextNode.nodeName)
            if NextNode.isUmbralNode then
                if not DoFish then
                    RandomWait()
                    LeaveDuty()
                    State = CharacterState.diademEntry
                    return
                end
                UmbralGathered = true
            else
                if NextNodeId >= #GatheringRoute[RouteType] then
                    if SelectedRoute == "Random" then
                        RouteType = GetRandomRouteType()
                        yield("/echo New random route selected : "..RouteType)
                    end
                    NextNodeId = 1
                else
                    NextNodeId = NextNodeId + 1
                end
                NextNode = GatheringRoute[RouteType][NextNodeId]
            end
            RandomWait()
            LastStuckCheckTime = os.clock()
            LastStuckCheckPosition = { x = GetPlayerRawXPos(), y = GetPlayerRawYPos(), z = GetPlayerRawZPos() }
            State = CharacterState.ready
            Dalamud.Log("[UmbralGathering] State Change: Ready")
        end
        return
    end

    if GetDistanceToTarget() < 5 and GetCharacterCondition(CharacterCondition.mounted) then
        State = CharacterState.dismounting
        Dalamud.Log("[UmbralGathering] State Change: Dismount")
        return
    end

    if GetDistanceToTarget() >= 3.5 then
        if not (PathfindInProgress() or PathIsRunning()) then
            Dalamud.Log("[UmbralGathering] Gathering move closer")
            PathfindAndMoveTo(GetTargetRawXPos(), GetTargetRawYPos(), GetTargetRawZPos(), GetCharacterCondition(CharacterCondition.flying))
        end
        return
    end

    if (PathfindInProgress() or PathIsRunning()) then
        yield("/vnav stop")
        return
    end

    if not GetCharacterCondition(CharacterCondition.gathering) then
        yield("/interact")
        return
    end

    SkillCheck()

    -- proc the buffs you need
    if (NextNode.isUmbralNode and not NextNode.isFishingNode) or visibleNode == "Max GP ≥ 858 → Gathering Attempts/Integrity +5" then
        Dalamud.Log("[UmbralGathering] This is a Max Integrity Node, time to start buffing/smacking")
        if BuffYield2 and GetGp() >= 500 and not HasStatusId(219) and GetLevel() >= 40 then
            Dalamud.Log("[UmbralGathering] Using skill yield2")
            UseSkill(Yield2)
            return
        elseif BuffGift2 and GetGp() >= 300 and not HasStatusId(759) and GetLevel() >= 50 then
            Dalamud.Log("[UmbralGathering] Using skill gift2")
            UseSkill(Gift2) -- Mountaineer's Gift 2 (Min)
            return
        elseif BuffTidings2 and GetGp() >= 200 and not HasStatusId(2667) and GetLevel() >= 81 then
            Dalamud.Log("[UmbralGathering] Using skill tidings2")
            UseSkill(Tidings2) -- Nald'thal's Tidings (Min)
            return
        elseif BuffGift1 and GetGp() >= 50 and not HasStatusId(2666) and GetLevel() >= 15 then
            Dalamud.Log("[UmbralGathering] Using skill gift1")
            UseSkill(Gift1) -- Mountaineer's Gift 1 (Min)
            return
        elseif BuffBYieldHarvest2 and GetGp() >= 100 and not HasStatusId(1286) and GetLevel() >= 68 then
            Dalamud.Log("[UmbralGathering] Using skill bountiful2")
            UseSkill(Bountiful2)
            return
        end
        -- elseif visibleNode ~= "Max GP ≥ 858 → Gathering Attempts/Integrity +5" then
        --     Dalamud.Log("[Diadem Gathering] [Node Type] Normal Node")
        --     DGatheringLoop = true
    end

    if (GetGp() >= (GetMaxGp() - 30)) and (GetLevel() >= 68) and visibleNode ~= "Max GP ≥ 858 → Gathering Attempts/Integrity +5" then
        Dalamud.Log("[UmbralGathering] Popping Yield 2 Buff")
        UseSkill(Bountiful2)
        return
    end

    if IsAddonVisible("Gathering") and IsAddonReady("Gathering") then
        yield("/wait 0.5")
        if GetTargetName():sub(1, 7) == "Clouded" then
            local callback = "/callback Gathering true "..(UmbralGatheringSlot-1)
            Dalamud.Log("[UmbralGathering] "..callback)
            yield(callback)
        else
            Dalamud.Log("[UmbralGathering] /callback Gathering true "..RegularGatheringSlot-1)
            yield("/callback Gathering true "..RegularGatheringSlot-1)
        end
    end

end

function GoFishing()
    local weather = GetActiveWeatherID()
    if not (weather >= 133 and weather <= 136) then
        if GetCharacterCondition(CharacterCondition.fishing) then
            yield("/ac Quit")
            yield("/wait 1")
        else
            State = CharacterState.ready
            Dalamud.Log("[UmbralGathering] State Change: ready")
        end
        return
    end

    if GetCharacterCondition(CharacterCondition.fishing) then
        if (PathfindInProgress() or PathIsRunning()) then
            yield("/vnav stop")
        end
        return
    end

    if GetCharacterCondition(CharacterCondition.mounted) then
        State = CharacterState.dismounting
        Dalamud.Log("[UmbralGathering] State Change: Dismounting")
        return
    end

    if GetDistanceToPoint(NextNode.fishingX, NextNode.fishingY, NextNode.fishingZ) > 1 and not PathfindInProgress() and not PathIsRunning() then
        PathfindAndMoveTo(NextNode.fishingX, NextNode.fishingY, NextNode.fishingZ)
        return
    end

    DeleteAllAutoHookAnonymousPresets()
    UseAutoHookAnonymousPreset(NextNode.autohookPreset)
    yield("/wait 1")
    yield("/ac Cast")
end

function BuyFishingBait()
    if GetItemCount(30279) >= 30 and GetItemCount(30280) >= 30 and GetItemCount(30281) >= 30 then
        if IsAddonVisible("Shop") then
            yield("/callback Shop true -1")
        else
            State = CharacterState.moveToNextNode
            Dalamud.Log("[UmbralGathering] State Change: MoveToNextNode")
        end
        return
    end

    if GetDistanceToPoint(Mender.x, Mender.y, Mender.z) > 100 then
        LeaveDuty()
        State = CharacterState.diademEntry
        Dalamud.Log("[UmbralGathering] Diadem Entry")
        return
    end

    if not HasTarget() or GetTargetName() ~= Mender.npcName then
        yield("/target "..Mender.npcName)
        return
    end

    if GetDistanceToPoint(Mender.x, Mender.y, Mender.z) > 5 then
        if not PathfindInProgress() and not PathIsRunning() then
            PathfindAndMoveTo(Mender.x, Mender.y, Mender.z)
        end
        return
    end

    if PathfindInProgress() or PathIsRunning() then
        yield("/vnav stop")
        return
    end

    if IsAddonVisible("SelectIconString") then
        yield("/callback SelectIconString true 0")
    elseif IsAddonVisible("SelectYesno") then
        yield("/callback SelectYesno true 0")
    elseif IsAddonVisible("Shop") then
        if GetItemCount(30279) < 30 then
            yield("/callback Shop true 0 4 99 0")
        elseif GetItemCount(30280) < 30 then
            yield("/callback Shop true 0 5 99 0")
        elseif GetItemCount(30281) < 30 then
            yield("/callback Shop true 0 6 99 0")
        end
    else
        yield("/interact")
    end
end

function FireCannon()
    if DEBUG_FULL == true then Dalamud.Log("[FireCannon]firing aether cannnon") end
    if (safeCall(GetDiademAetherGaugeBarCount) or 0) == 0 then
        State = CharacterState.ready
        Dalamud.LogDebug("[UmbralGathering] State Change: Ready")
        return
    end

    if Player.Job.Id ~= 16 and Player.Job.Id ~= 17 then
        yield("/gs change Miner")
        yield("/wait 3")
        return
    end

    local now = os.clock()
    if now - LastStuckCheckTime > 10 then
        local x = safeCall(GetPlayerRawXPos)
        local y = safeCall(GetPlayerRawYPos)
        local z = safeCall(GetPlayerRawZPos)

        if GetDistanceToPoint(LastStuckCheckPosition.x, LastStuckCheckPosition.y, LastStuckCheckPosition.z) < 3 then
            yield("/vnav stop")
            yield("/wait 1")
            Dalamud.LogDebug("[UmbralGathering] Antistuck: MoveToNextNode")
            State = CharacterState.moveToNextNode
        end

        LastStuckCheckTime = now
        LastStuckCheckPosition = { x = x, y = y, z = z }
        return
    end

    if not HasTarget() then
        for i = 1, #MobTable[TargetType] do
            yield("/target " .. MobTable[TargetType][i][1])
            yield("/wait 0.03")
            if HasTarget() then
                Dalamud.LogDebug("[UmbralGathering] Found cannon target")
                return
            end
        end

        State = CharacterState.moveToNextNode
        Dalamud.LogDebug("[UmbralGathering] State Change: MoveToNextNode")
        return
    end

    yield("/wait 0.5")
    if not HasTarget() then
        Dalamud.LogDebug("[UmbralGathering] Target does not stick. Skipping...")
        State = CharacterState.moveToNextNode
        Dalamud.LogDebug("[UmbralGathering] State Change: MoveToNextNode")
        return
    end

    if safeCall(GetDistanceToTarget) > 10 then
        if safeCall(GetDistanceToTarget) > 50 and not safeCall(GetCharacterCondition, CharacterCondition.mounted) then
            State = CharacterState.aetherCannonMount
            Dalamud.LogDebug("[UmbralGathering] State Change: Aether Cannon Mount")
        elseif not PathfindInProgress() and not PathIsRunning() then
            Dalamud.LogDebug("[UmbralGathering] Too far from target, moving closer")
            PathfindAndMoveTo(GetTargetRawXPos(), GetTargetRawYPos(), GetTargetRawZPos(),
                safeCall(GetCharacterCondition, CharacterCondition.mounted))
        end
        return
    end

    if PathfindInProgress() or PathIsRunning() then
        yield("/vnav stop")
        return
    end

    if safeCall(GetCharacterCondition, CharacterCondition.mounted) then
        yield("/ac dismount")
        yield("/wait 1")
        return
    end

    if safeCall(GetTargetHP) > 0 then
        yield("/gaction \"Duty Action I\"")
        yield("/wait 1")
    end
end


--#endregion Gathering

CharacterState = {
    ready = Ready,
    diademEntry = EnterDiadem,
    nextNodeMount = Mount,
    aetherCannonMount = AetherCannonMount,
    dismounting = Dismount,
    moveToNextNode = MoveToNextNode,
    gathering = Gather,
    fishing = GoFishing,
    fireCannon = FireCannon,
    buyFishingBait = BuyFishingBait,
}

FoundationZoneId = 418
FirmamentZoneId = 886
DiademZoneId = 939

--[[ if SelectedRoute == "Random" then
    RouteType = GetRandomRouteType()
elseif GatheringRoute[SelectedRoute] then
    RouteType = SelectedRoute
else
    yield("/echo Invalid SelectedRoute : " .. RouteType)
end
yield("/echo SelectedRoute : " .. RouteType)
if MinerRoutes[RouteType] and Player.Job.Id ~= 16 then
    yield("/gs change Miner")
elseif BotanistRoutes[RouteType] and Player.Job.Id ~= 17 then
    yield("/gs change Botanist")
end
yield("/wait 3")

SetSNDProperty("StopMacroIfTargetNotFound", "false")
if not (isinzone(FoundationZoneId) or isinzone(FirmamentZoneId) or isinzone(DiademZoneId)) then
    TeleportTo("Foundation")
end
if isinzone(FoundationZoneId) then
    yield("/target aetheryte")
    yield("/wait 1")
    if Entity.Target.Name == "aetheryte" then
        yield("/interact")
    end
    repeat
        yield("/wait 1")
    until IsAddonVisible("SelectString")
    yield("/callback SelectString true 2")
    repeat
        yield("/wait 1")
    until isinzone(FirmamentZoneId)
end
if isinzone(DiademZoneId) then
    JustEntered = GetDistanceToPoint(Mender.x, Mender.y, Mender.z) < 50
else
    JustEntered = true
end ]]

if SelectedRoute == "Random" then
    RouteType = GetRandomRouteType()
    if DEBUG_FULL then
        Dalamud.Log("[RouteSelect] Selected random route → " .. tostring(RouteType))
    end
elseif GatheringRoute[SelectedRoute] then
    RouteType = SelectedRoute
    if DEBUG_FULL then
        Dalamud.Log("[RouteSelect] Using explicit SelectedRoute → " .. tostring(RouteType))
    end
else
    yield("/echo Invalid SelectedRoute : " .. tostring(RouteType))
    if DEBUG_FULL then
        Dalamud.Log("[RouteSelect] Invalid SelectedRoute: " .. tostring(SelectedRoute))
    end
end

yield("/echo SelectedRoute : " .. tostring(RouteType))
if DEBUG_FULL then
    Dalamud.Log("[RouteSelect] Final RouteType = " .. tostring(RouteType))
end

if MinerRoutes[RouteType] and Player.Job.Id ~= 16 then
    if DEBUG_FULL then
        Dalamud.Log("[JobSwitch] Switching to Miner (was JobId " .. tostring(Player.Job.Id) .. ")")
    end
    yield("/gs change Miner")
elseif BotanistRoutes[RouteType] and Player.Job.Id ~= 17 then
    if DEBUG_FULL then
        Dalamud.Log("[JobSwitch] Switching to Botanist (was JobId " .. tostring(Player.Job.Id) .. ")")
    end
    yield("/gs change Botanist")
else
    if DEBUG_FULL then
        Dalamud.Log("[JobSwitch] No job switch required (JobId " .. tostring(Player.Job.Id) .. ")")
    end
end

yield("/wait 3")

-- Instead of setting StopMacroIfTargetNotFound directly, we let SafeTarget handle failures
if DEBUG_FULL then
    Dalamud.Log("[Macro] StopMacroIfTargetNotFound doesnt exist (using SafeTarget instead)")
end



if not (isinzone(FoundationZoneId) or isinzone(FirmamentZoneId) or isinzone(DiademZoneId)) then
    if DEBUG_FULL then
        Dalamud.Log("[ZoneCheck] Not in Foundation/Firmament/Diadem → teleporting to Foundation")
    end
    TeleportTo("Foundation")
end

if isinzone(FoundationZoneId) then
    if DEBUG_FULL then
        Dalamud.Log("[ZoneCheck] In Foundation → targeting aetheryte")
    end
    yield("/target aetheryte")
    yield("/wait 1")
    if Entity.Target and Entity.Target.Name == "aetheryte" then
        if DEBUG_FULL then
            Dalamud.Log("[ZoneCheck] Found aetheryte target → interacting")
        end
        yield("/interact")
    else
        if DEBUG_FULL then
            Dalamud.Log("[ZoneCheck] Aetheryte target not found after targeting attempt")
        end
    end

    -- Loop for SelectString
    local loopCount = 0
    repeat
        yield("/wait 1")
        loopCount = loopCount + 1
        if DEBUG_FULL and (loopCount % 5 == 0) then
            Dalamud.Log("[Loop:SelectString] Waiting... count=" .. tostring(loopCount))
        end
    until IsAddonVisible("SelectString")
    if DEBUG_FULL then
        Dalamud.Log("[Loop:SelectString] SelectString visible after " .. tostring(loopCount) .. " waits")
    end

    yield("/callback SelectString true 2")

    -- Loop for Firmament zone
    loopCount = 0
    repeat
        yield("/wait 1")
        loopCount = loopCount + 1
        if DEBUG_FULL and (loopCount % 5 == 0) then
            Dalamud.Log("[Loop:Firmament] Waiting for zone change... count=" .. tostring(loopCount))
        end
    until isinzone(FirmamentZoneId)
    if DEBUG_FULL then
        Dalamud.Log("[Loop:Firmament] Entered Firmament after " .. tostring(loopCount) .. " waits")
    end
end

if isinzone(DiademZoneId) then
    JustEntered = GetDistanceToPoint(Mender.x, Mender.y, Mender.z) < 50
    if DEBUG_FULL then
        Dalamud.Log("[ZoneCheck] In Diadem. JustEntered = " .. tostring(JustEntered))
    end
else
    JustEntered = true
    if DEBUG_FULL then
        Dalamud.Log("[ZoneCheck] Not in Diadem. Forcing JustEntered = true")
    end
end

LastStuckCheckTime = os.clock()
LastStuckCheckPosition = { x = GetPlayerRawXPos(), y = GetPlayerRawYPos(), z = GetPlayerRawZPos() }

State = CharacterState.ready
NextNodeId = 1
NextNode = GatheringRoute[RouteType][NextNodeId]
while true do
    if GetInventoryFreeSlotCount() == 0 then
        if isinzone(DiademZoneId) then
            LeaveDuty()
        end
        yield("/snd stop")
    elseif not isinzone(DiademZoneId) and State ~= CharacterState.diademEntry then
        State = CharacterState.diademEntry
    end
    if not (IsPlayerCasting() or
            GetCharacterCondition(CharacterCondition.betweenAreas) or
            GetCharacterCondition(CharacterCondition.jumping48) or
            GetCharacterCondition(CharacterCondition.jumpPlatform) or
            GetCharacterCondition(CharacterCondition.mounting57) or
            GetCharacterCondition(CharacterCondition.mounting64) or
            GetCharacterCondition(CharacterCondition.beingMoved) or
            LifestreamIsBusy())
    then
        State()
    end
    yield("/wait 0.1")
end

-- ================= Additional helper functions (define only if missing) =================
-- These are conservative, safe fallbacks. They do not override host implementations.

-- capture any host-provided versions to avoid accidental override
local host_LifestreamIsBusy = rawget(_G, "LifestreamIsBusy")
local host_LeaveDuty = rawget(_G, "LeaveDuty")


-- LifestreamIsBusy()
if host_LifestreamIsBusy == nil then
    function LifestreamIsBusy()
        -- Lifestream/fate busy checks are game/host-specific. If the host exposes a function, it will be used.
        -- Fallback: return false (do not block the script).
        return false
    end
end

-- LeaveDuty()
-- Important: leaving the Diadem/duty normally requires the host to provide a function.
-- If a host LeaveDuty() exists we won't override it. Otherwise we log and ask for manual intervention.
if host_LeaveDuty == nil then
    function LeaveDuty()
        yield(
        "/echo [UmbralGathering] LeaveDuty helper missing. Install SND helper that provides LeaveDuty() or implement a LeaveDuty() wrapper.")
        -- conservative: do nothing else here (do not attempt uncertain chat commands)
        return false
    end
end



