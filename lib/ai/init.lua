if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local mod = {}

--- Provider registry — lazy-loaded.
local providers = {}

local function get_provider(name)
	if providers[name] then return providers[name] end
	local ok, p = pcall(require, "lib.ai.providers." .. name)
	if ok and p then
		providers[name] = p
		return p
	end
	return nil
end

--- Parse model string: "provider:model_name" -> provider_name, model_name
-- No prefix -> nil, full_string (caller decides default)
local function parse_model(model)
	local provider_name, model_name = model:match("^([^:]+):(.+)$")
	if provider_name then return provider_name, model_name end
	return nil, model
end

--- Resolve provider from request.
-- Priority: req.provider > model prefix > "openai" default
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
	-- no prefix: default to openai (compatible APIs)
	local p = get_provider("openai")
	if not p then return nil, nil, "openai provider not available" end
	return p, model_name
end

--- Non-streaming generation.
--[[@param req ai_request]]
--[[@return ai_response?, string?]]
mod.generate = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then return nil, err end
	local r = {}
	for k, v in pairs(req) do r[k] = v end
	r.model = model_name
	r.provider = nil
	return provider.generate(r)
end

--- Streaming generation — returns closure iterator.
--[[@param req ai_request]]
--[[@return fun(): ai_delta?]]
mod.stream = function(req)
	local provider, model_name, err = resolve(req)
	if not provider then
		-- return a single-shot iterator that yields nil
		return function() return nil end, err
	end
	local r = {}
	for k, v in pairs(req) do r[k] = v end
	r.model = model_name
	r.provider = nil
	return provider.stream(r)
end

--- Register a custom provider.
--[[@param name string]]
--[[@param provider ai_provider]]
mod.register = function(name, provider)
	providers[name] = provider
end

return mod
