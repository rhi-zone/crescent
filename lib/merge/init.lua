if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local mod = {}

--[[creates new object with all the keys of the inputs. handles array part as well]]
--: (...{ [unknown]: unknown }) -> { [unknown]: unknown }
mod.merge = function (...)
	local ret = {}
	local next_i = 1
	for _, obj in ipairs({ ... }) do
		for _, v in ipairs(obj) do
			ret[next_i] = v
			next_i = next_i + 1
		end
		local len = #obj
		for k, v in pairs(obj) do
			local kn = k --[[:! number | nil]]
			if type(k) ~= "number" or (kn and (kn <= len or kn % 1 ~= 0)) then ret[k] = v end
		end
	end
	return ret
end

return mod
