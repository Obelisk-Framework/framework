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
    -- 46-bit unique counter: 32-bit second | 14-bit clockSeq.
    -- Covers ~9 X positions bijectively (36^9 > 2^46 > n). Beyond that,
    -- math.random fills remaining positions with negligible collision risk.
    -- Hard cap: 16,384 unique IDs per second (14-bit clockSeq limit).
    local n = ts * 0x4000 + cs

    local out = {}
    for i = 1, #pattern do
        local c = pattern:sub(i, i)
        if c == 'X' then
            local v = n > 0 and (n % 36) or math.random(0, 35)
            if n > 0 then n = n // 36 end
            out[#out + 1] = ALPHANUM:sub(v + 1, v + 1)
        elseif c == 'N' then
            local v = n > 0 and (n % 10) or math.random(0, 9)
            if n > 0 then n = n // 10 end
            out[#out + 1] = DIGIT:sub(v + 1, v + 1)
        elseif c == 'A' then
            local v = n > 0 and (n % 26) or math.random(0, 25)
            if n > 0 then n = n // 26 end
            out[#out + 1] = ALPHA:sub(v + 1, v + 1)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end
