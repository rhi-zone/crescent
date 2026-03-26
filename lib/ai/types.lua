--- AI library type annotations.
-- Neutral format — not OpenAI-shaped, not Anthropic-shaped.
-- Each provider maps independently to/from these types.

--:: ai_message = { role: "system" | "user" | "assistant" | "tool", content: string, tool_call_id?: string, name?: string }

--:: ai_tool = { name: string, description: string, parameters: table }

--:: ai_tool_call = { id: string, name: string, arguments: table }

--:: ai_request = {
--::   model: string,
--::   messages: ai_message[],
--::   max_tokens?: integer,
--::   temperature?: number,
--::   tools?: ai_tool[],
--::   stream?: boolean,
--::   provider?: ai_provider,
--:: }

--:: ai_response = {
--::   text: string?,
--::   tool_calls: ai_tool_call[]?,
--::   finish_reason: string,
--::   usage: { input_tokens: integer, output_tokens: integer }?,
--:: }

--:: ai_delta = {
--::   text: string?,
--::   tool_call: ai_tool_call?,
--::   finish_reason: string?,
--::   usage: { input_tokens: integer, output_tokens: integer }?,
--:: }

--:: ai_provider = {
--::   generate: (req: ai_request) -> ai_response?, string?,
--::   stream: (req: ai_request) -> (fun(): ai_delta?)?, string?,
--:: }

return {}
