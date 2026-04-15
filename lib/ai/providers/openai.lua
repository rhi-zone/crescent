--- OpenAI provider — thin wrapper over the OpenAI-compatible factory.
-- Call create(base_url) to get a provider instance.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local compat = require("lib.ai.providers.openai_compat")

local function create(base_url)
	local config = { name = "openai" }
	if base_url then
		local h, p = base_url:match("^https?://([^/]+)(.*)")
		if not h then h, p = base_url:match("^([^/]+)(.*)") end
		config.host = h or "api.openai.com"
		if p and #p > 0 then config.chat_path = p end
	else
		config.host = "api.openai.com"
	end
	return compat.create(config)
end

return { create = create }
