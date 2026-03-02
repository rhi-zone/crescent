-- docs/sketches/schema.lua
-- Sketch: Zod-like schema library and its type-level counterpart.
-- Shows how match types + structural typing map runtime schemas to static types.
--
-- This is not runnable code — it's a design sketch for how the type system
-- would handle schema → type inference.

------------------------------------------------------------------------
-- Part 1: The schema library (runtime)
------------------------------------------------------------------------

-- Each schema constructor returns a table tagged with a kind.
-- The typechecker infers precise literal types for the kind field,
-- which match types can then dispatch on.

local S = {}

function S.string()
    return { kind = "string" }
    -- inferred: { kind: "string" }
end

function S.number()
    return { kind = "number" }
    -- inferred: { kind: "number" }
end

function S.boolean()
    return { kind = "boolean" }
    -- inferred: { kind: "boolean" }
end

function S.integer()
    return { kind = "integer" }
    -- inferred: { kind: "integer" }
end

function S.literal(value)
    --: <T: string | number | boolean>(T) -> { kind: "literal", value: T }
    return { kind = "literal", value = value }
end

function S.optional(inner)
    --: <T: Schema>(T) -> { kind: "optional", inner: T }
    return { kind = "optional", inner = inner }
end

function S.array(inner)
    --: <T: Schema>(T) -> { kind: "array", inner: T }
    return { kind = "array", inner = inner }
end

function S.object(fields)
    --: <T: { [string]: Schema }>(T) -> { kind: "object", fields: T }
    return { kind = "object", fields = fields }
end

function S.union(...)
    --: <...T: Schema>(...T) -> { kind: "union", members: [...T] }
    return { kind = "union", members = { ... } }
end

------------------------------------------------------------------------
-- Part 2: The type-level mapping (annotations)
------------------------------------------------------------------------

-- The key question: given a schema value's TYPE, what is the corresponding
-- VALUE type that it validates?
--
-- In TypeScript/Zod: z.infer<typeof schema>
-- Here: Infer<typeof schema> using match types.

--:: Schema = { kind: "string" }
--::        | { kind: "number" }
--::        | { kind: "boolean" }
--::        | { kind: "integer" }
--::        | { kind: "literal", value: any }
--::        | { kind: "optional", inner: Schema }
--::        | { kind: "array", inner: Schema }
--::        | { kind: "object", fields: { [string]: Schema } }
--::        | { kind: "union", members: { [number]: Schema } }

-- The core match type: map schema type → value type
--:: Infer<T> = match T {
--::   { kind: "string" }              => string,
--::   { kind: "number" }              => number,
--::   { kind: "boolean" }             => boolean,
--::   { kind: "integer" }             => integer,
--::   { kind: "literal", value: V }   => V,
--::   { kind: "optional", inner: I }  => Infer<I>?,
--::   { kind: "array", inner: I }     => { [number]: Infer<I> },
--::   { kind: "object", fields: F }   => InferFields<F>,
--::   { kind: "union", members: M }   => InferUnionMembers<M>,
--:: }

-- Map a table of schema fields → table of value fields.
-- Each field's schema is replaced by its inferred value type.
--:: InferField<F> = match F {
--::   { key: K, value: V } => { key: K, value: Infer<V> },
--:: }
--:: InferFields<F> = $EachField<F, InferField>

-- Map an array of schema members → union of inferred types.
-- M[number] is indexed access: given M: { [number]: Schema }, it extracts the
-- element type (union of all element types for a tuple). Then Infer distributes
-- over the union — each member matches a different arm of the match type.
--
-- Indexed access is itself derivable from match types:
--   T[K] = match T { { [K]: V } => V }
-- So it's sugar, not a new primitive.
--:: InferUnionMembers<M> = Infer<M[number]>

------------------------------------------------------------------------
-- Part 3: Usage — how it feels
------------------------------------------------------------------------

local user_schema = S.object({
    name = S.string(),
    age = S.optional(S.number()),
    role = S.literal("admin"),
})
-- typeof user_schema:
--   { kind: "object", fields: {
--       name: { kind: "string" },
--       age: { kind: "optional", inner: { kind: "number" } },
--       role: { kind: "literal", value: "admin" },
--   } }
--
-- Infer<typeof user_schema>:
--   { name: string, age: number?, role: "admin" }

-- The check function validates at runtime and narrows the type:
function S.check(schema, data)
    --: <T: Schema>(T, any) -> Infer<T>
    -- runtime validation here...
    return data --[[as! Infer<T>]]
end

-- At the call site:
local raw = get_json_body()  --: any
local user = S.check(user_schema, raw)
-- user: { name: string, age: number?, role: "admin" }
-- Type is inferred from the schema, no annotation needed at the call site.

------------------------------------------------------------------------
-- Part 4: Composition — transforms on schemas
------------------------------------------------------------------------

-- Partial schema: make all fields optional
function S.partial(schema)
    --: <T: { kind: "object", fields: F }>(T) -> { kind: "object", fields: PartialFields<F> }
    -- runtime: wrap each field schema in S.optional
end

--:: MakeOptionalSchema<F> = match F {
--::   { key: K, value: V } => { key: K, value: { kind: "optional", inner: V } },
--:: }
--:: PartialFields<F> = $EachField<F, MakeOptionalSchema>

-- Pick: keep only named fields
function S.pick(schema, ...)
    --: <T: { kind: "object", fields: F }, K: string>(T, ...K) -> { kind: "object", fields: Pick<F, K> }
end

-- Usage: PATCH endpoint
local patch_schema = S.partial(S.pick(user_schema, "name", "age"))
-- Infer<typeof patch_schema>: { name?: string, age?: number }

------------------------------------------------------------------------
-- Part 5: What the constraint solver does
------------------------------------------------------------------------

-- When the checker sees:
--   local user = S.check(user_schema, raw)
--
-- It generates constraints:
--   T = typeof user_schema                           (from argument 1)
--   T : Schema                                       (from param constraint)
--   return type = Infer<T>                            (from return annotation)
--
-- Solving:
--   T unifies with the inferred type of user_schema
--   Infer<T> reduces via match rules:
--     T.kind = "object" → match arm 8 → InferFields<T.fields>
--     For each field in T.fields:
--       name: Infer<{ kind: "string" }> → match arm 1 → string
--       age: Infer<{ kind: "optional", inner: { kind: "number" } }>
--            → match arm 6 → Infer<{ kind: "number" }>?
--            → match arm 2 → number?
--       role: Infer<{ kind: "literal", value: "admin" }>
--            → match arm 5 → "admin"
--   Result: { name: string, age: number?, role: "admin" }
--
-- All of this is constraint propagation. The match type reductions
-- are rule applications that generate new unification constraints.
-- No separate evaluation engine.

return S
