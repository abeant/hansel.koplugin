package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
Stub.install()

local captured = {}
local get_body = { percentage = 0.2, progress = "/body/DocFragment[1]/body/p[2]" }
package.loaded["lib.http"] = {
    get = function(url, opts)
        captured.get_url, captured.get_opts = url, opts
        return true, 200, get_body
    end,
    put_json = function(url, payload, opts)
        captured.put_url, captured.payload, captured.put_opts = url, payload, opts
        return true, 200, {}
    end,
}

local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
local Client = require("lib.kosync_client")
local credentials = { username = "native-reader", userkey = "native-key" }

local checks = 0
local function ok(value, message)
    checks = checks + 1
    assert(value, "FAIL: " .. message)
end
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

local pulled = Client.get(credentials, "partial-md5")
ok(pulled.ok, "native pull succeeds")
eq(pulled.body.percentage, 0.2, "pull keeps fractional percent")
eq(pulled.body.progress, "/body/DocFragment[1]/body/p[2]", "pull keeps XPointer")
eq(pulled.body.cfi, nil, "pull never exposes CFI")
eq(captured.get_url,
    "http://grimmory.test:6060/api/koreader/syncs/progress/partial-md5",
    "partial MD5 is the wire document key")
eq(captured.get_opts.headers["x-auth-key"], "native-key", "native auth key header")
eq(captured.get_opts.headers.Accept, "application/vnd.koreader.v1+json",
    "native vendor accept")

get_body = {
    percentage = 0.55,
    progress = "epubcfi(/6/4[chap]!/4/2/1:0)",
    cfi = "epubcfi(/6/4[chap]!/4/2/1:0)",
}
local stripped = Client.get(credentials, "cfi-doc")
eq(stripped.body.percentage, 0.55, "CFI reply still yields percent")
eq(stripped.body.progress, nil, "CFI progress is dropped")
eq(stripped.body.cfi, nil, "CFI field is dropped")

Client.put(credentials, {
    digest = "partial-md5", percentage = 0.42,
    xpointer = "/body/section[4]", captured_at = 123,
})
eq(captured.payload.progress, "/body/section[4]", "rolling push includes XPointer")
eq(captured.payload.percentage, 0.42, "wire percentage stays fractional")
eq(captured.put_opts.headers["Content-Type"], "application/vnd.koreader.v1+json",
    "native vendor media type")

Client.put(credentials, {
    digest = "pdf-md5", percentage = 0.75, captured_at = 456,
    cfi = "epubcfi(/6/4!/4)",
})
eq(captured.payload.progress, nil, "paged push omits XPointer and CFI")
eq(captured.payload.cfi, nil, "push never includes CFI field")
eq(captured.payload.percentage, 0.75, "paged push still sends percent")

Client.put(credentials, {
    digest = "cfi-md5", percentage = 0.1,
    xpointer = "epubcfi(/6/8!/4/2)",
})
eq(captured.payload.progress, nil, "CFI-shaped xpointer is not sent")

print("kosync client: " .. checks .. " ok")
