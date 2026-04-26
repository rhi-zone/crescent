# lib/css Design Document

Version: 1.0 (Phase 1)

## Overview

`lib/css` is a type-safe CSS builder library for LuaJIT. It provides a constructor-based API for building selectors, rules, and stylesheets in pure Lua — no string interpolation, no magic syntax, no templating. The output is a deterministic CSS string.

The library is structured in five phases, each independently useful:

- **Phase 1** (this document): Core type machinery, selector DSL, rule and stylesheet builder, renderer.
- **Phase 2**: Keyframe animations — `@keyframes` blocks with named stops.
- **Phase 3**: Media queries — `@media` rules with logical operators.
- **Phase 4**: CSS custom property tooling — `var()` scope analysis, `@property` declarations.
- **Phase 5**: Integration with `lib/html` — typed style injection, scoped class generation.

---

## Phase 1 Detail

### Parameterized-newtype type machinery

CSS names — class names, IDs, CSS variable names, animation names — are all strings at runtime, but conflating them produces bugs (passing a class name where a variable name is expected, for example). The standard solution is nominal types.

The typechecker supports `--:: newtype Foo = string`, which creates a distinct nominal type that is structurally `string` but not assignable to plain `string` without a cast. At runtime, values are plain Lua strings — zero overhead, fully vendorable.

The constructors (`css.class`, `css.id`, `css.var`, `css.anim`, `css.keyframe`) are identity functions annotated to accept `string` and return the nominal type. This is the cast point: the caller passes a plain string once at the call site; from that point the type system tracks the name as its specific kind.

`css.var` is the one constructor with a runtime assertion: it checks that the name starts with `--`, since CSS custom property names are required to begin with two hyphens. This is a programmer error (wrong name format), so it throws (`error()`), not returns `(nil, errmsg)`.

`css.varref` turns a `CssVar` name into a `var(--name)` reference string, typed as `CssVarRef`.

`css.declare` is a batch constructor. It takes a spec table with `classes`, `ids`, `vars`, and `anims` sub-tables and applies the appropriate constructor to each value, returning a structured record. This is the idiomatic way to define a design system's token set.

### API shape

**Constructors:**

```lua
local css = require("lib.css")
local btn   = css.class("btn")          -- ClassName
local root  = css.id("root")            -- IdName
local brand = css.var("--brand")        -- CssVar (asserts "--" prefix)
local slide = css.anim("slide-in")      -- AnimationName
local ref   = css.varref(brand)         -- "var(--brand)"
```

**Batch constructor (`css.declare`):**

```lua
local S = css.declare {
  classes = { btn = "btn", card = "card" },
  ids     = { root = "root" },
  vars    = { brand = "--brand", radius = "--radius" },
  anims   = { slide_in = "slide-in" },
}
-- S.classes.btn == "btn", S.vars.brand == "--brand", etc.
```

**Selector DSL:**

Selectors are tables with a `_str` field (the CSS selector string) and combinator methods. The DSL is compositional — every method returns a new selector.

```lua
local sel = css.sel
sel.class("btn")                          -- .btn
sel.id("root")                            -- #root
sel.tag("div")                            -- div
sel.universal()                           -- *
sel.class("btn"):desc(sel.tag("span"))    -- .btn span
sel.class("btn"):child(sel.id("root"))    -- .btn > #root
sel.tag("h1"):adjacent(sel.tag("p"))      -- h1 + p
sel.tag("h1"):sibling(sel.tag("p"))       -- h1 ~ p
sel.class("btn"):and_(sel.class("primary")) -- .btn.primary
sel.class("btn"):pseudo("hover")          -- .btn:hover
sel.tag("input"):attr("disabled")         -- input[disabled]
sel.tag("input"):attr_eq("type", "text")  -- input[type="text"]
sel.list(sel.tag("h1"), sel.tag("h2"))    -- h1, h2
```

`and_` uses a trailing underscore because `and` is a Lua keyword.

**Stylesheet builder:**

```lua
local rule  = css.rule(selector, { color = "white", background_color = "blue" })
local sheet = css.stylesheet({ rule1, rule2, ... })
local css_string = css.render(sheet)
```

Property keys use snake_case in Lua (`background_color`) and are converted to kebab-case (`background-color`) on render. CSS variable keys (starting with `--`) are left as-is.

**Renderer:**

- `css.render_selector(s)` — converts a selector object or string to its CSS string.
- `css.render_decls(decls)` — renders a declarations block (sorted for determinism).
- `css.render_rule(rule)` — renders a complete rule block.
- `css.render(sheet)` — renders a full stylesheet, rules separated by blank lines.

---

## Phase 2 — Keyframe animations

Files: `lib/css/keyframes.lua`.

`css.keyframe_rule(name, stops)` where `stops` is a table mapping `"from"/"to"/percentage` strings to declaration tables. `css.render_keyframes(kf)` renders the `@keyframes name { ... }` block. Integration: `css.anim()` constructor types the name; `animation-name` property accepts `AnimationName`.

---

## Phase 3 — Media queries

Files: `lib/css/media.lua`.

`css.media(query, items)` constructs a `@media` rule. The query DSL covers `min-width`/`max-width`, `prefers-color-scheme`, `orientation`, and logical operators (`and_`, `or_`, `not_`). `css.render` extended to handle `_type = "media"` items.

---

## Phase 4 — CSS custom property tooling

Files: `lib/css/property.lua`.

`css.property(name, opts)` renders `@property` declarations (syntax, inherits, initial-value). Scope analysis: given a stylesheet and a set of `CssVar` names, report which rules declare vs. reference each variable. Useful for detecting undefined or unused variables at build time.

---

## Phase 5 — lib/html integration

Files: `lib/css/scoped.lua`.

Typed style injection into `lib/html` elements. Scoped class generation: given a stylesheet, emit a `<style>` block and return a record of typed `ClassName` values for use with `lib/html` element builders. Eliminates the class-name string scatter that `lib/html/html_builder.lua`'s `mod.style` currently requires.
