-- lib/ical/init.lua
-- iCalendar (RFC 5545) parser and builder.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find, match, gmatch, gsub, rep, len =
  string.byte, string.char, string.sub, string.find, string.match,
  string.gmatch, string.gsub, string.rep, string.len
local concat, insert = table.concat, table.insert
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Date/time utilities
-- ---------------------------------------------------------------------------

--- Parse an iCalendar DATE-TIME value.
-- Handles:
--   20260101T100000Z  → utc=true
--   20260101T100000   → utc=false (floating)
--   20260101          → date-only (hour/min/sec nil)
--: (string) -> { year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil } | nil, string | nil
function M.parse_datetime(s)
  if not s then return nil, "nil input" end
  -- DATE-TIME: YYYYMMDDTHHmmss[Z]
  local year, month, day, hour, min, sec, utc =
    match(s, "^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)(Z?)$")
  if year then
    return {
      year  = tonumber(year),
      month = tonumber(month),
      day   = tonumber(day),
      hour  = tonumber(hour),
      min   = tonumber(min),
      sec   = tonumber(sec),
      utc   = utc == "Z",
    }
  end
  -- DATE: YYYYMMDD
  year, month, day = match(s, "^(%d%d%d%d)(%d%d)(%d%d)$")
  if year then
    return {
      year  = tonumber(year),
      month = tonumber(month),
      day   = tonumber(day),
    }
  end
  return nil, "invalid datetime: " .. s
end

--- Parse an iCalendar DATE value.
--: (string) -> { year: integer, month: integer, day: integer } | nil, string | nil
function M.parse_date(s)
  if not s then return nil, "nil input" end
  local year, month, day = match(s, "^(%d%d%d%d)(%d%d)(%d%d)$")
  if not year then return nil, "invalid date: " .. s end
  return { year = tonumber(year), month = tonumber(month), day = tonumber(day) }
end

--- Format a datetime table to iCalendar DATE-TIME string.
--: ({ year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil }) -> string
function M.format_datetime(dt)
  local d = string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
  if dt.hour == nil then return d end
  local t = string.format("T%02d%02d%02d", dt.hour or 0, dt.min or 0, dt.sec or 0)
  return d .. t .. (dt.utc and "Z" or "")
end

--- Format a date table to iCalendar DATE string.
--: ({ year: integer, month: integer, day: integer }) -> string
function M.format_date(dt)
  return string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
end

-- ---------------------------------------------------------------------------
-- RRULE parsing
-- ---------------------------------------------------------------------------

--- Parse an RRULE value string into a table.
-- Example: "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR"
--: (string) -> { freq: string | nil, interval: integer | nil, count: integer | nil, until: unknown | nil, byday: [string] | nil, bymonthday: [integer] | nil, bymonth: [integer] | nil, wkst: string | nil }
function M.parse_rrule(s)
  local r = {}
  for part in gmatch(s, "[^;]+") do
    local key, val = match(part, "^([^=]+)=(.*)$")
    if key and val then
      key = key:upper()
      if key == "FREQ" then
        r.freq = val:upper()
      elseif key == "INTERVAL" then
        r.interval = tonumber(val)
      elseif key == "COUNT" then
        r.count = tonumber(val)
      elseif key == "UNTIL" then
        r["until"] = M.parse_datetime(val) or val
      elseif key == "WKST" then
        r.wkst = val:upper()
      elseif key == "BYDAY" then
        r.byday = {}
        for day in gmatch(val, "[^,]+") do
          insert(r.byday, day:upper())
        end
      elseif key == "BYMONTHDAY" then
        r.bymonthday = {}
        for d in gmatch(val, "[^,]+") do
          insert(r.bymonthday, tonumber(d))
        end
      elseif key == "BYMONTH" then
        r.bymonth = {}
        for mo in gmatch(val, "[^,]+") do
          insert(r.bymonth, tonumber(mo))
        end
      elseif key == "BYHOUR" then
        r.byhour = {}
        for h in gmatch(val, "[^,]+") do insert(r.byhour, tonumber(h)) end
      elseif key == "BYMINUTE" then
        r.byminute = {}
        for m in gmatch(val, "[^,]+") do insert(r.byminute, tonumber(m)) end
      elseif key == "BYSECOND" then
        r.bysecond = {}
        for sec in gmatch(val, "[^,]+") do insert(r.bysecond, tonumber(sec)) end
      elseif key == "BYSETPOS" then
        r.bysetpos = {}
        for p in gmatch(val, "[^,]+") do insert(r.bysetpos, tonumber(p)) end
      else
        r[key:lower()] = val
      end
    end
  end
  return r
