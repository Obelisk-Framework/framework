--- UniqueIdService — generates unique formatted identifiers from a pattern
--- string, using UUID v1 (timestamp-based) entropy.
---
--- Pattern chars:
---   X → random uppercase alphanumeric (A–Z 0–9), consumes 2 hex chars
---   N → random digit (0–9),                      consumes 1 hex char
---   A → random uppercase letter (A–Z),            consumes 2 hex chars
---   other → emitted as-is
UniqueIdService = {}

--- Overridable time source — replace in tests to control the clock.
UniqueIdService._getTime = os.time

local GREGORIAN_OFFSET = 122192928000000000 -- 100-ns ticks between 1582-10-15 and 1970-01-01

local clockSeq   = math.random(0, 0x3FFF)
local lastTimeSec = 0

-- Node: random 48-bit value with multicast bit set (signals non-hardware address).
local nodeHex = string.format('%012x',
    (math.random(0, 0xFFFF) | 0x0100) * 0x100000000 +
    math.random(0, 0xFFFFFFFF))

local function getTimestamp()
    local now = UniqueIdService._getTime()
    if now <= lastTimeSec then
        clockSeq = (clockSeq + 1) & 0x3FFF
    end
    lastTimeSec = now
    return now * 10000000 + GREGORIAN_OFFSET
end

--- Returns a 32-char lowercase hex string (UUID v1, dashes stripped).
local function nextUUID()
    local t         = getTimestamp()
    local timeLow   = t & 0xFFFFFFFF
    local timeMid   = (t >> 32) & 0xFFFF
    local timeHiVer = ((t >> 48) & 0x0FFF) | 0x1000
    local clkHi     = ((clockSeq >> 8) & 0x3F) | 0x80
    local clkLo     = clockSeq & 0xFF
    return string.format('%08x%04x%04x%02x%02x%s',
        timeLow, timeMid, timeHiVer, clkHi, clkLo, nodeHex)
end

local ALPHANUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' -- 36 chars
local ALPHA    = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'            -- 26 chars
local DIGIT    = '0123456789'                            -- 10 chars

--- Generate a unique formatted string from a pattern.
--- @param pattern string
--- @return string
function UniqueIdService.generate(pattern)
    local pool    = nextUUID() -- 32 hex chars
    local poolPos = 1

    local function consume(n)
        -- Extend pool if needed
        while poolPos + n - 1 > #pool do
            pool = pool .. nextUUID()
        end
        local chunk = pool:sub(poolPos, poolPos + n - 1)
        poolPos = poolPos + n
        return tonumber(chunk, 16)
    end

    local out = {}
    for i = 1, #pattern do
        local c = pattern:sub(i, i)
        if c == 'X' then
            local v = consume(2) % 36
            out[#out + 1] = ALPHANUM:sub(v + 1, v + 1)
        elseif c == 'N' then
            local v = consume(1) % 10
            out[#out + 1] = DIGIT:sub(v + 1, v + 1)
        elseif c == 'A' then
            local v = consume(2) % 26
            out[#out + 1] = ALPHA:sub(v + 1, v + 1)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end
