-- Configuration Section
local config = {
    et_time_range = {11, 12, 13, 14}, -- ET hours that trigger the action
    bait = "Glowworm",              -- Bait name
    preset = "OceanFishing"          -- AHPreset name
}

-- Utility function to check if a value is in a list
local function is_in_range(value, range)
    for _, v in ipairs(range) do
        if v == value then
            return true
        end
    end
    return false
end

-- State tracking
local was_triggered = false

while true do
    local hour = GetCurrentEorzeaHour()

    if is_in_range(hour, config.et_time_range) then
        if not was_triggered then
            was_triggered = true
            
            yield("/ahoff")
            yield("/wait 2")
            yield("/ac "Rest"")
            yield("/wait 2")
            yield("/bait " .. config.bait)
            yield("/wait 1")
            yield("/ahpreset " .. config.preset)
            yield("/wait 1")
            yield("/ahon")
        end
    else
        was_triggered = false
    end

    yield("/wait 5")
end
