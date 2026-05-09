-- lib/platform/caps/cap_types.lua
-- Type declarations for platform capability interfaces.
--
-- This file is declarations only (no runtime code). Load it as a typechecker
-- globals file (opts.globals_files) wherever cap interface types are needed.
--
-- Each cap interface type follows the naming convention `XxxCap`.

-- ── Shared ────────────────────────────────────────────────────────────────────

--:: HttpClientReq = { method: string, path: string, headers: { [string]: string } | nil, body: string | nil }
--:: HttpClientRes = { status: integer, headers: { [string]: string[] }, body: string | nil }
--:: HttpClientStreamRes = { status: integer, headers: { [string]: string[] } }

-- ── CliCap ────────────────────────────────────────────────────────────────────

--:: CliCap = {
--::   _type: "cli",
--::   args: () -> ({ [integer]: string } | nil, string | nil),
--:: }

-- ── TimeCap ───────────────────────────────────────────────────────────────────

--:: TimeCap = {
--::   _type: "time",
--::   now: () -> (integer | nil, string | nil),
--:: }

-- ── StdinCap ──────────────────────────────────────────────────────────────────

--:: StdinCap = {
--::   _type: "stdin",
--::   read: (n: integer | nil) -> (string | nil, string | nil),
--::   line: () -> (string | nil, string | nil),
--:: }

-- ── StdoutCap ─────────────────────────────────────────────────────────────────

--:: StdoutCap = {
--::   _type: "stdout",
--::   write: (str: string) -> (true | nil, string | nil),
--::   flush: () -> (true | nil, string | nil),
--:: }

-- ── StderrCap ─────────────────────────────────────────────────────────────────

--:: StderrCap = {
--::   _type: "stderr",
--::   write: (str: string) -> (true | nil, string | nil),
--::   flush: () -> (true | nil, string | nil),
--:: }

-- ── KvCap ─────────────────────────────────────────────────────────────────────

--:: KvCap = {
--::   _type: "kv",
--::   get: (key: string) -> (unknown | nil, string | nil),
--::   set: (key: string, value: unknown) -> (true | nil, string | nil),
--:: }

-- ── DbStmt ────────────────────────────────────────────────────────────────────

--:: DbStmt = {
--::   exec: (...unknown) -> (true | nil, string | nil),
--::   rows: (...unknown) -> unknown,
--::   close: () -> nil,
--:: }

-- ── DbCap ─────────────────────────────────────────────────────────────────────

--:: DbCap = {
--::   _type: "db",
--::   execute: (sql: string, ...unknown) -> (true | nil, string | nil),
--::   prepare: (sql: string) -> (DbStmt | nil, string | nil),
--::   query: (sql: string, ...unknown) -> unknown,
--::   last_insert_rowid: () -> (integer | nil, string | nil),
--::   changes: () -> (integer | nil, string | nil),
--::   close: () -> nil,
--::   attenuate: (sub_opts: { allow_write: boolean | nil } | nil) -> (DbCap | nil, (() -> nil) | string | nil),
--:: }

-- ── SharedDbCap ───────────────────────────────────────────────────────────────

--:: SharedDbCap = {
--::   _type: "shared_db",
--::   execute?: (sql: string) -> (true | nil, string | nil),
--::   query: (sql: string, params: unknown[] | nil) -> ({ [integer]: { [string]: unknown } }[] | nil, string | nil),
--::   close: () -> nil,
--::   attenuate: (sub_opts: { allow_write: boolean | nil } | nil) -> (SharedDbCap | nil, (() -> nil) | string | nil),
--:: }

-- ── FsCap ─────────────────────────────────────────────────────────────────────

--:: FsCap = {
--::   _type: "fs",
--::   read: (path: string) -> (string | nil, string | nil),
--::   write: (path: string, content: string) -> (true | nil, string | nil),
--::   list: (path: string | nil) -> (string[] | nil, string | nil),
--::   attenuate: (sub_opts: { root: string, allow_write: boolean | nil } | nil) -> (FsCap | nil, (() -> nil) | string | nil),
--:: }

-- ── RegistryCap ───────────────────────────────────────────────────────────────

--:: RegistryCap = {
--::   _type: "registry",
--::   get: (subkey: string | nil, name: string) -> (unknown | nil, string | nil),
--::   set: (subkey: string | nil, name: string, value: unknown, vtype: integer | nil) -> (true | nil, string | nil),
--::   list_keys: (subkey: string | nil) -> (string[] | nil, string | nil),
--::   list_values: (subkey: string | nil) -> ({ name: string, type: string }[] | nil, string | nil),
--::   attenuate: (sub_opts: { root: string, allow_write: boolean | nil } | nil) -> (RegistryCap | nil, (() -> nil) | string | nil),
--:: }

