# Typeclass Design

Crescent implements typeclass-style dispatch using tables as keys. This avoids the
problems with other approaches:

- **Metamethod dispatch** (`__add`, `__concat`) — operators are scarce and have existing
  semantic expectations; can't be stolen for general typeclass dispatch.
- **Method dispatch** (`:append`) — method names collide when a value implements multiple
  typeclasses that define the same method name.
- **Explicit instance passing** (`fold(Sum, list)`) — verbose at every call site; the
  caller has to know and pass the instance everywhere.

## The Pattern

Each typeclass is a table. Values that implement a typeclass store their implementation
at `value[Typeclass]`. Typeclass functions look up the implementation on the value
internally — the caller passes the value, not the instance.

```lua
local Monoid = {}

-- fold: given a monoid value and a list, combine all elements.
function Monoid.fold(value, list)
    local impl = value[Monoid]
    local acc = impl.empty()
    for _, v in ipairs(list) do
        acc = impl.append(acc, v)
    end
    return acc
end
```

### Instances

```lua
local Sum = {}

function Sum.new(n)
    return setmetatable({ value = n }, {
        __index = {
            [Monoid] = {
                empty   = function() return Sum.new(0) end,
                append  = function(a, b) return Sum.new(a.value + b.value) end,
            }
        }
    })
end

local Product = {}

function Product.new(n)
    return setmetatable({ value = n }, {
        __index = {
            [Monoid] = {
                empty   = function() return Product.new(1) end,
                append  = function(a, b) return Product.new(a.value * b.value) end,
            }
        }
    })
end
```

Usage:

```lua
local nums = { Sum.new(1), Sum.new(2), Sum.new(3) }
local result = Monoid.fold(nums[1], nums)  -- Sum(6)

local prods = { Product.new(2), Product.new(3), Product.new(4) }
local result2 = Monoid.fold(prods[1], prods)  -- Product(24)
```

No instance passed at the call site. `Monoid.fold` dispatches via `value[Monoid]`.
Two typeclasses with a method named `append` don't collide — they live at different
keys on the value.

## Numbers

Numbers in Lua cannot have metatables, so `Sum(42)` must be a wrapper table, not a
bare number. The wrapper is lightweight — just `{ value = n }` with a metatable — but
it is a real allocation. This is unavoidable without runtime support for primitive
metatables.

For pure numeric pipelines where allocation matters, the practical alternative is to
use explicit monoid functions directly (`sum`, `product`) rather than the generic
`Monoid.fold`. The typeclass abstraction is for code that needs to be generic over the
monoid; concrete code that knows it's summing doesn't need it.

## No Naming Convention Required

The typeclass table itself is the key — not a string name. There is no convention like
`@types/foo` or `__monoid__`. Two libraries that both define a `Monoid` typeclass would
have different table identities and would not be compatible — which is correct. A shared
`Monoid` definition should come from a shared library (`lib/fp/monoid`).

## Multiple Typeclasses

A value can implement multiple typeclasses without collision:

```lua
-- value[Monoid] = { append, empty }
-- value[Functor] = { map }
-- value[Foldable] = { fold }
-- all at different keys, no pollution
```

A function generic over `Functor` calls `value[Functor].map(...)`. A function generic
over `Monoid` calls `value[Monoid].append(...)`. They compose cleanly.
