--- OpenAI-compatible provider factory.
-- Creates a provider for any API that speaks the OpenAI chat completions,
-- embeddings, and images format. ~11 providers share this shape.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local https = require("lib.https.client")
local stream_mod = require("lib.http.stream")

local mod = {}

--- Convert neutral ai_message list to OpenAI format.
local function convert_messages(messages)
	local converted = {}
	for i = 1, #messages do
		local msg = messages[i]
		converted[i] = {
			role = msg.role,
			content = msg.content,
		}
		if msg.role == "tool" then
			converted[i].tool_call_id = msg.tool_call_id
		end
		if msg.name then
			converted[i].name = msg.name
		end
	end
	return converted
end

--- Convert neutral ai_tool list to OpenAI format.
local function convert_tools(tools)
	if not tools or #tools == 0 then return nil end
	local result = {}
	for i = 1, #tools do
		local t = tools[i]
		result[i] = {
			type = "function",
			["function"] = {
				name = t.name,
				description = t.description,
				parameters = t.parameters,
			},
		}
	end
	return result
end

--- Parse OpenAI chat response into neutral ai_response.
local function parse_chat_response(body)
	local data, err = json.decode(body)
	if not data then return nil, "json decode: " .. (err or "unknown") end

	if data.error then
		return nil, data.error.message or json.encode(data.error)
	end

	local choices = data.choices
	if not choices or #choices == 0 then return nil, "no choices in response" end
	local choice = choices[1]
	local msg = choice.message or {}

	local tool_calls
	if msg.tool_calls then
		tool_calls = {}
		for i = 1, #msg.tool_calls do
			local tc = msg.tool_calls[i]
			local args = tc["function"] and tc["function"].arguments
			if type(args) == "string" then args = json.decode(args) or {} end
			tool_calls[i] = {
				id = tc.id,
				name = tc["function"] and tc["function"].name,
				arguments = args,
			}
		end
	end

	return {
		text = msg.content,
		tool_calls = tool_calls,
		finish_reason = choice.finish_reason or "unknown",
		usage = data.usage and {
			input_tokens = data.usage.prompt_tokens,
			output_tokens = data.usage.completion_tokens,
		} or nil,
	}
end

