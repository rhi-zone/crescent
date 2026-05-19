if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local mod = {}

--:: require "lib.ai.types"

--- Provider registry — lazy-loaded.
--: { [string]: ai_provider }
local providers = {}

--- Create OpenAI-compatible providers on demand from the registry.
local function get_provider(name)
	if providers[name] then return providers[name] end

	-- try loading a dedicated provider module first
	local ok, p = pcall(require, "lib.ai.providers." .. name)
	if ok and type(p) == "table" and (p.generate or p.stream) then
		local p_ = ((p --[[: unknown]]) --[[:! ai_provider]])
		providers[name] = p_
		return p_
	end

	-- check if it's a known OpenAI-compatible provider
	local compat_ok, compat = pcall(require, "lib.ai.providers.openai_compat")
	if compat_ok and compat.registry[name] then
		local config = compat.registry[name]
		config.name = name
		p = compat.create(config)
		local p_ = ((p --[[: unknown]]) --[[:! ai_provider]])
		providers[name] = p_
		return p_
	end

	return nil
end

--- Resolve provider from request.
-- Priority: req.provider (string name or table) > "openai" default.
-- The model field is always just the model name.
--: ({ provider?: unknown, model: string, ... }) -> (ai_provider | nil, string | nil, string | nil)
local function resolve(req)
	local prov = req.provider
	if prov then
		if type(prov) == "string" then
			local p = get_provider(prov)
			if not p then return nil, nil, "unknown provider: " .. prov end
			return p, req.model, nil
		end
		-- provider is a table (custom provider)
		return prov --[[:! ai_provider]], req.model, nil
	end
	-- no provider specified: default to openai
	local p = get_provider("openai")
	if not p then return nil, nil, "openai provider not available" end
	return p, req.model, nil
end

--- Copy request table, clearing provider field.
--: (unknown) -> unknown
local function make_provider_req(req)
	local r = {}
	for k, v in pairs(req --[[:! { [string]: unknown }]]) do r[k] = v end
	r.provider = nil
	return r
end

--- Non-streaming generation.
--: (ai_request) -> (ai_response | nil, string | nil)
mod.generate = function(req)
	local provider_, model_name, err = resolve(req)
	if not provider_ then return nil, err end
	return provider_.generate(make_provider_req(req) --[[:! ai_request]])
end

--- Streaming generation — returns closure iterator.
--: (ai_request) -> ((() -> ai_delta | nil) | nil, string | nil)
mod.stream = function(req)
	local provider_, model_name, err = resolve(req)
	if not provider_ then
		return function() return nil end, err
	end
	return provider_.stream(make_provider_req(req) --[[:! ai_request]])
end

--- Embed a single value.
--: (ai_embed_request) -> (ai_embed_response | nil, string | nil)
mod.embed = function(req)
	local provider_, model_name, err = resolve(req)
	if not provider_ then return nil, err end
	if not provider_.embed then return nil, "provider does not support embeddings" end
	return provider_.embed(make_provider_req(req) --[[:! ai_embed_request]])
end

--- Embed multiple values.
--: (ai_embed_many_request) -> (ai_embed_many_response | nil, string | nil)
mod.embed_many = function(req)
	local provider_, model_name, err = resolve(req)
	if not provider_ then return nil, err end
	if not provider_.embed_many then return nil, "provider does not support batch embeddings" end
	return provider_.embed_many(make_provider_req(req) --[[:! ai_embed_many_request]])
end

--- Generate an image.
--: (ai_image_request) -> (ai_image_response | nil, string | nil)
mod.generate_image = function(req)
	local provider_, model_name, err = resolve(req)
	if not provider_ then return nil, err end
	if not provider_.generate_image then return nil, "provider does not support image generation" end
	return provider_.generate_image(make_provider_req(req) --[[:! ai_image_request]])
end

--- Register a custom provider.
--: (string, ai_provider) -> nil
mod.register = function(name, provider)
	providers[name] = provider
end

return mod
