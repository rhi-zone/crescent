# Coroutine Effects

Design exploration for typing Lua coroutines and the async/CPS pattern built on them. This is the one genuinely open area of the type system — not a resolved decision, but a map of the problem space.

## The Problem

Lua coroutines are the language's only concurrency primitive. They're used for two very different things:

**1. Simple producers/consumers** — coroutines that yield values of a fixed type:

```lua
-- Iterator that yields numbers
local function range(n)
  return coroutine.wrap(function()
    for i = 1, n do
      coroutine.yield(i)
    end
  end)
end

for i in range(10) do print(i) end
```

**2. Async/await via CPS** — coroutines that yield callback-registration thunks to a scheduler:

```lua
-- Async read: yield a thunk, scheduler resumes with result
local function async_read(fd)
  return coroutine.yield(function(resume)
    register_read_callback(fd, resume)
  end)
end

-- Sequential-looking async code:
local data = async_read(fd)       -- suspends, resumes with string
local parsed = json.decode(data)  -- continues after data arrives
local count = db_query(parsed.id) -- suspends again, resumes with number
```

Pattern 1 is straightforward to type. Pattern 2 is where it gets hard.

## Level 1: Simple Coroutine Types

Parameterize the coroutine type with three types:

```lua
Coroutine<Yield, Send, Return>
```

- `Yield` — type of values passed to `coroutine.yield()`
- `Send` — type of values passed to `coroutine.resume(co, value)` (returned from `yield`)
- `Return` — type of the coroutine's final return value

```lua
-- Producer: yields strings, receives nothing, returns nothing
--: () -> Coroutine<string, nil, nil>
local function lines(filename)
  return coroutine.create(function()
    for line in io.lines(filename) do
      coroutine.yield(line)
    end
  end)
end

-- Bidirectional: yields strings, receives numbers, returns number
--: () -> Coroutine<string, number, number>
local function accumulator()
  return coroutine.create(function()
    local sum = 0
    while true do
      local n = coroutine.yield("waiting")
      if not n then return sum end
      sum = sum + n
    end
  end)
end
```

`coroutine.resume` and `coroutine.wrap` are typed accordingly:

```lua
--: <Y, S, R> (Coroutine<Y, S, R>, S?) -> (boolean, Y | R)
coroutine.resume

--: <Y, S, R> (() -> Coroutine<Y, S, R>) -> ((S?) -> Y | R)
coroutine.wrap
```

**This covers:** iterators, simple producers, bidirectional channels.

**This doesn't cover:** async/CPS, where each yield point has a different type.

Prior art: TypeScript's `Generator<Yield, Return, Next>`, Python's `Generator[YieldType, SendType, ReturnType]`, Rust's `Generator<Resume, Yield, Return>` trait.

## Level 2: The Async Problem

The CPS async pattern yields a callback thunk and receives the async result:

```lua
local data = coroutine.yield(function(resume)
  register_read_callback(fd, resume)  -- resume(string)
end)
-- data: string

local count = coroutine.yield(function(resume)
  db_query("SELECT count(*)", resume)  -- resume(number)
end)
-- count: number
```

Each yield has type `((T) -> ()) -> ()` for a different `T`. The `Send` type changes at each yield point. `Coroutine<Yield, Send, Return>` with fixed types can't express this — you'd need `Send = string | number | ...` which loses the per-yield-point precision.

The type error you want to catch:

```lua
local data = async_read(fd)     -- data should be string
local n = data + 1              -- ERROR if data is any, OK if data is string
```

With fixed `Coroutine<ThunkType, any, R>`, the `data` would be `any` — the checker gives up. The whole point of typing is lost.

## Level 3: Effect Types

Effects model "what a function might do" as part of its type. An async function doesn't just return a value — it performs the `Async` effect:

```
effect Async {
  await: <T> (Future<T>) -> T
}
```

A function that uses `await` has the `Async` effect in its type:

```lua
--: (fd: number) -> string ! Async
local function read_all(fd)
  local chunks = {}
  while true do
    local chunk = await(async_read(fd))  -- Async effect
    if not chunk then break end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end
```

The `! Async` annotation says: this function performs the Async effect. A caller must either:
- Also be in an Async context (propagate the effect)
- Handle the effect (be a scheduler/event loop)

**Effect handlers** are the schedulers:

```lua
-- The event loop "handles" the Async effect
--: <T> (() -> T ! Async) -> T
local function run(f)
  local co = coroutine.create(f)
  -- ... scheduler loop that resumes co when futures resolve ...
end
```

**Key property:** each `await` call has its own type `T`, inferred from the `Future<T>` argument. No loss of precision. The checker knows `async_read(fd)` returns `Future<string>`, so `await(async_read(fd))` is `string`.

## The Design Space

### Do we need full algebraic effects?

Algebraic effects are general — they model async, exceptions, state, nondeterminism, and more. But Lua only uses coroutines for a few patterns:

| Pattern | Needs |
|---------|-------|
| Iterators | `Coroutine<Y, nil, nil>` — Level 1 is enough |
| Bidirectional channels | `Coroutine<Y, S, R>` — Level 1 is enough |
| Async/CPS | Per-yield typing — Level 2/3 needed |
| pcall/error | Already modeled as `never` return + narrowing |

