package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.install()
package.loaded["json"] = { encode = function() return "{}" end }

local Http = require("lib.http")

local checks = 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

local v = Http.validators({
    ETag = '"abc"',
    ["Last-Modified"] = "Mon, 01 Jan 2024 00:00:00 GMT",
})
eq(v.etag, '"abc"', "etag from mixed-case headers")
eq(v.last_modified, "Mon, 01 Jan 2024 00:00:00 GMT", "last-modified from mixed-case")
eq(Http.validators({}), nil, "no validators")
eq(Http.header_get({ ["if-none-match"] = "x" }, "If-None-Match"), "x", "header_get case fold")

local headers = {}
Http.apply_conditional(headers, {
    etag = '"abc"',
    last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
})
eq(headers["If-None-Match"], '"abc"', "sends If-None-Match")
eq(headers["If-Modified-Since"], "Mon, 01 Jan 2024 00:00:00 GMT", "sends If-Modified-Since")

local preset = { ["If-None-Match"] = '"keep"' }
Http.apply_conditional(preset, { etag = '"new"' })
eq(preset["If-None-Match"], '"keep"', "does not overwrite existing If-None-Match")

Http.apply_conditional(headers, { validators = { etag = '"v2"' } })
eq(headers["If-None-Match"], '"abc"', "existing conditional wins over validators")

local fresh = {}
Http.apply_conditional(fresh, { validators = { etag = '"v2"', last_modified = "Tue" } })
eq(fresh["If-None-Match"], '"v2"', "validators.etag")
eq(fresh["If-Modified-Since"], "Tue", "validators.last_modified")

local captured
local real_request = Http.request
Http.request = function(_, opts)
    captured = opts
    return true, 200, "{}"
end

Http.put_json("http://grimmory.test/api/koreader/syncs/progress", {}, {
    headers = { ["Content-Type"] = "application/vnd.koreader.v1+json" },
})
eq(captured.headers["Content-Type"], "application/vnd.koreader.v1+json",
    "native KOReader media type preserved")

Http.post_json("http://grimmory.test/api/v1/auth/login", {})
eq(captured.headers["Content-Type"], "application/json",
    "ordinary JSON gets the default media type")

Http.request = real_request

print("http: " .. checks .. " ok")
