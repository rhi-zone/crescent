if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- embed(sheet, css_mod) — takes a stylesheet (from css.stylesheet(...)) and
-- the css module itself (passed in to avoid circular require), then:
--   1. Renders the stylesheet to a CSS string
--   2. Wraps it in a <style> block
--   3. Collects all ClassName values from top-level simple class-selector rules
-- Returns: style_block (string), classes (table mapping name -> ClassName)
--
-- Only top-level rules with a single class selector (._str matching "^%.[%w_%-]+$")
-- contribute to the classes table. Media-wrapped rules and complex selectors are
-- rendered but not exposed as typed class names (they appear in the style block
-- regardless).
--
--: (sheet: { items: { [integer]: { _type: string, selector: unknown, ... } }, ... }, css_mod: { render: (unknown) -> string, class: (string) -> unknown, ... }) -> (string, { [string]: unknown })
function M.embed(sheet, css_mod)
  local css_text = css_mod.render(sheet)
  local style_block = "<style>\n" .. css_text .. "\n</style>"

  local classes = {}
  for _, item in ipairs(sheet.items) do
    if item._type == "rule" then
      local sel = item.selector
      local sel_str = type(sel) == "table" and sel._str or tostring(sel)
      -- Extract class name from simple class selectors like ".btn"
      local name = sel_str:match("^%.([%w_%-]+)$")
      if name then
        classes[name] = css_mod.class(name)
      end
    end
  end

  return style_block, classes
end

return M