end

--- Format an RRULE table back to string.
--: (unknown) -> string
function M.format_rrule(r)
  local parts = {}
  if r.freq     then insert(parts, "FREQ=" .. r.freq:upper()) end
  if r.interval then insert(parts, "INTERVAL=" .. r.interval) end
  if r.count    then insert(parts, "COUNT=" .. r.count) end
  if r["until"] then
    local u = r["until"]
    if type(u) == "table" then
      insert(parts, "UNTIL=" .. M.format_datetime(u))
    else
      insert(parts, "UNTIL=" .. u)
    end
  end
  if r.byday and #r.byday > 0 then
    insert(parts, "BYDAY=" .. concat(r.byday, ","))
  end
  if r.bymonthday and #r.bymonthday > 0 then
    insert(parts, "BYMONTHDAY=" .. concat(r.bymonthday, ","))
  end
  if r.bymonth and #r.bymonth > 0 then
    insert(parts, "BYMONTH=" .. concat(r.bymonth, ","))
  end
  if r.wkst then insert(parts, "WKST=" .. r.wkst:upper()) end
  return concat(parts, ";")
end

-- ---------------------------------------------------------------------------
-- Content-line parser
-- ---------------------------------------------------------------------------

--- Parse a single iCalendar content line (after unfolding).
-- Returns { name, params, value } or nil, errmsg.
--: (string) -> { name: string, params: { [string]: string }, value: string } | nil, string | nil
function M.parse_property(line)
  if not line or line == "" then return nil, "empty line" end

  -- Split name+params from value at first unescaped ':'
  -- Property name may have params: NAME;PARAM=VAL:value
  local colon_pos = find(line, ":", 1, true)
  if not colon_pos then
    return nil, "missing colon in property: " .. line
  end

  local name_part = sub(line, 1, colon_pos - 1)
  local value     = sub(line, colon_pos + 1)

  -- Parse name and parameters from name_part
  -- Format: NAME[;PARAM=value[;PARAM=value...]]
  local params = {}
  local name

  -- Split by semicolons, first token is the property name
  local tokens = {}
  -- We need to be careful: param values can be quoted strings containing semicolons
  local i = 1
  local current = {}
  local in_quote = false
  local nlen = len(name_part)
  while i <= nlen do
    local c = sub(name_part, i, i)
    if c == '"' then
      in_quote = not in_quote
      insert(current, c)
    elseif c == ";" and not in_quote then
      insert(tokens, concat(current))
      current = {}
    else
      insert(current, c)
    end
    i = i + 1
  end
  insert(tokens, concat(current))

  name = tokens[1] and tokens[1]:upper() or ""
  if name == "" then return nil, "empty property name" end

  for j = 2, #tokens do
    local tok = tokens[j]
    local eq = find(tok, "=", 1, true)
    if eq then
      local pname = sub(tok, 1, eq - 1):upper()
      local pval  = sub(tok, eq + 1)
      -- Strip surrounding quotes from param value
      if sub(pval, 1, 1) == '"' and sub(pval, -1) == '"' then
        pval = sub(pval, 2, -2)
      end
      params[pname] = pval
    else
      -- Boolean param (no value)
      params[tok:upper()] = true
    end
  end

  return { name = name, params = params, value = value }
end

-- ---------------------------------------------------------------------------
-- Content-line unfolding
-- ---------------------------------------------------------------------------

--- Unfold RFC 5545 content lines (CRLF + whitespace continuation).
--: (string) -> [string]
local function unfold_lines(s)
  -- Normalize line endings to \n
  s = gsub(s, "\r\n", "\n")
  s = gsub(s, "\r", "\n")
  -- Unfold: CRLF followed by a space or tab is a continuation
  s = gsub(s, "\n[ \t]", "")
  -- Split on newlines
  local lines = {}
  for line in gmatch(s, "[^\n]+") do
    insert(lines, line)
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Component parser helpers
-- ---------------------------------------------------------------------------

