--- OpenAI provider — thin wrapper over the OpenAI-compatible factory.
-- Supports OPENAI_BASE_URL for pointing at compatible endpoints.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local compat = require("lib.ai.providers.openai_compat")

local base_url = os.getenv("OPENAI_BASE_URL")
local config = { name = "openai", api_key_env = "OPENAI_API_KEY" }

if base_url then
	local h, p = base_url:match("^https?://([^/]+)(.*)")
	if not h then h, p = base_url:match("^([^/]+)(.*)") end
	config.host = h or "api.openai.com"
	if p and #p > 0 then config.chat_path = p end
else
	config.host = "api.openai.com"
end

return compat.create(config)
