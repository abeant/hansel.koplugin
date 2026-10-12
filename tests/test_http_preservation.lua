local source, scratch = arg[1], arg[2]
package.path = source .. '/?.lua;' .. package.path
package.loaded.logger = {warn=function() end}
local captured, external = nil, 0
local transport = { request=function(req)
 captured=req
 if req.redirect then external=external+1 end
 if req.sink then req.sink('synthetic response');req.sink(nil) end
 return 1, 302, {location='https://other.test/receive'}, 'redirect'
end}
package.loaded['socket.http']=transport
package.loaded['ssl.https']=transport
package.loaded.ltn12={sink={table=function(t) return function(c) if c then t[#t+1]=c end return 1 end end,file=function(f) return function(c) if c then f:write(c) else f:close() end return 1 end end},source={string=function(s) return function() local x=s;s=nil;return x end end}}
package.loaded.socket={skip=function(_,_,...) return ... end}
package.loaded.socketutil={set_timeout=function() end,reset_timeout=function() end,FILE_BLOCK_TIMEOUT=1,FILE_TOTAL_TIMEOUT=1}
local Http=require('lib.http')
local failures,checks=0,0
local function check(ok,msg) checks=checks+1;if not ok then failures=failures+1;print('FAIL '..msg) else print('PASS '..msg) end end
local function write(p,s) local f=assert(io.open(p,'wb'));f:write(s);f:close() end
local function read(p) local f=io.open(p,'rb');if not f then return nil end;local s=f:read('*a');f:close();return s end
local dest=scratch..'/existing.epub'
local real=Http.request
for _,case in ipairs({'http-error','interrupted'}) do
 write(dest,'original edition')
 Http.request=function(_,opts) opts.sink('partial replacement');opts.sink(nil);return false,case=='http-error' and 503 or 0,'synthetic failure' end
 local ok=Http.download_file('https://origin.test/content',dest,{})
 check(not ok and read(dest)=='original edition',case..' preserves existing edition bytes')
 check(read(dest..'.part')==nil,case..' cleans partial file')
end
write(dest,'original edition')
Http.request=function(_,opts) opts.sink('new edition');opts.sink(nil);return true,200,'' end
local rename=os.rename;os.rename=function() return nil,'fixture denied rename' end
local ok=Http.download_file('https://origin.test/content',dest,{})
os.rename=rename
check(not ok and read(dest)=='original edition','rename failure retains original edition')
check(read(dest..'.part')==nil,'rename failure cleans partial file')
write(dest,'original edition')
local ok=Http.download_file('https://origin.test/content',dest,{})
check(ok and read(dest)=='new edition','successful native replacement commits exact new bytes')
Http.request=real
for _,opts in ipairs({{user='fixture-user',password='fixture-secret'},{headers={Authorization='Bearer fixture-token'}},{headers={['x-auth-user']='fixture-user',['x-auth-key']='fixture-secret'}}}) do
 external=0
 Http.request('https://origin.test/content',opts)
 check(external==0,'credentialed redirect cannot contact synthetic other origin')
end
external=0
Http.request('https://origin.test/content',{})
check(external==1,'public unsigned redirect remains allowed')
local gated=Http.gated('http://origin.test/content',{url='https://origin.test',user='fixture-user',password='fixture-secret'})
check(gated.user==nil and gated.password==nil,'HTTPS downgrade strips explicit origin credentials')
print(string.format('RESULT checks=%d failures=%d',checks,failures))
os.exit(failures==0 and 0 or 1)