local DATETIME_PROPS = {
  DTSTART=true, DTEND=true, DUE=true, DTSTAMP=true,
  CREATED=true, ["LAST-MODIFIED"]=true, COMPLETED=true,
  RECURRENCE_ID=true, EXDATE=true, RDATE=true,
}

local function prop_key(name)
  -- Convert property name to a Lua-friendly field name
  return name:lower():gsub("-", "_")
end

--- Parse a datetime/date property value, honouring VALUE=DATE parameter.
local function parse_dt_prop(prop)
  local val = prop.value
  -- If VALUE=DATE param is set, parse as date only
  if prop.params and prop.params.VALUE == "DATE" then
    return M.parse_date(val)
  end
  return M.parse_datetime(val)
end

--- Parse a VALARM sub-component from a slice of lines [start_idx, end_idx].
local function parse_valarm(lines, start_idx, end_idx)
  local alarm = {}
  for i = start_idx, end_idx do
    local prop, err = M.parse_property(lines[i])
    if prop then
      local k = prop_key(prop.name)
      if prop.name == "TRIGGER" then
        alarm.trigger = prop.value
        if prop.params then alarm.trigger_params = prop.params end
      elseif prop.name == "ACTION" then
        alarm.action = prop.value:upper()
      elseif prop.name == "DESCRIPTION" then
        alarm.description = prop.value
      elseif prop.name == "SUMMARY" then
        alarm.summary = prop.value
      elseif prop.name == "DURATION" then
        alarm.duration = prop.value
      elseif prop.name == "REPEAT" then
        alarm.repeat_count = tonumber(prop.value)
      else
        alarm[k] = prop.value
      end
    end
  end
  return alarm
end

--- Parse a VEVENT or VTODO component from a slice of lines.
local function parse_component(lines, start_idx, end_idx, comp_type)
  local comp = { _alarms = {} }
  local i = start_idx
  while i <= end_idx do
    local line = lines[i]
    if line == "BEGIN:VALARM" then
      -- Find matching END:VALARM
      local alarm_start = i + 1
      local j = i + 1
      while j <= end_idx and lines[j] ~= "END:VALARM" do
        j = j + 1
      end
      insert(comp._alarms, parse_valarm(lines, alarm_start, j - 1))
      i = j + 1
    else
      local prop, err = M.parse_property(line)
      if prop then
        local k = prop_key(prop.name)
        if DATETIME_PROPS[prop.name] then
          local dt = parse_dt_prop(prop)
          if dt then comp[k] = dt end
          -- Preserve tzid if present
          if prop.params and prop.params.TZID then
            comp[k .. "_tzid"] = prop.params.TZID
          end
        elseif prop.name == "RRULE" then
          comp.rrule = M.parse_rrule(prop.value)
        elseif prop.name == "EXDATE" then
          if not comp.exdate then comp.exdate = {} end
          local dt = parse_dt_prop(prop)
          if dt then insert(comp.exdate, dt) end
        elseif prop.name == "RDATE" then
          if not comp.rdate then comp.rdate = {} end
          local dt = parse_dt_prop(prop)
          if dt then insert(comp.rdate, dt) end
        elseif prop.name == "CATEGORIES" then
          comp.categories = {}
          for cat in gmatch(prop.value, "[^,]+") do
            insert(comp.categories, cat)
          end
        elseif prop.name == "ATTENDEE" then
          if not comp.attendees then comp.attendees = {} end
          local att = { value = prop.value }
          if prop.params then
            for pk, pv in pairs(prop.params) do
              att[pk:lower()] = pv
            end
          end
          insert(comp.attendees, att)
        elseif prop.name == "ORGANIZER" then
          comp.organizer = { value = prop.value }
          if prop.params then
            for pk, pv in pairs(prop.params) do
              comp.organizer[pk:lower()] = pv
            end
          end
        else
          -- Store scalar props; VALUE param indicates type
          if prop.params and next(prop.params) ~= nil then
            -- Store params alongside value for extensibility
            comp[k] = prop.value
            comp[k .. "_params"] = prop.params
          else
            comp[k] = prop.value
          end
        end
      end
      i = i + 1
    end
  end
  -- Expose alarms as comp.alarms only if non-empty
  if #comp._alarms > 0 then
    comp.alarms = comp._alarms
  end
  comp._alarms = nil
  return comp
end

-- ---------------------------------------------------------------------------
-- Main parser
-- ---------------------------------------------------------------------------