-- ── SelfCap ───────────────────────────────────────────────────────────────────

--:: SelfCap = {
--::   _type: "self",
--::   app_id: string | nil,
--::   metadata: (keyword: string) -> (string | nil, string | nil),
--::   entries: () -> (string[] | nil, string | nil),
--::   entry: (path: string) -> (string | nil, string | nil),
--::   read: () -> (string | nil, string | nil),
--:: }

-- ── SelfWriteCap ─────────────────────────────────────────────────────────────

--:: SelfWriteCap = {
--::   _type: "self_write",
--::   app_id: string | nil,
--::   metadata: (keyword: string) -> (string | nil, string | nil),
--::   entries: () -> (string[] | nil, string | nil),
--::   entry: (path: string) -> (string | nil, string | nil),
--::   read: () -> (string | nil, string | nil),
--::   write_metadata: (keyword: string, bytes: string) -> (true | nil, string | nil),
--:: }

-- ── HttpClientCap ─────────────────────────────────────────────────────────────

--:: HttpClientCap = {
--::   _type: "http_client",
--::   host: string,
--::   model: string | nil,
--::   path: string | nil,
--::   methods: string[] | nil,
--::   request: (req: HttpClientReq) -> (HttpClientRes | nil, string | nil),
--::   request_stream: (req: HttpClientReq, on_chunk: (string) -> nil) -> (HttpClientStreamRes | nil, string | nil),
--::   attenuate: (sub_opts: { paths: string[] | nil, methods: string[] | nil } | nil) -> (HttpClientCap | nil, (() -> nil) | string | nil),
--:: }

-- ── HttpReq ───────────────────────────────────────────────────────────────────
-- The request object passed to handlers by http_server cap.

--:: HttpReq = {
--::   method: string,
--::   path: string,
--::   query: string | nil,
--::   headers: { [string]: string[] } | nil,
--::   body: string | nil,
--::   last_event_id: string | nil,
--:: }

-- ── HttpRes ───────────────────────────────────────────────────────────────────
-- The response builder object passed to handlers by http_server cap.

--:: HttpRes = {
--::   status: integer,
--::   headers: { [string]: unknown },
--::   body: string | nil,
--::   send_event: (data: string, opts: { id?: unknown, event?: string } | nil) -> (true | nil, string | nil),
--::   close: () -> nil,
--:: }

-- ── HttpServerCap ─────────────────────────────────────────────────────────────

--:: HttpServerCap = {
--::   _type: "http_server",
--::   url: string,
--::   port: integer,
--::   serve: (handler: (req: HttpReq, res: HttpRes) -> nil) -> (true | nil, string | nil),
--:: }

-- ── LlmMessage ────────────────────────────────────────────────────────────────

--:: LlmMessage = { role: "user" | "assistant" | "system", content: string }

-- ── LlmCallOpts ──────────────────────────────────────────────────────────────

--:: LlmCallOpts = { model: string | nil, temperature: number | nil, max_tokens: integer | nil, top_p: number | nil, stop: unknown | nil }

-- ── LlmCap ───────────────────────────────────────────────────────────────────

--:: LlmCap = {
--::   _type: "llm",
--::   call: (messages: LlmMessage[], call_opts: LlmCallOpts | nil) -> (string | nil, string | nil),
--::   call_stream: (messages: LlmMessage[], on_token: (string) -> nil, call_opts: LlmCallOpts | nil) -> (string | nil, string | nil),
--::   count_tokens: (text: string) -> (integer | nil, string | nil),
--:: }

-- ── ShellLineIter ─────────────────────────────────────────────────────────────

--:: ShellLineIter = {
--::   close: (self: ShellLineIter) -> nil,
--:: }

-- ── ShellCap ─────────────────────────────────────────────────────────────────

--:: ShellCap = {
--::   _type: "shell",
--::   run: (cmd: string) -> (string | nil, string | nil),
--::   run_stream: (cmd: string) -> (ShellLineIter | nil, string | nil),
--::   attenuate: (sub_decl: { type: string | nil } | nil) -> (ShellCap | nil, (() -> nil) | string | nil),
--:: }

-- ── ExecCap ───────────────────────────────────────────────────────────────────

--:: ExecCap = {
--::   _type: "exec",
--::   exec: (binary_name: string, args: unknown) -> (string | nil, string | nil),
--::   attenuate: (sub_decl: unknown) -> (ExecCap | nil, (() -> nil) | string | nil),
--:: }

return {}
