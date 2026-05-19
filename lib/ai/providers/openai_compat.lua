--- OpenAI-compatible provider factory.
-- Creates a provider for any API that speaks the OpenAI chat completions,
-- embeddings, and images format. ~11 providers share this shape.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local stream_mod = require("lib.http.stream")

local mod = {}

--:: require "lib.ai.types"
--:: openai_tool_call_in = { id?: string, function?: { name?: string, arguments?: string } }
--:: openai_message_in = { content?: string, tool_calls?: Arr<openai_tool_call_in> }
--:: openai_choice_in = { message?: openai_message_in, finish_reason?: string }
--:: openai_chat_response = { error?: { message?: string }, choices?: Arr<openai_choice_in>, usage?: { prompt_tokens: integer, completion_tokens: integer } }
--:: openai_stream_tc = { index?: integer, id?: string, function?: { name?: string, arguments?: string } }
--:: openai_stream_choice = { delta?: { content?: string, tool_calls?: Arr<openai_stream_tc> }, finish_reason?: string }
--:: openai_stream_chunk = { choices?: Arr<openai_stream_choice> }
--:: openai_embed_item = { embedding: Arr<number>, index?: integer }
--:: openai_embed_response = { error?: { message?: string }, data?: Arr<openai_embed_item>, usage?: { prompt_tokens?: integer, total_tokens?: integer } }
--:: openai_image_item = { url?: string, b64_json?: string }
--:: openai_image_response = { error?: { message?: string }, data?: Arr<openai_image_item> }
--:: http_stream_t = { read_headers: (self: unknown) -> (unknown, string | nil), status: (self: unknown) -> integer | nil, read_body: (self: unknown) -> (string | nil, string | nil), events: (self: unknown) -> () -> { event: string | nil, data: string, id: string | nil } | nil }

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
--: (ai_tool[] | nil) -> unknown
local function convert_tools(tools)
	if not tools then return nil end
	local n = #tools
	if n == 0 then return nil end
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
--: (string) -> (ai_response | nil, string | nil)
local function parse_chat_response(body)
	local raw, err = json.decode(body)
	if not raw then return nil, "json decode: " .. (err or "unknown") end
	local data = raw --[[:! openai_chat_response]]

	if data.error then
		local encoded_err = json.encode(data.error)
		return nil, data.error.message or encoded_err or "openai error"
	end

	local choices_opt = data.choices
	if not choices_opt then return nil, "no choices in response" end
	local choices = choices_opt --[[:! Arr<openai_choice_in>]]
	if #choices == 0 then return nil, "no choices in response" end
	local choice = choices[1]
	local msg = choice.message or {}

	local tool_calls --: ai_tool_call[] | nil
	local mtc_opt = msg.tool_calls
	if mtc_opt then
		local mtc = mtc_opt --[[:! Arr<openai_tool_call_in>]]
		tool_calls = {}
		for i = 1, #mtc do
			local tc = mtc[i]
			local args_raw = tc["function"] and tc["function"].arguments
			local args = {} --: { [string]: unknown }
			if type(args_raw) == "string" then
				local decoded = json.decode(args_raw)
				args = (decoded --[[:! { [string]: unknown } | nil]]) or {}
			end
			tool_calls[i] = {
				id = tc.id or "",
				name = (tc["function"] and tc["function"].name) or "",
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
--: ({ name: string, host: string, chat_path: (string | nil), embeddings_path: (string | nil), images_path: (string | nil), make_headers?: ((api_key: string, body_str: string) -> { [string]: { string } })}) -> ai_provider
mod.create = function(config)
	local host = config.host
	local chat_path = config.chat_path or "/v1/chat/completions"
	local embeddings_path = config.embeddings_path or "/v1/embeddings"
	local images_path = config.images_path or "/v1/images/generations"
	local make_headers = config.make_headers or make_bearer_headers

	--: (req: { api_key?: string, ... }) -> (string | nil, string | nil)
	local function get_api_key(req)
		local key = req and req.api_key
		if not key then return nil, "api_key is required" end
		return key
	end

	local provider = {}

	--: (ai_request) -> (ai_response | nil, string | nil)
	provider.generate = function(req)
		local api_key, err = get_api_key(req)
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

		local body_str_raw, body_err = json.encode(body)
		if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
		local body_str = body_str_raw

		local http_client = req.http_client
		if not http_client then return nil, "http_client is required" end

		local req_obj = {
			host = host,
			method = "POST",
			path = chat_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		}
		local res
		res, err = http_client.request(req_obj)
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
		else
			return parse_chat_response(res.body or "")
		end
	end

	--: (ai_request) -> ((() -> ai_delta | nil) | nil, string | nil)
	provider.stream = function(req)
		local api_key, err = get_api_key(req)
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

		local body_str_raw, body_err = json.encode(body)
		if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
		local body_str = body_str_raw

		local http_client = req.http_client
		if not http_client then return nil, "http_client is required" end

		local stream_req = {
			host = host,
			method = "POST",
			path = chat_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		}
		local recv_fn, close_fn = http_client.stream(stream_req)
		if not recv_fn then
			local err_msg = close_fn --[[:! string | nil]]
			return nil, err_msg
		end
		local close_cb = close_fn --[[:! () -> nil]]

		local s = stream_mod.new(recv_fn) --[[:! http_stream_t]]
		local headers
		headers, err = s:read_headers()
		if not headers then
			close_cb()
			return nil, err
		end

		local status = s:status()
		if status ~= 200 then
			local body_text_raw = s:read_body()
			local body_text = body_text_raw or ""
			close_cb()
			return nil, "HTTP " .. tostring(status or "?") .. ": " .. body_text
		end

		local events_iter = s:events()
		local done = false
		local tool_calls_acc = {} --: Arr<{ id: string, name: string, arguments_parts: Arr<string> }>

		return function()
			if done then return nil end
			while true do
				local event = events_iter()
				if not event then
					done = true
					close_cb()
					return nil
				end

				local data = event.data
				if data == "[DONE]" then
					done = true
					close_cb()
					return nil
				end

				local chunk_raw = json.decode(data)
				if not chunk_raw then goto continue end
				local chunk = chunk_raw --[[:! openai_stream_chunk]]

				local choices_opt = chunk.choices
				if not choices_opt then goto continue end
				local choices = choices_opt --[[:! Arr<openai_stream_choice>]]
				if #choices == 0 then goto continue end
				local delta = choices[1].delta or {}
				local finish = choices[1].finish_reason

				if delta.content then
					return { text = delta.content }
				end

				local dtc_opt = delta.tool_calls
				if dtc_opt then
					local dtc = dtc_opt --[[:! Arr<openai_stream_tc>]]
					for i = 1, #dtc do
						local tc = dtc[i]
						local idx = (tc.index or 0) + 1
						if not tool_calls_acc[idx] then
							tool_calls_acc[idx] = { id = "", name = "", arguments_parts = {} }
						end
						local acc_opt = tool_calls_acc[idx]
						local acc = acc_opt --[[:! { id: string, name: string, arguments_parts: Arr<string> }]]
						if tc.id then acc.id = tc.id end
						local fn = tc["function"]
						if fn then
							local fn_name = fn.name
							if fn_name ~= nil then
								acc.name = fn_name
							end
							local fn_args = fn.arguments
							if fn_args ~= nil then
								acc.arguments_parts[#acc.arguments_parts + 1] = fn_args
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
								local args_decoded = json.decode(args_str)
								local args = (args_decoded --[[:! { [string]: unknown } | nil]]) or {}
								return {
									tool_call = {
										id = acc.id,
										name = acc.name,
										arguments = args,
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
	--: (ai_embed_request) -> (ai_embed_response | nil, string | nil)
	provider.embed = function(req)
		local api_key, err = get_api_key(req)
		if not api_key then return nil, err end

		local body_str_raw, body_err = json.encode({
			model = req.model,
			input = req.value,
		})
		if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
		local body_str = body_str_raw

		local http_client = req.http_client
		if not http_client then return nil, "http_client is required" end

		local req_obj = {
			host = host,
			method = "POST",
			path = embeddings_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		}
		local res
		res, err = http_client.request(req_obj)
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
		else

		local data_raw
		data_raw, err = json.decode(res.body or "")
		if not data_raw then return nil, "json decode: " .. (err or "unknown") end
		local data = data_raw --[[:! openai_embed_response]]
		if data.error then local encoded_err = json.encode(data.error); return nil, data.error.message or encoded_err or "openai error" end

		local items_opt = data.data
		if not items_opt then return nil, "no embeddings in response" end
		local items = items_opt --[[:! Arr<openai_embed_item>]]
		if #items == 0 then return nil, "no embeddings in response" end

		return {
			embedding = items[1].embedding,
			usage = data.usage and {
				input_tokens = data.usage.prompt_tokens or data.usage.total_tokens or 0,
			} or nil,
		}
		end
	end

	--- Embed multiple values.
	--: (ai_embed_many_request) -> (ai_embed_many_response | nil, string | nil)
	provider.embed_many = function(req)
		local api_key, err = get_api_key(req)
		if not api_key then return nil, err end

		local body_str_raw, body_err = json.encode({
			model = req.model,
			input = req.values,
		})
		if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
		local body_str = body_str_raw

		local http_client = req.http_client
		if not http_client then return nil, "http_client is required" end

		local req_obj = {
			host = host,
			method = "POST",
			path = embeddings_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		}
		local res
		res, err = http_client.request(req_obj)
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
		else

		local data_raw
		data_raw, err = json.decode(res.body or "")
		if not data_raw then return nil, "json decode: " .. (err or "unknown") end
		local data = data_raw --[[:! openai_embed_response]]
		if data.error then local encoded_err = json.encode(data.error); return nil, data.error.message or encoded_err or "openai error" end

		local items_opt = data.data
		if not items_opt then return nil, "no embeddings in response" end
		local items = items_opt --[[:! Arr<openai_embed_item>]]

		-- sort by index to ensure correct order
		local embeddings = {}
		for i = 1, #items do
			local idx = (items[i].index or (i - 1)) + 1
			embeddings[idx] = items[i].embedding
		end

		return {
			embeddings = embeddings,
			usage = data.usage and {
				input_tokens = data.usage.prompt_tokens or data.usage.total_tokens or 0,
			} or nil,
		}
		end
	end

	--- Generate an image.
	--: (ai_image_request) -> (ai_image_response | nil, string | nil)
	provider.generate_image = function(req)
		local api_key, err = get_api_key(req)
		if not api_key then return nil, err end

		local body = {
			model = req.model,
			prompt = req.prompt,
			n = req.n or 1,
			response_format = "b64_json",
		}
		if req.size then body.size = req.size end

		local body_str_raw, body_err = json.encode(body)
		if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
		local body_str = body_str_raw

		local http_client = req.http_client
		if not http_client then return nil, "http_client is required" end

		local req_obj = {
			host = host,
			method = "POST",
			path = images_path,
			headers = make_headers(api_key, body_str),
			body = body_str,
		}
		local res
		res, err = http_client.request(req_obj)
		if not res then return nil, err end
		if res.status ~= 200 then
			return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
		else

		local data_raw
		data_raw, err = json.decode(res.body or "")
		if not data_raw then return nil, "json decode: " .. (err or "unknown") end
		local data = data_raw --[[:! openai_image_response]]
		if data.error then local encoded_err = json.encode(data.error); return nil, data.error.message or encoded_err or "openai error" end

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
	end

	return provider
end

--- Registry of well-known OpenAI-compatible providers.
-- { host, api_key_env, chat_path?, embeddings_path?, images_path? }
-- All use Bearer token auth and /v1/chat/completions unless overridden.
mod.registry = {
	-- ── Tier 1: major providers ─────────────────────────────────────────────
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
	mistral = {
		host = "api.mistral.ai",
		api_key_env = "MISTRAL_API_KEY",
	},
	xai = {
		host = "api.x.ai",
		api_key_env = "XAI_API_KEY",
	},
	perplexity = {
		host = "api.perplexity.ai",
		api_key_env = "PERPLEXITY_API_KEY",
	},
	cerebras = {
		host = "api.cerebras.ai",
		api_key_env = "CEREBRAS_API_KEY",
	},
	-- ── Tier 2: inference platforms ─────────────────────────────────────────
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
	sambanova = {
		host = "api.sambanova.ai",
		api_key_env = "SAMBANOVA_API_KEY",
	},
	nebius = {
		host = "api.studio.nebius.ai",
		api_key_env = "NEBIUS_API_KEY",
	},
	novita = {
		host = "api.novita.ai",
		chat_path = "/v3/openai/chat/completions",
		embeddings_path = "/v3/openai/embeddings",
		api_key_env = "NOVITA_API_KEY",
	},
	hyperbolic = {
		host = "api.hyperbolic.xyz",
		api_key_env = "HYPERBOLIC_API_KEY",
	},
	lambda = {
		host = "api.lambdalabs.com",
		api_key_env = "LAMBDA_API_KEY",
	},
	-- ── Tier 3: aggregators / routers ───────────────────────────────────────
	openrouter = {
		host = "openrouter.ai",
		chat_path = "/api/v1/chat/completions",
		api_key_env = "OPENROUTER_API_KEY",
	},
	huggingface = {
		host = "router.huggingface.co",
		api_key_env = "HF_TOKEN",
	},
	-- ── Tier 3b: open-source model hosts ───────────────────────────────────
	chutes = {
		host = "api.chutes.ai",
		api_key_env = "CHUTES_API_KEY",
	},
	featherless = {
		host = "api.featherless.ai",
		api_key_env = "FEATHERLESS_API_KEY",
	},
	friendli = {
		host = "inference.friendli.ai",
		api_key_env = "FRIENDLI_TOKEN",
	},
	parasail = {
		host = "api.parasail.io",
		api_key_env = "PARASAIL_API_KEY",
	},
	mancer = {
		host = "neuro.mancer.tech",
		api_key_env = "MANCER_API_KEY",
	},
	infermatic = {
		host = "api.infermatic.ai",
		api_key_env = "INFERMATIC_API_KEY",
	},
	venice = {
		host = "api.venice.ai",
		chat_path = "/api/v1/chat/completions",
		api_key_env = "VENICE_API_KEY",
	},
	-- ── Tier 4: regional / niche ────────────────────────────────────────────
	moonshot = {
		host = "api.moonshot.cn",
		api_key_env = "MOONSHOT_API_KEY",
	},
	yi = {
		host = "api.lingyiwanwu.com",
		api_key_env = "YI_API_KEY",
	},
	ai21 = {
		host = "api.ai21.com",
		chat_path = "/studio/v1/chat/completions",
		api_key_env = "AI21_API_KEY",
	},
	alibaba = {
		host = "dashscope-intl.aliyuncs.com",
		chat_path = "/compatible-mode/v1/chat/completions",
		embeddings_path = "/compatible-mode/v1/embeddings",
		api_key_env = "DASHSCOPE_API_KEY",
	},
	stepfun = {
		host = "api.stepfun.com",
		api_key_env = "STEPFUN_API_KEY",
	},
	minimax = {
		host = "api.minimaxi.chat",
		api_key_env = "MINIMAX_API_KEY",
	},
	cohere = {
		host = "api.cohere.ai",
		chat_path = "/compatibility/v1/chat/completions",
		embeddings_path = "/compatibility/v1/embeddings",
		api_key_env = "COHERE_API_KEY",
	},
	ovh = {
		host = "oai.endpoints.kepler.ai.cloud.ovh.net",
		api_key_env = "OVH_AI_API_KEY",
	},
}

return mod
