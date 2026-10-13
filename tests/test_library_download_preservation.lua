local source, scratch = assert(arg[1]), assert(arg[2])
package.path = source .. '/?.lua;' .. source .. '/tests/?.lua;' .. package.path
require('kostub').install()
local function write(path, bytes)
    local f = assert(io.open(path, 'wb')); f:write(bytes); f:close()
end
local function read(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local bytes = f:read('*a'); f:close(); return bytes
end
local function attributes(path)
    local bytes = read(path)
    return bytes and {size = #bytes, mode = 'file'} or nil
end
package.loaded['libs/libkoreader-lfs'] = {attributes = attributes}
package.loaded['lib.settings'] = {
    server_url = function() return 'https://fixture.test' end,
    has_tier2 = function() return false end,
    download_dir = function() return scratch end,
    get = function() return nil end, t1_password = function() return nil end,
}
local records, upserts = 0, 0
package.loaded['lib.cache_map'] = {
    local_path = function() return nil end,
    file_hash = read,
    record_download = function() records = records + 1 end,
    record_seen = function() records = records + 1 end,
}
package.loaded['lib.catalog'] = {upsert_book = function() upserts = upserts + 1 end}
local payload = 'new edition'
package.loaded['lib.http'] = {download_file = function(_, path)
    write(path, payload)
    return true, 200, path, {}
end}
require('lib.paths').ensure = function() end
local Library = require('lib.library')
local dest, collision = scratch .. '/Fixture.epub', scratch .. '/Fixture (42).epub'
local staged = scratch .. '/.hansel-42'
local rename = os.rename
local checks, failures = 0, 0
local function check(value, label)
    checks = checks + 1
    if not value then failures = failures + 1; print('FAIL ' .. label) else print('PASS ' .. label) end
end
local function seed()
    write(dest, 'different book'); write(collision, 'original edition')
    records, upserts = 0, 0
end
seed()
os.rename = function() return nil, 'fixture denied rename' end
local ok = Library.download({id = 42, title = 'Fixture', file_type = 'epub'})
os.rename = rename
check(not ok, 'rename failure reported')
check(read(dest) == 'different book' and read(collision) == 'original edition', 'rename failure preserves both existing files')
check(read(staged) == nil, 'rename failure clears task staging')
check(records == 0 and upserts == 0, 'rename failure cannot publish metadata')
seed(); payload = ''
local err
ok, err = Library.download({id = 42, title = 'Fixture', file_type = 'epub'})
check(not ok and err == 'empty download', 'empty successful response rejected')
check(read(dest) == 'different book' and read(collision) == 'original edition', 'empty response preserves both existing files')
check(read(staged) == nil, 'empty response clears task staging')
check(records == 0 and upserts == 0, 'empty response cannot publish metadata')
seed(); payload = 'new edition'
ok = Library.download({id = 42, title = 'Fixture', file_type = 'epub'})
check(ok and read(collision) == payload, 'successful nonempty replacement commits bytes')
check(read(dest) == 'different book', 'successful collision leaves distinct book intact')
check(records == 1 and upserts == 1, 'metadata published after successful commit')
check(read(staged) == nil, 'successful rename consumes task staging')
print(string.format('RESULT checks=%d failures=%d', checks, failures))
os.exit(failures == 0 and 0 or 1)
