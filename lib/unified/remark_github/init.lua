-- lib/unified/remark_github/init.lua
-- remark plugin: auto-link GitHub references in text nodes.
-- Port of remark-github.
--
-- Supported references:
--   #123              → https://github.com/{repo}/issues/123
--   a5c3785 (7-40 hex) → https://github.com/{repo}/commit/a5c3785
--   @user             → https://github.com/user
--   user/repo#123     → https://github.com/user/repo/issues/123
--   user/repo@a5c3785 → https://github.com/user/repo/commit/a5c3785
--
-- Options:
--   opts.repo           — "owner/repo" string (required for #123 and bare commit SHAs)
--   opts.mentionStrong  — boolean, wrap @user in <strong> (default true)
--
-- Usage:
--   local remark       = require("lib.unified.remark")
--   local remarkGithub = require("lib.unified.remark_github")
--   local processor    = remark():use(remarkGithub, { repo = "owner/repo" })
--   local ast          = processor:run(processor:parse(src))

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Node constructors ─────────────────────────────────────────────────────────

local function text_node(value)
  return { type = "text", value = value }
end

local function link_node(url, label)
  return { type = "link", url = url, children = { text_node(label) } }
end

local function strong_node(child)
  return { type = "strong", children = { child } }
end

-- ── Pattern scanner ───────────────────────────────────────────────────────────

-- Patterns (anchored to start via manual scanning):
--   cross-repo commit: word/word@hexsha  (try before cross-repo issue so @ wins over #)
--   cross-repo issue:  word/word#digits
--   bare commit sha:   7-40 hex chars (word boundary)
--   bare issue:        #digits
--   mention:           @word

-- Returns pos of first pattern match and a "kind" string, or nil.
-- We scan character by character finding the earliest match start.

local SHA_MIN = 7
local SHA_MAX = 40

-- Try to match a hex SHA starting at position `i` in `s`.
-- Returns end position (inclusive) if match of length SHA_MIN..SHA_MAX, else nil.
--: (string, integer) -> integer | nil
local function match_sha(s, i)
  local j = i
  local len = #s
  while j <= len and j - i < SHA_MAX do
    local b = s:byte(j) or 0
    if (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70) then
      j = j + 1
    else
      break
    end
  end
  local sha_len = j - i
  if sha_len < SHA_MIN then return nil end
  -- Must not be followed by another hex char (word boundary).
  if j <= len then
    local b = s:byte(j) or 0
    if (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70) then
      return nil
    end
  end
  return j - 1  -- inclusive end
end

-- Returns true if character at position i-1 (before i) is a word char.
--: (string, integer) -> boolean
local function preceded_by_word(s, i)
  if i <= 1 then return false end
  local b = s:byte(i - 1) or 0
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end

-- Match a GitHub username/repo name segment starting at i (alphanumeric + - + _).
-- Returns end pos (inclusive) or nil.
--: (string, integer) -> integer | nil
local function match_name_seg(s, i)
  local j = i
  local len = #s
  while j <= len do
    local b = s:byte(j) or 0
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 95 then
      j = j + 1
    else
      break
    end
  end
  if j == i then return nil end
  return j - 1
end

-- Scan `s` starting at offset `start` (1-based) for the earliest GitHub reference.
-- Returns: start_pos, end_pos, kind, data  OR nil
-- kind: "issue", "commit", "mention", "cross_issue", "cross_commit"
-- data: table with relevant fields
--: (string, integer, string | nil, boolean) -> (integer | nil, integer, string, { num: string, user: string, owner: string, repo: string, sha: string, ... })
local function find_next(s, start, repo, allow_bare)
  local len = #s
  local best_start = len + 1
  local best_end, best_kind, best_data

  local i = start
  while i <= len do
    local b = s:byte(i) or 0

    -- '#' → bare issue #123 or start of cross-repo (handled below)
    if b == 35 and allow_bare and repo then  -- '#'
      if not preceded_by_word(s, i) then
        -- match digits
        local j = i + 1
        while j <= len and (s:byte(j) or 0) >= 48 and (s:byte(j) or 0) <= 57 do j = j + 1 end
        local num_len = j - i - 1
        if num_len > 0 then
          local num = s:sub(i + 1, j - 1)
          if i < best_start then
            best_start = i
            best_end   = j - 1
            best_kind  = "issue"
            best_data  = { num = num }
          end
        end
      end

    -- '@' → mention
    elseif b == 64 then  -- '@'
      if not preceded_by_word(s, i) then
        local name_end = match_name_seg(s, i + 1)
        if name_end then
          if i < best_start then
            best_start = i
            best_end   = name_end
            best_kind  = "mention"
            best_data  = { user = s:sub(i + 1, name_end) }
          end
        end
      end

    -- letter or digit → possible cross-repo ref or bare commit
    elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
      if not preceded_by_word(s, i) then
        -- try cross-repo: owner/repo#N or owner/repo@SHA
        local owner_end = match_name_seg(s, i)
        if owner_end and owner_end + 1 <= len and (s:byte(owner_end + 1) or 0) == 47 then  -- '/'
          local repo_start = owner_end + 2
          local repo_end   = match_name_seg(s, repo_start)
          if repo_end then
            local next_pos = repo_end + 1
            if next_pos <= len then
              local nc = s:byte(next_pos) or 0
              if nc == 35 then  -- '#' → cross issue
                local j = next_pos + 1
                while j <= len and (s:byte(j) or 0) >= 48 and (s:byte(j) or 0) <= 57 do j = j + 1 end
                local num_len = j - next_pos - 1
                if num_len > 0 then
                  local num = s:sub(next_pos + 1, j - 1)
                  if i < best_start then
                    best_start = i
                    best_end   = j - 1
                    best_kind  = "cross_issue"
                    best_data  = {
                      owner = s:sub(i, owner_end),
                      repo  = s:sub(repo_start, repo_end),
                      num   = num,
                    }
                  end
                end
              elseif nc == 64 then  -- '@' → cross commit
                local sha_end = match_sha(s, next_pos + 1)
                if sha_end then
                  if i < best_start then
                    best_start = i
                    best_end   = sha_end
                    best_kind  = "cross_commit"
                    best_data  = {
                      owner = s:sub(i, owner_end),
                      repo  = s:sub(repo_start, repo_end),
                      sha   = s:sub(next_pos + 1, sha_end),
                    }
                  end
                end
              end
            end
          end
        end

        -- try bare commit sha (only if repo available)
        if allow_bare and repo then
          local sha_end = match_sha(s, i)
          if sha_end and i < best_start then
            best_start = i
            best_end   = sha_end
            best_kind  = "commit"
            best_data  = { sha = s:sub(i, sha_end) }
          end
        end
      end
    end

    -- If we found something before i+1, no need to continue past best_start.
    if best_start <= i then break end
    i = i + 1
  end

  if best_kind then
    return best_start, best_end, best_kind, best_data
  end
  return nil
end

-- ── Text node splitter ────────────────────────────────────────────────────────

local function split_text(value, repo, mention_strong)
  local nodes = {}
  local pos = 1
  local len = #value
  local allow_bare = (repo ~= nil)

  while pos <= len do
    local s, e, kind, data = find_next(value, pos, repo, allow_bare)
    if not s then
      -- No more matches; append remaining text.
      nodes[#nodes + 1] = text_node(value:sub(pos))
      break
    end

    -- Text before the match.
    if s > pos then
      nodes[#nodes + 1] = text_node(value:sub(pos, s - 1))
    end

    local label = value:sub(s, e)
    local url

    if kind == "issue" then
      url = "https://github.com/" .. repo .. "/issues/" .. data.num
      nodes[#nodes + 1] = link_node(url, label)

    elseif kind == "commit" then
      url = "https://github.com/" .. repo .. "/commit/" .. data.sha
      nodes[#nodes + 1] = link_node(url, label)

    elseif kind == "mention" then
      url = "https://github.com/" .. data.user
      local lnk = link_node(url, label)
      if mention_strong then
        nodes[#nodes + 1] = strong_node(lnk)
      else
        nodes[#nodes + 1] = lnk
      end

    elseif kind == "cross_issue" then
      url = "https://github.com/" .. data.owner .. "/" .. data.repo .. "/issues/" .. data.num
      nodes[#nodes + 1] = link_node(url, label)

    elseif kind == "cross_commit" then
      url = "https://github.com/" .. data.owner .. "/" .. data.repo .. "/commit/" .. data.sha
      nodes[#nodes + 1] = link_node(url, label)
    end

    pos = e + 1
  end

  -- Edge case: empty value.
  if #nodes == 0 then
    nodes[1] = text_node(value)
  end

  return nodes
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

-- Walk the tree; for any parent node, replace text-node children that contain
-- GitHub references with the expanded node list.
local function walk(node, repo, mention_strong)
  local children = node.children
  if not children then return end

  local new_children = {}
  local changed = false

  for i = 1, #children do
    local child = children[i]
    if child.type == "text" and child.value and #child.value > 0 then
      local parts = split_text(child.value, repo, mention_strong)
      if #parts == 1 and parts[1].type == "text" and parts[1].value == child.value then
        -- No change.
        new_children[#new_children + 1] = child
      else
        changed = true
        for _, p in ipairs(parts) do
          new_children[#new_children + 1] = p
        end
      end
    else
      new_children[#new_children + 1] = child
      -- Recurse into non-text children.
      walk(child, repo, mention_strong)
    end
  end

  if changed then
    node.children = new_children
    -- Recurse into newly-created link/strong nodes to handle nested text (none expected,
    -- but keeps the walk consistent).
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_github(processor, opts)
  local repo           = opts and opts.repo
  local mention_strong = (opts == nil or opts.mentionStrong == nil) and true
                         or (opts.mentionStrong ~= false)

  processor:use_transformer(function(tree)
    walk(tree, repo, mention_strong)
    return tree
  end)
end

M.plugin = remark_github

setmetatable(M, { __call = function(_, ...) return remark_github(...) end })

return M
