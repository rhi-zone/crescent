-- lib/table_ext/init.lua
-- Extended table utilities beyond Lua's built-in table.*.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor, random, sort = math.floor, math.random, table.sort
local insert, concat = table.insert, table.concat

-- ---------------------------------------------------------------------------
-- Array operations
-- ---------------------------------------------------------------------------

--- Map each element through fn(v, i), return new array.
function M.map(t, fn)
	local out = {}
	for i = 1, #t do out[i] = fn(t[i], i) end
	return out
end

--- Keep elements where fn(v, i) is truthy.
function M.filter(t, fn)
	local out, n = {}, 0
	for i = 1, #t do
		if fn(t[i], i) then
			n = n + 1
			out[n] = t[i]
		end
	end
	return out
end

--- Left fold. init is required.
function M.reduce(t, fn, init)
	local acc = init
	for i = 1, #t do acc = fn(acc, t[i], i) end
	return acc
end

--- Iterate calling fn(v, i) for side effects.
function M.each(t, fn)
	for i = 1, #t do fn(t[i], i) end
end

--- Map then flatten one level.
function M.flat_map(t, fn)
	local out, n = {}, 0
	for i = 1, #t do
		local sub = fn(t[i], i)
		for j = 1, #sub do
			n = n + 1
			out[n] = sub[j]
		end
	end
	return out
end

--- Flatten nested arrays. depth=1 by default, nil=infinite.
function M.flatten(t, depth)
	if depth == nil then depth = math.huge end
	local out, n = {}, 0
	local function rec(arr, d)
		for i = 1, #arr do
			local v = arr[i]
			if type(v) == "table" and d > 0 then
				rec(v, d - 1)
			else
				n = n + 1
				out[n] = v
			end
		end
	end
	rec(t, depth)
	return out
end

--- Return first element where fn(v, i) is true (or nil if none).
function M.find(t, fn)
	for i = 1, #t do
		if fn(t[i], i) then return t[i], i end
	end
	return nil
end

--- Return index of first element where fn(v, i) is true (or nil).
function M.find_index(t, fn)
	for i = 1, #t do
		if fn(t[i], i) then return i end
	end
	return nil
end

--- Return index of value v (linear scan), or nil.
function M.index_of(t, v)
	for i = 1, #t do
		if t[i] == v then return i end
	end
	return nil
end

--- True if v is in array.
function M.contains(t, v)
	for i = 1, #t do
		if t[i] == v then return true end
	end
	return false
end

--- True if any element satisfies fn(v, i).
function M.any(t, fn)
	for i = 1, #t do
		if fn(t[i], i) then return true end
	end
	return false
end

--- True if all elements satisfy fn(v, i).
function M.all(t, fn)
	for i = 1, #t do
		if not fn(t[i], i) then return false end
	end
	return true
end

--- True if no element satisfies fn(v, i).
function M.none(t, fn)
	for i = 1, #t do
		if fn(t[i], i) then return false end
	end
	return true
end

--- Count elements satisfying fn, or all elements if fn is nil.
function M.count(t, fn)
	if fn == nil then return #t end
	local n = 0
	for i = 1, #t do
		if fn(t[i], i) then n = n + 1 end
	end
	return n
end

--- Sum of all elements.
function M.sum(t)
	local s = 0
	for i = 1, #t do s = s + t[i] end
	return s
end

--- Minimum value.
function M.min(t)
	local m = t[1]
	for i = 2, #t do if t[i] < m then m = t[i] end end
	return m
end

--- Maximum value.
function M.max(t)
	local m = t[1]
	for i = 2, #t do if t[i] > m then m = t[i] end end
	return m
end

--- Minimum element by key function fn(v) -> key.
function M.min_by(t, fn)
	local best, best_key = t[1], fn(t[1])
	for i = 2, #t do
		local k = fn(t[i])
		if k < best_key then best, best_key = t[i], k end
	end
	return best
end

--- Maximum element by key function fn(v) -> key.
function M.max_by(t, fn)
	local best, best_key = t[1], fn(t[1])
	for i = 2, #t do
		local k = fn(t[i])
		if k > best_key then best, best_key = t[i], k end
	end
	return best
