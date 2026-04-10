-- lib/remark_toc/remark_toc_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remark = require("lib.unified.remark")
local toc    = require("lib.unified.remark_toc")
local mdast  = require("lib.unified.mdast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Parse md, apply toc transformer, return root children.
local function transform(md, opts)
  local proc = remark():use(toc, opts)
  local ast  = proc:parse(md)
  local out, err = proc:run(ast)
  if not out then error(err) end
  return out.children
end

-- Find the first list node in children (immediately after the marker heading).
local function first_list(children)
  for i = 1, #children do
    if children[i].type == "list" then return children[i], i end
  end
  return nil
end

-- Collect link URLs from a list node (depth-first, returns flat list).
local function collect_urls(list_node)
  local urls = {}
  local function walk(node)
    if node.type == "link" then
      urls[#urls + 1] = node.url
    end
    if node.children then
      for i = 1, #node.children do walk(node.children[i]) end
    end
  end
  walk(list_node)
  return urls
end

-- Collect link texts from a list node (depth-first, returns flat list).
local function collect_texts(list_node)
  local texts = {}
  local function walk(node)
    if node.type == "link" then
      -- text is first child of link
      local ch = node.children and node.children[1]
      texts[#texts + 1] = ch and ch.value or ""
    end
    if node.children then
      for i = 1, #node.children do walk(node.children[i]) end
    end
  end
  walk(list_node)
  return texts
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("remark_toc", function()

  T.it("inserts a list after the TOC heading", function()
    local md = [[
# Document

## Table of Contents

## Introduction

## Getting Started
]]
    local children = transform(md)
    -- Find marker heading index
    local marker_idx
    for i = 1, #children do
      if children[i].type == "heading" then
        local node = children[i]
        local text = (node.children and node.children[1] and node.children[1].value) or ""
        if text:lower() == "table of contents" then
          marker_idx = i
          break
        end
      end
    end
    T.ok(marker_idx ~= nil, "marker heading found")
    local next_node = children[marker_idx + 1]
    T.ok(next_node ~= nil, "node inserted after marker")
    T.eq(next_node.type, "list")
  end)

  T.it("produces correct link URLs for each subsequent heading", function()
    local md = [[
## Table of Contents

## Introduction

## Getting Started
]]
    local children = transform(md)
    local list = first_list(children)
    T.ok(list ~= nil, "list node present")
    local urls = collect_urls(list)
    T.eq(urls[1], "#introduction")
    T.eq(urls[2], "#getting-started")
  end)

  T.it("uses heading text as link text", function()
    local md = [[
## Table of Contents

## Hello World

## Foo Bar
]]
    local children = transform(md)
    local list = first_list(children)
    local texts = collect_texts(list)
    T.eq(texts[1], "Hello World")
    T.eq(texts[2], "Foo Bar")
  end)

  T.it("nests h3 under h2", function()
    local md = [[
## Table of Contents

## Introduction

### Step 1

### Step 2

## Conclusion
]]
    local children = transform(md)
    local list = first_list(children)
    T.ok(list ~= nil, "list present")
    -- Top-level items: Introduction, Conclusion
    T.eq(#list.children, 2)
    local intro_item = list.children[1]
    -- intro_item should have a paragraph and a nested list
    local nested_list = nil
    for i = 1, #intro_item.children do
      if intro_item.children[i].type == "list" then
        nested_list = intro_item.children[i]
        break
      end
    end
    T.ok(nested_list ~= nil, "nested list under Introduction")
    T.eq(#nested_list.children, 2)  -- Step 1, Step 2
    local urls = collect_urls(nested_list)
    T.eq(urls[1], "#step-1")
    T.eq(urls[2], "#step-2")
  end)

  T.it("returns ast unchanged when no TOC heading present", function()
    local md = [[
## Introduction

## Getting Started
]]
    local children = transform(md)
    local list = first_list(children)
    T.ok(list == nil, "no list inserted when no TOC heading")
  end)

  T.it("matches custom heading pattern", function()
    local md = [[
## Contents Here

## Alpha

## Beta
]]
    local children = transform(md, { heading = "contents here" })
    local list = first_list(children)
    T.ok(list ~= nil, "list inserted with custom heading")
    local urls = collect_urls(list)
    T.eq(urls[1], "#alpha")
    T.eq(urls[2], "#beta")
  end)

  T.it("respects opts.min_depth (excludes shallower headings)", function()
    local md = [[
## Table of Contents

## TopLevel

### SubLevel
]]
    -- min_depth=3 → only h3 included
    local children = transform(md, { min_depth = 3 })
    local list = first_list(children)
    T.ok(list ~= nil, "list present")
    local urls = collect_urls(list)
    T.eq(#urls, 1)
    T.eq(urls[1], "#sublevel")
  end)

  T.it("respects opts.max_depth (excludes deeper headings)", function()
    local md = [[
## Table of Contents

## Alpha

### Beta

#### Gamma
]]
    -- max_depth=3 → h4 excluded
    local children = transform(md, { max_depth = 3 })
    local list = first_list(children)
    local urls = collect_urls(list)
    -- Only Alpha and Beta
    T.eq(#urls, 2)
    T.eq(urls[1], "#alpha")
    T.eq(urls[2], "#beta")
  end)

  T.it("produces an ordered list when opts.ordered is true", function()
    local md = [[
## Table of Contents

## First

## Second
]]
    local children = transform(md, { ordered = true })
    local list = first_list(children)
    T.ok(list ~= nil, "list present")
    T.eq(list.ordered, true)
  end)

  T.it("headings before the TOC heading are not included", function()
    local md = [[
## Preamble

## Table of Contents

## After
]]
    local children = transform(md)
    local list = first_list(children)
    T.ok(list ~= nil, "list present")
    local urls = collect_urls(list)
    T.eq(#urls, 1)
    T.eq(urls[1], "#after")
  end)

  T.it("slugifies heading text correctly", function()
    local slugify = require("lib.unified.remark_toc").slugify
    T.eq(slugify("Hello World"),      "hello-world")
    T.eq(slugify("Foo  Bar"),         "foo-bar")
    T.eq(slugify("  Leading space"),  "leading-space")
    T.eq(slugify("trailing "),        "trailing")
    T.eq(slugify("Special!@#Chars"),  "special-chars")
    T.eq(slugify("already-fine"),     "already-fine")
  end)

  T.it("matches 'toc' and 'contents' by default", function()
    local function has_list(md)
      local children = transform(md)
      return first_list(children) ~= nil
    end
    T.ok(has_list("## TOC\n\n## A\n"),      "'toc' matches")
    T.ok(has_list("## Contents\n\n## A\n"), "'contents' matches")
    T.ok(has_list("## Table of Contents\n\n## A\n"), "'table of contents' matches")
  end)

end)
