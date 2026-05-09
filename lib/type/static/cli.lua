-- lib/type/static/cli.lua
-- CLI entry point for the typechecker.
-- Usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [--rules] [<file> ...]
-- If no files given, globs lib/ for *.lua (excluding *_test.lua and dep/).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── FFI for fork/pipe/waitpid ─────────────────────────────────────────────────

local fork_available = false
local ffi = require("ffi")
do
    local ffi_ok, ffi_mod = pcall(require, "ffi")
    if ffi_ok then
        ffi = ffi_mod
        pcall(function()
            ffi.cdef[[
                int fork(void);
                int getpid(void);
                int waitpid(int pid, int *status, int options);
                int pipe(int pipefd[2]);
                long read(int fd, void *buf, size_t count);
                long write(int fd, const void *buf, size_t count);
                int close(int fd);
                long sysconf(int name);
            ]]
        end)
        -- Access guarded: cdef may fail if already declared (safe — symbols still exist).
        local ok = pcall(function() return ffi.C.fork end)
        fork_available = ok
    end
end

local function get_cpu_count()
    if not fork_available then return 1 end
    local n = ffi.C.sysconf(84)  -- _SC_NPROCESSORS_ONLN = 84 on Linux
    if n <= 0 then return 1 end
    return tonumber(n) or 1
end

-- ── URL encoding (for pipe protocol) ─────────────────────────────────────────

--: (string) -> string
local function urlencode(s)
    --: (string) -> string
    local function repl(c)
        return ("%%%02X"):format(c:byte() or 0)
    end
    local out = s:gsub("([%c%s%%|])", repl)
    return out
end

--: (string) -> string
local function urldecode(s)
    --: (string) -> string
    local function repl(h)
        return string.char(tonumber(h, 16) or 0)
    end
    local out = s:gsub("%%(%x%x)", repl)
    return out
end

-- ── Pipe protocol ────────────────────────────────────────────────────────────
-- Newline-delimited lines written by each worker to its write-end pipe.
--
-- Error/warning line:
--   KIND|filename|line|col|msg[|NOTE filename|line|col|msg ...]
--   KIND = "E" (error) or "W" (warning)
--   filename and msg are URL-encoded.
--   Notes are appended as space-separated NOTE-prefixed fields (each url-encoded).
--
-- End-of-worker sentinel (last line from each worker):
--   DONE|<errors>|<warnings>

local function encode_note(n)
    return "NOTE " .. urlencode(n.filename or "") .. "|"
        .. tostring(n.line or 0) .. "|"
        .. tostring(n.col or 0) .. "|"
        .. urlencode(n.msg or "")
end

local function decode_note(s)
    local fname_enc, line_s, col_s, msg_enc = s:match("^NOTE ([^|]*)|(%d+)|(%d+)|(.*)$")
    if not fname_enc then return nil end
    return {
        filename = urldecode(fname_enc),
        line     = tonumber(line_s),
        col      = tonumber(col_s),
        msg      = urldecode(msg_enc),
        notes    = {},
    }
end