--- Parse an iCalendar string into a calendar table.
--: (string) -> { version: string | nil, prodid: string | nil, calscale: string | nil, method: string | nil, events: unknown, todos: unknown, journals: unknown, freebusys: unknown, timezones: unknown } | nil, string | nil
function M.parse(s)
  if not s then return nil, "nil input" end

  local lines = unfold_lines(s)
  if #lines == 0 then return nil, "empty input" end

  -- Must start with BEGIN:VCALENDAR
  if lines[1]:upper() ~= "BEGIN:VCALENDAR" then
    return nil, "missing BEGIN:VCALENDAR"
  end

  local cal = {
    events    = {},
    todos     = {},
    journals  = {},
    freebusys = {},
    timezones = {},
  }

  local i = 2
  while i <= #lines do
    local line = lines[i]
    local upper = line:upper()

    if upper == "END:VCALENDAR" then
      break
    elseif upper:find("^BEGIN:VEVENT") then
      -- Find matching END:VEVENT
      local comp_start = i + 1
      local j = i + 1
      local depth = 1
      while j <= #lines do
        local ul = lines[j]:upper()
        if ul:find("^BEGIN:") then depth = depth + 1
        elseif ul:find("^END:VEVENT") then
          depth = depth - 1
          if depth == 0 then break end
        end
        j = j + 1
      end
      insert(cal.events, parse_component(lines, comp_start, j - 1, "VEVENT"))
      i = j + 1
    elseif upper:find("^BEGIN:VTODO") then
      local comp_start = i + 1
      local j = i + 1
      local depth = 1
      while j <= #lines do
        local ul = lines[j]:upper()
        if ul:find("^BEGIN:") then depth = depth + 1
        elseif ul:find("^END:VTODO") then
          depth = depth - 1
          if depth == 0 then break end
        end
        j = j + 1
      end
      insert(cal.todos, parse_component(lines, comp_start, j - 1, "VTODO"))
      i = j + 1
    elseif upper:find("^BEGIN:VJOURNAL") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VJOURNAL" do j = j + 1 end
      insert(cal.journals, parse_component(lines, comp_start, j - 1, "VJOURNAL"))
      i = j + 1
    elseif upper:find("^BEGIN:VFREEBUSY") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VFREEBUSY" do j = j + 1 end
      insert(cal.freebusys, parse_component(lines, comp_start, j - 1, "VFREEBUSY"))
      i = j + 1
    elseif upper:find("^BEGIN:VTIMEZONE") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VTIMEZONE" do j = j + 1 end
      insert(cal.timezones, parse_component(lines, comp_start, j - 1, "VTIMEZONE"))
      i = j + 1
    elseif upper:find("^BEGIN:") then
      -- Unknown component: skip
      local begin_name = match(upper, "^BEGIN:(.+)$")
      local j = i + 1
      while j <= #lines and not lines[j]:upper():find("^END:" .. begin_name) do
        j = j + 1
      end
      i = j + 1
    else
      -- Calendar-level property
      local prop = M.parse_property(line)
      if prop then
        local k = prop_key(prop.name)
        cal[k] = prop.value
      end
      i = i + 1
    end
  end

  return cal
end

-- ---------------------------------------------------------------------------
-- Line folding
-- ---------------------------------------------------------------------------

--- Fold a content line to max 75 octets per line (RFC 5545 §3.1).
-- Continuation lines begin with a single space.
--: (string) -> string
local function fold_line(line)
  -- RFC 5545: lines SHOULD NOT be longer than 75 octets (not characters).
  -- We fold at octet boundaries; for ASCII content this equals characters.
  if len(line) <= 75 then return line end
  local out = {}
  local pos = 1
  local first = true
  while pos <= len(line) do
    local chunk_len = first and 75 or 74
    -- Don't split a multi-byte UTF-8 sequence mid-byte
    local e = pos + chunk_len - 1
    if e >= len(line) then
      insert(out, sub(line, pos))
      break
    end
    -- Walk back from e until we're at a safe UTF-8 boundary
    while e > pos do
      local b = byte(line, e)
      -- If b is a continuation byte (10xxxxxx), step back
      if b >= 0x80 and b < 0xC0 then
        e = e - 1
      else
        break
      end
    end
    insert(out, sub(line, pos, e))
    pos = e + 1
    first = false
  end
  return concat(out, "\r\n ")
