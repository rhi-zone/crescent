# agent-impl.md

Implementation spec for the agent substrate.

Status: not implemented. Design thesis in `docs/agent-design.md` — read that first.

## Background

The design thesis: context is an atemporal **set of facts**, not a sequence of turns. Every
LLM call receives a freshly constructed set. Every LLM output contributes to the next call's
set via field operations (`note`, `drop`). Chronological accumulation of raw tool output is
the anti-pattern this design is built against — see `docs/agent-design.md` for the full
argument.

This doc specifies the three implementation pieces needed to make that thesis runnable:

1. `lib/agent/` — the context-set primitive, renderer, curated leaf executor, and preset registry.
2. `lib/platform/caps/exec.lua` — subprocess cap wrapping `lib/exec` with manifest whitelist.
3. `lib/platform/caps/llm.lua` — LLM generation cap with grammar-constrained structured output.

---

## Section 1: lib/agent/ substrate

### lib/agent/set.lua

The context set primitive. An immutable-style (returns new set on mutation) keyed store.

Public API:

```lua
--:: AgentSet = { [string]: unknown }

-- Create an empty set.
--: () -> AgentSet
M.new() -> {}

-- Return a new set with key=value added or replaced.
--: (AgentSet, string, unknown) -> AgentSet
M.note(s, key, value) -> new_set

-- Return a new set with key removed. No-op if key absent.
--: (AgentSet, string) -> AgentSet
M.drop(s, key) -> new_set

-- Get a value by key. Returns nil if absent.
--: (AgentSet, string) -> unknown
M.get(s, key) -> value

-- Merge two sets. s2 wins on key collision.
--: (AgentSet, AgentSet) -> AgentSet
M.merge(s1, s2) -> new_set
```

Implementation: plain table copy on each operation (sets are small; O(n) copy is fine).
No metatables on returned sets — they are plain Lua tables inspectable without any library.

The set is NOT a schema-enforced structure. The LLM writes whatever keys it finds useful.
Preset authors may document expected keys in the preset spec, but the set itself imposes no
schema. See `docs/agent-design.md`: "Notes exist for the unexpected: if the preset author
knew upfront what to record, it would be a task input."

**Reserved keys** (set by the executor, not by the LLM):

- `"_task_inputs"` — the original task inputs table, injected at executor start.
- `"_tool_result"` — the most recent tool call's output; cleared after the decision that
  consumes it. The LLM never sees a history of tool results, only the one most recent.
- `"_system"` — policy/instructions for the task. Set from the preset's `system` field.
  The LLM can read it (it appears in the render) but must not overwrite it via `note`.
  Executor enforces: if LLM emits `note("_system", ...)`, the note is silently dropped.

### lib/agent/render.lua

Pure function. Converts a set to a messages array suitable for LLM inference.

```lua
--:: RenderMessage = { role: string, content: string }

-- Render a set into a messages array for an LLM call.
-- task_inputs is the current task's inputs (injected into user turn).
--: (AgentSet, unknown) -> RenderMessage[]
M.render(set, task_inputs) -> messages
```

Rendering rules:

**System turn** (always first):

Content is the `_system` field from the set, if present. If absent, system turn is omitted.
Do not synthesize a system prompt — the preset supplies it explicitly or not at all.

**User turn** (always present):

Contains the task inputs, serialized to a human-readable string. Format: each field of
`task_inputs` on a separate line as `key: value`. Tables are JSON-encoded. Nil fields
omitted.

After task inputs, append any notes from the set (all keys except reserved `_`-prefixed
keys), formatted as:

```
notes:
- hypothesis: <value>
- findings: <value>
```

Notes are sorted alphabetically by key for determinism.

**Tool result turn** (present only when `_tool_result` is set):

A final user turn containing only the tool result:

```
tool result:
<_tool_result value>
```

This is the LAST user turn. The LLM decision that follows sees it as the most recent input.
After the LLM produces output, `_tool_result` is cleared from the set for the next render.

`render` is a pure function — same set always produces the same messages array. No I/O.
No side effects. The implementer can test it exhaustively with table-equality assertions.

### lib/agent/leaf.lua

The curated leaf executor. Drives the decision loop for a single task.

```lua
--:: LeafTaskDef = {
--::   type: string,
--::   inputs: unknown,
--::   max_iterations: integer | nil,
--:: }

--:: LeafCaps = {
--::   llm: LlmCap,
--::   exec: ExecCap | nil,
--:: }

-- Run a single leaf task. Returns task output or nil+errmsg.
--: (LeafTaskDef, AgentSet, LeafCaps, table) -> unknown, string | nil
M.run(task_def, initial_set, caps, preset_spec) -> result, errmsg
```

