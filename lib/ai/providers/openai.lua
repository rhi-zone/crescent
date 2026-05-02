--- OpenAI provider — thin wrapper over the OpenAI-compatible factory.
-- Call create(base_url) to get a provider instance.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local compat = require("lib.ai.providers.openai_compat")

local function create(base_url)
	local host = "api.openai.com" --: string
	local chat_path = nil --: string | nil
	if base_url then
		local h, p = base_url:match("^https?://([^/]+)(.*)")
		if not h then h, p = base_url:match("^([^/]+)(.*)") end
		host = (h or "api.openai.com") --[[:! string]]
		if p and #p > 0 then chat_path = p --[[:! string]] end
	end
	local ep2 = nil --: string | nil
	local ip2 = nil --: string | nil
	local cfg = {
		name = "openai",
		host = host,
		chat_path = chat_path,
		embeddings_path = ep2,
		images_path = ip2,
	}
	return compat.create(cfg)
end

return { create = create }
