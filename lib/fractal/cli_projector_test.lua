-- lib/fractal/cli_projector_test.lua
-- Tests for lib/fractal/cli_projector.lua (the CLI projection of a Node tree).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local async   = require("lib.async")
local json    = require("lib.json")
local fractal = require("lib.fractal")
local result  = require("lib.fractal.result")
local stream  = require("lib.fractal.stream")
local cli     = require("lib.fractal.cli_projector")

--:: PromiseView = { _state: string, ... }

-- The projector's own argument types, re-declared structurally here — the
-- same thing every other file in this port does with the views it needs.
--:: Meta = { [string]: unknown }
--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: Meta }
--:: SchemaView = { type?: string, enum?: { [integer]: string }, items?: SchemaView, properties?: { [string]: SchemaView }, required?: { [integer]: string }, default?: unknown, description?: string }
--:: SchemaMap = { [string]: { inputSchema: SchemaView } }
--:: Store = { [string]: unknown }
--:: Stores = { [string]: Store }
--:: ErrorResponse = { exit_code: integer, message: string }
--:: ErrorEncoder = (error_value: unknown) -> (ErrorResponse | nil)
--:: HandlerFn = (input: unknown, stores: Stores) -> unknown
--:: Middleware = (next_fn: HandlerFn) -> HandlerFn
--:: Opts = { schemas?: SchemaMap, program_name?: string, version?: string, middleware?: { [integer]: Middleware }, detection?: { result?: boolean, streaming?: boolean }, error_encoder?: ErrorEncoder }
--:: Caps = { stdout_write: (s: string) -> nil, stderr_write: (s: string) -> nil, confirm: (prompt: string) -> unknown, env: { [string]: string } }

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
  if type(v) ~= "table" then return false end
  return v._state ~= nil
end

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

-- The captured effects of one `run_cli` call: everything written to each
-- stream, plus the promise's rejection reason (nil on success).
--:: Run = { out: string, err: string, reason: unknown }

