-- JSON collect-loop benchmark: 1000 objects → array of tables.
-- Compares strategies for the common pattern of parsing a batch of JSON
-- objects and collecting results. Schema+reuse+copy beats Node.js JSON.parse.
--
-- Run: luajit docs/perf/json_collect.lua
-- See: docs/perf/log.md for recorded results and analysis.

package.path = "./?.lua;./?/init.lua;" .. package.path
local pure = require("lib.format.json.pure")
local clock = require("os").clock

local names  = {"Alice","Bob","Carol","Dave","Eve","Frank","Grace","Hank","Iris","Jack"}
local cities = {"NY","LA","SF","Chicago","Houston","Phoenix","Dallas","Austin","Seattle","Denver"}
local lines  = {}
for i = 1, 1000 do
    lines[i] = string.format(
        '{"name":"%s","age":%d,"city":"%s","zip":%d,"active":%s}',
        names[(i-1)%10+1], 20+(i%50), cities[(i-1)%10+1], 10000+i,
        i%3==0 and "true" or "false")
end
local TOTAL = 0
for i = 1, 1000 do TOTAL = TOTAL + #lines[i] end

local function bench(name, n, fn)
    for i = 1, 5 do fn() end
    collectgarbage("collect")
    local t0 = clock()
    for i = 1, n do fn() end
    local ns = (clock() - t0) * 1e9 / n
    print(string.format("  %-52s %7.1f µs/batch  %3d MB/s",
        name, ns/1000, TOTAL/(ns*1e-9)/1e6))
end

-- 1. Baseline
bench("baseline: pure.decode → array of tables", 2000, function()
    local res = {}
    for i = 1, 1000 do res[i] = pure.decode(lines[i]) end
    return res
end)

-- 2. Schema + fresh table
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
bench("schema + fresh table", 2000, function()
    local res = {}
    for i = 1, 1000 do res[i] = schema_decode(lines[i]) end
    return res
end)

-- 3. Schema + reuse + copy (winner: beats Node.js JSON.parse)
-- Decode into a persistent table, then copy known fields into a fresh table.
-- The copy uses 5 literal-key writes — JIT treats it like a table constructor.
local _rt = {}
local function reuse_decode(src, t)
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
            t[key]=src:sub(vs,pos-1); pos=pos+1
        elseif b==116 then t[key]=true;  pos=pos+4
        elseif b==102 then t[key]=false; pos=pos+5
        else
            local ns2=pos; b=src:byte(pos)
            while b~=44 and b~=125 and pos<=len do pos=pos+1; b=src:byte(pos) end
            t[key]=tonumber(src:sub(ns2,pos-1))
        end
        if src:byte(pos)==44 then pos=pos+1 end
    until pos >= len
end
bench("schema + reuse + copy (beats Node.js)", 2000, function()
    local res = {}
    for i = 1, 1000 do
        reuse_decode(lines[i], _rt)
        res[i] = {name=_rt.name, age=_rt.age, city=_rt.city, zip=_rt.zip, active=_rt.active}
    end
    return res
end)

-- 4. SAX → columnar arrays
local function sax_scan(src, on_kv)
    local pos, len = 2, #src
    repeat
        local b = src:byte(pos)
        while b~=34 and pos<=len do pos=pos+1; b=src:byte(pos) end
        if b~=34 then break end
        pos=pos+1; local ks=pos; b=src:byte(pos)
        while b~=34 do pos=pos+1; b=src:byte(pos) end
        local key=src:sub(ks,pos-1); pos=pos+2; b=src:byte(pos)
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
bench("SAX → columnar arrays", 2000, function()
    local names_a,ages_a,cities_a,zips_a,active_a = {},{},{},{},{}
    local n = 0
    local function on_kv(k,v)
        if     k=="name"   then names_a[n]=v
        elseif k=="age"    then ages_a[n]=v
        elseif k=="city"   then cities_a[n]=v
        elseif k=="zip"    then zips_a[n]=v
        elseif k=="active" then active_a[n]=v end
    end
    for i = 1, 1000 do n=i; sax_scan(lines[i], on_kv) end
    return names_a
end)

-- 5. SAX → array of tables (callback overhead eats the gain)
bench("SAX → array of tables (slower than baseline!)", 2000, function()
    local res, cur = {}, nil
    local function on_kv(k,v) cur[k]=v end
    for i = 1, 1000 do
        cur={}; sax_scan(lines[i], on_kv); res[i]=cur
    end
    return res
end)
