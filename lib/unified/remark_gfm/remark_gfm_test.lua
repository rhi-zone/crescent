-- lib/remark_gfm/remark_gfm_test.lua
-- Tests for the remark_gfm GFM transformer plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remark = require("lib.unified.remark")
local gfm    = require("lib.unified.remark_gfm")

-- Shared processor: remark() + gfm plugin.
local proc = remark():use(gfm)

local function parse(src)
  local ast = proc:parse(src)
  return proc:run(ast)
end

local function first(ast)  return ast.children[1] end
local function child(node, ...) local n = node; for _, k in ipairs({...}) do n = n.children[k] end; return n end

-- ── Tables ────────────────────────────────────────────────────────────────────

T.describe("GFM tables", function()
  T.it("basic 3-column table produces table node", function()
    local ast = parse("| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |")
    local tbl = first(ast)
    T.eq(tbl.type, "table")
  end)

  T.it("table has header row and data row", function()
    local ast = parse("| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |")
    local tbl = first(ast)
    T.eq(#tbl.children, 2)
    T.eq(tbl.children[1].type, "tableRow")
    T.eq(tbl.children[2].type, "tableRow")
  end)

  T.it("table cells contain text nodes", function()
    local ast = parse("| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |")
    local tbl = first(ast)
    -- Header cells
    T.eq(child(tbl, 1, 1).type, "tableCell")
    T.eq(child(tbl, 1, 1, 1).value, "A")
    T.eq(child(tbl, 1, 2, 1).value, "B")
    T.eq(child(tbl, 1, 3, 1).value, "C")
    -- Data cells
    T.eq(child(tbl, 2, 1, 1).value, "1")
    T.eq(child(tbl, 2, 2, 1).value, "2")
    T.eq(child(tbl, 2, 3, 1).value, "3")
  end)

  T.it("table alignment: left, center, right", function()
    local ast = parse("| L | C | R |\n| :--- | :---: | ---: |\n| a | b | c |")
    local tbl = first(ast)
    T.eq(tbl.align[1], "left")
    T.eq(tbl.align[2], "center")
    T.eq(tbl.align[3], "right")
  end)

  T.it("table with no alignment markers produces nil align entries", function()
    local ast = parse("| A | B |\n| --- | --- |\n| 1 | 2 |")
    local tbl = first(ast)
    T.eq(tbl.align[1], nil)
    T.eq(tbl.align[2], nil)
  end)

  T.it("two-column table has correct cell count", function()
    local ast = parse("| Name | Value |\n| --- | --- |\n| foo | bar |")
    local tbl = first(ast)
    T.eq(#tbl.children[1].children, 2)
    T.eq(#tbl.children[2].children, 2)
  end)
end)

-- ── Strikethrough ─────────────────────────────────────────────────────────────

T.describe("GFM strikethrough", function()
  T.it("~~del~~ produces delete node in paragraph children", function()
    local ast = parse("Hello ~~world~~ end")
    local para = first(ast)
    T.eq(para.type, "paragraph")
    -- Should have: text "Hello ", delete, text " end"
    local del
    for _, n in ipairs(para.children) do
      if n.type == "delete" then del = n end
    end
    T.ok(del ~= nil, "expected a delete node")
    T.eq(del.children[1].type, "text")
    T.eq(del.children[1].value, "world")
  end)

  T.it("delete node has children", function()
    local ast = parse("~~strikethrough~~")
    local para = first(ast)
    local del
    for _, n in ipairs(para.children) do
      if n.type == "delete" then del = n end
    end
    T.ok(del ~= nil)
    T.eq(#del.children, 1)
    T.eq(del.children[1].value, "strikethrough")
  end)

  T.it("text before and after delete node is preserved", function()
    local ast = parse("before ~~mid~~ after")
    local para = first(ast)
    local found_before, found_after = false, false
    for _, n in ipairs(para.children) do
      if n.type == "text" and n.value == "before " then found_before = true end
      if n.type == "text" and n.value == " after"  then found_after  = true end
    end
    T.ok(found_before, "text before delete missing")
    T.ok(found_after,  "text after delete missing")
  end)
end)

-- ── Task lists ────────────────────────────────────────────────────────────────

T.describe("GFM task lists", function()
  T.it("- [x] done → listItem.checked == true", function()
    local ast = parse("- [x] done")
    local list = first(ast)
    T.eq(list.type, "list")
    local item = list.children[1]
    T.eq(item.checked, true)
  end)

  T.it("- [ ] todo → listItem.checked == false", function()
    local ast = parse("- [ ] todo")
    local list = first(ast)
    local item = list.children[1]
    T.eq(item.checked, false)
  end)

  T.it("- [X] done (uppercase X) → listItem.checked == true", function()
    local ast = parse("- [X] done")
    local list = first(ast)
    local item = list.children[1]
    T.eq(item.checked, true)
  end)

  T.it("regular list item has checked == nil", function()
    local ast = parse("- plain item")
    local list = first(ast)
    local item = list.children[1]
    T.eq(item.checked, nil)
  end)

  T.it("checkbox prefix is stripped from text content", function()
    local ast  = parse("- [x] done task")
    local item = first(ast).children[1]
    -- Find the text value inside the item (in a paragraph child or direct).
    local text_val
    for _, block in ipairs(item.children) do
      if block.type == "paragraph" then
        for _, inline in ipairs(block.children) do
          if inline.type == "text" then text_val = inline.value; break end
        end
      elseif block.type == "text" then
        text_val = block.value
      end
    end
    T.eq(text_val, "done task")
  end)

  T.it("mixed task and regular items", function()
    local ast  = parse("- [x] done\n- [ ] pending\n- normal")
    local list = first(ast)
    T.eq(list.children[1].checked, true)
    T.eq(list.children[2].checked, false)
    T.eq(list.children[3].checked, nil)
  end)
end)

-- ── Autolinks ─────────────────────────────────────────────────────────────────

T.describe("GFM autolinks", function()
  T.it("bare https URL in text produces link node", function()
    local ast  = parse("Visit https://example.com today")
    local para = first(ast)
    local lnk
    for _, n in ipairs(para.children) do
      if n.type == "link" then lnk = n end
    end
    T.ok(lnk ~= nil, "expected a link node")
    T.eq(lnk.url, "https://example.com")
  end)

  T.it("bare http URL produces link node", function()
    local ast  = parse("See http://example.org")
    local para = first(ast)
    local lnk
    for _, n in ipairs(para.children) do
      if n.type == "link" then lnk = n end
    end
    T.ok(lnk ~= nil)
    T.eq(lnk.url, "http://example.org")
  end)

  T.it("autolink children contain the URL as text", function()
    local ast  = parse("https://example.com")
    local para = first(ast)
    local lnk  = para.children[1]
    T.eq(lnk.type, "link")
    T.eq(lnk.children[1].type, "text")
    T.eq(lnk.children[1].value, "https://example.com")
  end)

  T.it("autolink title is nil", function()
    local ast = parse("https://example.com")
    local lnk = first(ast).children[1]
    T.eq(lnk.title, nil)
  end)

  T.it("text before and after autolink is preserved", function()
    local ast  = parse("Go to https://example.com now")
    local para = first(ast)
    local found_before, found_after = false, false
    for _, n in ipairs(para.children) do
      if n.type == "text" and n.value == "Go to " then found_before = true end
      if n.type == "text" and n.value == " now"   then found_after  = true end
    end
    T.ok(found_before, "text before autolink missing")
    T.ok(found_after,  "text after autolink missing")
  end)
end)
