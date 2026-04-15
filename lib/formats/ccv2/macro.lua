-- lib/formats/ccv2/macro.lua — SillyTavern-compatible macro substitution
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- weekday names (1=Sunday in os.date("*t"))
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December" }

--: (number) -> string
local function format_idle(seconds)
	if not seconds then return "" end
	local s = math.floor(seconds)
	if s < 60 then return s .. "s" end
	if s < 3600 then return math.floor(s / 60) .. "m " .. (s % 60) .. "s" end
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	return h .. "h " .. m .. "m " .. (s % 60) .. "s"
end

--: (string, string) -> { string }
local function split_args(inner, sep)
	sep = sep or "::"
	local parts = {}
	local pos = 1
	while true do
		local i = inner:find(sep, pos, true)
		if not i then
			parts[#parts + 1] = inner:sub(pos)
			break
		end
		parts[#parts + 1] = inner:sub(pos, i - 1)
		pos = i + #sep
	end
	return parts
end

--: (string) -> (number, number) | nil
local function parse_dice(s)
	local n, m = s:match("^(%d+)[dD](%d+)$")
	if not n then return nil end
	return tonumber(n), tonumber(m)
end

-- Variable helpers
--: (table, string) -> string
local function do_getvar(env, name)
	if env.getvar then
		return env.getvar(name) or ""
	end
	return ""
end

--: (table, string, string) -> string
local function do_setvar(env, name, value)
	if env.setvar then env.setvar(name, value) end
	return ""
end

--: (table, string) -> string
local function do_getglobalvar(env, name)
	if env.getglobalvar then
		return env.getglobalvar(name) or ""
	end
	return ""
end

--: (table, string, string) -> string
local function do_setglobalvar(env, name, value)
	if env.setglobalvar then env.setglobalvar(name, value) end
	return ""
end

-- Dispatch table: macro_name -> function(env, args) -> string
-- All keys are lowercase.
--: { [string]: (table, { string }) -> string }
local handlers = {}

-- Core identity
handlers["char"] = function(env) return env.char or "" end
handlers["user"] = function(env) return env.user or "" end

-- Character fields
handlers["description"] = function(env) return env.description or "" end
handlers["personality"] = function(env) return env.personality or "" end
handlers["scenario"] = function(env) return env.scenario or "" end
handlers["persona"] = function(env) return env.persona or "" end
handlers["charprompt"] = function(env) return env.system_prompt or "" end
handlers["charinstruction"] = function(env) return env.post_history_instructions or "" end
handlers["mesexamples"] = function(env) return env.mes_examples or "" end
handlers["mesexamplesraw"] = function(env) return env.mes_examples or "" end
handlers["charfirstmessage"] = function(env) return env.first_mes or "" end
handlers["charcreatornotes"] = function(env) return env.creator_notes or "" end
handlers["charversion"] = function(env) return env.char_version or "" end

-- Whitespace
handlers["newline"] = function(_, args)
	local n = tonumber(args[2]) or 1
	return ("\n"):rep(n)
end
handlers["space"] = function(_, args)
	local n = tonumber(args[2]) or 1
	return (" "):rep(n)
end
handlers["noop"] = function() return "" end
handlers["trim"] = function() return "" end

-- Time — requires env.time_fn: () -> {year,month,day,hour,min,sec,wday}
-- No fallback: caller must inject a time source.
local function get_time(env)
	if not env.time_fn then return nil end
	return env.time_fn()
end
handlers["time"] = function(env)
	local t = get_time(env)
	if not t then return "{{time}}" end
	return string.format("%02d:%02d", t.hour, t.min)
end
handlers["date"] = function(env)
	local t = get_time(env)
	if not t then return "{{date}}" end
	return string.format("%s %d, %d", MONTHS[t.month], t.day, t.year)
end
handlers["weekday"] = function(env)
	local t = get_time(env)
	if not t then return "{{weekday}}" end
	return WEEKDAYS[t.wday]
end
handlers["isotime"] = function(env)
	local t = get_time(env)
	if not t then return "{{isotime}}" end
	return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
end
handlers["isodate"] = function(env)
	local t = get_time(env)
	if not t then return "{{isodate}}" end
	return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end
handlers["idle_duration"] = function(env) return format_idle(env.idle_duration) end

-- Chat history
handlers["lastmessage"] = function(env) return env.last_message or "" end
handlers["lastusermessage"] = function(env) return env.last_user_message or "" end
handlers["lastcharmessage"] = function(env) return env.last_char_message or "" end
handlers["lastmessageid"] = function(env)
	if env.last_message_id then return tostring(env.last_message_id) end
	return ""
end
handlers["firstincludedmessageid"] = function(env)
	if env.first_included_message_id then return tostring(env.first_included_message_id) end
	return ""
end

-- Local variables
handlers["getvar"] = function(env, args) return do_getvar(env, args[2] or "") end
handlers["setvar"] = function(env, args)
	return do_setvar(env, args[2] or "", args[3] or "")
end
handlers["addvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getvar(env, name)
	local val = (tonumber(cur) or 0) + (tonumber(args[3]) or 0)
	do_setvar(env, name, tostring(val))
	return ""
end
handlers["incvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getvar(env, name)
	local val = (tonumber(cur) or 0) + 1
	do_setvar(env, name, tostring(val))
	return tostring(val)
end
handlers["decvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getvar(env, name)
	local val = (tonumber(cur) or 0) - 1
	do_setvar(env, name, tostring(val))
	return tostring(val)
end
handlers["hasvar"] = function(env, args)
	local name = args[2] or ""
	local val = do_getvar(env, name)
	return (val ~= "") and "true" or "false"
end
handlers["deletevar"] = function(env, args)
	return do_setvar(env, args[2] or "", "")
end

-- Global variables
handlers["getglobalvar"] = function(env, args) return do_getglobalvar(env, args[2] or "") end
handlers["setglobalvar"] = function(env, args)
	return do_setglobalvar(env, args[2] or "", args[3] or "")
end
handlers["addglobalvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getglobalvar(env, name)
	local val = (tonumber(cur) or 0) + (tonumber(args[3]) or 0)
	do_setglobalvar(env, name, tostring(val))
	return ""
end
handlers["incglobalvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getglobalvar(env, name)
	local val = (tonumber(cur) or 0) + 1
	do_setglobalvar(env, name, tostring(val))
	return tostring(val)
end
handlers["decglobalvar"] = function(env, args)
	local name = args[2] or ""
	local cur = do_getglobalvar(env, name)
	local val = (tonumber(cur) or 0) - 1
	do_setglobalvar(env, name, tostring(val))
	return tostring(val)
end
handlers["hasglobalvar"] = function(env, args)
	local name = args[2] or ""
	local val = do_getglobalvar(env, name)
	return (val ~= "") and "true" or "false"
end
handlers["deleteglobalvar"] = function(env, args)
	return do_setglobalvar(env, args[2] or "", "")
end

-- Random
handlers["random"] = function(env, args)
	if #args < 2 then return "" end
	local rng = env.rng or math.random
	local idx = math.floor(rng() * (#args - 1)) + 2
	return args[idx]
end
handlers["roll"] = function(env, args)
	local spec = args[2] or "1d6"
	local n, m = parse_dice(spec)
	if not n or n < 1 or m < 1 then return "0" end
	local rng = env.rng or math.random
	local total = 0
	for _ = 1, n do
		total = total + math.floor(rng() * m) + 1
	end
	return tostring(total)
end

-- Runtime
handlers["maxprompt"] = function(env)
	if env.max_prompt then return tostring(env.max_prompt) end
	return ""
end
handlers["maxcontexttokens"] = function(env)
	if env.max_context_tokens then return tostring(env.max_context_tokens) end
	return ""
end
handlers["maxresponsetokens"] = function(env)
	if env.max_response_tokens then return tostring(env.max_response_tokens) end
	return ""
end
handlers["model"] = function(env) return env.model or "" end

--- Substitute macros in text using the given environment table.
--- Single-pass: does not recurse into replacement results.
--: (string, table) -> string
function M.substitute(text, env)
	env = env or {}
	-- Legacy angle-bracket aliases (case-insensitive)
	text = text:gsub("<([Uu][Ss][Ee][Rr])>", "{{user}}")
	text = text:gsub("<([Bb][Oo][Tt])>", "{{char}}")
	text = text:gsub("<([Cc][Hh][Aa][Rr])>", "{{char}}")
	-- Macro substitution: single pass
	text = text:gsub("{{(.-)}}", function(inner)
		local parts = split_args(inner)
		local name = parts[1]:lower()
		local handler = handlers[name]
		if handler then
			return handler(env, parts)
		end
		-- Unknown macro: leave as-is
		return "{{" .. inner .. "}}"
	end)
	return text
end

return M
