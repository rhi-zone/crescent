if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Split text into words on whitespace. Collapses multiple spaces unless
-- preserve_spaces is set (but we still split on whitespace boundaries).
local function split_words(text)
  local words = {}
  for w in text:gmatch("%S+") do
    words[#words + 1] = w
  end
  return words
end

-- Greedy (first-fit) line wrapping.
-- Returns array of line strings.
-- opts.break_long_words = true  (break words longer than width)
-- opts.preserve_spaces = false  (currently ignored — always collapses)
function M.greedy(text, width, opts)
  opts = opts or {}
  local break_long = opts.break_long_words or false
  local words = split_words(text)
  if #words == 0 then return {} end

  local lines = {}
  local current = ""
  local current_len = 0

  local function flush()
    if current ~= "" then
      lines[#lines + 1] = current
      current = ""
      current_len = 0
    end
  end

  for _, word in ipairs(words) do
    local wlen = #word

    -- Handle words longer than width
    if break_long and wlen > width then
      -- Flush current line first
      flush()
      -- Break the long word into chunks
      local pos = 1
      while pos <= wlen do
        -- How much space is left on the current line?
        local space = (current_len == 0) and width or (width - current_len - 1)
        if space <= 0 then
          flush()
          space = width
        end
        local chunk = word:sub(pos, pos + space - 1)
        if current_len == 0 then
          current = chunk
          current_len = #chunk
        else
          current = current .. " " .. chunk
          current_len = current_len + 1 + #chunk
        end
        pos = pos + space
        if current_len >= width then
          flush()
        end
      end
    else
      -- Normal word
      if current_len == 0 then
        current = word
        current_len = wlen
      elseif current_len + 1 + wlen <= width then
        current = current .. " " .. word
        current_len = current_len + 1 + wlen
      else
        flush()
        current = word
        current_len = wlen
      end
    end
  end

  flush()
  return lines
end

-- Optimal (Knuth-Plass simplified) line wrapping via DP.
-- Minimizes sum of squared slack on non-last lines.
-- Returns array of line strings.
function M.optimal(text, width, opts)
  opts = opts or {}
  local words = split_words(text)
  local n = #words
  if n == 0 then return {} end

  -- Precompute word lengths
  local wlen = {}
  for i, w in ipairs(words) do
    wlen[i] = #w
  end

  -- cost[i] = minimum total raggedness to wrap words[1..i]
  -- break[i] = j such that words[j+1..i] are on the last segment
  local INF = math.huge
  local cost = {}
  local brk = {}

  cost[0] = 0

  for i = 1, n do
    cost[i] = INF
    brk[i] = 0
    -- Try line containing words[j+1 .. i]
    local line_len = 0
    for j = i, 1, -1 do
      -- Add word j to the front of this candidate line
      if j == i then
        line_len = wlen[i]
      else
        line_len = line_len + 1 + wlen[j]  -- +1 for space
      end
      if line_len > width then break end
      local slack = width - line_len
      -- If this is the last line (j == 1 implies words 1..i), cost for last line = 0
      -- We treat a segment as the last only when j==1 (starts from beginning) but
      -- we don't know that here; we use cost[j-1] + segment_cost(j,i)
      -- For the last line: if j-1 == 0, segment cost = 0
      local seg_cost = (j == 1) and 0 or (slack * slack)
      local total = cost[j - 1] + seg_cost
      if total < cost[i] then
        cost[i] = total
        brk[i] = j - 1  -- last word of previous segment
      end
    end
    -- If we couldn't fit even a single word, force it
    if cost[i] == INF then
      cost[i] = cost[i - 1] + (width * width)
      brk[i] = i - 1
    end
  end

  -- Backtrack to find line boundaries
  local breaks = {}
  local pos = n
  while pos > 0 do
    breaks[#breaks + 1] = pos
    pos = brk[pos]
  end

  -- Reverse and build lines
  local lines = {}
  local prev = 0
  for k = #breaks, 1, -1 do
    local last = breaks[k]
    local parts = {}
    for i = prev + 1, last do
      parts[#parts + 1] = words[i]
    end
    lines[#lines + 1] = table.concat(parts, " ")
    prev = last
  end

  return lines
end

-- Measure raggedness (sum of squared slack) for a wrapping.
-- The last line is excluded from the sum (as per Knuth-Plass convention).
function M.raggedness(lines, width)
  local total = 0
  for i = 1, #lines - 1 do
    local slack = width - #lines[i]
    total = total + slack * slack
  end
  return total
end

-- Wrap a paragraph preserving newlines.
-- Each \n-delimited segment is wrapped independently.
-- Returns a single string with \n between lines.
function M.paragraph(text, width, opts)
  local segments = {}
  -- Split on newlines
  for seg in (text .. "\n"):gmatch("([^\n]*)\n") do
    segments[#segments + 1] = seg
  end
  local result_lines = {}
  for _, seg in ipairs(segments) do
    local wrapped = M.greedy(seg, width, opts)
    if #wrapped == 0 then
      result_lines[#result_lines + 1] = ""
    else
      for _, line in ipairs(wrapped) do
        result_lines[#result_lines + 1] = line
      end
    end
  end
  return table.concat(result_lines, "\n")
end

-- Count words in text.
function M.count_words(text)
  local n = 0
  for _ in text:gmatch("%S+") do n = n + 1 end
  return n
end

-- Count non-whitespace characters.
function M.count_chars(text)
  local n = 0
  for _ in text:gmatch("%S") do n = n + 1 end
  return n
end

-- Justify lines: pad spaces between words so each line is exactly width chars.
-- The last line is left-aligned (not justified).
-- Returns array of justified line strings.
function M.justify(lines, width)
  local result = {}
  for i, line in ipairs(lines) do
    if i == #lines then
      -- Last line: left-aligned
      result[#result + 1] = line
    else
      local words = {}
      for w in line:gmatch("%S+") do words[#words + 1] = w end
      if #words <= 1 then
        -- Single word: left-align
        result[#result + 1] = line
      else
        local total_word_len = 0
        for _, w in ipairs(words) do total_word_len = total_word_len + #w end
        local gaps = #words - 1
        local total_spaces = width - total_word_len
        local base_space = math.floor(total_spaces / gaps)
        local extra = total_spaces - base_space * gaps
        local parts = {}
        for j, w in ipairs(words) do
          parts[#parts + 1] = w
          if j < #words then
            local sp = base_space + (j <= extra and 1 or 0)
            parts[#parts + 1] = string.rep(" ", sp)
          end
        end
        result[#result + 1] = table.concat(parts)
      end
    end
  end
  return result
end

-- Center a line within width (pad with spaces on both sides).
function M.center(line, width)
  local len = #line
  if len >= width then return line end
  local total_pad = width - len
  local left_pad = math.floor(total_pad / 2)
  local right_pad = total_pad - left_pad
  return string.rep(" ", left_pad) .. line .. string.rep(" ", right_pad)
end

-- Left-pad a line to width (right-align).
function M.pad_left(line, width)
  local len = #line
  if len >= width then return line end
  return string.rep(" ", width - len) .. line
end

-- Truncate text with ellipsis if it exceeds width.
-- ellipsis defaults to "..."
function M.truncate(text, width, ellipsis)
  ellipsis = ellipsis or "..."
  if #text <= width then return text end
  local cut = width - #ellipsis
  if cut <= 0 then
    -- ellipsis itself is too long; just truncate hard
    return ellipsis:sub(1, width)
  end
  return text:sub(1, cut) .. ellipsis
end

-- Full pipeline: wrap text then join with newlines.
function M.wrap(text, width, opts)
  local lines = M.greedy(text, width, opts)
  return table.concat(lines, "\n")
end

return M