end

--- Sort by key function fn(v) -> key. Returns new array.
function M.sort_by(t, fn)
	local out = M.shallow_copy(t)
	sort(out, function(a, b) return fn(a) < fn(b) end)
	return out
end

--- Group array into map of arrays by key function fn(v, i) -> key.
function M.group_by(t, fn)
	local out = {}
	for i = 1, #t do
		local k = fn(t[i], i)
		if out[k] == nil then out[k] = {} end
		insert(out[k], t[i])
	end
	return out
end

--- Deduplicate preserving order.
function M.unique(t)
	local seen, out, n = {}, {}, 0
	for i = 1, #t do
		local v = t[i]
		if not seen[v] then
			seen[v] = true
			n = n + 1
			out[n] = v
		end
	end
	return out
end

--- Deduplicate by key function fn(v) -> key, preserving order.
function M.unique_by(t, fn)
	local seen, out, n = {}, {}, 0
	for i = 1, #t do
		local k = fn(t[i])
		if not seen[k] then
			seen[k] = true
			n = n + 1
			out[n] = t[i]
		end
	end
	return out
end

--- Zip multiple arrays into array of tuples.
function M.zip(...)
	local arrays = {...}
	local len = #arrays[1]
	for i = 2, #arrays do
		if #arrays[i] < len then len = #arrays[i] end
	end
	local out = {}
	for i = 1, len do
		local tuple = {}
		for j = 1, #arrays do tuple[j] = arrays[j][i] end
		out[i] = tuple
	end
	return out
end

--- Unzip array of tuples into multiple arrays.
function M.unzip(t)
	if #t == 0 then return {} end
	local width = #t[1]
	local out = {}
	for j = 1, width do out[j] = {} end
	for i = 1, #t do
		for j = 1, width do out[j][i] = t[i][j] end
	end
	return unpack(out)
end

--- Split array into chunks of size n. Last chunk may be smaller.
function M.chunk(t, n)
	local out, idx = {}, 0
	local i = 1
	while i <= #t do
		idx = idx + 1
		local chunk = {}
		for j = 0, n - 1 do
			if t[i + j] ~= nil then chunk[j + 1] = t[i + j]
			else break end
		end
		out[idx] = chunk
		i = i + n
	end
	return out
end

--- First n elements.
function M.take(t, n)
	local out = {}
	for i = 1, n < #t and n or #t do out[i] = t[i] end
	return out
end

--- All but first n elements.
function M.drop(t, n)
	local out, idx = {}, 0
	for i = n + 1, #t do
		idx = idx + 1
		out[idx] = t[i]
	end
	return out
end

--- Reverse array. Returns new array.
function M.reverse(t)
	local len = #t
	local out = {}
	for i = 1, len do out[i] = t[len - i + 1] end
	return out
end

--- Remove nil/false values.
function M.compact(t)
	local out, n = {}, 0
	for i = 1, #t do
		if t[i] ~= nil and t[i] ~= false then
			n = n + 1
			out[n] = t[i]
		end
	end
	return out
end

--- Concatenate arrays.
function M.concat(...)
	local out, n = {}, 0
	local arrays = {...}
	for _, arr in ipairs(arrays) do
		for i = 1, #arr do
			n = n + 1
			out[n] = arr[i]
		end
	end
	return out
end

--- Build {from, from+step, ..., <=to}. step defaults to 1 (or -1 if to<from).
function M.range(from, to, step)
	if step == nil then step = (to >= from) and 1 or -1 end
	local out, n = {}, 0
	if step > 0 then
		local v = from
		while v <= to do
			n = n + 1
			out[n] = v
			v = v + step
		end
	else
		local v = from
		while v >= to do
			n = n + 1
			out[n] = v
			v = v + step
		end
	end
	return out
end

--- {v, v, ...} n times.
function M.repeat_val(v, n)
	local out = {}
	for i = 1, n do out[i] = v end
	return out
end

