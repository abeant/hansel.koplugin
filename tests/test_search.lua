package.path = "./?.lua;./tests/?.lua;" .. package.path
local function eq(actual, expected, message)
    assert(actual == expected, (message or "eq") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local Search = require("lib.search")

local books = {
    { id = "1", title = "The Left Hand of Darkness", authors = { "Ursula K. Le Guin" }, tags = { "sf" } },
    { id = "2", title = "Dune", authors = { "Frank Herbert" }, filename = "dune.epub" },
}

eq(#Search.query("guin", books), 1, "author hit")
eq(#Search.query("dune", books), 1, "title hit")
eq(#Search.query("sf", books), 1, "tag hit")
eq(#Search.query("", books), 0, "empty query")
eq(#Search.query("nope", books), 0, "miss")

print("search: 5 ok")
