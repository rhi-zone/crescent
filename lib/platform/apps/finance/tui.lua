if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- TUI frontend for the finance app: projects lib/platform/apps/finance
-- .views' View data to a terminal screen via lib/tui, and drives navigation
-- /form input through lib/platform/apps/finance/init.lua's app API and
-- actions.lua's form-submission dispatch. Renders no HTML, does not know
-- about lib/html or lib/web -- dom.lua is the web counterpart, projecting
-- the exact same View data differently.
--
-- Rendering approach: each View is flattened to plain text lines (pure,
-- unit-testable -- M.render_lines) rather than laid out as a tree of
-- lib/tui box/row/col widgets one-per-section. lib/tui's row/col divide a
-- FIXED w/h proportionally among children; there is no "give this child
-- exactly as many rows as its content needs" primitive, so a
-- content-driven variable-height document (an accounts table with N rows
-- next to a form with M fields) doesn't fit that model without inventing
-- one. The flattened text is still rendered through lib/tui at the end
-- (M.render wraps it in a single tui.text widget and calls tui.render),
-- so the terminal-geometry/ANSI concerns (clearing, cursor positioning,
-- truncation to terminal width) are lib/tui's, not reimplemented here.
--
-- Caps: db (via init.lua), stdin, stdout (both required -- see
-- manifest.json's tui entry).

local tui     = require("lib.tui")
local ansi    = require("lib.ansi")
local views   = require("lib.platform.apps.finance.views")
local actions = require("lib.platform.apps.finance.actions")

local M = {}

--:: AppApi = {
--::   add_account: (unknown) -> (unknown | nil, string | nil),
--::   update_account: (string, unknown) -> (unknown | nil, string | nil),
--::   delete_account: (string) -> (true | nil, string | nil),
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   list_entries: () -> (unknown | nil, string | nil),
--::   post_entry: (string, unknown) -> (unknown | nil, string | nil),
--::   void_entry: (string, string, string) -> (unknown | nil, string | nil),
--::   delete_entry: (string, string) -> (true | nil, string | nil),
--::   list_periods: () -> { [number]: { id: string, start_date: string, end_date: string } },
--::   add_period: (string, unknown) -> (true | nil, string | nil),
--::   set_active_period: (string) -> (true | nil, string | nil),
--::   active_period: () -> (string | nil),
--::   get_ledger: () -> (unknown | nil, string | nil),
--::   get_trial_balance: () -> (unknown | nil, string | nil),
--::   get_income_statement: (string, string) -> (unknown | nil, string | nil),
--::   get_balance_sheet: (string) -> (unknown | nil, string | nil),
--::   sync: () -> ({ [number]: string } | nil, string | nil),
--:: }

-- Restated from views.lua's own View/ViewSection/ViewField declarations
-- (typeof doesn't survive require(), and these aliases aren't exported
-- under a namespace -- same reasoning bridge.lua/init.lua's own headers
-- give for restating each other's shapes).
--:: ViewField = { name: string, label: string, kind: string, value: string, options?: { [number]: { value: string, label: string } }, required?: boolean }
--:: ViewForm = { label: string, action: string, method: string, fields: { [number]: ViewField }, submit_label: string }
--:: ViewSection = { kind: string, label?: string, rows?: unknown, columns?: unknown, empty_text?: string, items?: unknown, form?: ViewForm, value?: string }
--:: View = { title: string, view: string, sections: { [number]: ViewSection }, error?: string, notice?: string }
--:: ViewSummaryRow = { label: string, value: string }
--:: ViewColumn = { key: string, label: string }
--:: ViewRow = { [string]: string }
--:: ViewNavItem = { label: string, view: string, params: { [string]: string } | nil }

-- A numbered menu entry the user can select by typing its number. Built
-- alongside the rendered text so "what does typing 3 do" is answered by
-- the same pass that rendered "[3] <label>" -- never recomputed separately
-- (that would risk the numbering drifting out of sync with the text).
--:: MenuEntry = (
--::     { kind: "nav", view: string, params: { [string]: string } | nil }
--::   | { kind: "form", form: ViewForm }
--:: )
--:: RenderResult = { lines: { [integer]: string }, menu: { [integer]: MenuEntry } }

-- ---------------------------------------------------------------------------
-- Pure rendering: View -> (text lines, numbered menu)
-- ---------------------------------------------------------------------------

--: (string) -> string
local function fmt_field_kind(kind)
  if kind == "select" then return " (select)" end
  if kind == "date" then return " (YYYY-MM-DD)" end
  return ""
end

--: ({ [integer]: string }, { [integer]: MenuEntry }, ViewSection) -> ()
local function render_section(lines, menu, section)
  lines[#lines + 1] = ""
  local label = section.label
  if label ~= nil then
    lines[#lines + 1] = "-- " .. label .. " --"
  end

  if section.kind == "summary" then
    local raw_summary_rows = section.rows
    if type(raw_summary_rows) == "table" then
      local rows = raw_summary_rows --[[: { [number]: ViewSummaryRow } ]]
      for i = 1, #rows do
        lines[#lines + 1] = "  " .. rows[i].label .. ": " .. rows[i].value
      end
    end
  elseif section.kind == "table" then
    local raw_columns = section.columns
    local raw_rows = section.rows
    if type(raw_rows) == "table" then
      local rows = raw_rows --[[: { [number]: ViewRow } ]]
      if #rows == 0 then
        lines[#lines + 1] = "  " .. (section.empty_text or "(none)")
      elseif type(raw_columns) == "table" then
        local columns = raw_columns --[[: { [number]: ViewColumn } ]]
        local header = {} --: { [integer]: string }
        for i = 1, #columns do header[#header + 1] = columns[i].label end
        lines[#lines + 1] = "  " .. table.concat(header, " | ")
        for r = 1, #rows do
          local cells = {} --: { [integer]: string }
          for i = 1, #columns do cells[#cells + 1] = rows[r][columns[i].key] or "" end
          lines[#lines + 1] = "  " .. table.concat(cells, " | ")
        end
      end
    end
  elseif section.kind == "nav" or section.kind == "actions" then
    local raw_items = section.items
    if type(raw_items) == "table" then
      local items = raw_items --[[: { [number]: ViewNavItem } ]]
      for i = 1, #items do
        local item = items[i]
        menu[#menu + 1] = { kind = "nav", view = item.view, params = item.params }
        lines[#lines + 1] = "  [" .. #menu .. "] " .. item.label
      end
    end
  elseif section.kind == "form" then
    local form = section.form
    if form ~= nil then
      menu[#menu + 1] = { kind = "form", form = form }
      lines[#lines + 1] = "  [" .. #menu .. "] " .. form.label .. " (fill form)"
      for i = 1, #form.fields do
        local f = form.fields[i]
        if f.kind ~= "hidden" then
          local current = f.value ~= "" and (" [current: " .. f.value .. "]") or ""
          lines[#lines + 1] = "      - " .. f.label .. fmt_field_kind(f.kind) .. current
        end
      end
    end
  elseif section.kind == "text" then
    local value = section.value
    if value ~= nil then lines[#lines + 1] = "  " .. value end
  end
end

--- Flatten a View into plain text lines plus the numbered menu that lines
--- refer to (e.g. "[3] Accounts" is menu[3]). Pure -- no I/O, no lib.tui
--- dependency -- so it's directly unit-testable.
--: View -> RenderResult
M.render_lines = function(view)
  local lines = {} --: { [integer]: string }
  local menu = {} --: { [integer]: MenuEntry }

  lines[#lines + 1] = "=== " .. view.title .. " ==="
  local notice = view.notice
  if notice ~= nil then lines[#lines + 1] = "(" .. notice .. ")" end
  local view_err = view.error
  if view_err ~= nil then lines[#lines + 1] = "ERROR: " .. view_err end

  for i = 1, #view.sections do
    render_section(lines, menu, view.sections[i])
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Type a number, or 'q' to quit."
  return { lines = lines, menu = menu }
end

--- Render a View to a full ANSI screen via lib/tui (single tui.text widget
--- covering the whole terminal -- see this file's header comment on why).
--: (View, integer, integer) -> string
M.render = function(view, w, h)
  local result = M.render_lines(view)
  local text = table.concat(result.lines, "\n")
  local widget = tui.text(text, { align = "left", wrap = false })
  return tui.render(widget, 1, 1, w, h)
end

-- ---------------------------------------------------------------------------
-- Input resolution
-- ---------------------------------------------------------------------------

--- Resolve raw typed input against a rendered menu. Returns nil for "quit"
--- (a bare "q"/"quit", case-insensitive) or unrecognised input -- the
--- caller's loop treats a nil menu entry from non-quit input as "invalid
--- selection, re-prompt" (see M.run).
--: ({ [number]: MenuEntry }, string) -> (MenuEntry | nil, boolean)
M.resolve_choice = function(menu, raw_input)
  local trimmed = raw_input:match("^%s*(.-)%s*$")
  local lowered = trimmed:lower()
  if lowered == "q" or lowered == "quit" then return nil, true end
  local n = tonumber(trimmed)
  if n == nil then return nil, false end
  local idx = math.floor(n)
  local entry = menu[idx]
  if entry == nil then return nil, false end
  return entry, false
end

-- ---------------------------------------------------------------------------
-- Interactive loop (not unit-tested -- see this app's manifest/task brief:
-- rendering and routing are tested above; driving real stdin/stdout is not)
-- ---------------------------------------------------------------------------

--:: StdinCap = { line: () -> (string | nil, string | nil), ... }
--:: StdoutCap = { write: (string) -> (true | nil, string | nil), flush: () -> (true | nil, string | nil), ... }

-- Prompts for every non-hidden field in `form` via stdin, one line each,
-- pre-filling hidden fields' values (e.g. account_form's `id` in edit
-- mode) straight through without prompting -- the user never sees or
-- retypes a hidden field.
--: (ViewForm, StdinCap, StdoutCap) -> { [string]: string }
local function collect_form_fields(form, stdin, stdout)
  local fields = {} --: { [string]: string }
  for i = 1, #form.fields do
    local f = form.fields[i]
    if f.kind == "hidden" then
      fields[f.name] = f.value
    else
      stdout.write(f.label .. fmt_field_kind(f.kind))
      if f.value ~= "" then stdout.write(" [" .. f.value .. "]") end
      stdout.write(": ")
      stdout.flush()
      local line = stdin.line()
      if line == nil or line == "" then
        fields[f.name] = f.value
      else
        fields[f.name] = line
      end
    end
  end
  return fields
end

--- Run the interactive TUI loop until the user quits. Blocks on stdin.line()
--- each iteration; every screen redraw goes through M.render (lib/tui).
--: (AppApi, StdinCap, StdoutCap, (string) -> string | nil) -> ()
M.run = function(app, stdin, stdout, getenv)
  local w, h = tui.size(getenv)
  local view_name = "dashboard"
  local params = nil --: { [string]: string } | nil
  local form_error = nil --: string | nil

  while true do
    local view = views.build(view_name, app, params, form_error)
    form_error = nil
    stdout.write(ansi.clear())
    stdout.write(M.render(view, w, h))
    stdout.write("\n> ")
    stdout.flush()

    local line = stdin.line()
    if line == nil then break end

    local result = M.render_lines(view)
    local entry, quit = M.resolve_choice(result.menu, line)
    if quit then break end
    if entry ~= nil then
      if entry.kind == "nav" then
        view_name = entry.view
        params = entry.params
      elseif entry.kind == "form" then
        local fields = collect_form_fields(entry.form, stdin, stdout)
        local action_result = actions.perform(entry.form.action, app, fields)
        if action_result ~= nil then
          view_name = action_result.view
          params = action_result.params
          form_error = action_result.error
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Entrypoint: platform runner calls M.create(caps, opts)
-- ---------------------------------------------------------------------------

local finance_init = require("lib.platform.apps.finance.init")

--- Entrypoint convention (see lib/platform/apps/finance/init.lua's own
--- M.create comment): a headless app with no `handler` field is valid --
--- M.run blocks until the user quits, then this returns an empty table.
--: (unknown, unknown) -> (unknown | nil, string | nil)
M.create = function(caps, opts)
  if type(caps) ~= "table" then return nil, "finance.tui: caps must be a table" end
  local c = caps --[[: { db: unknown, stdin: StdinCap, stdout: StdoutCap, ... } ]]
  local app, err = finance_init.create(c, opts)
  if type(app) ~= "table" then return nil, "finance.tui: " .. tostring(err) end

  local stdin_cap = c.stdin
  local stdout_cap = c.stdout
  if stdin_cap == nil or stdout_cap == nil then
    return nil, "finance.tui: stdin and stdout caps are both required"
  end

  -- No cap in lib/platform/CLAUDE.md's cap taxonomy exposes environment
  -- variables or ioctl (the sandbox has no `os`/`ffi` at all -- see that
  -- file's "Sandbox is the security boundary" section), so lib.tui.size's
  -- COLUMNS/LINES/ioctl paths are all unreachable from inside the sandbox.
  -- This stub always returns nil, which sends tui.size straight to its own
  -- documented 80x24 fallback (lib/tui/init.lua's M.size). Real terminal
  -- dimensions would need a new primitive cap (e.g. a `tty`/`terminal` cap
  -- surfacing COLUMNS/LINES); logged in TODO.md rather than guessed at.
  --: (string) -> string | nil
  local function no_env(_name) return nil end

  M.run(app --[[: AppApi]], stdin_cap, stdout_cap, no_env)
  return {}
end

return M