end

-- ---------------------------------------------------------------------------
-- Builder
-- ---------------------------------------------------------------------------

--- Escape special characters in iCalendar TEXT values.
--: (string) -> string
local function escape_text(s)
  s = gsub(s, "\\", "\\\\")
  s = gsub(s, ";", "\\;")
  s = gsub(s, ",", "\\,")
  s = gsub(s, "\n", "\\n")
  s = gsub(s, "\r\n", "\\n")
  return s
end

--- Unescape iCalendar TEXT values.
--: (string) -> string
function M.unescape_text(s)
  s = gsub(s, "\\n", "\n")
  s = gsub(s, "\\N", "\n")
  s = gsub(s, "\\,", ",")
  s = gsub(s, "\\;", ";")
  s = gsub(s, "\\\\", "\\")
  return s
end

--- Add a property line to a lines table, with optional parameters.
local function add_prop(lines, name, value, params)
  if value == nil then return end
  local parts = { name }
  if params then
    for k, v in pairs(params) do
      if v == true then
        insert(parts, ";" .. k)
      else
        -- Quote value if it contains special chars
        if find(tostring(v), "[;:,]") then
          insert(parts, ";" .. k .. '="' .. v .. '"')
        else
          insert(parts, ";" .. k .. "=" .. v)
        end
      end
    end
  end
  local prop_line = concat(parts) .. ":" .. tostring(value)
  insert(lines, fold_line(prop_line))
end

--- Add a datetime property (handles date-only vs date-time).
local function add_dt_prop(lines, name, dt, tzid)
  if not dt then return end
  local params = nil
  if tzid then
    params = { TZID = tzid }
  elseif dt.hour == nil then
    params = { VALUE = "DATE" }
  end
  add_prop(lines, name, M.format_datetime(dt), params)
end

--- Serialize a VEVENT component to lines.
local function event_to_lines(ev)
  local lines = { "BEGIN:VEVENT" }
  add_prop(lines, "UID",         ev.uid)
  add_dt_prop(lines, "DTSTART",  ev.dtstart,  ev.dtstart_tzid)
  add_dt_prop(lines, "DTEND",    ev.dtend,    ev.dtend_tzid)
  add_dt_prop(lines, "DTSTAMP",  ev.dtstamp,  ev.dtstamp_tzid)
  add_dt_prop(lines, "CREATED",  ev.created)
  add_dt_prop(lines, "LAST-MODIFIED", ev.last_modified)
  add_prop(lines, "SUMMARY",     ev.summary and escape_text(ev.summary))
  add_prop(lines, "DESCRIPTION", ev.description and escape_text(ev.description))
  add_prop(lines, "LOCATION",    ev.location and escape_text(ev.location))
  add_prop(lines, "STATUS",      ev.status)
  add_prop(lines, "TRANSP",      ev.transp)
  add_prop(lines, "CLASS",       ev.class)
  add_prop(lines, "PRIORITY",    ev.priority)
  add_prop(lines, "SEQUENCE",    ev.sequence)
  add_prop(lines, "URL",         ev.url)
  add_prop(lines, "COMMENT",     ev.comment and escape_text(ev.comment))
  if ev.rrule then
    add_prop(lines, "RRULE", M.format_rrule(ev.rrule))
  end
  if ev.exdate then
    for _, dt in ipairs(ev.exdate) do
      add_dt_prop(lines, "EXDATE", dt)
    end
  end
  if ev.rdate then
    for _, dt in ipairs(ev.rdate) do
      add_dt_prop(lines, "RDATE", dt)
    end
  end
  if ev.categories and #ev.categories > 0 then
    add_prop(lines, "CATEGORIES", concat(ev.categories, ","))
  end
  if ev.organizer then
    add_prop(lines, "ORGANIZER", ev.organizer.value or ev.organizer,
      ev.organizer.cn and { CN = ev.organizer.cn } or nil)
  end
  if ev.attendees then
    for _, att in ipairs(ev.attendees) do
      local params = {}
      for k, v in pairs(att) do
        if k ~= "value" then params[k:upper()] = v end
      end
      add_prop(lines, "ATTENDEE", att.value, next(params) ~= nil and params or nil)
    end
  end
  -- VALARM sub-components
  if ev.alarms then
    for _, alarm in ipairs(ev.alarms) do
      insert(lines, "BEGIN:VALARM")
      add_prop(lines, "ACTION",      alarm.action)
      if alarm.trigger then
        add_prop(lines, "TRIGGER", alarm.trigger, alarm.trigger_params)
      end
      add_prop(lines, "DESCRIPTION", alarm.description and escape_text(alarm.description))
      add_prop(lines, "SUMMARY",     alarm.summary and escape_text(alarm.summary))
      add_prop(lines, "DURATION",    alarm.duration)
      if alarm.repeat_count then
        add_prop(lines, "REPEAT", alarm.repeat_count)
      end
      insert(lines, "END:VALARM")
    end
  end
  insert(lines, "END:VEVENT")
  return lines
