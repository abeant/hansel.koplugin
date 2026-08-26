package.path = "./lib/?.lua;./?.lua;" .. package.path
local Obfuscate = require("lib/obfuscate")

local n = 0
local function eq(a, b, msg)
    n = n + 1
    if a ~= b then
        error(string.format("FAIL %s: %s ~= %s", msg or n, tostring(a), tostring(b)))
    end
end

local secret = "hunter2/with spaces"
local stored = Obfuscate.encode(secret, "device-id")
assert(stored:sub(1, 3) == "d1:", "prefix")
assert(not stored:find("hunter2", 1, true), "not plaintext")
eq(Obfuscate.decode(stored, "device-id"), secret, "roundtrip")
local other = Obfuscate.decode(stored, "other-device")
assert(other ~= secret, "salt must change the key")
eq(Obfuscate.decode(""), "", "empty")
eq(Obfuscate.decode("not-obfuscated"), "not-obfuscated", "legacy plaintext passthrough")

print("obfuscate: " .. n .. " ok")
