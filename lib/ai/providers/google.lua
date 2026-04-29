--- Google Generative AI (Gemini) provider.
-- Uses the generateContent / embedContent API.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local stream_mod = require("lib.http.stream")

local mod = {}

local API_HOST = "generativelanguage.googleapis.com"

local function get_api_key(req)
	local key = req and req.api_key
	if not key then return nil, "api_key is required" end
	return key
end

--- Convert neutral messages to Google format.
-- Google uses { role: "user"|"model", parts: [{text: string}] }
-- System message goes into systemInstruction.
local function convert_messages(messages)
	local contents = {}
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
local function convert_tools(tools)
	if not tools or #tools == 0 then return nil end
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
local function parse_response(body)
	local data, err = json.decode(body)
	if not data then return nil, "json decode: " .. (err or "unknown") end

	if data.error then
		return nil, data.error.message or json.encode(data.error)
	end

	local candidates = data.candidates
	if not candidates or #candidates == 0 then return nil, "no candidates in response" end
	local candidate = candidates[1]
	local content = candidate.content or {}
	local parts = content.parts or {}

	local text_parts = {}
	local tool_calls
	for i = 1, #parts do
		local part = parts[i]
		if part.text then
			text_parts[#text_parts + 1] = part.text
		elseif part.functionCall then
			if not tool_calls then tool_calls = {} end
			tool_calls[#tool_calls + 1] = {
				id = part.functionCall.name, -- Google doesn't have separate IDs
				name = part.functionCall.name,
				arguments = part.functionCall.args or {},
			}
		end
	end

	local finish_map = {
		STOP = "stop", MAX_TOKENS = "length", SAFETY = "content_filter",
		RECITATION = "content_filter", OTHER = "stop",
	}

	return {
		text = #text_parts > 0 and table.concat(text_parts) or nil,
		tool_calls = tool_calls,
		finish_reason = finish_map[candidate.finishReason] or "unknown",
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

	local body_str = json.encode(body)
	local path = "/v1beta/models/" .. req.model .. ":generateContent?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local res
	res, err = http_client.request({
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
		body = body_str,
	})
	if not res then return nil, err end
	if res.status ~= 200 then
		return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
	end

	return parse_response(res.body)
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

	local body_str = json.encode(body)
	local path = "/v1beta/models/" .. req.model .. ":streamGenerateContent?key=" .. api_key .. "&alt=sse"

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local recv_fn, close_fn = http_client.stream({
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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

	return function()
		if done then return nil end
		while true do
			local event = events_iter()
			if not event then
				done = true
				close_fn()
				return nil
			end

			local chunk = json.decode(event.data)
			if not chunk then goto continue end

			local candidates = chunk.candidates
			if not candidates or #candidates == 0 then goto continue end
			local candidate = candidates[1]
			local content = candidate.content or {}
			local parts = content.parts or {}

			for i = 1, #parts do
				local part = parts[i]
				if part.text then
					return { text = part.text }
				elseif part.functionCall then
					return {
						tool_call = {
							id = part.functionCall.name,
							name = part.functionCall.name,
							arguments = part.functionCall.args or {},
						},
					}
				end
			end

			if candidate.finishReason then
				local finish_map = {
					STOP = "stop", MAX_TOKENS = "length", SAFETY = "content_filter",
				}
				return {
					finish_reason = finish_map[candidate.finishReason] or "unknown",
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

	local body_str = json.encode({
		model = "models/" .. req.model,
		content = { parts = { { text = req.value } } },
	})
	local path = "/v1beta/models/" .. req.model .. ":embedContent?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local res
	res, err = http_client.request({
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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

	local emb = data.embedding
	if not emb or not emb.values then return nil, "no embedding in response" end

	return { embedding = emb.values }
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

	local body_str = json.encode({ requests = requests })
	local path = "/v1beta/models/" .. req.model .. ":batchEmbedContents?key=" .. api_key

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local res
	res, err = http_client.request({
		host = API_HOST,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Content-Length"] = { tostring(#body_str) },
		},
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

	local items = data.embeddings
	if not items then return nil, "no embeddings in response" end

	local embeddings = {}
	for i = 1, #items do
		embeddings[i] = items[i].values
	end

	return { embeddings = embeddings }
end

return mod
