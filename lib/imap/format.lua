--[[https://datatracker.ietf.org/doc/rfc9051/]]
--[[https://www.mailenable.com/kb/content/article.asp?ID=ME020711]]
--[[Client and server implementations MUST implement the capabilities
"AUTH=PLAIN" (described in [PLAIN]), and MUST implement "STARTTLS"
and "LOGINDISABLED" on the cleartext port.]]

--:: imap_flag = string
--:: imap_capability = string
--:: imap_date_time = { day: string, month: string, year: string, hour: string, minute: string, second: string, zone: { sign: string, hour: string, minute: string } }
--:: imap_nil = {}

local maxint = 9007199254740991

local mod = {}

local ffi

--: (s: string, i: integer | nil) -> (string | nil, integer | nil, string | nil)
mod.read_quoted = function(s, i)
	i = i or 1
	if s:byte(i) ~= 0x22 --[["]] then return nil, nil, "imap: quoted string is missing starting quote" end
	local parts = {} --: { [integer]: string, ... }
	i = i + 1
	local c = s:byte(i)
	while c ~= 0x22 --[["]] do
		--[[does not validate that the character after \ is a quoted-special]]
		if c == 0x5c --[[\]] then
			i = i + 2
			parts[#parts + 1] = string.char(s:byte(i - 1))
		else
			--[[does not validate that the non-ascii sequences are utf8]]
			local match = s:match("[^\"\\\\]", i)
			if not match then break end
			parts[#parts + 1] = match
			i = i + #match
		end
		if i > #s then break end
		c = s:byte(i)
	end
	if c ~= 0x22 then return nil, nil, "imap: quoted string is missing ending quote" end
	return table.concat(parts), i + 1, nil
end

--: (s: string, i: integer | nil) -> (string | nil, integer | nil, string | nil)
mod.read_literal = function(s, i)
	i = i or 1
	local _, end_, length_raw = s:find("{(%d+)+?}", i)
	if not end_ then return nil, nil, "imap: literal string is missing length" end
	local ni = end_ + 1
	local length = tonumber(length_raw)
	if not length then return nil, nil, "imap: literal: invalid length" end
	local ilen = length --[[:! integer]]
	if length > maxint then
		if not ffi then
			ffi = require("ffi")
			ffi.cdef [[ long long atoll(const char *str); ]]
		end
		ilen = (ffi --[[:! { C: { atoll: (string) -> integer } }]]).C.atoll(length_raw)
	end
	return s:sub(ni, ni + ilen - 1), ni + ilen, nil
end

--: (s: string, i: integer | nil) -> (string | nil, integer | nil, string | nil)
mod.read_string = function(s, i)
	i = i or 1
	local c = s:byte(i)
	if c == 0x22 --[["]] then
		return mod.read_quoted(s, i)
	elseif c == 0x7b --[[{]] then
		return mod.read_literal(s, i)
	else
		return nil, nil, "imap: invalid start of string: " .. s:sub(i, i)
	end
end

--: (s: string, i: integer | nil) -> (string | nil, integer | nil, string | nil)
mod.read_astring = function(s, i)
	i = i or 1
	local ret = s:match("[^%z- \x7f(){%*\"\\\\]+", i)
	if ret then
		local sret = ret --[[:! string]]
		return sret, i + #sret, nil
	end
	return mod.read_string(s, i)
end

--[[a placeholder representing imap's `nil`]]
mod.nil_ = {} --: imap_nil

--: (s: string, i: integer | nil) -> (string | imap_nil | nil, integer | nil, string | nil)
mod.read_string_or_nil = function(s, i)
	i = i or 1
	local c = s:byte(i)
	if c == 0x22 --[["]] then
		return mod.read_quoted(s, i)
	elseif c == 0x7b --[[{]] then
		return mod.read_literal(s, i)
	elseif s:find("[Nn][Ii][Ll]", i) then
		return mod.nil_, i + 3, nil
	else
		return nil, nil, "imap: invalid start of string: " .. s:sub(i, i)
	end
end

--: (s: string, i: integer | nil) -> (imap_date_time | nil, integer | nil, string | nil)
mod.read_date_time = function(s, i)
	i = i or 1
	local _, end_, day, month, year, hour, minute, second, zone_sign, zone_hour, zone_minute = s:find(
		"\"([ %d]%d)-([a-z][a-z][a-z])-(%d%d%d%d) (%d%d):(%d%d):(%d%d) ([+-])(%d%d)(%d%d)\"")
	if not end_ then return nil, nil, "imap: date_time: invalid" end
	local ret = {
		day = day, month = month, year = year,
		hour = hour, minute = minute, second = second,
		zone = { sign = zone_sign, hour = zone_hour, minute = zone_minute }
	} --: imap_date_time
	return ret, end_ + 1, nil
end

--: (s: string, i: integer | nil) -> (imap_flag | nil, integer | nil, string | nil)
mod.read_flag = function(s, i)
	i = i or 1
	--[[flags: \Answered | \Flagged | \Deleted | \Seen | \Draft]]
	--[[flag-keywords: $MDNSent | $Forwarded | $Junk | $NotJunk | $Phishing]]
	local match = s:match("[\\$]?[^%z- \x7f(){%*\"\\\\]+", i)
	if not match then return nil, nil, "imap: invalid start of flag: " .. s:sub(i, i) end
	local smatch = match --[[:! string]]
	return smatch, i + #smatch, nil
end

--: (s: string, i: integer | nil) -> (imap_capability | nil, integer | nil, string | nil)
mod.read_capability = function(s, i)
	i = i or 1
	local match = s:match("[Aa][Uu][Tt][Hh]=[^%z- \x7f(){%*\"\\\\]+", i)
	if not match then match = s:match("[^%z- \x7f(){%*\"\\\\]+", i) end
	if not match then return nil, nil, "imap: expected capability, found \"" .. s:sub(i, i) .. "\"" end
	local smatch = match --[[:! string]]
	return smatch, i + #smatch, nil
end

local noop_command_reader = function() return {}, 0, nil end

--: (s: string, i: integer) -> ({ mailbox: string, ... } | nil, integer | nil, string | nil)
local mailbox_command_reader = function(s, i)
	local mailbox, next_i, err = mod.read_astring(s, i)
	if not mailbox then return nil, nil, "imap: error reading mailbox:\n" .. (err or "") end
	return { mailbox = mailbox }, next_i, nil
end

mod.command_readers = {} --: { [string]: (s: string, i: integer) -> ({ [string]: unknown, ... } | nil, integer | nil, string | nil) }
mod.command_readers.capability = noop_command_reader
mod.command_readers.logout = noop_command_reader
mod.command_readers.noop = noop_command_reader
mod.command_readers.append = function(s, i)
	local mailbox, mi, merr = mod.read_astring(s, i)
	if not mailbox then return nil, nil, "imap: append: error reading mailbox:\n" .. (merr or "") end
	if not mi then return nil, nil, "imap: append: missing position after mailbox" end
	i = mi
	if s:byte(i) ~= 0x20 --[[ ]] then return nil, nil, "imap: append: missing space after mailbox" end
	i = i + 1
	local flags = {} --: imap_flag[]
	if s:byte(i) == 0x28 --[[(]] then
		while true do
			local flag, fi = mod.read_flag(s, i)
			if not flag then break end
			if not fi then break end
			i = fi
			if s:byte(i) ~= 0x20 then break end
			i = i + 1
			flags[#flags + 1] = flag
		end
		if s:byte(i) ~= 0x29 --[[)]] then return nil, nil, "imap: append: missing `)` after flags" end
	end
	local date_time, dti = mod.read_date_time(s, i)
	if date_time and dti then i = dti end
	local message, msg_i = mod.read_literal(s, i)
	if msg_i then i = msg_i end
	return { mailbox = mailbox, flags = flags, date_time = date_time, message = message }, i, nil
end
--[[use of "inbox" should give a NO error]]
mod.command_readers.create = mailbox_command_reader
--[[use of "inbox" should give a NO error]]
mod.command_readers.delete = mailbox_command_reader
--: (s: string, i: integer) -> ({ capabilities: imap_capability[], ... } | nil, integer | nil, string | nil)
mod.command_readers.enable = function(s, i)
	local capabilities = {} --: imap_capability[]
	while s:byte(i) == 0x20 do
		i = i + 1
		local capability, ci = mod.read_capability(s, i)
		if not capability then break end
		if not ci then break end
		i = ci
		capabilities[#capabilities + 1] = capability
	end
	return { capabilities = capabilities }, i, nil
end
mod.command_readers.starttls = noop_command_reader
mod.command_readers.close = noop_command_reader
mod.command_readers.unselect = noop_command_reader
mod.command_readers.expunge = noop_command_reader

--: (s: string, i: integer | nil) -> ({ tag: string, type: string, ... } | nil, integer | nil, string | nil)
mod.read_command = function(s, i)
	i = i or 1
	local _, end_, tag, type_ = s:find("([^%z- \x7f(){%*\"\\\\+]+) (%S+) ?")
	if not end_ then return nil, nil, "imap: command missing tag or command name" end
	local cmd_type = (type_ --[[:! string]]):lower()
	local reader = mod.command_readers[cmd_type]
	if not reader then return nil, nil, "imap: unknown command type " .. cmd_type end
	local ret, next_i, err = reader(s, i)
	if not ret then return nil, nil, err end
	ret.tag = tag --[[:! string]]
	ret.type = cmd_type
	return ret, next_i and next_i + 1 or nil, nil
end

mod.string_to_imap_command = mod.read_command

return mod
