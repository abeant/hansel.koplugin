package.path = "./lib/?.lua;./?.lua;" .. package.path
local OPDS = require("lib/opds")
local Origin = require("lib/origin") -- luacheck: ignore

local n = 0
local function eq(a, b, msg)
    n = n + 1
    if a ~= b then
        error(string.format("FAIL %s: %s ~= %s", msg or n, tostring(a), tostring(b)))
    end
end

eq(OPDS.extract_book_id("http://h:6060/api/v1/opds/99/download"), "99", "id from download")
eq(OPDS.extract_book_id("http://h:6060/api/v1/opds/7/cover"), "7", "id from cover")

local xml = [[
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <title>All Books</title>
  <opensearch:totalResults>2</opensearch:totalResults>
  <link rel="next" href="/api/v1/opds/catalog?page=2&amp;size=12"/>
  <entry>
    <title>The Left Hand of Darkness</title>
    <id>urn:grimmory:book:15</id>
    <author><name>Ursula K. Le Guin</name></author>
    <summary>A winter planet.</summary>
    <link rel="http://opds-spec.org/image" href="/api/v1/opds/15/cover" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/15/download" type="application/epub+zip"/>
  </entry>
  <entry>
    <title>No Id Here</title>
    <id>urn:uuid:nope</id>
  </entry>
</feed>
]]

local feed = OPDS.parse(xml, "http://h:6060/api/v1/opds/catalog?page=1&size=12")
eq(#feed.books, 1, "skip entry without book id")
eq(feed.books[1].id, "15", "canonical id")
eq(feed.books[1].title, "The Left Hand of Darkness", "title")
eq(feed.books[1].authors[1], "Ursula K. Le Guin", "author")
eq(feed.books[1].file_type, "epub", "type")
eq(feed.total, 2, "totalResults")
assert(feed.books[1].cover_url:find("/opds/15/cover"), "cover url")
assert(feed.next_url:find("page=2"), "next link")

print("opds: " .. n .. " ok")
