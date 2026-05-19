--- Google Generative AI (Gemini) provider.
-- Uses the generateContent / embedContent API.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local stream_mod = require("lib.http.stream")

local mod = {}

--:: require "lib.ai.types"
-- Local forks (intentionally differ from canonical):
--   ai_http_response: not in types.lua; provider accesses res.status/res.body directly.
--   ai_http_client: returns typed ai_http_response instead of unknown so res.status/res.body are visible without a cast.
--   ai_request / ai_embed_request / ai_embed_many_request: rebound so their http_client? field references the local ai_http_client above.
--   ai_delta: stream emits partial deltas (only one field at a time), so all fields are optional (?:) rather than T | nil.
--:: ai_http_response = { status: integer | nil, body: string | nil, headers?: { [string]: { string } } }
--:: ai_http_client = { request: (req: unknown) -> (ai_http_response | nil, string | nil), stream: (req: unknown) -> ((() -> string | nil, string | nil) | nil, (() -> nil) | string | nil) }
--:: ai_request = { model: string, messages: ai_message[], max_tokens?: integer, temperature?: number, tools?: ai_tool[], stream?: boolean, provider?: ai_provider, http_client?: ai_http_client, api_key?: string }
--:: ai_embed_request = { model: string, value: string, provider?: ai_provider, http_client?: ai_http_client, api_key?: string }
--:: ai_embed_many_request = { model: string, values: string[], provider?: ai_provider, http_client?: ai_http_client, api_key?: string }
--:: ai_delta = { text?: string | nil, tool_call?: ai_tool_call | nil, finish_reason?: string | nil, usage?: { input_tokens: integer, output_tokens: integer } | nil }
--:: google_part = { text?: string, functionCall?: { name?: string, args?: { [string]: unknown } } }
--:: google_candidate = { content?: { parts?: Arr<google_part> }, finishReason?: string }
--:: google_response = { error?: { message?: string }, candidates?: Arr<google_candidate>, usageMetadata?: { promptTokenCount: integer, candidatesTokenCount: integer } }
--:: google_embedding = { values: Arr<number> }
--:: google_embed_response = { error?: { message?: string }, embedding?: google_embedding }
--:: google_embed_many_response = { error?: { message?: string }, embeddings?: Arr<google_embedding> }
--:: http_stream_t = { read_headers: (self: unknown) -> (unknown, string | nil), status: (self: unknown) -> integer | nil, read_body: (self: unknown) -> (string | nil, string | nil), events: (self: unknown) -> () -> { event: string | nil, data: string, id: string | nil } | nil }

local API_HOST = "generativelanguage.googleapis.com"

--: (req: { api_key?: string, ... }) -> (string | nil, string | nil)
local function get_api_key(req)
	local key = req and req.api_key
	if not key then return nil, "api_key is required" end
	return key
end

