-- At-rest obfuscation, not encryption. XOR with a built-in key, then base64.
-- Stops casual `cat settings.lua` leaks. Documented in README.

local Obfuscate = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(data)
    local out = {}
    local n = #data
    local i = 1
    while i <= n do
        local a = data:byte(i) or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local triple = a * 65536 + b * 256 + c
        local pad = (i + 1 > n and 2) or (i + 2 > n and 1) or 0
        local s = ALPHABET:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
            .. ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
            .. (pad >= 2 and "=" or ALPHABET:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1))
            .. (pad >= 1 and "=" or ALPHABET:sub(triple % 64 + 1, triple % 64 + 1))
        out[#out + 1] = s
        i = i + 3
    end
    return table.concat(out)
end

local DECODE = {}
for i = 1, #ALPHABET do
    DECODE[ALPHABET:byte(i)] = i - 1
end
DECODE[string.byte("=")] = 0

local function b64decode(data)
    if type(data) ~= "string" then return nil end
    data = data:gsub("%s", "")
    if data == "" then return "" end
    if #data % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #data, 4 do
        local a = DECODE[data:byte(i)]
        local b = DECODE[data:byte(i + 1)]
        local c = DECODE[data:byte(i + 2)]
        local d = DECODE[data:byte(i + 3)]
        if not a or not b or not c or not d then return nil end
        local triple = a * 262144 + b * 4096 + c * 64 + d
        out[#out + 1] = string.char(math.floor(triple / 65536) % 256)
        if data:sub(i + 2, i + 2) ~= "=" then
            out[#out + 1] = string.char(math.floor(triple / 256) % 256)
        end
        if data:sub(i + 3, i + 3) ~= "=" then
            out[#out + 1] = string.char(triple % 256)
        end
    end
    return table.concat(out)
end

-- Built-in key, mixed with an optional device salt at encode time.
-- Stable across the Hansel rebrand so existing secrets still decode.
local KEY = "dork.koplugin/grimmory-at-rest-v1"

local function xor_real(s, key)
    local bxor
    local ok_bit, bit = pcall(require, "bit")
    if ok_bit and bit and bit.bxor then
        bxor = bit.bxor
    elseif _G.bit32 and _G.bit32.bxor then
        bxor = _G.bit32.bxor
    else
        bxor = function(a, c)
            local r, p = 0, 1
            while a > 0 or c > 0 do
                local abit, cbit = a % 2, c % 2
                if abit ~= cbit then r = r + p end
                a, c, p = math.floor(a / 2), math.floor(c / 2), p * 2
            end
            return r
        end
    end
    local out = {}
    local kn = #key
    for i = 1, #s do
        out[i] = string.char(bxor(s:byte(i), key:byte(((i - 1) % kn) + 1)))
    end
    return table.concat(out)
end

function Obfuscate.encode(plain, salt)
    if plain == nil or plain == "" then return "" end
    plain = tostring(plain)
    local key = KEY
    if type(salt) == "string" and salt ~= "" then
        -- Salt first: KEY is longer than most secrets, so a suffix never
        -- participates in the XOR.
        key = salt .. "|" .. KEY
    end
    return "d1:" .. b64encode(xor_real(plain, key))
end

function Obfuscate.decode(stored, salt)
    if stored == nil or stored == "" then return "" end
    stored = tostring(stored)
    if stored:sub(1, 3) ~= "d1:" then
        -- Legacy / accidental plaintext: return as-is so a bad write is recoverable.
        return stored
    end
    local payload = b64decode(stored:sub(4))
    if not payload then return "" end
    local key = KEY
    if type(salt) == "string" and salt ~= "" then
        key = salt .. "|" .. KEY
    end
    return xor_real(payload, key)
end

Obfuscate._b64encode = b64encode
Obfuscate._b64decode = b64decode

return Obfuscate