Loop:

1. `set = set.note(set, "_tool_result", nil)` if no tool result pending; else keep.
2. `messages = render.render(set, task_def.inputs)`.
3. `response, err = caps.llm.generate({ messages = messages, schema = preset_spec.output_schema })`.
4. If `err`, return `nil, err`.
5. Parse `response`:
   - `response.notes_add`: table of `{key, value}` pairs → apply `set.note` for each,
     skipping reserved `_`-prefixed keys.
   - `response.notes_drop`: list of keys → apply `set.drop` for each, skipping reserved keys.
   - `response.tool_call`: `{name, args}` → execute via `caps.exec`, store stdout in
     `_tool_result` via `set.note`.
   - `response.result`: if present and non-nil, return it as the task output. Loop exits.
6. Increment iteration counter. If `max_iterations` exceeded, return `nil, "max_iterations reached"`.
7. Goto 1.

**Structured output schema** (`preset_spec.output_schema`):

The LLM response is grammar-constrained. The schema passed to `caps.llm.generate` is:

```json
{
  "type": "object",
  "properties": {
    "notes_add":  { "type": "array",  "items": { "type": "object" } },
    "notes_drop": { "type": "array",  "items": { "type": "string" } },
    "tool_call":  { "type": "object", "nullable": true },
    "result":     {}
  }
}
```

The `result` field schema comes from `preset_spec.output_schema.result` if specified.
Presets may tighten it; the leaf does not enforce it beyond what the grammar constraint
already validates.

**Tool call execution**:

`caps.exec` is the exec cap (Section 2). Tool calls use binary name + args:

```lua
local out, err = caps.exec(response.tool_call.name, response.tool_call.args)
```

If `caps.exec` is nil (no exec cap), a `tool_call` in the response is an error:
return `nil, "tool_call in response but no exec cap provided"`.

**Error handling**: errors from `caps.llm` or `caps.exec` are propagated immediately —
no silent retry. Retry policy is a preset-level concern (wrap `leaf.run` in a retry task
via `lib/taskgraph`).

### lib/agent/preset.lua

Preset registry and runner.

```lua
--:: PresetSpec = {
--::   input_schema: unknown,
--::   output_schema: unknown,
--::   system: string | nil,
--::   max_iterations: integer | nil,
--::   executor_fn: (inputs: unknown, caps: LeafCaps) -> (unknown, string | nil),
--:: }

-- Register a named preset.
--: (string, PresetSpec) -> nil
M.register(name, spec)

-- Run a named preset with given inputs and caps.
-- Returns preset output or nil+errmsg.
--: (string, unknown, LeafCaps) -> unknown, string | nil
M.run(name, inputs, caps) -> result, errmsg
```

`preset.run` does:

1. Look up `spec = registry[name]`. Error if absent.
2. Build initial set: `set.note(set.new(), "_system", spec.system)` if system present.
3. Build task_def: `{ type = name, inputs = inputs, max_iterations = spec.max_iterations }`.
4. Delegate to `spec.executor_fn(inputs, caps)` if provided (preset can own its loop).
   Otherwise delegate to `leaf.run(task_def, set, caps, spec)`.
5. Return result.

Preset authors who need a multi-step graph (not just a single leaf) set `executor_fn` to
a function that calls `lib.taskgraph.run` internally. Presets without `executor_fn` default
to `leaf.run`. This keeps the registry interface uniform regardless of what runs underneath.

### Integration with lib/taskgraph

`lib/taskgraph` is the orchestration substrate (already implemented). Presets are registered
as taskgraph executors:

```lua
local taskgraph = require("lib.taskgraph")
local preset = require("lib.agent.preset")

-- Register a preset as a taskgraph executor so tasks can spawn it by name.
preset.register("code_review", spec)
taskgraph.register("code_review", function(task_def, ctx)
    return preset.run("code_review", task_def.inputs, ctx.caps)
end)
```

This is app-level wiring; `lib/agent/` itself does not import `lib/taskgraph`.

### Tests

Test file: `lib/agent/agent_test.lua` (or per-file: `set_test.lua`, `render_test.lua`,
`leaf_test.lua`).

Required coverage:

- `set`: new/note/drop/get/merge round-trips; reserved key drop enforcement; immutability
  (original set unchanged after note/drop).