end

--- Serialize a VTODO component to lines.
local function todo_to_lines(td)
  local lines = { "BEGIN:VTODO" }
  add_prop(lines, "UID",         td.uid)
  add_dt_prop(lines, "DTSTART",  td.dtstart)
  add_dt_prop(lines, "DUE",      td.due)
  add_dt_prop(lines, "COMPLETED", td.completed)
  add_dt_prop(lines, "DTSTAMP",  td.dtstamp)
  add_dt_prop(lines, "CREATED",  td.created)
  add_dt_prop(lines, "LAST-MODIFIED", td.last_modified)
  add_prop(lines, "SUMMARY",     td.summary and escape_text(td.summary))
  add_prop(lines, "DESCRIPTION", td.description and escape_text(td.description))
  add_prop(lines, "STATUS",      td.status)
  add_prop(lines, "PRIORITY",    td.priority)
  add_prop(lines, "PERCENT-COMPLETE", td.percent_complete)
  add_prop(lines, "CLASS",       td.class)
  add_prop(lines, "URL",         td.url)
  add_prop(lines, "COMMENT",     td.comment and escape_text(td.comment))
  if td.categories and #td.categories > 0 then
    add_prop(lines, "CATEGORIES", concat(td.categories, ","))
  end
  if td.rrule then
    add_prop(lines, "RRULE", M.format_rrule(td.rrule))
  end
  if td.alarms then
    for _, alarm in ipairs(td.alarms) do
      insert(lines, "BEGIN:VALARM")
      add_prop(lines, "ACTION",      alarm.action)
      if alarm.trigger then
        add_prop(lines, "TRIGGER", alarm.trigger, alarm.trigger_params)
      end
      add_prop(lines, "DESCRIPTION", alarm.description and escape_text(alarm.description))
      insert(lines, "END:VALARM")
    end
  end
  insert(lines, "END:VTODO")
  return lines
end

-- ---------------------------------------------------------------------------
-- Calendar builder
-- ---------------------------------------------------------------------------

--- Create a new calendar builder.
--: ({ prodid: string | nil, version: string | nil, calscale: string | nil, method: string | nil } | nil) -> unknown
function M.calendar(opts)
  opts = opts or {}
  local cal = {
    _version  = opts.version  or "2.0",
    _prodid   = opts.prodid   or "-//crescent//ical//EN",
    _calscale = opts.calscale,
    _method   = opts.method,
    _events   = {},
    _todos    = {},
    _timezones = {},
  }

  --- Add a VEVENT to this calendar.
  function cal:add_event(ev)
    insert(self._events, ev)
    return self
  end

  --- Add a VTODO to this calendar.
  function cal:add_todo(td)
    insert(self._todos, td)
    return self
  end

  --- Serialize the calendar to an iCalendar string.
  function cal:to_string()
    local lines = {}
    insert(lines, "BEGIN:VCALENDAR")
    add_prop(lines, "VERSION",  self._version)
    add_prop(lines, "PRODID",   self._prodid)
    if self._calscale then add_prop(lines, "CALSCALE", self._calscale) end
    if self._method   then add_prop(lines, "METHOD",   self._method)   end
    for _, ev in ipairs(self._events) do
      for _, l in ipairs(event_to_lines(ev)) do insert(lines, l) end
    end
    for _, td in ipairs(self._todos) do
      for _, l in ipairs(todo_to_lines(td)) do insert(lines, l) end
    end
    insert(lines, "END:VCALENDAR")
    -- RFC 5545 requires CRLF line endings
    return concat(lines, "\r\n") .. "\r\n"
  end

  return cal
end

return M
