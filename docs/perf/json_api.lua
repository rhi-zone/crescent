-- JSON API variant benchmarks.
-- Compares decode strategies for a 5-field flat object: pure.decode baseline,
-- SAX (callbacks), SAX zerocopy (positions), schema+fresh table, schema+reuse.
--
-- Run: luajit docs/perf/json_api.lua
-- See: docs/perf/log.md for recorded results and analysis.

package.path = "./?.lua;./?/init.lua;" .. package.path
local pure = require("lib.format.json.pure")
local clock = require("os").clock
local N = 300000
local SRC = '{"name":"Alice","age":30,"city":"NY","zip":10001,"active":true}'
local LSRC = #SRC

local function bench(name, n, fn)
    for i = 1, 300 do fn() end
    collectgarbage("collect")
    local t0 = clock()
    for i = 1, n do fn() end
    local ns = (clock() - t0) * 1e9 / n
    print(string.format("  %-50s %6.1f ns  %3d MB/s", name, ns, LSRC/(ns*1e-9)/1e6))
end

bench("baseline: pure.decode", N, function() return pure.decode(SRC) end)

-- SAX: scan + fire callback, no table allocation
local _sink = 0
local function cb(k, v) _sink = _sink + 1 end

local function sax_scan(src, on_kv)
    local pos, len = 2, #src
    repeat
        local b = src:byte(pos)
        while b ~= 34 and pos <= len do pos=pos+1; b=src:byte(pos) end
        if b ~= 34 then break end
        pos=pos+1; local ks=pos; b=src:byte(pos)
        while b~=34 do pos=pos+1; b=src:byte(pos) end
        local key = src:sub(ks, pos-1)
        pos=pos+2; b=src:byte(pos)
        local val
        if b==34 then
            pos=pos+1; local vs=pos; b=src:byte(pos)
            while b~=34 do pos=pos+1; b=src:byte(pos) end
            val=src:sub(vs,pos-1); pos=pos+1
        elseif b==116 then val=true;  pos=pos+4
        elseif b==102 then val=false; pos=pos+5
        else
            local ns2=pos; b=src:byte(pos)
            while b~=44 and b~=125 and pos<=len do pos=pos+1; b=src:byte(pos) end
            val=tonumber(src:sub(ns2,pos-1))
        end
        on_kv(key, val)
        if src:byte(pos)==44 then pos=pos+1 end
    until pos >= len
end
bench("SAX: scan+callbacks, no table", N, function() sax_scan(SRC, cb) end)

-- SAX zerocopy: pass string positions instead of extracting substrings
local function sax_zerocopy(src, on_kv)
    local pos, len = 2, #src
    repeat
        local b = src:byte(pos)
        while b~=34 and pos<=len do pos=pos+1; b=src:byte(pos) end
        if b~=34 then break end
        pos=pos+1; local ks=pos; b=src:byte(pos)
        while b~=34 do pos=pos+1; b=src:byte(pos) end
        local ke=pos-1; pos=pos+2; b=src:byte(pos)
        local vs, ve
        if b==34 then
            pos=pos+1; vs=pos; b=src:byte(pos)
            while b~=34 do pos=pos+1; b=src:byte(pos) end
            ve=pos-1; pos=pos+1
        elseif b==116 then vs=pos; ve=pos+3; pos=pos+4
        elseif b==102 then vs=pos; ve=pos+4; pos=pos+5
        else
            vs=pos; b=src:byte(pos)
            while b~=44 and b~=125 and pos<=len do pos=pos+1; b=src:byte(pos) end
            ve=pos-1
        end
        on_kv(ks, ke, vs, ve)
        if src:byte(pos)==44 then pos=pos+1 end
    until pos >= len
end
local function cb2(ks,ke,vs,ve) _sink=_sink+ks+ke+vs+ve end
bench("SAX zerocopy: pass positions (no str_sub)", N, function() sax_zerocopy(SRC, cb2) end)

-- Schema: pre-interned keys + rawset into fresh table
local PRE = {name="name",age="age",city="city",zip="zip",active="active"}
local function schema_decode(src)
    local t, pos, len = {}, 2, #src
    repeat
        local b = src:byte(pos)
        while b~=34 and pos<=len do pos=pos+1; b=src:byte(pos) end
        if b~=34 then break end
        pos=pos+1; local ks=pos; b=src:byte(pos)
        while b~=34 do pos=pos+1; b=src:byte(pos) end
        local key=PRE[src:sub(ks,pos-1)] or src:sub(ks,pos-1)
        pos=pos+2; b=src:byte(pos)
        if b==34 then
            pos=pos+1; local vs=pos; b=src:byte(pos)
            while b~=34 do pos=pos+1; b=src:byte(pos) end
            rawset(t,key,src:sub(vs,pos-1)); pos=pos+1
        elseif b==116 then rawset(t,key,true);  pos=pos+4
        elseif b==102 then rawset(t,key,false); pos=pos+5
        else
            local ns2=pos; b=src:byte(pos)
            while b~=44 and b~=125 and pos<=len do pos=pos+1; b=src:byte(pos) end
            rawset(t,key,tonumber(src:sub(ns2,pos-1)))
        end
        if src:byte(pos)==44 then pos=pos+1 end
    until pos >= len
    return t
end
bench("schema: pre-interned keys + rawset + fresh table", N, function() return schema_decode(SRC) end)

-- Schema + table reuse (LuaJIT analog of V8 hidden classes)
local _rt = {}
local function reuse_decode(src)
    local pos, len = 2, #src
    repeat
        local b = src:byte(pos)
        while b~=34 and pos<=len do pos=pos+1; b=src:byte(pos) end
        if b~=34 then break end
        pos=pos+1; local ks=pos; b=src:byte(pos)
        while b~=34 do pos=pos+1; b=src:byte(pos) end
        local key=PRE[src:sub(ks,pos-1)] or src:sub(ks,pos-1)
        pos=pos+2; b=src:byte(pos)
        if b==34 then
            pos=pos+1; local vs=pos; b=src:byte(pos)
            while b~=34 do pos=pos+1; b=src:byte(pos) end
            _rt[key]=src:sub(vs,pos-1); pos=pos+1
        elseif b==116 then _rt[key]=true;  pos=pos+4
        elseif b==102 then _rt[key]=false; pos=pos+5
        else
            local ns2=pos; b=src:byte(pos)
            while b~=44 and b~=125 and pos<=len do pos=pos+1; b=src:byte(pos) end
            _rt[key]=tonumber(src:sub(ns2,pos-1))
        end
        if src:byte(pos)==44 then pos=pos+1 end
    until pos >= len
    return _rt
end
bench("schema + table reuse (V8 hidden-class analog)", N, function() return reuse_decode(SRC) end)

print(string.format("\n_sink=%d (prevents dead code elim)", _sink))