- `render`: empty set → messages array with only user turn; set with system → system turn
  first; set with notes → notes in user turn alphabetically; set with `_tool_result` →
  final user turn with tool result.
- `leaf`: mock llm cap returning `{result = "done"}` → single iteration, correct output;
  mock returning `{notes_add = [{key="k", value="v"}], tool_call = {name="x", args={}}}` →
  note applied, tool called, `_tool_result` set; max_iterations exceeded → error.
- `preset`: register + run dispatches correctly; missing preset → error.

---

## Section 2: caps.exec

Platform cap wrapping `lib/exec` with a manifest-declared binary whitelist and optional
subcommand grant restrictions.

File: `lib/platform/caps/exec.lua`.

Follow the existing cap pattern in `lib/platform/caps/` — plain table, closures, revoke
flag, `(cap_table, revoke_fn)` return.

### Construction

```lua
--:: ExecManifestEntry = {
--::   binaries: { [string]: { schema: "auto" | HelpSchema | nil, allow: string[] | nil } },
--::   popen: POpenFn,
--::   stderr: string | nil,
--:: }

-- Construct the exec cap from a manifest entry.
-- For each binary with schema="auto": runs `binary --help`, parses via lib.exec.help,
-- caches the schema. Done at construction time, not per-call.
-- Returns cap table and revoke function.
--: (ExecManifestEntry) -> ExecCap, () -> nil
M.new(manifest_entry) -> cap, revoke_fn
```

**`schema = "auto"`**: at construction, calls `help.fetch(binary_name, { popen = manifest_entry.popen })`.
Parses and caches the `HelpSchema`. If `--help` fails or the binary is absent, the schema
is nil and the binary falls back to raw-arg mode (no validation).

**`schema = HelpSchema`**: caller provides a pre-built schema (for binaries with
non-standard or unparseable help output). Cached directly.

**`schema = nil`**: no schema; binary accepts raw arg lists only, no flag validation.

### Invocation

```lua
--:: ExecArgsTable = { [1]: string[], [string]: unknown }
--:: ExecCap = (binary_name: string, args: string[] | ExecArgsTable) -> string | nil, string | nil
```

`cap(binary_name, args)`:

1. Check revoked flag; return `nil, "capability revoked"` if set.
2. Validate `binary_name` against `manifest_entry.binaries` whitelist. Return
   `nil, "binary not in whitelist: " .. binary_name` if absent.
