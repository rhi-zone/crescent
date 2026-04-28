-- lib/platform/apps/system_dashboard/projections/example_text.lua
-- Example projection: render a Text primitive as a styled span.
--
-- Authored against the typed environment in projection_types.lua. Transpiled
-- to JS via lib/lua2ts (with harden = true) and registered at runtime as a
-- handler for the "text" shape tag.
--
-- This file is the smallest possible thing that exercises:
--   - typed `value` parameter (Text variant of Primitive)
--   - typed `ctx` parameter (unused here, but accepted)
--   - dom.<tag>(props, children) constructor call
--   - prop record literal
--   - string child passthrough
-- It serves as the typecheck + transpile fixture for projection_types_test.

--: (Text, Ctx) -> Element
local function project_text(value, ctx)
    local class_name = "text"
    if value.style then
        class_name = "text text-" .. value.style
    end
    return dom.span({ class = class_name }, { value.text })
end

return project_text
