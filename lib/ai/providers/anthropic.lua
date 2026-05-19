if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local stream_mod = require("lib.http.stream")

local mod = {}

--:: require "lib.ai.types"
--:: anthropic_response = { error?: { message?: string }, content?: { type: string, text?: string, id?: string, name?: string, input?: { [string]: unknown } }[], stop_reason?: string, usage?: { input_tokens: integer, output_tokens: integer } }
--:: anthropic_stream_block = { content_block?: { type: string, id?: string, name?: string } }
--:: anthropic_stream_delta = { delta?: { type: string, text?: string, partial_json?: string, stop_reason?: string }, usage?: { input_tokens: integer, output_tokens: integer } }

local API_URL = "api.anthropic.com"
local API_PATH = "/v1/messages"
local API_VERSION = "2023-06-01"

--: (req: ai_request) -> (string | nil, string | nil)
local function get_api_key(req)
	local key = req and req.api_key
	if not key then return nil, "api_key is required" end
	return key
end

--- Convert neutral ai_message list to Anthropic format.
-- Extracts system messages to top-level, maps the rest.
--: (messages: ai_message[]) -> (unknown[], string | nil)
local function convert_messages(messages)
	local system_parts = {}
	local converted = {} --: unknown[]
	for i = 1, #messages do
		local msg = messages[i]
		if msg.role == "system" then
			system_parts[#system_parts + 1] = msg.content
		elseif msg.role == "tool" then
			converted[#converted + 1] = {
				role = "user",
				content = { {
					type = "tool_result",
					tool_use_id = msg.tool_call_id,
					content = msg.content,
				} },
			}
		else
			converted[#converted + 1] = {
				role = msg.role,
				content = msg.content,
			}
		end
	end
	local system = #system_parts > 0 and table.concat(system_parts, "\n") or nil
	return converted, system
end

--- Convert neutral ai_tool list to Anthropic format.
--: (tools: ai_tool[] | nil) -> unknown[] | nil
local function convert_tools(tools)
	if not tools then return nil end
	if #tools == 0 then return nil end
	local result = {}
	for i = 1, #tools do
		local t = tools[i]
		result[i] = {
			name = t.name,
			description = t.description,
			input_schema = t.parameters,
		}
	end
	return result
end

--- Parse Anthropic response into neutral ai_response.
--: (body: string) -> (ai_response | nil, string | nil)
local function parse_response(body)
	local raw, err = json.decode(body)
	if not raw then return nil, "json decode: " .. (err or "unknown") end
	local data = raw --[[:! anthropic_response]]

	if data.error then
		local encoded_err --: string | nil
		encoded_err, _ = json.encode(data.error)
		return nil, data.error.message or encoded_err or "anthropic error"
	end

	local text_parts = {}
	local tool_calls --: ai_tool_call[] | nil
	local content = data.content or {}
	for i = 1, #content do
		local block = content[i]
		if block.type == "text" then
			text_parts[#text_parts + 1] = block.text
		elseif block.type == "tool_use" then
			if not tool_calls then tool_calls = {} end
			tool_calls[#tool_calls + 1] = {
				id = block.id or "",
				name = block.name or "",
				arguments = block.input or {},
			}
		end
	end

	return {
		text = #text_parts > 0 and table.concat(text_parts) or nil,
		tool_calls = tool_calls,
		finish_reason = data.stop_reason or "unknown",
		usage = data.usage and {
			input_tokens = data.usage.input_tokens,
			output_tokens = data.usage.output_tokens,
		} or nil,
	}
end

--: (ai_request) -> (ai_response | nil, string | nil)
mod.generate = function(req)
	local api_key = get_api_key(req)
	if not api_key then return nil, "ANTHROPIC_API_KEY not set" end

	local messages, system = convert_messages(req.messages)
	local body = {
		model = req.model,
		messages = messages,
		max_tokens = req.max_tokens or 1024,
	}
	if system then body.system = system end
	if req.temperature then body.temperature = req.temperature end
	local tools = convert_tools(req.tools)
	if tools then body.tools = tools end

	local body_str_raw, body_err = json.encode(body)
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local req_obj = {
		host = API_URL,
		method = "POST",
		path = API_PATH,
		headers = {
			["Content-Type"] = { "application/json" },
			["x-api-key"] = { api_key },
			["anthropic-version"] = { API_VERSION },
			["Content-Length"] = { tostring(#body_str) },
		},
		body = body_str,
	}
	local res, err = http_client.request(req_obj)
	if not res then return nil, err end
	if res.status ~= 200 then
		return nil, "HTTP " .. tostring(res.status or "?") .. ": " .. (res.body or "")
	else
		return parse_response(res.body or "")
	end
end

--: (ai_request) -> ((() -> ai_delta | nil) | nil, string | nil)
mod.stream = function(req)
	local api_key = get_api_key(req)
	if not api_key then return nil, "ANTHROPIC_API_KEY not set" end

	local messages, system = convert_messages(req.messages)
	local body = {
		model = req.model,
		messages = messages,
		max_tokens = req.max_tokens or 1024,
		stream = true,
	}
	if system then body.system = system end
	if req.temperature then body.temperature = req.temperature end
	local tools = convert_tools(req.tools)
	if tools then body.tools = tools end

	local body_str_raw, body_err = json.encode(body)
	if not body_str_raw then return nil, "json encode: " .. (body_err or "unknown") end
	local body_str = body_str_raw

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local stream_req = {
		host = API_URL,
		method = "POST",
		path = API_PATH,
		headers = {
			["Content-Type"] = { "application/json" },
			["x-api-key"] = { api_key },
			["anthropic-version"] = { API_VERSION },
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

	--:: http_stream_t = { read_headers: (self: unknown) -> (unknown, string | nil), status: (self: unknown) -> integer | nil, read_body: (self: unknown) -> (string | nil, string | nil), events: (self: unknown) -> () -> { event: string | nil, data: string, id: string | nil } | nil }
	local s = stream_mod.new(recv_fn) --[[:! http_stream_t]]
	local headers, err = s:read_headers()
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

	-- current tool call being accumulated
	local cur_tool_id
	local cur_tool_name
	local cur_tool_json_parts = {}

	return function()
		if done then return nil end
		while true do
			local event = events_iter()
			if not event then
				done = true
				close_cb()
				return nil
			end

			local etype = event.event
			local data = event.data

			if etype == "message_stop" then
				done = true
				close_cb()
				return nil
			end

			if etype == "content_block_start" then
				local block_raw = json.decode(data)
				local block = block_raw --[[:! anthropic_stream_block | nil]]
				if block and block.content_block and block.content_block.type == "tool_use" then
					cur_tool_id = block.content_block.id
					cur_tool_name = block.content_block.name
					cur_tool_json_parts = {}
				end
			elseif etype == "content_block_delta" then
				local delta_raw = json.decode(data)
				local delta = delta_raw --[[:! anthropic_stream_delta | nil]]
				if delta and delta.delta then
					if delta.delta.type == "text_delta" then
						return { text = delta.delta.text }
					elseif delta.delta.type == "input_json_delta" then
						cur_tool_json_parts[#cur_tool_json_parts + 1] = delta.delta.partial_json
					end
				end
			elseif etype == "content_block_stop" then
				if cur_tool_id then
					local args_str = table.concat(cur_tool_json_parts)
					local args_raw = json.decode(args_str)
					local args = args_raw --[[:! { [string]: unknown } | nil]] or {}
					local tc = {
						tool_call = {
							id = cur_tool_id or "",
							name = cur_tool_name or "",
							arguments = args,
						},
					}
					cur_tool_id = nil
					cur_tool_name = nil
					cur_tool_json_parts = {}
					return tc
				end
			elseif etype == "message_delta" then
				local delta_raw = json.decode(data)
				local delta = delta_raw --[[:! anthropic_stream_delta | nil]]
				if delta and delta.delta then
					return {
						finish_reason = delta.delta.stop_reason,
						usage = delta.usage and {
							input_tokens = delta.usage.input_tokens,
							output_tokens = delta.usage.output_tokens,
						} or nil,
					}
				end
			end
			-- skip ping, message_start, and other events
		end
	end
end

return mod
