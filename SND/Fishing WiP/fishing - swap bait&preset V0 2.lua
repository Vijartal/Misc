-- Configuration Section
local config = {
    et_time_range = "11-14",        -- ET hour range string (e.g. "11-14")
    bait_main = "Glowworm",         -- Bait for main trigger
    preset_main = "OceanFishing",   -- Preset for main trigger
    bait_reset = "Moth Pupa",       -- Bait for reset action
    preset_reset = "DefaultFishing" -- Preset for reset action
}

-- Utility function to parse a range string and return a table of valid hours
local function parse_range(range_str)
    local range = {}
    local start_s, end_s = range_str:match("(%d+)%-(%d+)")
    if start_s and end_s then
        local start_num = tonumber(start_s)
        local end_num = tonumber(end_s)
        for i = start_num, end_num do
            table.insert(range, i)
        end
    end
    return range
end

-- Utility function to check if a value is in a list
local function is_in_range(value, range)
    for _, v in ipairs(range) do
        if v == value then
            return true
        end
    end
    return false
end

-- Parse range once
local et_range = parse_range(config.et_time_range)

-- State tracking
local was_triggered = false

while true do
    local hour = GetCurrentEorzeaHour()

    if is_in_range(hour, et_range) then
        if not was_triggered then
            was_triggered = true

            yield("/ahoff")
            yield("/wait 2")
            yield("/ac Rest")
            yield("/wait 2")
            yield("/bait " .. config.bait_main)
            yield("/wait 1")
            yield("/ahpreset " .. config.preset_main)
            yield("/wait 1")
            yield("/ahon")
        end
    else
        if was_triggered then
            was_triggered = false

            yield("/ahoff")
            yield("/wait 2")
            yield("/ac Rest")
            yield("/wait 2")
            yield("/bait " .. config.bait_reset)
            yield("/wait 1")
            yield("/ahpreset " .. config.preset_reset)
            yield("/wait 1")
            yield("/ahon")
        end
    end

    yield("/wait 5")
end