--- Fisher-Yates in-place shuffle. Returns t.
function M.shuffle(t)
	for i = #t, 2, -1 do
		local j = random(i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

--- Return n random elements without replacement (new array).
function M.sample(t, n)
	local copy = M.shallow_copy(t)
	M.shuffle(copy)
	return M.take(copy, n)
end

-- ---------------------------------------------------------------------------
-- Map / dict operations
-- ---------------------------------------------------------------------------

--- Sorted array of keys.
function M.keys(t)
	local out, n = {}, 0
	for k in pairs(t) do
		n = n + 1
		out[n] = k
	end
	sort(out, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return out
end

--- Array of values in key-sorted order (matches keys()).
function M.values(t)
	local ks = M.keys(t)
	local out = {}
	for i = 1, #ks do out[i] = t[ks[i]] end
	return out
end

--- Array of {k, v} pairs in key-sorted order.
function M.entries(t)
	local ks = M.keys(t)
	local out = {}
	for i = 1, #ks do out[i] = {ks[i], t[ks[i]]} end
	return out
end

--- {k, v} pairs → map.
function M.from_entries(arr)
	local out = {}
	for i = 1, #arr do out[arr[i][1]] = arr[i][2] end
	return out
end

--- Transform keys via fn(k, v) -> new_key.
function M.map_keys(t, fn)
	local out = {}
	for k, v in pairs(t) do out[fn(k, v)] = v end
	return out
end

--- Transform values via fn(v, k) -> new_value.
function M.map_values(t, fn)
	local out = {}
	for k, v in pairs(t) do out[k] = fn(v, k) end
	return out
end

--- Keep entries where fn(k) is true.
function M.filter_keys(t, fn)
	local out = {}
	for k, v in pairs(t) do
		if fn(k) then out[k] = v end
	end
	return out
end

--- Keep entries where fn(v, k) is true.
function M.filter_values(t, fn)
	local out = {}
	for k, v in pairs(t) do
		if fn(v, k) then out[k] = v end
	end
	return out
end

--- Shallow merge. Later tables win.
function M.merge(...)
	local out = {}
	local args = {...}
	for _, t in ipairs(args) do
		for k, v in pairs(t) do out[k] = v end
	end
	return out
end

--- Recursive merge of two tables. t2 values win on conflict (non-table).
function M.deep_merge(t1, t2)
	local out = {}
	for k, v in pairs(t1) do out[k] = v end
	for k, v in pairs(t2) do
		if type(v) == "table" and type(out[k]) == "table" then
			out[k] = M.deep_merge(out[k], v)
		else
			out[k] = v
		end
	end
	return out
end

--- New table with only the specified keys array.
function M.pick(t, keys)
	local out = {}
	for i = 1, #keys do
		local k = keys[i]
		if t[k] ~= nil then out[k] = t[k] end
	end
	return out
end

--- New table without the specified keys array.
function M.omit(t, keys)
	local skip = {}
	for i = 1, #keys do skip[keys[i]] = true end
	local out = {}
	for k, v in pairs(t) do
		if not skip[k] then out[k] = v end
	end
	return out
end

--- Swap keys and values.
function M.invert(t)
	local out = {}
	for k, v in pairs(t) do out[v] = k end
	return out
end

--- True if t[k] ~= nil.
function M.has_key(t, k)
	return t[k] ~= nil
end

-- ---------------------------------------------------------------------------
-- General
-- ---------------------------------------------------------------------------

--- Copy one level.
function M.shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

--- Recursive copy.
function M.deep_copy(t)
	local out = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			out[k] = M.deep_copy(v)
		else
			out[k] = v
		end
	end
	return out
end

--- Deep equality.
function M.eq(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	-- check all keys in a
	for k, v in pairs(a) do
		if not M.eq(v, b[k]) then return false end
	end
	-- check for keys in b not in a
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

--- Count all keys (uses # for arrays, pairs for maps).
function M.size(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--- True if table has contiguous integer keys from 1.
function M.is_array(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n == #t
end

--- True if table has no keys at all.
function M.is_empty(t)
	return next(t) == nil
end

return M
