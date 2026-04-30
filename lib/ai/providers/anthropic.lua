if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local stream_mod = require("lib.http.stream")

local mod = {}

-- Type declarations (mirror lib/ai/types.lua; redeclared because the typechecker has no cross-module type import).
--:: ai_message = { role: "system" | "user" | "assistant" | "tool", content: string, tool_call_id?: string, name?: string }
--:: ai_tool = { name: string, description: string, parameters: { [string]: unknown } }
--:: ai_tool_call = { id: string, name: string, arguments: { [string]: unknown } }
--:: ai_http_client = { request: (req: unknown) -> (unknown, string | nil), stream: (req: unknown) -> ((() -> string | nil, string | nil) | nil, (() -> nil) | string | nil) }
--:: ai_request = { model: string, messages: ai_message[], max_tokens?: integer, temperature?: number, tools?: ai_tool[], stream?: boolean, http_client?: ai_http_client, api_key?: string }
--:: ai_response = { text: string | nil, tool_calls: ai_tool_call[] | nil, finish_reason: string, usage: { input_tokens: integer, output_tokens: integer } | nil }
--:: ai_delta = { text: string | nil, tool_call: ai_tool_call | nil, finish_reason: string | nil, usage: { input_tokens: integer, output_tokens: integer } | nil }

local API_URL = "api.anthropic.com"
local API_PATH = "/v1/messages"
local API_VERSION = "2023-06-01"

local function get_api_key(req)
	local key = req and req.api_key
	if not key then return nil, "api_key is required" end
	return key
end

--- Convert neutral ai_message list to Anthropic format.
-- Extracts system messages to top-level, maps the rest.
local function convert_messages(messages)
	local system_parts = {}
	local converted = {}
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
local function convert_tools(tools)
	if not tools or #tools == 0 then return nil end
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
local function parse_response(body)
	local data, err = json.decode(body)
	if not data then return nil, "json decode: " .. (err or "unknown") end

	if data.error then
		return nil, data.error.message or json.encode(data.error)
	end

	local text_parts = {}
	local tool_calls
	local content = data.content or {}
	for i = 1, #content do
		local block = content[i]
		if block.type == "text" then
			text_parts[#text_parts + 1] = block.text
		elseif block.type == "tool_use" then
			if not tool_calls then tool_calls = {} end
			tool_calls[#tool_calls + 1] = {
				id = block.id,
				name = block.name,
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

	local body_str = json.encode(body)

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local res, err = http_client.request({
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
	})
	if not res then return nil, err end
	if res.status ~= 200 then
		return nil, "HTTP " .. (res.status or "?") .. ": " .. (res.body or "")
	end

	return parse_response(res.body)
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

	local body_str = json.encode(body)

	local http_client = req.http_client
	if not http_client then return nil, "http_client is required" end

	local recv_fn, close_fn = http_client.stream({
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
	})
	if not recv_fn then return nil, close_fn end -- close_fn is err in failure case

	local s = stream_mod.new(recv_fn)
	local headers, err = s:read_headers()
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
				close_fn()
				return nil
			end

			local etype = event.event
			local data = event.data

			if etype == "message_stop" then
				done = true
				close_fn()
				return nil
			end

			if etype == "content_block_start" then
				local block = json.decode(data)
				if block and block.content_block and block.content_block.type == "tool_use" then
					cur_tool_id = block.content_block.id
					cur_tool_name = block.content_block.name
					cur_tool_json_parts = {}
				end
			elseif etype == "content_block_delta" then
				local delta = json.decode(data)
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
					local args = json.decode(args_str) or {}
					local tc = {
						tool_call = {
							id = cur_tool_id,
							name = cur_tool_name,
							arguments = args,
						},
					}
					cur_tool_id = nil
					cur_tool_name = nil
					cur_tool_json_parts = {}
					return tc
				end
			elseif etype == "message_delta" then
				local delta = json.decode(data)
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
