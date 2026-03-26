if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")
local https = require("lib.https.client")
local stream_mod = require("lib.http.stream")

local mod = {}

local DEFAULT_URL = "api.openai.com"
local DEFAULT_PATH = "/v1/chat/completions"

local function get_config()
	local base_url = os.getenv("OPENAI_BASE_URL")
	local host, path
	if base_url then
		-- parse "https://host/path" or "host/path"
		local h, p = base_url:match("^https?://([^/]+)(.*)")
		if not h then h, p = base_url:match("^([^/]+)(.*)") end
		host = h or DEFAULT_URL
		path = (p and #p > 0) and p or DEFAULT_PATH
	else
		host = DEFAULT_URL
		path = DEFAULT_PATH
	end
	return host, path
end

local function get_api_key()
	return os.getenv("OPENAI_API_KEY")
end

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

--- Parse OpenAI response into neutral ai_response.
local function parse_response(body)
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

--[[@param req ai_request]]
--[[@return ai_response?, string?]]
mod.generate = function(req)
	local api_key = get_api_key()
	if not api_key then return nil, "OPENAI_API_KEY not set" end

	local host, path = get_config()
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

	local res, err = https.request({
		host = host,
		method = "POST",
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Authorization"] = { "Bearer " .. api_key },
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

--[[@param req ai_request]]
--[[@return fun(): ai_delta?, string?]]
mod.stream = function(req)
	local api_key = get_api_key()
	if not api_key then return nil, "OPENAI_API_KEY not set" end

	local host, path = get_config()
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
		path = path,
		headers = {
			["Content-Type"] = { "application/json" },
			["Authorization"] = { "Bearer " .. api_key },
			["Content-Length"] = { tostring(#body_str) },
		},
		body = body_str,
	})
	if not recv_fn then return nil, close_fn end

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

	-- accumulate tool call deltas by index
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

			-- text content
			if delta.content then
				return { text = delta.content }
			end

			-- tool call deltas
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

			-- finish reason
			if finish then
				-- flush accumulated tool calls
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

return mod