--- Convert neutral messages to Google format.
-- Google uses { role: "user"|"model", parts: [{text: string}] }
-- System message goes into systemInstruction.
local function convert_messages(messages)
	local contents = {} --: unknown[]
	local system_parts = {}
	for i = 1, #messages do
		local msg = messages[i]
		if msg.role == "system" then
			system_parts[#system_parts + 1] = { text = msg.content }
		elseif msg.role == "tool" then
			contents[#contents + 1] = {
				role = "function",
				parts = { {
					functionResponse = {
						name = msg.name or "",
						response = { content = msg.content },
					},
				} },
			}
		else
			local role = msg.role == "assistant" and "model" or "user"
			contents[#contents + 1] = {
				role = role,
				parts = { { text = msg.content } },
			}
		end
	end
	local system_instruction = #system_parts > 0 and { parts = system_parts } or nil
	return contents, system_instruction
end

--- Convert neutral tools to Google format.
--: (ai_tool[] | nil) -> unknown
local function convert_tools(tools)
	if not tools then return nil end
	local n = #tools
	if n == 0 then return nil end
	local declarations = {}
	for i = 1, #tools do
		local t = tools[i]
		declarations[i] = {
			name = t.name,
			description = t.description,
			parameters = t.parameters,
		}
	end
	return { { functionDeclarations = declarations } }
end

--- Parse Google generateContent response.
--: (string) -> (ai_response | nil, string | nil)
local function parse_response(body)
	local raw, err = json.decode(body)
	if not raw then return nil, "json decode: " .. (err or "unknown") end
	local data = raw --[[:! google_response]]

	if data.error then
		local enc, _ = json.encode(data.error)
		return nil, data.error.message or enc or "google error"
	end

	local candidates_opt = data.candidates
	if not candidates_opt then return nil, "no candidates in response" end
	local candidates = candidates_opt --[[:! Arr<google_candidate>]]
	if #candidates == 0 then return nil, "no candidates in response" end
	local candidate = candidates[1]
	local content = candidate.content or {}
	local parts = content.parts or ({} --[[:! Arr<google_part>]])

	local text_parts = {}
	local tool_calls --: ai_tool_call[] | nil
	for i = 1, #parts do
		local part = parts[i]
		if part.text then
			text_parts[#text_parts + 1] = part.text
		elseif part.functionCall then
			if not tool_calls then tool_calls = {} end
			local fc = part.functionCall
			local fc_name = (fc and fc.name) or ""
			tool_calls[#tool_calls + 1] = {
				id = fc_name, -- Google doesn't have separate IDs
				name = fc_name,
				arguments = (fc and fc.args) or {},
			}
		end
	end

	local finish_map = {
		STOP = "stop", MAX_TOKENS = "length", SAFETY = "content_filter",
		RECITATION = "content_filter", OTHER = "stop",
	}

	local fr_key = candidate.finishReason or ""
	return {
		text = #text_parts > 0 and table.concat(text_parts) or nil,
		tool_calls = tool_calls,
		finish_reason = finish_map[fr_key] or "unknown",
		usage = data.usageMetadata and {
			input_tokens = data.usageMetadata.promptTokenCount,
			output_tokens = data.usageMetadata.candidatesTokenCount,
		} or nil,
	}
end

--: (ai_request) -> (ai_response | nil, string | nil)
mod.generate = function(req)
	local api_key, err = get_api_key(req)
	if not api_key then return nil, err end

	local contents, system_instruction = convert_messages(req.messages)
	local body = { contents = contents }
	if system_instruction then body.systemInstruction = system_instruction end
	local tools = convert_tools(req.tools)
	if tools then body.tools = tools end
	if req.max_tokens then
		body.generationConfig = body.generationConfig or {}
		body.generationConfig.maxOutputTokens = req.max_tokens
	end
	if req.temperature then
		body.generationConfig = body.generationConfig or {}
		body.generationConfig.temperature = req.temperature
	end

	local body_str_raw, body_err = json.encode(body)
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw
	local path = "/v1beta/models/" .. req.model .. ":generateContent?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local req_obj = {
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
		body = body_str,
	}
	local res
	res, err = http_client.request(req_obj)
	if not res then return nil, err end
	if res.status ~= 200 then
		return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
	else
		return parse_response(res.body or "")
	end
end

--: (ai_request) -> ((() -> ai_delta | nil) | nil, string | nil)
mod.stream = function(req)
	local api_key, err = get_api_key(req)
	if not api_key then return nil, err end

	local contents, system_instruction = convert_messages(req.messages)
	local body = { contents = contents }
	if system_instruction then body.systemInstruction = system_instruction end
	local tools = convert_tools(req.tools)
	if tools then body.tools = tools end
	if req.max_tokens then
		body.generationConfig = body.generationConfig or {}
		body.generationConfig.maxOutputTokens = req.max_tokens
	end
	if req.temperature then
		body.generationConfig = body.generationConfig or {}
		body.generationConfig.temperature = req.temperature
	end

	local body_str_raw, body_err = json.encode(body)
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw
	local path = "/v1beta/models/" .. req.model .. ":streamGenerateContent?key=" .. api_key .. "&alt=sse"

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local stream_req = {
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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

	return function()
		if done then return nil end
		while true do
			local event = events_iter()
			if not event then
				done = true
				close_cb()
				return nil
			end

			local chunk_raw = json.decode(event.data)
			if not chunk_raw then goto continue end
			local chunk = chunk_raw --[[:! google_response]]

			local candidates_opt = chunk.candidates
			if not candidates_opt then goto continue end
			local candidates = candidates_opt --[[:! Arr<google_candidate>]]
			if #candidates == 0 then goto continue end
			local candidate = candidates[1]
			local content = candidate.content or {}
			local parts = content.parts or ({} --[[:! Arr<google_part>]])

			for i = 1, #parts do
				local part = parts[i]
				if part.text then
					return { text = part.text }
				elseif part.functionCall then
					local fc = part.functionCall
					local fc_name = (fc and fc.name) or ""
					return {
						tool_call = {
							id = fc_name,
							name = fc_name,
							arguments = (fc and fc.args) or {},
						},
					}
				end
			end

			local fr = candidate.finishReason
			if fr then
				local finish_map = {
					STOP = "stop", MAX_TOKENS = "length", SAFETY = "content_filter",
				}
				return {
					finish_reason = finish_map[fr] or "unknown",
					usage = chunk.usageMetadata and {
						input_tokens = chunk.usageMetadata.promptTokenCount,
						output_tokens = chunk.usageMetadata.candidatesTokenCount,
					} or nil,
				}
			end

			::continue::
		end
	end
end

--- Embed a single value.
--: (ai_embed_request) -> (ai_embed_response | nil, string | nil)
mod.embed = function(req)
	local api_key, err = get_api_key(req)
	if not api_key then return nil, err end

	local body_str_raw, body_err = json.encode({
		model = "models/" .. req.model,
		content = { parts = { { text = req.value } } },
	})
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw
	local path = "/v1beta/models/" .. req.model .. ":embedContent?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local req_obj = {
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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
	local data = data_raw --[[:! google_embed_response]]
	if data.error then local enc, _ = json.encode(data.error); return nil, data.error.message or enc or "google error" end

	local emb = data.embedding
	if not emb then return nil, "no embedding in response" end
	local emb_values_opt = emb.values
	if not emb_values_opt then return nil, "no embedding in response" end
	local emb_values = emb_values_opt --[[:! Arr<number>]]

	return { embedding = emb_values, usage = nil }
	end
end

--- Embed multiple values.
--: (ai_embed_many_request) -> (ai_embed_many_response | nil, string | nil)
mod.embed_many = function(req)
	local api_key, err = get_api_key(req)
	if not api_key then return nil, err end

	local requests = {}
	for i = 1, #req.values do
		requests[i] = {
			model = "models/" .. req.model,
			content = { parts = { { text = req.values[i] } } },
		}
	end

	local body_str_raw, body_err = json.encode({ requests = requests })
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw
	local path = "/v1beta/models/" .. req.model .. ":batchEmbedContents?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local req_obj = {
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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
	local data = data_raw --[[:! google_embed_many_response]]
	if data.error then local enc, _ = json.encode(data.error); return nil, data.error.message or enc or "google error" end

	local items_opt = data.embeddings
	if not items_opt then return nil, "no embeddings in response" end
	local items = items_opt --[[:! Arr<google_embedding>]]

	local embeddings = {} --: number[][]
	for i = 1, #items do
		embeddings[i] = items[i].values
	end

	return { embeddings = embeddings, usage = nil }
	end
end

return mod
