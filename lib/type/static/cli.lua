-- lib/type/static/cli.lua
-- CLI entry point for the static typechecker.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local errors = require("lib.type.static.errors")

local function glob_lua_files(dir)
  local files = {}
  local p = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*_test.lua" -not -path "*/dep/*" 2>/dev/null')
  if not p then return files end
  for line in p:lines() do
    files[#files + 1] = line
  end
  p:close()
  return files
end

local function main()
  local checker = require("lib.type.static")
  local types = require("lib.type.static.types")
  local files = {}
  local target = "luajit" -- default target
  local format = "text"   -- text | json | sarif
  local dump = false
  local annotate = false

  local i = 1
  while i <= #arg do
    if arg[i] == "--target" and arg[i + 1] then
      target = arg[i + 1]
      i = i + 2
    elseif arg[i] == "--format" and arg[i + 1] then
      format = arg[i + 1]
      i = i + 2
    elseif arg[i] == "--dump" then
      dump = true
      i = i + 1
    elseif arg[i] == "--annotate" then
      annotate = true
      i = i + 1
    else
      files[#files + 1] = arg[i]
      i = i + 1
    end
  end

  if #files == 0 then
    files = glob_lua_files("lib")
  end

  -- --dump mode: print inferred types for each file
  if dump then
    for _, filename in ipairs(files) do
      local err_ctx, ctx = checker.check_file(filename)
      if ctx and ctx.scope then
        -- Walk the file's own scope bindings (not parent/builtins)
        local names = {}
        for name in pairs(ctx.scope.bindings) do
          names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
          io.write(name .. ": " .. types.display(ctx.scope.bindings[name]) .. "\n")
        end
      end
      -- Show module return type
      if ctx and ctx.module_return then
        io.write("(return): " .. types.display(ctx.module_return) .. "\n")
      end
    end
    return
  end

  -- --annotate mode: emit source with inferred type annotations
  if annotate then
    for _, filename in ipairs(files) do
      local err_ctx, ctx = checker.check_file(filename)
      if not ctx then
        io.stderr:write(filename .. ": failed to check\n")
      else
        -- Read source lines
        local source_lines = {}
        local f = io.open(filename, "r")
        if f then
          for line in f:lines() do
            source_lines[#source_lines + 1] = line
          end
          f:close()
        end

        -- Build insertion map: line -> list of annotation strings to insert before it
        local insertions = {} -- line -> { text, ... }
        for _, ann in ipairs(ctx.inferred_anns) do
          local line = ann.line
          if line and line > 0 then
            if ann.kind == "type" then
              local ty = ann.type_fn()
              if ty then
                local resolved = types.resolve(ty)
                -- Skip trivial/obvious types
                local trivial = resolved.tag == "any" or resolved.tag == "var"
                  or resolved.tag == "nil"
                  or (resolved.tag == "table" and not next(resolved.fields) and #resolved.indexers == 0)
                if not trivial then
                  if not insertions[line] then insertions[line] = {} end
                  local ins = insertions[line]
                  ins[#ins + 1] = "--: " .. types.display(ty)
                end
              end
            elseif ann.kind == "function" then
              local ft = ann.fn_type
              -- Build function signature: --: (params) -> returns
              local param_parts = {}
              local all_trivial = true
              for j = 1, #ft.params do
                local p_ty = ft.params[j]
                local resolved = types.resolve(p_ty)
                if resolved.tag ~= "any" and resolved.tag ~= "var" then
                  all_trivial = false
                end
                param_parts[j] = types.display(p_ty)
              end
              local ret_parts = {}
              for j = 1, #ft.returns do
                local r_ty = ft.returns[j]
                local resolved = types.resolve(r_ty)
                if resolved.tag ~= "any" and resolved.tag ~= "var" then
                  all_trivial = false
                end
                ret_parts[j] = types.display(r_ty)
              end
              -- Skip if everything is any/var (no useful info)
              if not all_trivial then
                if not insertions[line] then insertions[line] = {} end
                local ins = insertions[line]
                local sig = "(" .. table.concat(param_parts, ", ") .. ")"
                if #ret_parts > 0 then
                  sig = sig .. " -> " .. table.concat(ret_parts, ", ")
                end
                ins[#ins + 1] = "--: " .. sig
              end
            end
          end
        end

        -- Emit source with insertions
        for line_num, line_text in ipairs(source_lines) do
          if insertions[line_num] then
            -- Match indentation of the source line
            local indent = line_text:match("^(%s*)")
            for _, ann_text in ipairs(insertions[line_num]) do
              io.write(indent .. ann_text .. "\n")
            end
          end
          io.write(line_text .. "\n")
        end
      end
    end
    return
  end

  local total_errors = 0
  local total_warnings = 0
  local total_files = 0
  -- For JSON/SARIF, collect all errors into a merged context
  local merged_ctx = errors.new()

  for _, filename in ipairs(files) do
    local err_ctx = checker.check_file(filename)
    local n_errors = errors.count(err_ctx, "error")
    local n_warnings = errors.count(err_ctx, "warning")

    if format == "text" then
      if n_errors > 0 or n_warnings > 0 then
        -- Read source lines for display
        local source_lines = {}
        local f = io.open(filename, "r")
        if f then
          local line_num = 0
          for line in f:lines() do
            line_num = line_num + 1
            source_lines[line_num] = line
          end
          f:close()
        end

        io.stderr:write(errors.format(err_ctx, source_lines))
        io.stderr:write("\n")
      end
    else
      -- Merge errors for JSON/SARIF output
      for j = 1, #err_ctx.errors do
        merged_ctx.errors[#merged_ctx.errors + 1] = err_ctx.errors[j]
      end
    end

    total_errors = total_errors + n_errors
    total_warnings = total_warnings + n_warnings
    total_files = total_files + 1
  end

  -- Output structured formats to stdout
  if format == "json" then
    io.write(errors.format_json(merged_ctx))
    io.write("\n")
  elseif format == "sarif" then
    io.write(errors.format_sarif(merged_ctx))
    io.write("\n")
  end

  -- Summary (always to stderr)
  io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
    total_files, total_errors, total_warnings))

  if total_errors > 0 then
    os.exit(1)
  else
    os.exit(0)
  end
end

main()