local function encode_diag(d, kind)
    -- d: DiagEntry with fields filename, line, col, msg, notes
    local notes_parts = {}
    for _, n in ipairs(d.notes or {}) do
        notes_parts[#notes_parts + 1] = encode_note(n)
    end
    local notes_str = #notes_parts > 0 and (" " .. table.concat(notes_parts, " ")) or ""
    return kind .. "|" .. urlencode(d.filename or "") .. "|"
        .. tostring(d.line or 0) .. "|"
        .. tostring(d.col or 0) .. "|"
        .. urlencode(d.msg or "")
        .. notes_str
end

local function decode_diag(s)
    -- Parse: KIND|filename|line|col|msg[ NOTE fname|line|col|msg ...]*
    local kind, fname_enc, line_s, col_s, rest = s:match("^([EW])|([^|]*)|(%d+)|(%d+)|(.*)$")
    if not kind then return nil end

    -- rest = url-encoded msg, then zero or more " NOTE ..." groups.
    -- Split on " NOTE " delimiter.
    local parts = {} --: { [integer]: string, ... }
    local pos = 1
    while pos <= #rest do
        local nxt = rest:find(" NOTE ", pos, true)
        if nxt then
            parts[#parts + 1] = rest:sub(pos, nxt - 1)
            pos = nxt + 1  -- skip the space before NOTE
        else
            parts[#parts + 1] = rest:sub(pos)
            break
        end
    end

    local msg_enc = parts[1] or ""
    local notes = {}
    for i = 2, #parts do
        local n = decode_note(parts[i])
        if n then notes[#notes + 1] = n end
    end

    return {
        kind     = kind == "E" and "error" or "warning",
        filename = urldecode(fname_enc),
        line     = tonumber(line_s),
        col      = tonumber(col_s),
        msg      = urldecode(msg_enc),
        notes    = notes,
    }
end

-- ── Pipe I/O helpers ──────────────────────────────────────────────────────────

local function pipe_write_all(fd, s)
    local buf   = ffi.cast("const char *", s) --[[: any]]
    local total = #s
    local done  = 0
    while done < total do
        local n = ffi.C.write(fd, buf + done, total - done) --[[:! integer]]
        if n < 0 then
            if ffi.errno() == 4 then  -- EINTR: retry
                -- continue
            else
                break
            end
        elseif n == 0 then
            break
        else
            done = done + n
        end
    end
end

-- EINTR (4 on Linux/glibc and musl): syscall interrupted by signal.
-- We MUST retry, not abort: SIGCHLD from worker exits will interrupt this
-- parent-side read() and silently truncate worker output otherwise.
local EINTR = 4

local function pipe_read_all(fd)
    local chunk_size = 4096
    local buf    = ffi.new("uint8_t[4096]") --[[: any]]
    local chunks = {}
    while true do
        local n = ffi.C.read(fd, buf, chunk_size) --[[:! integer]]
        if n < 0 then
            if ffi.errno() == EINTR then
                -- retry
            else
                break
            end
        elseif n == 0 then
            break
        else
            chunks[#chunks + 1] = ffi.string(buf, n)
        end
    end
    return table.concat(chunks)
end

-- ── Parallel worker ───────────────────────────────────────────────────────────

local function run_worker(file_subset, write_fd, project_opts, cache_dir)
    -- We are in a forked child. Check each file and send diagnostics over pipe.
    local check_mod = require("lib.type.static.check")
    check_mod.set_cache_dir(cache_dir)

    local total_errors   = 0
    local total_warnings = 0
    local lines = {}

    for _, filename in ipairs(file_subset) do
        local err_ctx = check_mod.check_file(filename, nil, nil, project_opts)
        for _, e in ipairs(err_ctx.errors) do
            lines[#lines + 1] = encode_diag(e, "E") .. "\n"
            total_errors = total_errors + 1
        end
        for _, w in ipairs(err_ctx.warnings) do
            lines[#lines + 1] = encode_diag(w, "W") .. "\n"
            total_warnings = total_warnings + 1
        end
    end

    -- Flush the cache manifest shard before sending DONE.
    local cache_mod = require("lib.type.static.cache")
    local shard_path = cache_dir .. "/manifest.shard." .. tostring(ffi.C.getpid()) .. ".lua"
    cache_mod.flush(shard_path)

    lines[#lines + 1] = "DONE|" .. tostring(total_errors) .. "|" .. tostring(total_warnings) .. "\n"

    pipe_write_all(write_fd, table.concat(lines))
    ffi.C.close(write_fd)
    os.exit(0)
end

-- ── Parallel check runner ─────────────────────────────────────────────────────

-- Fork a worker for `bucket` and return (pid, read_fd). The child does not
-- return — run_worker calls os.exit. Aborts the process on pipe/fork failure.
local function spawn_worker(bucket, project_opts, cache_dir)
    local C = --[[: any]] ffi.C
    local pipefd = ffi.new("int[2]")
    if C.pipe(pipefd) ~= 0 then
        io.stderr:write("pipe() failed\n")
        os.exit(2)
    end
    local rfd, wfd = pipefd[0], pipefd[1]
    local pid = C.fork()
    if pid < 0 then
        io.stderr:write("fork() failed\n")
        os.exit(2)
    elseif pid == 0 then
        C.close(rfd)
        run_worker(bucket, wfd, project_opts, cache_dir)
        -- unreachable
    end
    C.close(wfd)
    return pid, rfd
end

local function check_parallel(files, n, project_opts, cache_dir, format, errors_mod_arg)
    local errors_mod = require("lib.type.static.errors")
    -- Distribute files round-robin across n workers.
    local buckets = {}
    for i = 1, n do buckets[i] = {} end
    for i, f in ipairs(files) do
        local b = ((i - 1) % n) + 1
        buckets[b][#buckets[b] + 1] = f
    end

    -- Remove empty buckets (fewer files than workers).
    local workers = {}
    for _, bucket in ipairs(buckets) do
        if #bucket > 0 then
            workers[#workers + 1] = bucket
        end
    end

    -- Fork one worker per bucket.
    local pids     = {}
    local read_fds = {} --: { [integer]: integer, ... }

    for i, bucket in ipairs(workers) do
        pids[i], read_fds[i] = spawn_worker(bucket, project_opts, cache_dir)
    end

    -- Collect output from each worker pipe.
    -- A worker's last line is "DONE|<errors>|<warnings>". Any worker whose
    -- output is missing the DONE sentinel crashed (typically SIGSEGV inside
    -- LuaJIT under heavy parallel load) and silently lost its bucket. Detect
    -- those workers and replay their files in the parent so the total error
    -- count is deterministic regardless of worker survival.
    local all_lines = {}
    local failed_buckets = {}  -- workers index → bucket
    for i = 1, #workers do
        local text = pipe_read_all(read_fds[i])
        ffi.C.close(read_fds[i])
        local worker_lines = {}
        local saw_done = false
        for line in text:gmatch("[^\n]+") do
            worker_lines[#worker_lines + 1] = line
            if line:sub(1, 5) == "DONE|" then saw_done = true end
        end
        if saw_done then
            -- Worker completed cleanly: keep its diagnostics.
            for _, line in ipairs(worker_lines) do
                all_lines[#all_lines + 1] = line
            end
        else
            -- Worker crashed (typically SIGSEGV inside LuaJIT under heavy
            -- parallel load). Discard its partial output and queue the bucket
            -- for sequential replay in the parent.
            failed_buckets[i] = workers[i]
        end
    end

    -- Wait for all children.
    local status_p = ffi.new("int[1]")
    for i = 1, #workers do
        ffi.C.waitpid(pids[i], status_p, 0)
    end

    -- Merge manifest shards now that all workers are done.
    local cache_mod = require("lib.type.static.cache")
    cache_mod.merge_shards(cache_dir)

    -- Replay any failed buckets via a single fresh child. Bundling all failed
    -- buckets into one child reduces the chance of hitting another crash, and
    -- a fresh child matches the in-memory state surviving workers had so the
    -- diagnostics are bit-identical to what a non-crashed worker would have
    -- produced.
    if next(failed_buckets) then
        local nfailed = 0
        for _ in pairs(failed_buckets) do nfailed = nfailed + 1 end
        io.stderr:write(string.format(
            "warning: %d worker(s) crashed; replaying their files\n",
            nfailed))
        local replay_files = {}
        for _, bucket in pairs(failed_buckets) do
            for _, filename in ipairs(bucket) do
                replay_files[#replay_files + 1] = filename
            end
        end
        local replay_pid, replay_rfd = spawn_worker(replay_files, project_opts, cache_dir)
        local replay_text = pipe_read_all(replay_rfd)
        ffi.C.close(replay_rfd)
        ffi.C.waitpid(replay_pid, status_p, 0)
        local replay_saw_done = false
        for line in replay_text:gmatch("[^\n]+") do
            all_lines[#all_lines + 1] = line
            if line:sub(1, 5) == "DONE|" then replay_saw_done = true end
        end
        if not replay_saw_done then
            io.stderr:write("warning: replay child also crashed; results incomplete\n")
        end
        cache_mod.merge_shards(cache_dir)
    end

    -- Decode diagnostics into per-file err_ctx tables.
    local file_errs = {}   -- filename -> err_ctx
    local total_errors   = 0
    local total_warnings = 0

    for _, filename in ipairs(files) do
        file_errs[filename] = errors_mod.new_ctx()
    end

    for _, line in ipairs(all_lines) do
        if line:match("^DONE|") then
            -- sentinel: counts already implicit; skip
        elseif line:match("^[EW]|") then
            local d = decode_diag(line)
            if d then
                local ec = file_errs[d.filename]
                if not ec then
                    -- Diagnostic for a file not in our list (shouldn't happen, but be safe).
                    ec = errors_mod.new_ctx()
                    file_errs[d.filename] = ec
                end
                if d.kind == "error" then
                    local entry = {
                        kind     = "error",
                        filename = d.filename,
                        line     = d.line,
                        col      = d.col,
                        msg      = d.msg,
                        notes    = d.notes,
                    }
                    ec.errors[#ec.errors + 1] = entry
                    total_errors = total_errors + 1
                else
                    local entry = {
                        kind     = "warning",
                        filename = d.filename,
                        line     = d.line,
                        col      = d.col,
                        msg      = d.msg,
                        notes    = d.notes,
                    }
                    ec.warnings[#ec.warnings + 1] = entry
                    total_warnings = total_warnings + 1
                end
            end
        end
    end

    -- Populate source_lines for each file that has diagnostics (enables caret context).
    -- Read each unique filename once per err_ctx. Cost is negligible vs the full check.
    for _, ec in pairs(file_errs) do
        local needed = {}
        for _, d in ipairs(ec.errors) do
            needed[d.filename] = true
            for _, n in ipairs(d.notes or {}) do needed[n.filename] = true end
        end
        for _, d in ipairs(ec.warnings) do
            needed[d.filename] = true
            for _, n in ipairs(d.notes or {}) do needed[n.filename] = true end
        end
        for fname in pairs(needed) do
            if not ec.source_lines[fname] then
                local f = io.open(fname, "r")
                if f then
                    errors_mod.set_source(ec, fname, f:read("*a"))
                    f:close()
                end
            end
        end
    end

    -- Output results in file order (deterministic).
    local structured_parts = {}

    for _, filename in ipairs(files) do
        local err_ctx = file_errs[filename]
        local ne = #err_ctx.errors
        local nw = #err_ctx.warnings

        if format == "json" then
            structured_parts[#structured_parts + 1] = errors_mod.format_json(err_ctx)
        elseif format == "sarif" then
            structured_parts[#structured_parts + 1] = err_ctx
        elseif ne > 0 or nw > 0 then
            if format == "plain" then
                io.stderr:write(errors_mod.format_plain(err_ctx))
            else
                io.stderr:write(errors_mod.format_ansi(err_ctx))
            end
            io.stderr:write("\n")
        end
    end

    if format == "json" then
        io.write("[")
        local first = true
        for _, part in ipairs(structured_parts) do
            local inner = part:match("^%[(.*)%]$") or ""
            if inner ~= "" then
                if not first then io.write(",") end
                io.write(inner)
                first = false
            end
        end
        io.write("]\n")
    elseif format == "sarif" then
        local combined = errors_mod.new_ctx()
        for _, ec in ipairs(structured_parts --[[:! { [integer]: ErrCtx, ... }]]) do
            for _, e in ipairs(ec.errors)   do combined.errors[#combined.errors+1]     = e end
            for _, w in ipairs(ec.warnings) do combined.warnings[#combined.warnings+1] = w end
        end
        io.write(errors_mod.format_sarif(combined))
        io.write("\n")
    end

    io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
        #files, total_errors, total_warnings))

    os.exit(total_errors > 0 and 1 or 0)
end

local function glob_lua_files(dir)
    local files = {}
    local p = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*_test.lua" -not -path "*/dep/*" 2>/dev/null')
    if not p then return files end
    for line in p:lines() do
        files[#files + 1] = line
    end
    p:close()
    table.sort(files)
    return files
end

-- ── dump helpers ──────────────────────────────────────────────────────────────

-- Escape a string for JSON output.
--: (string) -> string
local function json_str(s)
    local r = (s:gsub('\\', '\\\\'))
    r = (r:gsub('"', '\\"'))
    r = (r:gsub('\n', '\\n'))
    r = (r:gsub('\r', '\\r'))
    r = (r:gsub('\t', '\\t'))
    return '"' .. r .. '"'
end

--- Return { file, bindings, ["return"] } for filename, or nil if check fails.
-- bindings is an array of { name, type } sorted by name.
--: (string, any, any) -> { file: string, bindings: { [integer]: { name: string, type: string }, ... }, ["return"]: string | nil } | nil
function M.dump_one(filename, parent_scope, opts)
    local check_mod  = require("lib.type.static.check")
    local intern_mod = require("lib.type.static.intern")
    local types_mod  = require("lib.type.static.types")
    local _, ctx = check_mod.check_file(filename, parent_scope, nil, opts)
    if not ctx then return nil end
    local list = {}
    for name_id, type_id in pairs(ctx.scope.bindings) do
        local name = intern_mod.get(ctx.pool, name_id) or tostring(name_id)
        list[#list + 1] = { name = name, type = types_mod.display(ctx, types_mod.find(ctx, type_id)) }
    end
    table.sort(list --[[: any]], (function(a, b) return a.name < b.name end) --[[: any]])
    local result = { file = filename, bindings = list }
    local rets = ctx.module_return_tids
    if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
        result["return"] = types_mod.display(ctx, types_mod.find(ctx, rets[1][1]))
    end
    return result
end

--- Dump a list of files as a JSON array string.
-- Each element: { "file", "bindings": [{name, type},...], "return"? }
function M.dump_json(filenames)
    local parts = { "[\n" }
    local first = true
    for _, filename in ipairs(filenames) do
        local r = M.dump_one(filename)
        if r then
            if not first then parts[#parts + 1] = ",\n" end
            first = false
            parts[#parts + 1] = '  {"file":' .. json_str(r.file) .. ',"bindings":['
            for j, b in ipairs(r.bindings) do
                if j > 1 then parts[#parts + 1] = ',' end
                parts[#parts + 1] = '{"name":' .. json_str(b.name) .. ',"type":' .. json_str(b.type) .. '}'
            end
            parts[#parts + 1] = ']'
            if r["return"] then
                parts[#parts + 1] = ',"return":' .. json_str(r["return"] --[[:! string]])
            end
            parts[#parts + 1] = '}'
        end
    end
    parts[#parts + 1] = "\n]\n"
    return table.concat(parts)
end

-- ── Summary mode ─────────────────────────────────────────────────────────────

-- Resolve a module name to a file path (same logic as check.lua's cri_loader).
--: (string) -> string | nil
local function resolve_mod_path(mod_name)
    --: string
    local rel = mod_name:gsub("%.", "/")
    local path = rel .. ".lua"
    local f = io.open(path, "r")
    if f then f:close(); return path end
    --: string
    local rel2 = path:gsub("%.lua$", "/init.lua")
    f = io.open(rel2, "r")
    if f then f:close(); return rel2 end
    return nil
end

-- Extract require("mod") calls from source text (skipping comments).
-- Returns an array of module name strings (in order, may contain duplicates).
--: (string) -> { [integer]: string, ... }
local function extract_requires(source)
    local mods = {}
    -- Strip single-line comments (-- ...) so we don't match requires in comments.
    local stripped = source:gsub("%-%-[^\n]*", "")
    for mod in stripped:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
        mods[#mods + 1] = mod
    end
    return mods
end

-- Categorise a single error message into a short bucket label.
--: (string) -> string
local function bucket_label(msg)
    -- Strip ANSI codes first (should be plain text from err_ctx, but be safe).
    msg = msg:gsub("\27%[[%d;]*m", "")
    if msg:find("unknown`? must be narrowed", 1, false)
        or msg:find("of type `unknown`", 1, false) then
        return "unknown cascade (narrowing required)"
    elseif msg:find("doesn't exist", 1, true) then
        return "field doesn't exist"
    elseif msg:find("type mismatch", 1, true) or msg:find("cannot assign", 1, true) then
        return "type mismatch / assignment"
    elseif msg:find("cannot call", 1, true) or msg:find("no matching overload", 1, true)
        or msg:find("no method", 1, true) then
        return "call / overload mismatch"
    elseif msg:find("cannot perform arithmetic", 1, true)
        or msg:find("cannot concatenate", 1, true)
        or msg:find("cannot get length", 1, true)
        or msg:find("cannot compare", 1, true)
        or msg:find("cannot take length", 1, true) then
        return "operator on wrong type"
    elseif msg:find("missing required argument", 1, true) then
        return "missing required argument"
    elseif msg:find("unknown identifier", 1, true) then
        return "unknown identifier"
    else
        return "other"
    end
end

-- Print a root-cause-aware summary for a list of (filename, err_ctx) pairs.
-- If total errors is 0, prints nothing (clean file).
--: ({ [integer]: { filename: string, err_ctx: { errors: { [integer]: { msg: string, line: integer, ... }, ... }, ... } }, ... }) -> ()
local function print_summary(file_errs_list)
    local grand_total = 0
    for _, fe in ipairs(file_errs_list) do
        grand_total = grand_total + #fe.err_ctx.errors
    end

    if grand_total == 0 then
        io.stderr:write("No errors.\n")
        return
    end

    for _, fe in ipairs(file_errs_list) do
        local filename = fe.filename
        local err_ctx  = fe.err_ctx
        local errors   = err_ctx.errors
        local n = #errors
        if n == 0 then goto continue end

        io.stderr:write(string.format("%s: %d error%s\n", filename, n, n == 1 and "" or "s"))

        -- Read source to find require() calls.
        --: string
        local source = ""
        local sf = io.open(filename, "r")
        if sf then source = (sf:read("*a") or ""); sf:close() end

        local mods = extract_requires(source)

        -- Determine which requires are unresolved.
        -- Skip built-in LuaJIT modules: bit, ffi, jit, table, string, etc.
        --: { [string]: boolean | nil, ... }
        local builtin = {
            bit=true, ffi=true, jit=true, string=true, table=true,
            math=true, io=true, os=true, coroutine=true, debug=true,
            package=true, utf8=true,
        }
        --: { [string]: boolean | nil, ... }
        local unresolved = {}
        --: { [integer]: string, ... }
        local unresolved_list = {}
        --: { [string]: boolean | nil, ... }
        local seen_mod = {}
        for _, mod in ipairs(mods) do
            if not seen_mod[mod] and not builtin[mod] then
                seen_mod[mod] = true
                if not resolve_mod_path(mod) then
                    unresolved[mod] = true
                    unresolved_list[#unresolved_list + 1] = mod
                end
            end
        end

        -- Count cascade errors (messages referencing unknown narrowing).
        -- We attribute these to unresolved requires heuristically: if there are
        -- unresolved requires and the error mentions `unknown`, it's a cascade.
        --: { [string]: integer | nil, ... }
        local cascade_count = {}  -- mod_name → count
        local remaining_errors = {}
        local has_unresolved = #unresolved_list > 0

        for _, e in ipairs(errors) do
            local lbl = bucket_label(e.msg)
            if has_unresolved and lbl == "unknown cascade (narrowing required)" then
                -- Attribute to the first unresolved require (simple heuristic).
                -- A more precise version would track which variable names came from
                -- which require and match on line context.
                local first_mod = unresolved_list[1]
                cascade_count[first_mod] = (cascade_count[first_mod] or 0) + 1
            else
                remaining_errors[#remaining_errors + 1] = e
            end
        end

        -- If we have multiple unresolved requires, try to distribute cascade errors
        -- by attributing based on source proximity: the require that appears earliest
        -- before the error line. This is a rough heuristic.
        if #unresolved_list > 1 then
            -- Build: mod_name → line number of the require() call.
            -- Use comment-stripped source so requires in comments are ignored.
            --: { [string]: integer | nil, ... }
            local mod_line = {}
            local stripped_src = source:gsub("%-%-[^\n]*", "")
            local lineno = 1
            local prev_end = 1
            local nl = stripped_src:find("\n", prev_end, true)
            while nl do
                --: integer
                local nl_pos = nl
                local segment = stripped_src:sub(prev_end, nl_pos)
                for mod in segment:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
                    if unresolved[mod] and not mod_line[mod] then
                        mod_line[mod] = lineno
                    end
                end
                lineno = lineno + 1
                prev_end = nl_pos + 1
                nl = stripped_src:find("\n", prev_end, true)
            end

            -- Re-bucket cascade errors from the first-mod bucket.
            local first_mod = unresolved_list[1]
            local old_count = cascade_count[first_mod] or 0
            if old_count > 0 then
                -- Reset and re-attribute all cascade errors.
                for _, mod in ipairs(unresolved_list) do
                    cascade_count[mod] = 0
                end
                -- Re-scan errors for cascade attribution.
                local new_remaining = {}
                for _, e in ipairs(errors) do
                    local lbl = bucket_label(e.msg)
                    if lbl == "unknown cascade (narrowing required)" then
                        -- Find which unresolved require most recently precedes this error's line.
                        local best_mod = unresolved_list[1]
                        --: integer
                        local best_line = 0 - 1
                        for _, mod in ipairs(unresolved_list) do
                            --: integer
                            local ml = mod_line[mod] or 0
                            if ml <= e.line then
                                if ml > best_line then
                                    best_line = ml
                                    best_mod = mod
                                end
                            end
                        end
                        cascade_count[best_mod] = (cascade_count[best_mod] or 0) + 1
                    else
                        new_remaining[#new_remaining + 1] = e
                    end
                end
                remaining_errors = new_remaining
            end
        end

        -- Bucket remaining errors.
        --: { [string]: integer | nil, ... }
        local buckets = {}
        --: { [integer]: string, ... }
        local bucket_order = {}
        for _, e in ipairs(remaining_errors) do
            local lbl = bucket_label(e.msg)
            if not buckets[lbl] then
                bucket_order[#bucket_order + 1] = lbl
                buckets[lbl] = 0
            end
            buckets[lbl] = (buckets[lbl] or 0) + 1
        end

        -- Print root causes section.
        local has_cascade = false
        for _, mod in ipairs(unresolved_list) do
            local cnt = cascade_count[mod] or 0
            if cnt > 0 then has_cascade = true; break end
        end

        if has_cascade then
            io.stderr:write("  Root causes:\n")
            for _, mod in ipairs(unresolved_list) do
                local cnt = cascade_count[mod] or 0
                if cnt > 0 then
                    io.stderr:write(string.format(
                        "    require(%q) → unknown (module not found): %d downstream error%s\n",
                        mod, cnt, cnt == 1 and "" or "s"))
                end
            end
        end

        -- Print remaining (non-cascade) errors bucketed.
        local remaining_count = #remaining_errors
        if remaining_count > 0 then
            io.stderr:write(string.format("  Remaining (%s):\n",
                has_cascade and "no cascade root" or "all errors"))
            for _, lbl in ipairs(bucket_order) do
                local cnt = buckets[lbl] or 0
                io.stderr:write(string.format("    %3d  %s\n", cnt, lbl))
            end
        end

        -- List unresolved requires with no cascade errors (module not found but
        -- no unknown errors attributed to them — may still be the root cause).
        local silent_unresolved = {}
        for _, mod in ipairs(unresolved_list) do
            if (cascade_count[mod] or 0) == 0 then
                silent_unresolved[#silent_unresolved + 1] = mod
            end
        end
        if #silent_unresolved > 0 then
            io.stderr:write("  Unresolved requires (no cascade errors attributed):\n")
            for _, mod in ipairs(silent_unresolved) do
                io.stderr:write(string.format("    require(%q) — module not found\n", mod))
            end
        end

        io.stderr:write("\n")
        ::continue::
    end
end

--- Main entry point. argv is a 1-indexed list of arguments.
function M.main(argv)
    local check_mod  = require("lib.type.static.check")
    local errors_mod = require("lib.type.static.errors")
    local intern_mod = require("lib.type.static.intern")
    local types_mod  = require("lib.type.static.types")
    local defs       = require("lib.type.static.defs")

    local format    = "ansi"  -- ansi | plain | json | sarif
    local dump      = false
    local annotate  = false
    local run_rules = false  -- --rules flag: run lint passes after check
    local summary   = false  -- --summary flag: print bucketed root-cause summary
    local files     = {}

    local i = 1
    while i <= #argv do
        if argv[i] == "--format" and argv[i + 1] then
            format = argv[i + 1]
            i = i + 2
        elseif argv[i] == "--dump" then
            dump = true
            i = i + 1
        elseif argv[i] == "--annotate" then
            annotate = true
            i = i + 1
        elseif argv[i] == "--rules" then
            run_rules = true
            i = i + 1
        elseif argv[i] == "--summary" then
            summary = true
            i = i + 1
        else
            files[#files + 1] = argv[i]
            i = i + 1
        end
    end

    -- Load rule passes once when --rules is active.
    local rules_mod
    if run_rules then
        rules_mod = require("lib.type.static.rules")
        rules_mod.load_all()
    end

    -- Auto-discover lib/ when no files given (mirrors v1 behaviour).
    if #files == 0 then
        files = glob_lua_files("lib")
        if #files == 0 then
            io.stderr:write("usage: luajit lib/type/static/cli.lua [--format plain|ansi|json|sarif] [--dump] [--annotate] <file> ...\n")
            os.exit(1)
        end
    end

    -- Look for pkg.lua (walk up from the first file's directory or cwd).
    -- If found and it has typecheck.globals, resolve the listed module names to
    -- file paths and pass them as opts.globals_files to each check call.
    -- Each file is loaded into its own ctx's scope (correct: types allocated in
    -- the checking ctx's arenas, not a shared parent arena).
    local project_opts = nil
    local cache_dir
    do
        -- Walk up from cwd looking for pkg.lua.
        local function find_pkg_lua()
            -- Try cwd first.
            local f = io.open("pkg.lua", "r")
            if f then f:close(); return "pkg.lua" end
            -- Walk up from first file's directory.
            if #files > 0 then
                local dir = files[1]:match("^(.+)/[^/]+$") or "."
                while dir and dir ~= "" and dir ~= "." do
                    local path = dir .. "/pkg.lua"
                    f = io.open(path, "r")
                    if f then f:close(); return path end
                    dir = dir:match("^(.+)/[^/]+$")
                end
            end
            return nil
        end

        local pkg_path = find_pkg_lua()
        -- Derive project root and enable the disk .cri cache.
        local project_root = pkg_path and (pkg_path:match("^(.+)/[^/]+$") or ".") or "."
        cache_dir = project_root .. "/.crescentcache"
        check_mod.set_cache_dir(cache_dir)

        if pkg_path then
            local ok_load, pkg_fn = pcall(loadfile, pkg_path)
            if ok_load and type(pkg_fn) == "function" then
                local ok_run, manifest = pcall(pkg_fn --[[: any]])
                if ok_run and type(manifest) == "table" then
                    local tc = (manifest --[[: any]]).typecheck
                    if tc and type(tc) == "table" and type(tc.globals) == "table" then
                        -- Resolve module names to file paths.
                        -- "lib/type/static/stdlib_types" → "lib/type/static/stdlib_types.lua"
                        local globals_files = {}
                        for _, mod_name in ipairs(tc.globals --[[:! { [integer]: string, ... }]]) do
                            -- Accept both slash-path and dot-path conventions.
                            local rel, _ = mod_name:gsub("%.", "/")
                            globals_files[#globals_files + 1] = rel .. ".lua"
                        end
                        if #globals_files > 0 then
                            project_opts = { globals_files = globals_files }
                        end
                    end
                end
            end
        end
    end

    -- --annotate mode: emit source with inferred type annotations inserted.
    if annotate then
        for _, filename in ipairs(files) do
            local _, ctx = check_mod.check_file(filename, nil, nil, project_opts)
            if not ctx then
                io.stderr:write(filename .. ": failed to check\n")
            else
                -- Read source lines.
                local src_lines = {} --: { [integer]: string | nil, ... }
                local f = io.open(filename, "r")
                if f then
                    for line in f:lines() do src_lines[#src_lines + 1] = line end
                    f:close()
                end

                -- Build line → annotation string to insert before that line.
                -- type_at is a flat array {line, col, tid, ...} stride 3.
                -- Emit at most one annotation per source line: pick the first
                -- non-trivial type seen on that line (constraint-generation order).
                local insertions = {} --: { [integer]: string }
                local ta = ctx.type_at
                local i = 1
                while i <= #ta do
                    local line = ta[i]
                    local tid  = ta[i + 2]
                    i = i + 3
                    if line and line > 0 and not insertions[line] then
                        local resolved = types_mod.find(ctx, tid)
                        local rt = ctx.types:get(resolved)
                        -- Skip trivial: vars, any, nil.
                        if rt.tag ~= defs.TAG_VAR and rt.tag ~= defs.TAG_ANY
                                and rt.tag ~= defs.TAG_NIL then
                            insertions[line] = "--: " .. types_mod.display(ctx, resolved)
                        end
                    end
                end

                -- Emit source with annotations inserted before each annotated line.
                for ln, src_line in ipairs(src_lines) do
                    local sl = src_line --[[:! string]]
                    if insertions[ln] then
                        local indent = sl:match("^(%s*)") or ""
                        io.write(indent .. insertions[ln] .. "\n")
                    end
                    io.write(sl .. "\n")
                end
            end
        end
        require("lib.type.static.cache").flush()
        return
    end

    -- --dump mode: print inferred top-level bindings for each file.
    if dump then
        if format == "json" then
            io.write(M.dump_json(files))
        else
            for _, filename in ipairs(files) do
                local r = M.dump_one(filename, nil, project_opts)
                if r then
                    io.write("-- " .. r.file .. "\n")
                    for _, b in ipairs(r.bindings) do
                        io.write(b.name .. ": " .. b.type .. "\n")
                    end
                    if r["return"] then
                        io.write("(return): " .. (r["return"] --[[:! string]]) .. "\n")
                    end
                end
            end
        end
        require("lib.type.static.cache").flush()
        return
    end

    -- Inputs use the disk cache: a hash hit restores cached diagnostics + types
    -- and skips the solver entirely. Diagnostics are stored in the .cri file
    -- (Section 7, v2). To force a re-check, delete .crescentcache or bump the
    -- .cri schema version.
    local input_opts = (project_opts or {}) --[[:! { no_disk_cache: boolean | nil, globals_files: { [integer]: string, ... } | nil, ... }]]

    -- Determine parallelism level.
    -- Don't parallelize when --rules or --summary is active (state lives in-process).
    local njobs
    if run_rules or summary or not fork_available then
        njobs = 1
    else
        njobs = math.min(get_cpu_count(), #files)
    end

    if njobs > 1 then
        -- Parallel path: forks workers, each checks a subset, parent collects.
        check_parallel(files, njobs, input_opts, cache_dir, format, errors_mod)
        -- check_parallel calls os.exit(); unreachable.
        return
    end

    -- Sequential path (--rules/--summary active, fork unavailable, or single file).
    local total_errors   = 0
    local total_warnings = 0
    local structured_parts = {}
    -- Accumulates { filename, err_ctx } for --summary output.
    --: { [integer]: { filename: string, err_ctx: ErrCtx }, ... }
    local summary_entries = {}

    for _, filename in ipairs(files) do
        local err_ctx, ctx = check_mod.check_file(filename, nil, nil, input_opts)

        -- Run lint rule passes when --rules is active and the check succeeded.
        if run_rules and ctx then
            (rules_mod --[[:! { run: (Ctx, ErrCtx, string, nil) -> (), ... }]]).run(ctx, err_ctx, filename, nil)
        end

        local ne = #err_ctx.errors
        local nw = #err_ctx.warnings
        total_errors   = total_errors   + ne
        total_warnings = total_warnings + nw

        if summary then
            summary_entries[#summary_entries + 1] = { filename = filename, err_ctx = err_ctx }
        end

        if not summary then
            if format == "json" then
                structured_parts[#structured_parts + 1] = errors_mod.format_json(err_ctx)
            elseif format == "sarif" then
                structured_parts[#structured_parts + 1] = err_ctx
            elseif ne > 0 or nw > 0 then
                if format == "plain" then
                    io.stderr:write(errors_mod.format_plain(err_ctx))
                else
                    io.stderr:write(errors_mod.format_ansi(err_ctx))
                end
                io.stderr:write("\n")
            end
        end
    end

    if summary then
        print_summary(summary_entries)
    else
        if format == "json" then
            -- Merge all JSON arrays into one.
            io.write("[")
            local first = true
            for _, part in ipairs(structured_parts) do
                local inner = part:match("^%[(.*)%]$") or ""
                if inner ~= "" then
                    if not first then io.write(",") end
                    io.write(inner)
                    first = false
                end
            end
            io.write("]\n")
        elseif format == "sarif" then
            -- Merge all err_ctx into one SARIF document.
            local combined = errors_mod.new_ctx()
            for _, ec in ipairs(structured_parts) do
                for _, e in ipairs(ec.errors)   do combined.errors[#combined.errors+1]     = e end
                for _, w in ipairs(ec.warnings) do combined.warnings[#combined.warnings+1] = w end
            end
            io.write(errors_mod.format_sarif(combined))
            io.write("\n")
        end
    end

    io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
        #files, total_errors, total_warnings))

    require("lib.type.static.cache").flush()
    os.exit(total_errors > 0 and 1 or 0)
end

-- ── standalone entry point ────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("static/cli%.lua$") then
    M.main(arg)
end

return M
