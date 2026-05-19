--- AI library type annotations.
-- Neutral format — not OpenAI-shaped, not Anthropic-shaped.
-- Each provider maps independently to/from these types.

-- ── Chat ────────────────────────────────────────────────────────────────────────

--:: ai_message = { role: "system" | "user" | "assistant" | "tool", content: string, tool_call_id?: string, name?: string }

--:: ai_tool = { name: string, description: string, parameters: { [string]: unknown } }

--:: ai_tool_call = { id: string, name: string, arguments: { [string]: unknown } }

--- HTTP response shape returned by ai_http_client.request — caller-injected,
-- matches the response shape produced by lib.https.client.
--:: ai_http_response = { status: integer | nil, body: string | nil, headers?: { [string]: { string } } }

--- HTTP client capability — caller-injected, matches lib.https.client shape.
--:: ai_http_client = {
--::   request: (req: unknown) -> (ai_http_response | nil, string | nil),
--::   stream: (req: unknown) -> ((() -> string | nil, string | nil) | nil, (() -> nil) | string | nil),
--:: }

--:: ai_request = {
--::   model: string,
--::   messages: ai_message[],
--::   max_tokens?: integer,
--::   temperature?: number,
--::   tools?: ai_tool[],
--::   stream?: boolean,
--::   provider?: ai_provider,
--::   http_client?: ai_http_client,
--::   api_key?: string,
--:: }

--:: ai_response = {
--::   text: string | nil,
--::   tool_calls: ai_tool_call[] | nil,
--::   finish_reason: string,
--::   usage: { input_tokens: integer, output_tokens: integer } | nil,
--:: }

--- Streamed partial response. Each delta typically carries one field at a time
-- (text chunk, tool call, finish reason, or usage), so fields are optional.
--:: ai_delta = {
--::   text?: string | nil,
--::   tool_call?: ai_tool_call | nil,
--::   finish_reason?: string | nil,
--::   usage?: { input_tokens: integer, output_tokens: integer } | nil,
--:: }

-- ── Embeddings ──────────────────────────────────────────────────────────────────

--:: ai_embed_request = { model: string, value: string, provider?: ai_provider, http_client?: ai_http_client, api_key?: string }

--:: ai_embed_many_request = { model: string, values: string[], provider?: ai_provider, http_client?: ai_http_client, api_key?: string }

--:: ai_embed_response = { embedding: number[], usage: { input_tokens: integer } | nil }

--:: ai_embed_many_response = { embeddings: number[][], usage: { input_tokens: integer } | nil }

-- ── Image generation ────────────────────────────────────────────────────────────

--:: ai_image_request = { model: string, prompt: string, n?: integer, size?: string, provider?: ai_provider, http_client?: ai_http_client, api_key?: string }

--:: ai_image = { url?: string, b64_json?: string }

--:: ai_image_response = { images: ai_image[] }

-- ── Provider ────────────────────────────────────────────────────────────────────

--:: ai_provider = {
--::   generate: (req: ai_request) -> (ai_response | nil, string | nil),
--::   stream: (req: ai_request) -> ((() -> ai_delta | nil) | nil, string | nil),
--::   embed?: (req: ai_embed_request) -> (ai_embed_response | nil, string | nil),
--::   embed_many?: (req: ai_embed_many_request) -> (ai_embed_many_response | nil, string | nil),
--::   generate_image?: (req: ai_image_request) -> (ai_image_response | nil, string | nil),
--:: }

return {}
