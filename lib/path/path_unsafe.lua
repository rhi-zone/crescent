local mod = {}

--[[@param base string]] --[[@param path string]]
--: (string, string) -> string
mod.resolve = function (base, path)
	--: string
	local base_ = base --[[:! string]]
	--: string
	local path_ = path --[[:! string]]
	base_ = base_:gsub("/$", "")
	if path_:byte(1) == 0x2f --[["/"]] then path_ = path_:sub(2) end
	local path_parts = {} --[[@type string[] ]]
	local i = 1
	while i < #base_ do
		local start, end_ = base_:find("[^/]*", i)
		path_parts[#path_parts+1] = base_:sub(start or i, end_ or i)
		i = (end_ or i) + 2
	end
	local path_it = (path_ --[[:! string]]):gmatch("([^/]+)") --[[:! () -> string | nil]]
	--[[TODO: check if this is safe]]
	while true do
		local part = path_it()
		if not part then break end
		if part == ".." then
			if #path_parts > 0 then path_parts[#path_parts] = nil end
		elseif part == "." then --[[ignored]]
		else
			path_parts[#path_parts+1] = part
		end
	end
	return table.concat(path_parts, "/")
end

return mod
