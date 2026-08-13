--- Pure-Lua SHA-256 + HMAC-SHA256. FXServer's Lua 5.4 sandbox has no crypto
--- library, so this exists to give StorageService's S3 adapter (AWS SigV4
--- needs HMAC-SHA256 chained four times per request) something to sign with.
--- Uses Lua 5.4's native 64-bit integers and bitwise operators (&, |, ~, <<,
--- >>) — no bit32 library needed.
Sha256 = {}

local MASK32 = 0xFFFFFFFF

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function rrotate(x, n)
  x = x & MASK32
  return ((x >> n) | (x << (32 - n))) & MASK32
end

local function toBytesBE32(n)
  return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

--- @param msg string
--- @return string raw 32-byte digest
function Sha256.digest(msg)
  local H = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}

  local bitlen = #msg * 8
  local padded = msg .. '\128'
  while (#padded % 64) ~= 56 do padded = padded .. '\0' end
  for i = 7, 0, -1 do
    padded = padded .. string.char((bitlen >> (i * 8)) & 0xFF)
  end

  for chunkStart = 1, #padded, 64 do
    local w = {}
    for i = 0, 15 do
      local o = chunkStart + i * 4
      w[i] = (padded:byte(o) << 24) | (padded:byte(o + 1) << 16) | (padded:byte(o + 2) << 8) | padded:byte(o + 3)
    end
    for i = 16, 63 do
      local s0 = rrotate(w[i - 15], 7) ~ rrotate(w[i - 15], 18) ~ (w[i - 15] >> 3)
      local s1 = rrotate(w[i - 2], 17) ~ rrotate(w[i - 2], 19) ~ (w[i - 2] >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK32
    end

    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
      local s1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local ch = (e & f) ~ ((~e & MASK32) & g)
      local temp1 = (h + s1 + ch + K[i + 1] + w[i]) & MASK32
      local s0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (s0 + maj) & MASK32
      h = g; g = f; f = e; e = (d + temp1) & MASK32
      d = c; c = b; b = a; a = (temp1 + temp2) & MASK32
    end

    H[1] = (H[1] + a) & MASK32; H[2] = (H[2] + b) & MASK32
    H[3] = (H[3] + c) & MASK32; H[4] = (H[4] + d) & MASK32
    H[5] = (H[5] + e) & MASK32; H[6] = (H[6] + f) & MASK32
    H[7] = (H[7] + g) & MASK32; H[8] = (H[8] + h) & MASK32
  end

  local out = {}
  for i = 1, 8 do out[i] = toBytesBE32(H[i]) end
  return table.concat(out)
end

--- @param raw string 32-byte raw digest
--- @return string 64-char lowercase hex
function Sha256.hex(raw)
  local out = {}
  for i = 1, #raw do out[i] = string.format('%02x', raw:byte(i)) end
  return table.concat(out)
end

--- @param key string
--- @param msg string
--- @return string raw 32-byte HMAC-SHA256
function Sha256.hmac(key, msg)
  local blockSize = 64
  if #key > blockSize then key = Sha256.digest(key) end
  if #key < blockSize then key = key .. string.rep('\0', blockSize - #key) end

  local ipad, opad = {}, {}
  for i = 1, blockSize do
    local kb = key:byte(i)
    ipad[i] = string.char(kb ~ 0x36)
    opad[i] = string.char(kb ~ 0x5c)
  end

  local inner = Sha256.digest(table.concat(ipad) .. msg)
  return Sha256.digest(table.concat(opad) .. inner)
end
