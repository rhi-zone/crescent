if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local mod = {}

--- Provider registry — lazy-loaded.
local providers = {}

--- Create OpenAI-compatible providers on demand from the registry.
local function get_provider(name)
	if providers[name] then return providers[name] end

	-- try loading a dedicated provider module first
	local ok, p = pcall(require, "lib.ai.providers." .. name)
	if ok and type(p) == "table" and (p.generate or p.stream) then
		providers[name] = p
		return p
	end

	-- check if it's a known OpenAI-compatible provider
	local compat_ok, compat = pcall(require, "lib.ai.providers.openai_compat")
	if compat_ok and compat.registry[name] then
		local config = compat.registry[name]
		config.name = name
		p = compat.create(config)
		providers[name] = p
		return p
	end

	return nil
end

--- Resolve provider from request.
-- Priority: req.provider (string name or table) > "openai" default.
-- The model field is always just the model name.
local function resolve(req)
	local prov = req.provider
	if prov then
		if type(prov) == "string" then
			local p = get_provider(prov)
			if not p then return nil, nil, "unknown provider: " .. prov end
			return p, req.model
		end
		-- provider is a table (custom provider)
		return prov, req.model
	end
	-- no provider specified: default to openai
	local p = get_provider("openai")
	if not p then return nil, nil, "openai provider not available" end
	return p, req.model
end

--- Copy request table, clearing provider field.
local function make_provider_req(req)
	local r = {}
	for k, v in pairs(req) do r[k] = v end
	r.provider = nil
	return r
end

--- Non-streaming generation.
--[[@param req ai_request]]
--[[@return ai_response?, string?]]
mod.generate = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	return provider.generate(make_provider_req(req))
end

--- Streaming generation — returns closure iterator.
--[[@param req ai_request]]
--[[@return fun(): ai_delta?]]
mod.stream = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then
		return function() return nil end, err
	end
	return provider.stream(make_provider_req(req))
end

--- Embed a single value.
--[[@param req { model: string, value: string, provider?: string|ai_provider }]]
--[[@return { embedding: number[], usage: table? }?, string?]]
mod.embed = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.embed then return nil, "provider does not support embeddings" end
	return provider.embed(make_provider_req(req))
end

--- Embed multiple values.
--[[@param req { model: string, values: string[], provider?: string|ai_provider }]]
--[[@return { embeddings: number[][], usage: table? }?, string?]]
mod.embed_many = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.embed_many then return nil, "provider does not support batch embeddings" end
	return provider.embed_many(make_provider_req(req))
end

--- Generate an image.
--[[@param req { model: string, prompt: string, n?: integer, size?: string, provider?: string|ai_provider }]]
--[[@return { images: table[] }?, string?]]
mod.generate_image = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.generate_image then return nil, "provider does not support image generation" end
	return provider.generate_image(make_provider_req(req))
end

--- Register a custom provider.
--[[@param name string]]
--[[@param provider ai_provider]]
mod.register = function(name, provider)
	providers[name] = provider
end

return mod
