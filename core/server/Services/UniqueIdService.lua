--- UniqueIdService — generates unique formatted identifiers from a pattern
--- string, using mixed-radix decomposition of a timestamp-based counter.
---
--- Pattern chars:
---   X → uppercase alphanumeric (A–Z 0–9), extracted via mixed-radix decomposition
---   N → digit (0–9),                      extracted via mixed-radix decomposition
---   A → uppercase letter (A–Z),            extracted via mixed-radix decomposition
---   other → emitted as-is
---
--- The counter is built from timestamp-seconds and clockSeq, ensuring that
--- consecutive calls produce distinct outputs via mixed-radix extraction.
UniqueIdService = {}

--- Overridable time source — replace in tests to control the clock.
UniqueIdService._getTime = os.time

local clockSeq    = math.random(0, 0x3FFF)
local lastTimeSec = 0

local ALPHANUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' -- 36 chars
local ALPHA    = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'            -- 26 chars
local DIGIT    = '0123456789'                            -- 10 chars

--- Update clock sequence if called within the same second.
local function tick()
    local now = UniqueIdService._getTime()
    if now <= lastTimeSec then
        clockSeq = (clockSeq + 1) & 0x3FFF
    end
    lastTimeSec = now
    return clockSeq, now
end

--- Generate a unique formatted string from a pattern.
--- Uses mixed-radix decomposition of a 46-bit counter (32-bit timestamp + 14-bit clockSeq).
--- @param pattern string
--- @return string
function UniqueIdService.generate(pattern)
    local cs, ts = tick()
    -- 46-bit unique counter: 32-bit timestamp-seconds in upper bits, 14-bit clockSeq in lower
    -- Consecutive calls produce consecutive n values → distinct outputs for patterns with 2+ X positions
    local n = ts * 0x4000 + cs

    local out = {}
    for i = 1, #pattern do
        local c = pattern:sub(i, i)
        if c == 'X' then
            out[#out + 1] = ALPHANUM:sub((n % 36) + 1, (n % 36) + 1)
            n = n // 36
        elseif c == 'N' then
            out[#out + 1] = DIGIT:sub((n % 10) + 1, (n % 10) + 1)
            n = n // 10
        elseif c == 'A' then
            out[#out + 1] = ALPHA:sub((n % 26) + 1, (n % 26) + 1)
            n = n // 26
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end
