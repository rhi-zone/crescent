-- lib/api-tree/http_client_extension.lua — the HTTP client's extension
-- protocol, ported from fractal's
-- packages/http-api-projector/src/extension.ts.
--
-- ONE VALUE, TWO INTERPRETERS. A `ClientExtension` is a plain data record that
-- two entirely separate consumers read:
--
--   runtime — `M.compose_transport` wraps the transport FUNCTION, and
--             `M.compose_decode_response` offers each extension a chance to
--             own a response before the client's default decode runs.
--   codegen — `M.compose_codegen_transport` / `M.compose_codegen_result` /
--             `M.collect_result_helpers` / `M.find_streaming_call` wrap and
--             emit source TEXT.
--
-- That is the "extensible DU + interpreter" shape this port already uses for
-- routing and the type IR, applied to client middleware. Fractal's own
-- built-in extensions (retry, timeout, interceptors, pagination, streaming,
-- validation) are ordinary `ClientExtension` values — there is no privileged
-- internal API a user-authored extension cannot also use, and this port keeps
-- that property: nothing in `lib/api-tree/http_client.lua` reads an extension
-- through anything but the functions below.
--
-- WHY A WRAPPER, NOT A HOOK ENUM. The TypeScript module doc argues this at
-- length and the reasoning carries over unchanged: fixed
-- `before_request`/`after_response` slots cannot express retry, which must
-- re-run the ENTIRE inner call an arbitrary number of times rather than
-- observe around one. An interceptor is the degenerate wrapper that calls
-- `inner` exactly once, so the wrapper shape subsumes the hook shape while the
-- reverse is false.
--
-- COMPOSITION ORDER. `extensions[1]` is the OUTERMOST wrapper. Reading
-- `{ retry(), interceptors() }` top-to-bottom names outer-to-inner — retry
-- sees the interceptors' effects on every attempt — which is both the reading
-- order a caller expects and the direction the server-side layer stack wraps
-- in. Implemented as a reverse-order fold, the direct translation of the TS
-- `reduceRight`.
--
-- ── DELIBERATE DIVERGENCES FROM THE TYPESCRIPT ───────────────────────────
--
-- `fetch` IS CALLED `transport` THROUGHOUT. The TS names the wrapped function
-- `FetchImpl` because it is literally a WHATWG `fetch`, defaulting to the
-- ambient global. Crescent has no ambient fetch and this port forbids a
-- default (see `http_client.lua`'s caps rule), so the name would describe a
-- thing that does not exist here. `TransportFn` names what it actually is: an
-- injected capability taking a request value and returning a response value,
-- or a promise of one. `wrapFetch` is therefore `wrap_transport`, and
-- `composeFetch`/`composeCodegenFetch` are
-- `compose_transport`/`compose_codegen_transport`.
--
-- REQUEST AND RESPONSE ARE `unknown` AT THIS BOUNDARY. `TransportFn` is
-- `(req: unknown) -> unknown` rather than a structural mirror of
-- `http_value.lua`'s `HttpRequestValue`/`HttpResponseValue`. Cross-module
-- named types are not yet supported by the checker, and this module — which
-- never reads a single field of either value, only passes them through — has
-- nothing to gain from re-declaring both records field-for-field and
-- everything to lose if the two copies drift. `http_adapter.lua`'s `FetchFn`
-- makes exactly the same call for exactly the same reason. The consumer that
-- DOES read fields (`http_client.lua`) declares its own structural view and
-- narrows there.
--
-- `composeCodegenFetch` RETURNS TWO VALUES, not a record. The TS returns
-- `{ expr, helpers }` because JS has no multiple return; Lua does, and
-- `(string, string[])` is what the rest of this repo returns for a
-- primary-value-plus-secondary pair.
--
-- HELPER DEDUPLICATION ORDER IS PRESERVED EXACTLY. The TS accumulates helper
-- blocks into a `Set` from inside `reduceRight`, so the emitted order is
-- INNERMOST-first (reverse of the extensions array), not listed order. That is
-- observable in generated source, so this port folds in the same direction
-- rather than "fixing" it to listed order — a byte-for-byte difference in
-- codegen output is a behavior change, not a cleanup.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────

-- The injected capability the whole client is built on: takes a request value
-- (`http_value.lua`'s `HttpRequestValue`) and returns a response value
-- (`HttpResponseValue`), or a promise of one. The async-optional return is the
-- same shape `direct.lua` established for leaf callables, so an in-process
-- transport needs no event loop at all.
--:: TransportFn = (req: unknown) -> unknown

-- What `decode_response` receives alongside the response.
--
--   request      — the request value that produced this response.
--   refetch      — the SAME composed transport the client called, so an
--                  extension whose decoded value needs further round-trips
--                  (pagination's auto-advance) issues them through the full
--                  wrapper chain rather than around it.
--   meta         — the leaf's own resolved meta bag, as accumulated by `op`.
--   codegen_name — the `SchemaMap` key for this operation, when the client was
--                  built with enough information to recover it (see
--                  `http_client.lua`'s name maps). Nil otherwise.
-- `codegen_name` is `string | nil` rather than an optional field: the client
-- always fills it in, with nil when it has no authored tree to derive one
-- from, so a required-but-nilable field is what is actually being passed.
--:: DecodeContext = { request: unknown, refetch: TransportFn, meta: { [string]: unknown }, codegen_name: string | nil }

-- A decoder's result. A record rather than a bare value because nil is itself
-- a legitimate decoded value (an SSE `event: done` frame with no payload), and
-- nil is also the "declined, try the next extension" signal — the same
-- collision `stream.lua` avoids by tagging its steps.
--:: DecodedResponse = { value: unknown }

-- Per-operation facts codegen has already resolved by the time result-shaping
-- runs. `response_schema` is `unknown` rather than a named JSON Schema type
-- for the cross-module reason in the module doc.
--:: CodegenOperationInfo = { codegen_name: string, response_schema?: unknown }

-- The hook that emits one streaming operation's whole call expression. Named
-- rather than written inline at its two use sites because a bare function type
-- in a UNION RETURN position (`-> ((args) -> string) | nil`) is rejected by the
-- checker's annotation grammar even fully parenthesized; an alias sidesteps the
-- parse entirely and reads better at both sites regardless.
--:: StreamingCallFn = (args: StreamingCallArgs) -> string

-- Everything one streaming operation's emitted call expression needs. All
-- fields are SOURCE TEXT, not live values — codegen has no live values.
-- `path_literal` is the interpolation body only, with no surrounding quoting,
-- exactly as the TS passes a template-literal body without its backticks.
--:: StreamingCallArgs = { base_url_expr: string, transport_expr: string, headers_expr: string, method: string, path_literal: string, input_expr: string, base_timeout_expr: string, base_cancel_expr: string, call_opts_expr: string }

-- The codegen-side interpreter contribution.
--
--   wrap           — wraps the source EXPRESSION evaluating to the current
--                    transport, the text analogue of `wrap_transport`.
--   helpers        — top-level declarations either hook depends on, emitted
--                    once per distinct block (deduplicated by exact content).
--   streaming_call — replaces an entire operation body for a streaming
--                    operation. A SEPARATE axis from `wrap`: a streaming call
--                    returns a stream synchronously rather than a promise of
--                    one more request, so it cannot be expressed as a wrapper
--                    around the ordinary request expression.
--   wrap_result    — wraps ONE operation's result expression, the per-
--                    operation analogue of `wrap`.
--   result_helpers — declarations that need the FULL operation list up front
--                    (one schema constant per operation, say), which neither
--                    `helpers` (no operation knowledge) nor `wrap_result` (one
--                    at a time) can emit.
--:: ClientExtensionCodegen = { wrap?: (inner_expr: string) -> string, helpers?: string, streaming_call?: StreamingCallFn, wrap_result?: (inner_expr: string, codegen_name: string) -> string, result_helpers?: (operations: { [integer]: CodegenOperationInfo }) -> (string | nil) }

-- An extension. Every hook but `name` is optional: an extension that only
-- makes sense at runtime omits `codegen` and the codegen interpreter skips it
-- silently, exactly as an interpreter ignores a DU variant it does not
-- recognize.
--
-- `decode_response` returns `{ value = ... }` to fully own decoding this
-- response — which skips BOTH the client's default body decode AND its
-- non-2xx error check, deliberately: an SSE stream is `200 OK` at the HTTP
-- layer and reports failure through the stream itself, so a decoder that
-- claims the response owns its error reporting too. Returning nil declines and
-- falls through to the next extension, then to the client's default.
--:: ClientExtension = { name: string, wrap_transport?: (inner: TransportFn) -> TransportFn, decode_response?: (res: unknown, ctx: DecodeContext) -> (DecodedResponse | nil), codegen?: ClientExtensionCodegen }

-- ── Runtime interpreter ──────────────────────────────────────────────────

-- Compose every extension's `wrap_transport` around `transport`,
-- outermost-first. Extensions without the hook are skipped. Returns
-- `transport` itself when there is nothing to wrap, so an extension-free
-- client pays no wrapper overhead at all.
--: (transport: TransportFn, extensions: { [integer]: ClientExtension } | nil) -> TransportFn
function M.compose_transport(transport, extensions)
	if extensions == nil then return transport end
	local out = transport
	for i = #extensions, 1, -1 do
		local wrap = extensions[i].wrap_transport
		if wrap ~= nil then
			out = wrap(out)
		end
	end
	return out
end

-- Offer `res` to each extension's `decode_response` in listed order, returning
-- the first `{ value = ... }` result. Nil when none claims it, which is the
-- client's signal to run its own default decode.
--: (res: unknown, ctx: DecodeContext, extensions: { [integer]: ClientExtension } | nil) -> DecodedResponse | nil
function M.compose_decode_response(res, ctx, extensions)
	if extensions == nil then return nil end
	for i = 1, #extensions do
		local decode = extensions[i].decode_response
		if decode ~= nil then
			local decoded = decode(res, ctx)
			if decoded ~= nil then return decoded end
		end
	end
	return nil
end

-- ── Codegen interpreter ──────────────────────────────────────────────────

-- The first extension contributing a `streaming_call`, or nil. Codegen needs
-- only one: emitting a streaming operation is a single static decision per
-- operation, not a composable wrapper chain like `wrap` or `decode_response`.
-- Nil tells codegen to emit even an `x-stream`-tagged operation as an ordinary
-- request call.
--: (extensions: { [integer]: ClientExtension } | nil) -> (StreamingCallFn | nil)
function M.find_streaming_call(extensions)
	if extensions == nil then return nil end
	for i = 1, #extensions do
		local codegen = extensions[i].codegen
		if codegen ~= nil then
			local call = codegen.streaming_call
			if call ~= nil then return call end
		end
	end
	return nil
end

-- Compose every extension's `codegen.wrap` around a base source expression,
-- outermost-first, and collect the helper blocks the wrappers depend on.
--
-- Returns the wrapped expression and the deduplicated helper blocks. Helper
-- order is innermost-first, matching the fold direction — see the module doc
-- on why that is preserved rather than normalized.
--: (inner_expr: string, extensions: { [integer]: ClientExtension } | nil) -> (string, { [integer]: string })
function M.compose_codegen_transport(inner_expr, extensions)
	if extensions == nil then return inner_expr, {} end
	local expr = inner_expr
	--: { [string]: boolean }
	local seen = {}
	--: { [integer]: string }
	local helpers = {}
	for i = #extensions, 1, -1 do
		local codegen = extensions[i].codegen
		if codegen ~= nil then
			local block = codegen.helpers
			if block ~= nil and not seen[block] then
				seen[block] = true
				helpers[#helpers + 1] = block
			end
			local wrap = codegen.wrap
			if wrap ~= nil then
				expr = wrap(expr)
			end
		end
	end
	return expr, helpers
end

-- Compose every extension's `codegen.wrap_result` around ONE operation's
-- result expression, outermost-first — the same direction as
-- `compose_codegen_transport`, one operation at a time.
--: (inner_expr: string, codegen_name: string, extensions: { [integer]: ClientExtension } | nil) -> string
function M.compose_codegen_result(inner_expr, codegen_name, extensions)
	if extensions == nil then return inner_expr end
	local expr = inner_expr
	for i = #extensions, 1, -1 do
		local codegen = extensions[i].codegen
		if codegen ~= nil then
			local wrap_result = codegen.wrap_result
			if wrap_result ~= nil then
				expr = wrap_result(expr, codegen_name)
			end
		end
	end
	return expr
end

-- Collect every extension's `result_helpers` output, given the full operation
-- list, in listed (not folded) order — matching the TS, which iterates forward
-- here even though the two `wrap` composers fold backward. Empty when no
-- extension contributes any.
--: (operations: { [integer]: CodegenOperationInfo }, extensions: { [integer]: ClientExtension } | nil) -> { [integer]: string }
function M.collect_result_helpers(operations, extensions)
	--: { [integer]: string }
	local out = {}
	if extensions == nil then return out end
	for i = 1, #extensions do
		local codegen = extensions[i].codegen
		if codegen ~= nil then
			local emit = codegen.result_helpers
			if emit ~= nil then
				local helper = emit(operations)
				if helper ~= nil then out[#out + 1] = helper end
			end
		end
	end
	return out
end

return M