The question: is async/CPS common enough to justify effect types, or can we get away with a simpler approach?

In crescent's ecosystem: `lib/http/server`, `lib/websocket`, `lib/dns` — the async pattern is everywhere. It's *the* concurrency model. So yes, it needs proper typing.

### Approach A: Effect types (Koka/OCaml 5 style)

Full algebraic effects with handlers. Most general, most complex.

```lua
--: (fd: number) -> string ! Async
--: <T> (() -> T ! Async) -> T           -- handler
```

Pros:
- Per-yield-point typing (each await has its own T)
- Composable effects (Async + Logger + State)
- Effect handlers are first-class
- Future-proof for patterns we haven't thought of

Cons:
- Significant type system complexity
- Inference for effects is hard (effect polymorphism, row effects)
- Prior art (Koka, OCaml 5) is still relatively young
- Learning curve

### Approach B: Async-only typing

Don't generalize. Just type the async pattern specifically:

```lua
--: async (fd: number) -> string
local function read_all(fd)
  local chunk = await(async_read(fd))  -- typed via Future<T>
  ...
end
```

`async` is a function modifier, not a general effect. `await` is a keyword/builtin that unwraps `Future<T>`. No effect system, just async/sync distinction.

Pros:
- Simple — one concept (async functions) not a general effect system
- Easy to explain: async functions yield to a scheduler, that's it
- Covers the primary use case

Cons:
- Doesn't generalize to other coroutine patterns
- Bidirectional channels and custom yield protocols need separate handling
- If we later need effects, this might not be forward-compatible

### Approach C: Parameterized coroutines + async sugar

Level 1 (`Coroutine<Y, S, R>`) for general coroutines. Special `async`/`await` sugar that desugars to typed coroutines for the CPS pattern:

```lua
-- General coroutine (explicit types):
--: () -> Coroutine<string, nil, nil>
local function lines(f) ... end

-- Async sugar (desugars to coroutine + scheduler protocol):
--: async (fd: number) -> string
local function read_all(fd)
  local data = await(async_read(fd))
  ...
end
```

The `async` annotation means: this function's coroutine follows the CPS protocol. `await` is typed via the `Future<T>` argument. General coroutines keep their explicit `Coroutine<Y, S, R>` types.

Pros:
- Pragmatic — covers both patterns
- No effect system needed
- `async`/`await` is well-understood from other languages
- General coroutines are still supported with explicit types

Cons:
- Two mechanisms (general coroutines + async sugar) instead of one unified concept
- `async` is a special case, not composable with other effects
- May paint us into a corner if effects are needed later

### Approach D: Defer

Type coroutines as `Coroutine<any, any, any>` (Level 0.5). Every yield/resume crosses an `any` boundary with a warning. Async code works but is untyped.

This is what the checker does today. It's honest — we don't have a design, so we say `any`. Users who want typed async code add annotations at the boundary.

Pros:
- Ship now, design later
- No wrong decisions to undo
- Coroutine-heavy code gets `any` warnings, flagging where typing is needed

Cons:
- The most common concurrency pattern in the ecosystem is untyped
- `any` warnings everywhere in async code is noisy

## Prior Art

- **Koka** (2012–present): algebraic effects with handlers, effect rows, full inference. The gold standard for effect types. Research language, but the type theory is proven.
- **OCaml 5** (2022): algebraic effects landed in OCaml. Typed via the existing type system + `Effect.t` type. Still maturing.
- **Eff** (2012): research language, pure algebraic effects. Cleaner semantics than Koka but less practical.
- **TypeScript generators**: `Generator<Yield, Return, Next>` — three fixed type params. Covers Level 1. Async is separate (`async`/`await` with `Promise<T>`).
- **Python typing**: `Generator[YieldType, SendType, ReturnType]` and `AsyncGenerator`. Same approach as TS — fixed params for sync, separate async.
- **Rust**: `Generator` trait (unstable), `async`/`await` with `Future<Output>`. Async is desugared to state machines, not coroutines.
- **Lua libraries**: cosock, copas, OpenResty — all use the CPS-over-coroutines pattern. None have type systems.

## Open Questions

- **Which approach?** A (full effects), B (async-only), C (coroutines + async sugar), or D (defer)? The answer depends on how much complexity the type system can absorb. C is the pragmatic sweet spot. A is the theoretically right answer. D is honest.
- **Effect polymorphism.** If we go with effects, functions that don't care whether they're async should be polymorphic over the effect. `map(f, list)` works whether `f` is async or not. This requires effect polymorphism (row polymorphism over effects), which is hard to infer.
- **Scheduler protocol.** The CPS pattern assumes a specific protocol (yield a thunk, receive the result). Different schedulers might have different protocols. Can the type system abstract over the protocol?
- **Interaction with pcall.** `pcall(f)` catches errors. If `f` is async, does `pcall` interact with the effect? `pcall` in a coroutine that yields is already tricky in Lua — the type system needs to model this correctly.
- **Coloring problem.** Async functions can only be called from async contexts. This is the "function coloring" problem. Effect systems solve it via effect polymorphism. Simpler approaches (B, C) accept the coloring as a feature, not a bug.
- **Syntax.** `! Effect` suffix? `async` keyword? Both? Where do effect annotations go in the `--:` syntax?
