--- AI library type annotations.
-- Neutral format — not OpenAI-shaped, not Anthropic-shaped.
-- Each provider maps independently to/from these types.

-- ── Chat ────────────────────────────────────────────────────────────────────────

--:: ai_message = { role: "system" | "user" | "assistant" | "tool", content: string, tool_call_id?: string, name?: string }

--:: ai_tool = { name: string, description: string, parameters: { [string]: unknown } }

--:: ai_tool_call = { id: string, name: string, arguments: { [string]: unknown } }

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

-- ── Embeddings ──────────────────────────────────────────────────────────────────

--:: ai_embed_request = { model: string, value: string, provider?: ai_provider }

--:: ai_embed_many_request = { model: string, values: string[], provider?: ai_provider }

--:: ai_embed_response = { embedding: number[], usage: { input_tokens: integer }? }

--:: ai_embed_many_response = { embeddings: number[][], usage: { input_tokens: integer }? }

-- ── Image generation ────────────────────────────────────────────────────────────

--:: ai_image_request = { model: string, prompt: string, n?: integer, size?: string, provider?: ai_provider }

--:: ai_image = { url?: string, b64_json?: string }

--:: ai_image_response = { images: ai_image[] }

-- ── Provider ────────────────────────────────────────────────────────────────────

--:: ai_provider = {
--::   generate: (req: ai_request) -> (ai_response?, string?),
--::   stream: (req: ai_request) -> ((() -> ai_delta?)?, string?),
--::   embed?: (req: ai_embed_request) -> (ai_embed_response?, string?),
--::   embed_many?: (req: ai_embed_many_request) -> (ai_embed_many_response?, string?),
--::   generate_image?: (req: ai_image_request) -> (ai_image_response?, string?),
--:: }

return {}