3. **Subcommand grant check** (if `manifest_entry.binaries[binary_name].allow` is set):
   Extract the subcommand path from the call (first element of args if it's a list, or
   `args[1]` if it's an args table). Check that it matches one of the allowed subcommand
   strings. If not, return `nil, "subcommand not allowed: " .. subpath`.
   `allow` entries are prefix matches: `"view"` allows `normalize view <anything>`.
4. **Args dispatch**:
   - If `args` is a plain list (`args[1]` is a string or args is `{}`): pass directly to
     `exec.run(binary_name, args, { popen = manifest_entry.popen, stderr = manifest_entry.stderr })`.
   - If `args` is an `ExecArgsTable` (has a schema): the `[1]` field is the subcommand path
     list; remaining string keys are flag fields. Expand flags using the cached schema's
     flag expansion logic (same rules as `lib/exec/make_api` flag expansion). Assemble
     final arg list and call `exec.run`.
5. Return stdout or `nil, errmsg`.

### Grant precision

`manifest_entry.binaries.normalize.allow = {"view", "grep"}` means:

- `cap("normalize", {"view", "/path"})` — allowed.
- `cap("normalize", {"grep", "/path", "--pattern", "foo"})` — allowed.
- `cap("normalize", {"edit", ...})` — denied: `"subcommand not allowed: edit"`.
- `cap("normalize", {})` — denied (no subcommand, not in allow list).
- `allow = nil` means all subcommands allowed.

Matching is on the first element of the path list (top-level subcommand name), not the
full path. Deeper nesting (`normalize foo bar`) checks only `"foo"`.

### Tests

Test file: `lib/platform/caps/exec_test.lua`.

Required coverage:

- Construction with `schema="auto"` and a mock popen that returns help text.
- Whitelist enforcement: unknown binary → error.
- Allow list enforcement: disallowed subcommand → error; allowed → succeeds.
- Revocation: after `revoke_fn()`, all calls return `nil, "capability revoked"`.
- Raw args passthrough: list args → forwarded verbatim to exec.run.
- Flag expansion: ExecArgsTable with known flags → correct CLI args assembled.

---

## Section 3: caps.llm

Platform cap for grammar-constrained LLM generation via a local llama.cpp instance (or
any OpenAI-compatible endpoint).

File: `lib/platform/caps/llm.lua`.

Uses `lib/ai/providers/openai_compat.lua` (already implemented). Wraps it with:
structured-output enforcement, schema validation, and the cap revoke pattern.

### Construction

```lua
--:: LlmManifestEntry = {
--::   endpoint: string | nil,
--::   model: string | nil,
--::   api_key: string | nil,
--::   http_client: HttpClientCap | nil,
--:: }

-- Construct the llm cap.
-- endpoint: base URL, default "http://127.0.0.1:8081"
-- model: model name string, default "local"
-- api_key: passed through to openai_compat; may be empty string for local servers
-- http_client: injected HTTP client cap (required for actual calls)
--: (LlmManifestEntry) -> LlmCap, () -> nil
M.new(manifest_entry) -> cap, revoke_fn
```

### Invocation

```lua
--:: LlmGenerateRequest = {
--::   messages: RenderMessage[],
--::   schema: unknown | nil,
--::   max_tokens: integer | nil,
--::   temperature: number | nil,
--:: }

--:: LlmCap = {
--::   generate: (LlmGenerateRequest) -> unknown | nil, string | nil,
--:: }
```

`cap.generate(req)`:

1. Check revoked flag; return `nil, "capability revoked"` if set.
2. Build `openai_compat` request:
   ```lua
   {
     messages    = req.messages,
     model       = manifest_entry.model or "local",
     api_key     = manifest_entry.api_key or "",
     max_tokens  = req.max_tokens,
     temperature = req.temperature,
     http_client = manifest_entry.http_client,
   }
   ```
3. If `req.schema` is provided, add `response_format`:
   ```lua
   body.response_format = {
     type        = "json_schema",
     json_schema = { schema = req.schema },
   }
   ```
   This is llama.cpp's grammar-constrained output format. The server enforces the schema
   at sampling time; the response will always be valid JSON matching the schema.
4. Call `provider.generate(request)`. The `provider` is built via `openai_compat.create`
   with `host` extracted from `manifest_entry.endpoint` (strip `http://` prefix for the
   openai_compat host field).
5. Parse the response: `response.text` is the JSON string. Decode via `lib.format.json`.
6. If `req.schema` provided: validate the decoded table against the schema (basic required-
   field check — not full JSON Schema validation). If validation fails, return
   `nil, "response failed schema validation: " .. details`.
7. Return decoded table on success, or `nil, errmsg` on any failure.

**Schema validation**: v1 validation is minimal — check that required fields declared in
the schema's `"required"` array are present in the decoded table. Full JSON Schema
validation (`lib/openapi/` already implements a JSON Schema subset) can be wired in as a
follow-on; don't block on it.

**Endpoint parsing**: `manifest_entry.endpoint` is a full URL like
`"http://127.0.0.1:8081"`. Extract host for `openai_compat.create`:
strip scheme (`http://` or `https://`), keep host+port. The `openai_compat` provider
`host` field is scheme-free (e.g. `"127.0.0.1:8081"`).

**No streaming in v1**: `cap.stream` is not required. `leaf.lua` uses only `cap.generate`.
Streaming can be added later without changing the leaf loop.

### Tests

Test file: `lib/platform/caps/llm_test.lua`.

Required coverage:

- Construction with a mock http_client.
- `cap.generate` without schema: messages forwarded, raw text returned (no JSON parse).
- `cap.generate` with schema: `response_format` added to request body; response parsed
  as JSON; decoded table returned.
- Schema validation failure: decoded table missing required field → `nil, errmsg`.
- HTTP error from mock client → `nil, errmsg` propagated.
- Revocation: `revoke_fn()` then `cap.generate(...)` → `nil, "capability revoked"`.

---

## Dependency graph

```
lib/agent/set.lua          — no deps
lib/agent/render.lua       — lib/agent/set
lib/agent/leaf.lua         — lib/agent/set, lib/agent/render, caps (injected)
lib/agent/preset.lua       — lib/agent/leaf (default executor)

lib/platform/caps/exec.lua — lib/exec (init, help), lib/format/json (for args table)
lib/platform/caps/llm.lua  — lib/ai/providers/openai_compat, lib/format/json
```

No circular deps. `lib/agent/` has zero platform dependencies — it is pure library code,
vendorable without the platform.