--- Make auth headers for the request.
local function make_bearer_headers(api_key, body_str)
	return {
		["Content-Type"] = { "application/json" },
		["Authorization"] = { "Bearer " .. api_key },
		["Content-Length"] = { tostring(#body_str) },
	}
end

--- Create an OpenAI-compatible provider.
--[[@param config { name: string, host: string, chat_path?: string, embeddings_path?: string, images_path?: string, api_key_env: string, make_headers?: fun(api_key: string, body_str: string): table }]]
--[[@return ai_provider]]
mod.create = function(config)
	local host = config.host
	local chat_path = config.chat_path or "/v1/chat/completions"
	local embeddings_path = config.embeddings_path or "/v1/embeddings"
	local images_path = config.images_path or "/v1/images/generations"
	local api_key_env = config.api_key_env
	local make_headers = config.make_headers or make_bearer_headers

	local function get_api_key()
		local key = os.getenv(api_key_env)
		if not key then return nil, api_key_env .. " not set" end
		return key
	end

	local provider = {}

	--[[@param req ai_request]]
	--[[@return ai_response?, string?]]
	provider.generate = function(req)
		local api_key, err = get_api_key()
		if not api_key then return nil, err end

		local messages = convert_messages(req.messages)
		local body = {
			model = req.model,
			messages = messages,
		}
		if req.max_tokens then body.max_tokens = req.max_tokens end
		if req.temperature then body.temperature = req.temperature end
		local tools = convert_tools(req.tools)
		if tools then body.tools = tools end

		local body_str = json.encode(body)
		local res
		res, err = https.request({
			host = host,
			method = "POST",
			path = chat_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		})
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
		end

		return parse_chat_response(res.body)
	end

	--[[@param req ai_request]]
	--[[@return fun(): ai_delta?, string?]]
	provider.stream = function(req)
		local api_key, err = get_api_key()
		if not api_key then return nil, err end

		local messages = convert_messages(req.messages)
		local body = {
			model = req.model,
			messages = messages,
			stream = true,
		}
		if req.max_tokens then body.max_tokens = req.max_tokens end
		if req.temperature then body.temperature = req.temperature end
		local tools = convert_tools(req.tools)
		if tools then body.tools = tools end

		local body_str = json.encode(body)

		local recv_fn, close_fn = https.stream({
			host = host,
			method = "POST",
			path = chat_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		})
		if not recv_fn then return nil, close_fn end

		local s = stream_mod.new(recv_fn)
		local headers
		headers, err = s:read_headers()
		if not headers then
			close_fn()
			return nil, err
		end

		local status = s:status()
		if status ~= 200 then
			local body_text = s:read_body() or ""
			close_fn()
			return nil, "HTTP " .. (status or "?") .. ": " .. body_text
		end

		local events_iter = s:events()
		local done = false
		local tool_calls_acc = {}

		return function()
			if done then return nil end
			while true do
				local event = events_iter()
				if not event then
					done = true
					close_fn()
					return nil
				end

				local data = event.data
				if data == "[DONE]" then
					done = true
					close_fn()
					return nil
				end

				local chunk = json.decode(data)
				if not chunk then goto continue end

				local choices = chunk.choices
				if not choices or #choices == 0 then goto continue end
				local delta = choices[1].delta or {}
				local finish = choices[1].finish_reason

				if delta.content then
					return { text = delta.content }
				end

				if delta.tool_calls then
					for i = 1, #delta.tool_calls do
						local tc = delta.tool_calls[i]
						local idx = (tc.index or 0) + 1
						if not tool_calls_acc[idx] then
							tool_calls_acc[idx] = { id = "", name = "", arguments_parts = {} }
						end
						local acc = tool_calls_acc[idx]
						if tc.id then acc.id = tc.id end
						if tc["function"] then
							if tc["function"].name then acc.name = tc["function"].name end
							if tc["function"].arguments then
								acc.arguments_parts[#acc.arguments_parts + 1] = tc["function"].arguments
							end
						end
					end
				end

				if finish then
					if finish == "tool_calls" or finish == "stop" then
						for idx = 1, #tool_calls_acc do
							local acc = tool_calls_acc[idx]
							if acc then
								local args_str = table.concat(acc.arguments_parts)
								return {
									tool_call = {
										id = acc.id,
										name = acc.name,
										arguments = json.decode(args_str) or {},
									},
								}
							end
						end
					end
					return { finish_reason = finish }
				end

				::continue::
			end
		end
	end

	--- Embed a single value.
	--[[@param req { model: string, value: string }]]
	--[[@return { embedding: number[], usage: table? }?, string?]]
	provider.embed = function(req)
		local api_key, err = get_api_key()
		if not api_key then return nil, err end

		local body_str = json.encode({
			model = req.model,
			input = req.value,
		})

		local res
		res, err = https.request({
			host = host,
			method = "POST",
			path = embeddings_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		})
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
		end

		local data
		data, err = json.decode(res.body)
		if not data then return nil, "json decode: " .. (err or "unknown") end
		if data.error then return nil, data.error.message or json.encode(data.error) end

		local items = data.data
		if not items or #items == 0 then return nil, "no embeddings in response" end

		return {
			embedding = items[1].embedding,
			usage = data.usage and {
				input_tokens = data.usage.prompt_tokens or data.usage.total_tokens,
			} or nil,
		}
	end

	--- Embed multiple values.
	--[[@param req { model: string, values: string[] }]]
	--[[@return { embeddings: number[][], usage: table? }?, string?]]
	provider.embed_many = function(req)
		local api_key, err = get_api_key()
		if not api_key then return nil, err end

		local body_str = json.encode({
			model = req.model,
			input = req.values,
		})

		local res
		res, err = https.request({
			host = host,
			method = "POST",
			path = embeddings_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		})
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
		end

		local data
		data, err = json.decode(res.body)
		if not data then return nil, "json decode: " .. (err or "unknown") end
		if data.error then return nil, data.error.message or json.encode(data.error) end

		local items = data.data
		if not items then return nil, "no embeddings in response" end

		-- sort by index to ensure correct order
		local embeddings = {}
		for i = 1, #items do
			local idx = (items[i].index or (i - 1)) + 1
			embeddings[idx] = items[i].embedding
		end

		return {
			embeddings = embeddings,
			usage = data.usage and {
				input_tokens = data.usage.prompt_tokens or data.usage.total_tokens,
			} or nil,
		}
	end

	--- Generate an image.
	--[[@param req { model: string, prompt: string, n?: integer, size?: string }]]
	--[[@return { images: { url?: string, b64_json?: string }[] }?, string?]]
	provider.generate_image = function(req)
		local api_key, err = get_api_key()
		if not api_key then return nil, err end

		local body = {
			model = req.model,
			prompt = req.prompt,
			n = req.n or 1,
			response_format = "b64_json",
		}
		if req.size then body.size = req.size end

		local body_str = json.encode(body)

		local res
		res, err = https.request({
			host = host,
			method = "POST",
			path = images_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		})
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
		end

		local data
		data, err = json.decode(res.body)
		if not data then return nil, "json decode: " .. (err or "unknown") end
		if data.error then return nil, data.error.message or json.encode(data.error) end

		local images = {}
		local items = data.data or {}
		for i = 1, #items do
			images[i] = {
				b64_json = items[i].b64_json,
				url = items[i].url,
			}
		end

		return { images = images }
	end

	return provider
end

--- Registry of well-known OpenAI-compatible providers.
-- { name, host, api_key_env, chat_path?, embeddings_path?, images_path? }
mod.registry = {
	openai = {
		host = "api.openai.com",
		api_key_env = "OPENAI_API_KEY",
	},
	groq = {
		host = "api.groq.com",
		chat_path = "/openai/v1/chat/completions",
		embeddings_path = "/openai/v1/embeddings",
		api_key_env = "GROQ_API_KEY",
	},
	deepseek = {
		host = "api.deepseek.com",
		api_key_env = "DEEPSEEK_API_KEY",
	},
	togetherai = {
		host = "api.together.xyz",
		api_key_env = "TOGETHER_API_KEY",
	},
	fireworks = {
		host = "api.fireworks.ai",
		chat_path = "/inference/v1/chat/completions",
		embeddings_path = "/inference/v1/embeddings",
		images_path = "/inference/v1/images/generations",
		api_key_env = "FIREWORKS_API_KEY",
	},
	deepinfra = {
		host = "api.deepinfra.com",
		chat_path = "/v1/openai/chat/completions",
		embeddings_path = "/v1/openai/embeddings",
		api_key_env = "DEEPINFRA_API_KEY",
	},
	cerebras = {
		host = "api.cerebras.ai",
		api_key_env = "CEREBRAS_API_KEY",
	},
	perplexity = {
		host = "api.perplexity.ai",
		api_key_env = "PERPLEXITY_API_KEY",
	},
	xai = {
		host = "api.x.ai",
		api_key_env = "XAI_API_KEY",
	},
	mistral = {
		host = "api.mistral.ai",
		api_key_env = "MISTRAL_API_KEY",
	},
}

return mod