-- Drive `run_cli` to completion against capture caps. Every tree in this file
-- is synchronous, so the promise settles without an event loop — the same
-- property direct_test.lua and stream_test.lua rely on.
--: (tree: NodeView, argv: { [integer]: string }, opts: Opts | nil, confirm_answer: boolean, env: { [string]: string } | nil) -> Run
local function run_with(tree, argv, opts, confirm_answer, env)
  local out = {} --: { [integer]: string }
  local err = {} --: { [integer]: string }

  --: (s: string) -> nil
  local function stdout_write(s) out[#out + 1] = s end
  --: (s: string) -> nil
  local function stderr_write(s) err[#err + 1] = s end
  --: (prompt: string) -> unknown
  local function confirm(_prompt) return confirm_answer end

  local caps = {
    stdout_write = stdout_write,
    stderr_write = stderr_write,
    confirm = confirm,
    env = env or {},
  }
  local p = cli.run_cli(tree, argv, caps, opts)
  if not is_promise(p) then error("run_with: run_cli did not return a promise") end
  local _, reason = async.run(p)
  return { out = table.concat(out), err = table.concat(err), reason = reason }
end

--: (tree: NodeView, argv: { [integer]: string }, opts: Opts | nil) -> Run
local function run(tree, argv, opts)
  return run_with(tree, argv, opts, true, nil)
end

--: (v: unknown, needle: string) -> boolean
local function contains(v, needle)
  if type(v) ~= "string" then return false end
  return v:find(needle, 1, true) ~= nil
end

-- The rejection reason's fields, read off the `cli_error` DU.
--: (reason: unknown) -> (string, number)
local function cli_error_parts(reason)
  if not as_record(reason) then error("expected a cli_error table") end
  local message = reason.message
  local exit_code = reason.exit_code
  if type(message) ~= "string" then error("cli_error has no message") end
  if type(exit_code) ~= "number" then error("cli_error has no exit_code") end
  return message, exit_code
end

-- Decode one JSON document written to stdout.
--: (text: string) -> unknown
local function decoded(text)
  local value = json.decode(text)
  return value
end

--: (text: string) -> { [integer]: string }
local function lines_of(text)
  local out = {} --: { [integer]: string }
  for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

-- ── Fixture tree ─────────────────────────────────────────────────────────
--
--   books list              readOnly, paginated leaf
--   books create            takes --title
--   books delete            destructive
--   books <bookId> read     fallback subtree with a nested leaf
--   ping                    aliased "p", deprecated
--   hidden                  meta.cli.hidden

--: (input: unknown) -> unknown
local function echo(input)
  return input
end

--: () -> NodeView
local function build_tree()
  return fractal.api({
    books = fractal.api({
      list = fractal.op(function(_) return { "a", "b" } end,
        { description = "List books", tags = { readOnly = true } }),
      create = fractal.op(echo, { description = "Create a book" }),
      delete = fractal.op(function(_) return { deleted = true } end,
        { tags = { destructive = true } }),
    }, {
      meta = { description = "Book commands" },
      fallback = {
        name = "bookId",
        subtree = fractal.api({
          read = fractal.op(echo, {}),
        }, {}),
      },
    }),
    ping = fractal.op(function(_) return "pong" end,
      { cli = { alias = "p" }, tags = { deprecated = true } }),
    hidden = fractal.op(function(_) return 1 end, { cli = { hidden = true } }),
  }, {})
end

T.describe("lib.fractal.cli_projector", function()

  -- NOT TESTED: `run_cli`'s missing-cap guard. It raises for a caller that
  -- reaches the function without the typechecker in the loop, and there is no
  -- way to express that call here — an incomplete caps table is rejected at
  -- check time in every formulation, including through `pcall`, and a force
  -- cast is refused outright. The guard is exercised by every other test in
  -- this file only on its passing path.

  T.describe("cli_error", function()

    T.it("carries a message and an exit code under a kind tag", function()
      local e = cli.cli_error("nope", 2)
      T.eq(e.kind, "cli_error")
      T.eq(e.message, "nope")
      T.eq(e.exit_code, 2)
    end)

    T.it("is_cli_error is exact on kind", function()
      T.eq(cli.is_cli_error(cli.cli_error("x", 1)), true)
      T.eq(cli.is_cli_error({ kind = "err", error = "x" }), false)
      T.eq(cli.is_cli_error("cli_error"), false)
      T.eq(cli.is_cli_error(nil), false)
    end)

  end)

  T.describe("dispatch", function()

    T.it("resolves a nested leaf and prints pretty JSON", function()
      local r = run(build_tree(), { "books", "create", "--title", "Dune" }, nil)
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.title, "Dune")
    end)

    T.it("resolves a leaf by its meta.cli alias", function()
      local r = run(build_tree(), { "p" }, nil)
      T.eq(r.reason, nil)
      T.eq(r.out, '"pong"\n')
    end)

    T.it("binds a fallback segment as a slug on the handler input", function()
      local r = run(build_tree(), { "books", "b1", "read" }, nil)
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.bookId, "b1")
    end)

    T.it("a static child wins over the fallback", function()
      local r = run(build_tree(), { "books", "list" }, nil)
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "a"), true)
    end)

    T.it("rejects an unknown command with a suggestion", function()
      local r = run(build_tree(), { "books", "creat" }, nil)
      local message, exit_code = cli_error_parts(r.reason)
      T.eq(contains(message, 'Unknown command: "books creat"'), true)
      T.eq(contains(message, "books create"), true)
      T.eq(exit_code, 1)
      T.eq(contains(r.err, "Run with --help"), true)
    end)

    T.it("rejects an empty argv", function()
      local r = run(build_tree(), {}, nil)
      local message, exit_code = cli_error_parts(r.reason)
      T.eq(message, "No subcommand provided")
      T.eq(exit_code, 1)
    end)

  end)

  T.describe("help", function()

    T.it("root help lists commands, groups and global flags", function()
      local r = run(build_tree(), { "--help" }, { program_name = "shelf" })
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "Usage: shelf <subcommand> [options]"), true)
      T.eq(contains(r.out, "ping (alias: p)"), true)
      T.eq(contains(r.out, "[DEPRECATED] ping"), true)
      T.eq(contains(r.out, "books"), true)
      T.eq(contains(r.out, "Global flags:"), true)
    end)

    T.it("omits a hidden node from help but still dispatches it", function()
      local r = run(build_tree(), { "--help" }, nil)
      T.eq(contains(r.out, "hidden"), false)
      local dispatched = run(build_tree(), { "hidden" }, nil)
      T.eq(dispatched.reason, nil)
      T.eq(dispatched.out, "1\n")
    end)

    T.it("group help walks to the branch", function()
      local r = run(build_tree(), { "books", "--help" }, { program_name = "shelf" })
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "Book commands"), true)
      T.eq(contains(r.out, "Usage: shelf books <subcommand> [options]"), true)
      T.eq(contains(r.out, "<bookId>  — parameterized group"), true)
    end)

    T.it("leaf help lists schema fields with type hints and requiredness", function()
      local schemas = {
        books_create = {
          inputSchema = {
            type = "object",
            properties = {
              title = { type = "string", description = "The title" },
              copies = { type = "integer" },
            },
            required = { "title" },
          },
        },
      }
      local r = run(build_tree(), { "books", "create", "--help" }, { schemas = schemas })
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "--title  <string>  The title (required)"), true)
      T.eq(contains(r.out, "--copies  <integer> (optional)"), true)
    end)

    T.it("leaf help announces the leaf's tags", function()
      local r = run(build_tree(), { "books", "delete", "--help" }, nil)
      T.eq(contains(r.out, "destructive and irreversible"), true)
      local read_only = run(build_tree(), { "books", "list", "--help" }, nil)
      T.eq(contains(read_only.out, "This operation is read-only."), true)
    end)

  end)

  T.describe("--version", function()

    T.it("prints the configured version", function()
      local r = run(build_tree(), { "--version" }, { version = "1.2.3" })
      T.eq(r.reason, nil)
      T.eq(r.out, "1.2.3\n")
    end)

    T.it("fails when no version is configured", function()
      local r = run(build_tree(), { "-V" }, nil)
      local message = cli_error_parts(r.reason)
      T.eq(message, "No version configured")
    end)

  end)

  T.describe("flag parsing", function()

    T.it("a valueless flag is true and a repeated flag collects", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local r = run(tree, { "echo", "--draft", "--tag", "a", "--tag", "b" }, nil)
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.draft, true)
      local tag_list = value.tag
      if not as_record(tag_list) then error("expected an array") end
      T.eq(tag_list[1], "a")
      T.eq(tag_list[2], "b")
    end)

    T.it("a slug wins over a same-named flag", function()
      local r = run(build_tree(), { "books", "b1", "read", "--bookId", "b2" }, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.bookId, "b1")
    end)

  end)

  T.describe("coercion against the input schema", function()

    --: (schema: SchemaView) -> SchemaMap
    local function schemas_for(schema)
      return { echo = { inputSchema = schema } }
    end

    T.it("coerces numbers, integers and booleans", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({
        type = "object",
        properties = {
          count = { type = "integer" },
          ratio = { type = "number" },
          draft = { type = "boolean" },
        },
      })
      local r = run(tree, { "echo", "--count", "3", "--ratio", "1.5", "--draft", "yes" }, { schemas = schemas })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.count, 3)
      T.eq(value.ratio, 1.5)
      T.eq(value.draft, true)
    end)

    T.it("rejects a non-integer for an integer field", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({ type = "object", properties = { count = { type = "integer" } } })
      local r = run(tree, { "echo", "--count", "1.5" }, { schemas = schemas })
      local message = cli_error_parts(r.reason)
      T.eq(contains(message, "expected an integer"), true)
    end)

    T.it("rejects an unparseable number", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({ type = "object", properties = { count = { type = "number" } } })
      local r = run(tree, { "echo", "--count", "many" }, { schemas = schemas })
      local message = cli_error_parts(r.reason)
      T.eq(contains(message, "expected a number"), true)
    end)

    T.it("validates an enum and suggests the closest member", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({
        type = "object",
        properties = { format = { enum = { "json", "yaml", "toml" } } },
      })
      local r = run(tree, { "echo", "--format", "yml" }, { schemas = schemas })
      local message = cli_error_parts(r.reason)
      T.eq(contains(message, 'invalid value "yml"'), true)
      T.eq(contains(message, 'Did you mean "yaml"?'), true)
    end)

    T.it("coerces each element of an array field", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({
        type = "object",
        properties = { ids = { type = "array", items = { type = "integer" } } },
      })
      local r = run(tree, { "echo", "--ids", "1", "--ids", "2" }, { schemas = schemas })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      local ids = value.ids
      if not as_record(ids) then error("expected an array") end
      T.eq(ids[1], 1)
      T.eq(ids[2], 2)
    end)

    T.it("a field the schema does not know about passes through", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = schemas_for({ type = "object", properties = { count = { type = "integer" } } })
      local r = run(tree, { "echo", "--note", "hi" }, { schemas = schemas })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.note, "hi")
    end)

  end)

  T.describe("defaults and required fields", function()

    T.it("fills a default for an absent field", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = { echo = { inputSchema = {
        type = "object",
        properties = { limit = { type = "integer", default = 10 } },
      } } }
      local r = run(tree, { "echo" }, { schemas = schemas })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.limit, 10)
    end)

    T.it("reports every missing required field at once", function()
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local schemas = { echo = { inputSchema = {
        type = "object",
        properties = { a = { type = "string" }, b = { type = "string" } },
        required = { "a", "b" },
      } } }
      local r = run(tree, { "echo" }, { schemas = schemas })
      local message = cli_error_parts(r.reason)
      T.eq(contains(message, "Missing required fields:"), true)
      T.eq(contains(message, "--a"), true)
      T.eq(contains(message, "--b"), true)
    end)

  end)

  T.describe("destructive confirmation", function()

    T.it("aborts when confirm declines", function()
      local r = run_with(build_tree(), { "books", "delete" }, nil, false, nil)
      local message, exit_code = cli_error_parts(r.reason)
      T.eq(message, "Aborted by user")
      T.eq(exit_code, 1)
      T.eq(contains(r.err, "Aborted."), true)
    end)

    T.it("proceeds when confirm accepts", function()
      local r = run_with(build_tree(), { "books", "delete" }, nil, true, nil)
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "deleted"), true)
    end)

    T.it("--yes skips the prompt", function()
      local r = run_with(build_tree(), { "books", "delete", "--yes" }, nil, false, nil)
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "deleted"), true)
    end)

  end)

  T.describe("Result unwrapping", function()

    T.it("unwraps an ok Result to its value", function()
      local tree = fractal.api({ get = fractal.op(function(_) return result.ok({ id = 1 }) end, {}) }, {})
      local r = run(tree, { "get" }, nil)
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.id, 1)
    end)

    T.it("an err Result becomes a cli_error with the default message", function()
      local tree = fractal.api({
        get = fractal.op(function(_) return result.err({ kind = "notFound" }) end, {}),
      }, {})
      local r = run(tree, { "get" }, nil)
      local message, exit_code = cli_error_parts(r.reason)
      T.eq(contains(message, "Error:"), true)
      T.eq(contains(message, "notFound"), true)
      T.eq(exit_code, 1)
    end)

    T.it("an error encoder overrides the exit code and message", function()
      local tree = fractal.api({
        get = fractal.op(function(_) return result.err({ kind = "notFound" }) end, {}),
      }, {})
      local encoder = cli.error_encoder_from_map({ notFound = { exit = 4, message = "not found" } })
      local r = run(tree, { "get" }, { error_encoder = encoder })
      local message, exit_code = cli_error_parts(r.reason)
      T.eq(message, "not found")
      T.eq(exit_code, 4)
      T.eq(r.err, "not found\n")
    end)

    T.it("an unmatched kind falls back to the default encoding", function()
      local tree = fractal.api({
        get = fractal.op(function(_) return result.err({ kind = "conflict" }) end, {}),
      }, {})
      local encoder = cli.error_encoder_from_map({ notFound = { exit = 4 } })
      local r = run(tree, { "get" }, { error_encoder = encoder })
      local _, exit_code = cli_error_parts(r.reason)
      T.eq(exit_code, 1)
    end)

    T.it("detection.result = false leaves the Result shape intact", function()
      local tree = fractal.api({ get = fractal.op(function(_) return result.ok(1) end, {}) }, {})
      local r = run(tree, { "get" }, { detection = { result = false } })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.kind, "ok")
    end)

  end)

  T.describe("thrown handler errors", function()

    T.it("are collapsed to an internal error, never surfaced verbatim", function()
      local tree = fractal.api({
        boom = fractal.op(function(_) error("secret path /etc/passwd") end, {}),
      }, {})
      local r = run(tree, { "boom" }, nil)
      local message = cli_error_parts(r.reason)
      T.eq(message, "internal error")
      T.eq(contains(r.err, "secret"), false)
      T.eq(r.err, "Error: internal error\n")
    end)

  end)

  T.describe("JSONL output", function()

    T.it("a streaming-tagged array prints one item per line", function()
      local tree = fractal.api({
        list = fractal.op(function(_) return { 1, 2, 3 } end, { tags = { streaming = true } }),
      }, {})
      local r = run(tree, { "list" }, nil)
      T.eq(r.reason, nil)
      T.eq(r.out, "1\n2\n3\n")
    end)

    T.it("--jsonl turns on the same output mode", function()
      local tree = fractal.api({ list = fractal.op(function(_) return { 1, 2 } end, {}) }, {})
      local r = run(tree, { "list", "--jsonl" }, nil)
      T.eq(r.out, "1\n2\n")
    end)

    T.it("nil prints as null", function()
      local tree = fractal.api({ nothing = fractal.op(function(_) return nil end, {}) }, {})
      local r = run(tree, { "nothing" }, nil)
      T.eq(r.reason, nil)
      T.eq(r.out, "null\n")
    end)

  end)

  T.describe("streamed handlers", function()

    T.it("drains a stream, routing chunks to stdout and progress to stderr", function()
      local tree = fractal.api({
        sync = fractal.op(function(_)
          return stream.from(function(emit)
            async.await(emit({ kind = "progress", progress = 1, total = 2, message = "half" }))
            async.await(emit({ kind = "chunk", data = "a" }))
            async.await(emit("b"))
            return "done"
          end)
        end, {}),
      }, {})
      local r = run(tree, { "sync" }, nil)
      T.eq(r.reason, nil)
      T.eq(r.out, '"a"\n"b"\n"done"\n')
      T.eq(r.err, "[progress] 50% half\n")
    end)

    T.it("detection.streaming = false leaves the stream undrained", function()
      -- With detection off the stream value falls through to the ordinary
      -- output path, where it is just a table carrying a `next` function.
      -- lib/json refuses to encode a function (JS's JSON.stringify drops it
      -- and prints `{}`), so the encode failure surfaces as a cli_error.
      local tree = fractal.api({
        sync = fractal.op(function(_)
          return stream.from(function(_emit) return "done" end)
        end, {}),
      }, {})
      local r = run(tree, { "sync" }, { detection = { streaming = false } })
      local message = cli_error_parts(r.reason)
      T.eq(contains(message, "could not encode the result as JSON"), true)
      T.eq(r.out, "")
    end)

  end)

  T.describe("pagination", function()

    --: () -> NodeView
    local function offset_tree()
      return fractal.api({
        list = fractal.op(function(input)
          if not as_record(input) then error("expected an input table") end
          local offset = input.offset or 0
          if type(offset) ~= "number" then error("offset must be a number") end
          if offset == 0 then
            return { items = { "a", "b" }, offset = 0, total = 3, hasMore = true }
          end
          return { items = { "c" }, offset = offset, total = 3, hasMore = false }
        end, {}),
      }, {})
    end

    T.it("hints at the next page on stderr without --all-pages", function()
      local r = run(offset_tree(), { "list" }, nil)
      T.eq(r.reason, nil)
      T.eq(contains(r.err, "# more results available — pass --offset 2"), true)
      T.eq(contains(r.out, "hasMore"), true)
    end)

    T.it("--all-pages walks every page as JSONL", function()
      local r = run(offset_tree(), { "list", "--all-pages" }, nil)
      T.eq(r.reason, nil)
      T.eq(r.out, '"a"\n"b"\n"c"\n')
    end)

    T.it("a cursor page hints with the cursor param", function()
      local tree = fractal.api({
        list = fractal.op(function(_)
          return { items = { "a" }, cursor = "next1", hasMore = true }
        end, {}),
      }, {})
      local r = run(tree, { "list" }, nil)
      T.eq(contains(r.err, "pass --cursor next1"), true)
    end)

  end)

  T.describe("input sources", function()

    T.it("meta.cli.sourceMap can pull a field from the env cap", function()
      local tree = fractal.api({
        whoami = fractal.op(echo, { cli = { sourceMap = { apiKey = { store = "env", key = "API_KEY" } } } }),
      }, {})
      local r = run_with(tree, { "whoami" }, nil, true, { API_KEY = "k1" })
      T.eq(r.reason, nil)
      local value = decoded(r.out)
      if not as_record(value) then error("expected an object") end
      T.eq(value.apiKey, "k1")
    end)

  end)

  T.describe("middleware", function()

    T.it("wraps the handler outermost-first and sees the stores", function()
      local trace = {} --: { [integer]: string }
      --: (next_fn: unknown) -> unknown
      local function outer(next_fn)
        if type(next_fn) ~= "function" then error("middleware: next is not callable") end
        return function(input, stores)
          trace[#trace + 1] = "outer"
          return next_fn(input, stores)
        end
      end
      --: (next_fn: unknown) -> unknown
      local function inner(next_fn)
        if type(next_fn) ~= "function" then error("middleware: next is not callable") end
        return function(input, stores)
          if not as_record(stores) then error("middleware: no stores") end
          trace[#trace + 1] = "inner"
          return next_fn(input, stores)
        end
      end
      local tree = fractal.api({ echo = fractal.op(echo, {}) }, {})
      local r = run(tree, { "echo", "--a", "1" }, { middleware = { outer, inner } })
      T.eq(r.reason, nil)
      T.eq(trace[1], "outer")
      T.eq(trace[2], "inner")
    end)

  end)

  T.describe("walk_commands", function()

    T.it("enumerates every reachable leaf, fallback subtrees included", function()
      local entries = cli.walk_commands(build_tree())
      local names = {} --: { [string]: boolean }
      for i = 1, #entries do
        names[table.concat(entries[i].path, " ") .. "/" .. entries[i].leaf_name] = true
      end
      T.eq(names["books/list"], true)
      T.eq(names["books/create"], true)
      T.eq(names["books/delete"], true)
      T.eq(names["books/read"], true)
      T.eq(names["/ping"], true)
    end)

    T.it("records the fallback name as an accumulated slug", function()
      local entries = cli.walk_commands(build_tree())
      local read_slugs = nil --: { [integer]: string } | nil
      for i = 1, #entries do
        if entries[i].leaf_name == "read" then read_slugs = entries[i].slugs end
      end
      if read_slugs == nil then error("no read entry") end
      T.eq(read_slugs[1], "bookId")
    end)

  end)

  T.describe("completions", function()

    T.it("is_shell_name accepts exactly the three supported shells", function()
      T.eq(cli.is_shell_name("bash"), true)
      T.eq(cli.is_shell_name("zsh"), true)
      T.eq(cli.is_shell_name("fish"), true)
      T.eq(cli.is_shell_name("nu"), false)
      T.eq(cli.is_shell_name(nil), false)
    end)

    T.it("the reserved completions command prints a bash script", function()
      local r = run(build_tree(), { "completions", "bash" }, { program_name = "shelf" })
      T.eq(r.reason, nil)
      T.eq(contains(r.out, "# bash completion for shelf"), true)
      T.eq(contains(r.out, "complete -F _shelf_completions shelf"), true)
      T.eq(contains(r.out, 'STATICS["__root__"]'), true)
      T.eq(contains(r.out, "books"), true)
    end)

    T.it("rejects a missing or unknown shell", function()
      local r = run(build_tree(), { "completions" }, nil)
      local message = cli_error_parts(r.reason)
      T.eq(message, "Unknown or missing shell for completions")
      T.eq(contains(r.err, "completions <bash|zsh|fish>"), true)
    end)

    T.it("zsh output loads bashcompinit and reuses the bash body", function()
      local r = run(build_tree(), { "completions", "zsh" }, { program_name = "shelf" })
      T.eq(contains(r.out, "#compdef shelf"), true)
      T.eq(contains(r.out, "autoload -U +X bashcompinit && bashcompinit"), true)
      T.eq(contains(r.out, "declare -A STATICS"), true)
    end)

    T.it("fish output skips fallback subtrees", function()
      local r = run(build_tree(), { "completions", "fish" }, { program_name = "shelf" })
      T.eq(contains(r.out, "complete -c shelf"), true)
      T.eq(contains(r.out, "__fish_seen_subcommand_from 'books'"), true)
      T.eq(contains(r.out, "*"), false)
    end)

    T.it("a hidden node is absent from every generated script", function()
      local r = run(build_tree(), { "completions", "bash" }, nil)
      T.eq(contains(r.out, "hidden"), false)
    end)

    T.it("enum values are emitted for a leaf's flag", function()
      local schemas = {
        books_create = { inputSchema = {
          type = "object",
          properties = { format = { enum = { "json", "yaml" } } },
        } },
      }
      local r = run(build_tree(), { "completions", "bash" }, { schemas = schemas })
      T.eq(contains(r.out, 'ENUMS["books create|--format"]="json yaml"'), true)
    end)

  end)

  T.describe("deterministic output", function()

    T.it("object keys are sorted, so output does not vary run to run", function()
      local tree = fractal.api({
        get = fractal.op(function(_) return { zeta = 1, alpha = 2, mid = 3 } end, {}),
      }, {})
      local first = run(tree, { "get", "--jsonl" }, nil)
      local second = run(tree, { "get", "--jsonl" }, nil)
      T.eq(first.out, second.out)
      T.eq(first.out, '{"alpha":2,"mid":3,"zeta":1}\n')
    end)

    T.it("help listings are sorted by command name", function()
      local r = run(build_tree(), { "books", "--help" }, nil)
      local listed = lines_of(r.out)
      local seen = {} --: { [integer]: string }
      for i = 1, #listed do
        local name = listed[i]:match("^  ([a-z]+)")
        if name ~= nil then seen[#seen + 1] = name end
      end
      T.eq(seen[1], "create")
      T.eq(seen[2], "delete")
      T.eq(seen[3], "list")
    end)

  end)

end)
