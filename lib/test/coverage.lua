-- pure-Lua line coverage tracker using debug.sethook
-- usage:
--   local cov = require("lib.test.coverage")
--   cov.start()
--   -- run tests --
--   cov.stop()
--   cov.report()

local mod = {}

--[[line hit counts per source file: {[source] = {[line] = count}}]]
local hits = {}

--[[files to include (prefix match)]]
local include_prefix = "lib/"

--[[patterns to exclude from tracking]]
local exclude_patterns = {
	"_test%.lua$",
	"lib/test/",
}

--[[normalize source path: strip @ prefix and leading ./]]
local function normalize(source)
	if source:sub(1, 1) == "@" then source = source:sub(2) end
	if source:sub(1, 2) == "./" then source = source:sub(3) end
	return source
end

local function should_track(source)
	if source:sub(1, #include_prefix) ~= include_prefix then return false end
	for _, pat in ipairs(exclude_patterns) do
		if source:find(pat) then return false end
	end
	return true
end

--[[cache of source path -> normalized path or false]]
local path_cache = {}

local function hook(_, line)
	local info = debug.getinfo(2, "S")
	local raw = info.source
	local source = path_cache[raw]
	if source == nil then
		source = normalize(raw)
		source = should_track(source) and source or false
		path_cache[raw] = source
	end
	if not source then return end
	local file_hits = hits[source]
	if not file_hits then file_hits = {}; hits[source] = file_hits end
	file_hits[line] = (file_hits[line] or 0) + 1
end

mod.start = function ()
	hits = {}
	debug.sethook(hook, "l")
end

mod.stop = function ()
	debug.sethook()
end

--[[read a file and return its lines]]
local function read_lines(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local lines = {}
	for line in f:lines() do lines[#lines + 1] = line end
	f:close()
	return lines
end

--[[check if a line is executable (not blank, not comment-only, not block-comment-only)]]
local function is_executable(line)
	local trimmed = line:match("^%s*(.-)%s*$")
	if trimmed == "" then return false end
	if trimmed:sub(1, 2) == "--" then return false end
	if trimmed == "end" or trimmed == "else" or trimmed == "}" or trimmed == ")" then return false end
	return true
end

--[[get sorted list of tracked files]]
mod.files = function ()
	local out = {}
	for source in pairs(hits) do out[#out + 1] = source end
	table.sort(out)
	return out
end

--[[get per-file stats: {hit, executable, pct}]]
mod.stats = function (source)
	local lines = read_lines(source)
	if not lines then return nil end
	local file_hits = hits[source] or {}
	local executable = 0
	local hit = 0
	for i, line in ipairs(lines) do
		if is_executable(line) then
			executable = executable + 1
			if file_hits[i] then hit = hit + 1 end
		end
	end
	local pct = executable > 0 and (hit / executable * 100) or 100
	return { hit = hit, executable = executable, pct = pct }
end

--[[print coverage report to stdout]]
mod.report = function (opts)
	opts = opts or {}
	local sources = mod.files()
	if #sources == 0 then
		print("no coverage data")
		return
	end
	local total_hit, total_exec = 0, 0
	local file_stats = {}
	for _, source in ipairs(sources) do
		local s = mod.stats(source)
		if s and s.executable > 0 then
			file_stats[#file_stats + 1] = { source = source, stats = s }
			total_hit = total_hit + s.hit
			total_exec = total_exec + s.executable
		end
	end
	-- find longest filename for alignment
	local max_len = 4
	for _, fs in ipairs(file_stats) do
		if #fs.source > max_len then max_len = #fs.source end
	end
	local fmt = "  %-" .. max_len .. "s  %6s  %s"
	print("")
	print(string.format(fmt, "file", "cover", "lines"))
	print(string.format(fmt, string.rep("-", max_len), "------", "----------"))
	for _, fs in ipairs(file_stats) do
		local s = fs.stats
		local bar = string.format("%d/%d", s.hit, s.executable)
		print(string.format(fmt, fs.source, string.format("%5.1f%%", s.pct), bar))
	end
	local total_pct = total_exec > 0 and (total_hit / total_exec * 100) or 100
	print(string.format(fmt, string.rep("-", max_len), "------", "----------"))
	print(string.format(fmt, "total", string.format("%5.1f%%", total_pct),
		string.format("%d/%d", total_hit, total_exec)))

	-- per-file uncovered lines
	if opts.uncovered then
		print("")
		for _, fs in ipairs(file_stats) do
			if fs.stats.pct < 100 then
				local lines = read_lines(fs.source)
				local file_hits = hits[fs.source] or {}
				local uncovered = {}
				for i, line in ipairs(lines) do
					if is_executable(line) and not file_hits[i] then
						uncovered[#uncovered + 1] = i
					end
				end
				if #uncovered > 0 then
					-- collapse consecutive lines into ranges
					local ranges = {}
					local range_start = uncovered[1]
					local range_end = uncovered[1]
					for j = 2, #uncovered do
						if uncovered[j] == range_end + 1 then
							range_end = uncovered[j]
						else
							ranges[#ranges + 1] = range_start == range_end
								and tostring(range_start)
								or (range_start .. "-" .. range_end)
							range_start = uncovered[j]
							range_end = uncovered[j]
						end
					end
					ranges[#ranges + 1] = range_start == range_end
						and tostring(range_start)
						or (range_start .. "-" .. range_end)
					print("  " .. fs.source .. ": " .. table.concat(ranges, ", "))
				end
			end
		end
	end
end

--[[get raw hit data]]
mod.hits = function () return hits end

return mod
