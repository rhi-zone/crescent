if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local mod = {}

local maxint = 9007199254740992
local minint = -9007199254740992

local typeid = { ["nil"] = 1, boolean = 2, number = 3, string = 4, table = 5, ["function"] = 6, lightuserdata = 7, thread = 8 }
local sort_any_value = function(a, b)
	if type(a) ~= type(b) then
		return typeid[type(a)] < typeid[type(b)]
	elseif type(a) == "table" then
		return tostring(a) < tostring(b)
		-- it's possible to sort based on element but it's slow
		-- and this should have a consistent as long as the tables are created in the same order
	else
		return a < b
	end
end

local pretty_print_
local pretty_printers = {}
pretty_printers["nil"] = function(n, write) write(tostring(n)) end
pretty_printers.boolean = function(b, write) write(tostring(b)) end
--: (n: number, write: (...any) -> nil) -> nil
pretty_printers.number = function(n, write)
	write((n % 1 == 0 and n >= minint and n <= maxint) and string.format("%d", n) or
		n)
end
pretty_printers.string = function(s, write)
	-- FIXME: proper string escape
	write("\"",
		s:gsub("[\"\n\r\t\v]", { ["\""] = "\\\"", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\v"] = "\\v" }),
		"\"")
end
pretty_printers["function"] = function(_, write) write("<function>") end -- TODO: yucky, replace with string.dump and loadstring(f, "b")
pretty_printers.lightuserdata = function(_, write) write("<lightuserdata>") end
pretty_printers.thread = function(_, write) write("<thread>") end
pretty_printers.cdata = function(_, write) write("<cdata>") end
pretty_printers.userdata = function(_, write) write("<userdata>") end
--: (t: { [unknown]: unknown, __keyorder?: { [integer]: unknown } }, write: (...any) -> nil, seen: { [unknown]: boolean }) -> nil
pretty_printers.table = function(t, write, seen)
	seen[t] = true
	-- do
	-- 	local mt = getmetatable(t)
	-- 	local tostring = mt and mt.__tostring
	-- 	if tostring and type(tostring) == "function" then
	-- 		write(tostring(t)); return
	-- 	end
	-- end
	if t.__keyorder then
		local not_first = false
		for _, k in ipairs(t.__keyorder) do
			write(not_first and ", " or "{ ")
			if type(k) == "string" and k:find("^[_%a][_%w]*$") then
				write(k)
			else
				write("["); pretty_print_(k, write, true); write("]")
			end
			write(" = ")
			pretty_print_(t[k], write, true)
			not_first = true
		end
		write(not_first and " }" or "{}")
		return
	end
	local is_hash = false
	local max = #t
	for k in pairs(t) do
		if type(k) ~= "number" then is_hash = true; break end
		local kn = k --[[:! number]]
		if kn < 1 or kn > max or kn % 1 ~= 0 then
			is_hash = true; break
		end
	end
	if is_hash then
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, sort_any_value)
		local not_first = false
		for _, k in ipairs(keys) do
			write(not_first and ", " or "{ ")
			if type(k) == "string" and k:find("^[_%a][_%w]*$") then
				write(k)
			else
				write("["); pretty_print_(k, write, true); write("]")
			end
			write(" = ")
			pretty_print_(t[k], write, true, nil, seen)
			not_first = true
		end
		write(not_first and " }" or "{}")
	else
		local not_first = false
		for i = 1, max do
			write(not_first and ", " or "{ ")
			pretty_print_(t[i], write, true, nil, seen)
			not_first = true
		end
		write(not_first and " }" or "{}")
	end
end

--: (value: any, write: (...any) -> nil, not_top_level: boolean | nil, opts: { no_trailing_newline: boolean | nil, no_print_nil: boolean | nil } | nil, seen: { [any]: boolean } | nil) -> nil
pretty_print_ = function(value, write, not_top_level, opts, seen)
	if type(write) ~= "function" then
		error("pretty_print: write function is required")
	end
	seen = seen or {}
	if seen[value] then
		write("<circular>"); return
	end
	local opts_ = opts or {}
	if not not_top_level then
		if type(value) == "string" then
			write(value, "\n"); return
		elseif value == nil and opts_.no_print_nil then
			return
		end
	end
	local printer = pretty_printers[type(value)]
	if type(printer) == "function" then printer(value, write, seen) end
	if not not_top_level and not opts_.no_trailing_newline then write("\n") end
end
--: (any, (...any) -> nil, boolean | nil, { no_trailing_newline: boolean | nil, no_print_nil: boolean | nil } | nil, { [any]: boolean } | nil) -> nil
mod.pretty_print_ = pretty_print_
--: (any) -> string
mod.uneval = function(value)
	local parts = {} --: { [integer]: string }
	local write = function(...) for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end end
	pretty_print_(value, write, true)
	return table.concat(parts)
end
--: ((string) -> nil, ...any) -> nil
mod.pretty_print = function(write_fn, ...)
	if type(write_fn) ~= "function" then
		error("pretty_print: write_fn function is required")
	end
	local count = select("#", ...)
	if count == 1 then
		pretty_print_(select(1, ...), write_fn)
	else
		if count > 1 then pretty_print_(select(1, ...), write_fn, true) end
		for i = 2, count do
			write_fn(" ")
			pretty_print_(select(i, ...), write_fn, true)
		end
		write_fn("\n")
	end
end

return mod
