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

--- Parse model string: "provider:model_name" -> provider_name, model_name
local function parse_model(model)
	local provider_name, model_name = model:match("^([^:]+):(.+)$")
	if provider_name then return provider_name, model_name end
	return nil, model
end

--- Resolve provider from request.
local function resolve(req)
	if req.provider then
		return req.provider, req.model
	end
	local provider_name, model_name = parse_model(req.model)
	if provider_name then
		local p = get_provider(provider_name)
		if not p then return nil, nil, "unknown provider: " .. provider_name end
		return p, model_name
	end
	local p = get_provider("openai")
	if not p then return nil, nil, "openai provider not available" end
	return p, model_name
end

--- Copy request table, substituting model name and clearing provider.
local function make_provider_req(req, model_name)
	local r = {}
	for k, v in pairs(req) do r[k] = v end
	r.model = model_name
	r.provider = nil
	return r
end

--- Non-streaming generation.
--[[@param req ai_request]]
--[[@return ai_response?, string?]]
mod.generate = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	return provider.generate(make_provider_req(req, model_name))
end

--- Streaming generation — returns closure iterator.
--[[@param req ai_request]]
--[[@return fun(): ai_delta?]]
mod.stream = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then
		return function() return nil end, err
	end
	return provider.stream(make_provider_req(req, model_name))
end

--- Embed a single value.
--[[@param req { model: string, value: string, provider?: ai_provider }]]
--[[@return { embedding: number[], usage: table? }?, string?]]
mod.embed = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.embed then return nil, "provider does not support embeddings" end
	return provider.embed(make_provider_req(req, model_name))
end

--- Embed multiple values.
--[[@param req { model: string, values: string[], provider?: ai_provider }]]
--[[@return { embeddings: number[][], usage: table? }?, string?]]
mod.embed_many = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.embed_many then return nil, "provider does not support batch embeddings" end
	return provider.embed_many(make_provider_req(req, model_name))
end

--- Generate an image.
--[[@param req { model: string, prompt: string, n?: integer, size?: string, provider?: ai_provider }]]
--[[@return { images: table[] }?, string?]]
mod.generate_image = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	if not provider.generate_image then return nil, "provider does not support image generation" end
	return provider.generate_image(make_provider_req(req, model_name))
end

--- Register a custom provider.
--[[@param name string]]
--[[@param provider ai_provider]]
mod.register = function(name, provider)
	providers[name] = provider
end

return mod
