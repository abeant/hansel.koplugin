package.path = "./lib/?.lua;./?.lua;" .. package.path
local Origin = require("lib.origin")

local n = 0
local function eq(a, b, msg)
    n = n + 1
    if a ~= b then
        error(string.format("FAIL %s: %s ~= %s", msg or n, tostring(a), tostring(b)))
    end
end

eq(Origin.from_any("http://10.0.0.5:6060/api/v1/opds"), "http://10.0.0.5:6060", "strip opds path")
eq(Origin.from_any("10.0.0.5:6060"), "http://10.0.0.5:6060", "add scheme")
eq(Origin.opds_catalog("http://h:6060", 2, 12),
    "http://h:6060/api/v1/opds/catalog?page=2&size=12", "catalog url")
eq(Origin.opds_cover("http://h:6060", 42), "http://h:6060/api/v1/opds/42/cover", "cover")
eq(Origin.opds_download("http://h:6060", 42), "http://h:6060/api/v1/opds/42/download", "download")
eq(Origin.koreader_sync("http://h:6060"), "http://h:6060/api/koreader", "kosync")
eq(Origin.same_origin("http://h:6060/a", "http://h:6060/b"), true, "same origin")
eq(Origin.same_origin("http://h:6060/a", "https://h:6060/a"), false, "scheme mismatch")
eq(Origin.absolute("http://h:6060/api/v1/opds", "/api/v1/opds/9/cover"),
    "http://h:6060/api/v1/opds/9/cover", "absolute")
eq(Origin.host_matches_kosync("http://h:6060", "http://h:6060/api/koreader"), true, "kosync host")
eq(Origin.from_any(" HTTP://Grimmory.Test:80/api/v1/opds "),
    "http://grimmory.test", "canonical origin")
eq(Origin.from_any("https://Grimmory.Test:0443/path"),
    "https://grimmory.test", "canonical default port")
eq(Origin.same_origin("http://GRIMMORY.test/a", "http://grimmory.test:80/b"),
    true, "equivalent origins")

eq(Origin.host_matches_kosync("HTTP://Grimmory.Test:6060/",
    "http://grimmory.test:6060/api/koreader/"), true, "case slash path")
eq(Origin.host_matches_kosync("http://grimmory.test:6060",
    "http://grimmory.test:6060/api/koreader?x=1"), true, "query on kosync")
eq(Origin.host_matches_kosync("http://grimmory.test:6060",
    "http://grimmory.test:6060"), true, "bare custom server")
eq(Origin.host_matches_kosync("http://grimmory.test",
    "http://grimmory.test:80/api/koreader"), true, "default http port")
eq(Origin.host_matches_kosync("https://grimmory.test",
    "https://grimmory.test:443/api/koreader"), true, "default https port")
eq(Origin.host_matches_kosync("http://grimmory.test:6060",
    "http://grimmory.test:6061/api/koreader"), false, "port mismatch")
eq(Origin.host_matches_kosync("http://grimmory.test:6060",
    "https://grimmory.test:6060/api/koreader"), false, "scheme mismatch")
eq(Origin.host_matches_kosync("http://grimmory.test:6060",
    "http://other.test:6060/api/koreader"), false, "host mismatch")
eq(Origin.host_matches_kosync(nil, "http://h:6060/api/koreader"), false, "nil origin")
eq(Origin.host_matches_kosync("http://h:6060", nil), false, "nil custom")
eq(Origin.host_matches_kosync("http://h:6060", ""), false, "empty custom")
eq(Origin.host_matches_kosync("http://user:pass@h:6060",
    "http://h:6060/api/koreader"), false, "userinfo origin rejected")
eq(Origin.host_matches_kosync("http://h:6060",
    "http://user:pass@h:6060/api/koreader"), false, "userinfo kosync rejected")
eq(Origin.host_matches_kosync("http://[::1]:6060",
    "http://[::1]:6060/api/koreader"), true, "ipv6 same origin")
eq(Origin.host_matches_kosync("http://[::1]:6060",
    "http://[::1]:6061/api/koreader"), false, "ipv6 port mismatch")
eq(Origin.same_host("http://h:6060", "https://h:443"), true, "same host ignores scheme")
eq(Origin.same_host("http://h:6060", "http://other:6060"), false, "different host")

print("origin: " .. n .. " ok")
