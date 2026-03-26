local mod = {}

--[[@alias type_ {type:"integer"|"number"|"string"|"boolean"|"nil"}]]
--[[@alias type_type "integer"|"number"|"string"|"boolean"|"tuple"|"struct"|"struct_exact"|"array"|"dictionary"|"optional"]]

-- Schema<T> is a phantom structural type. The __schema field carries T at the
-- type level only — it is never present at runtime. All schema constructors
-- return Schema<T> for the appropriate T; check/validate/coerce accept
-- Schema<T> and return T (or T?).
--:: Schema<T> = { __schema: T }

-- UnwrapField maps a $EachField descriptor whose value is Schema<V> to a
-- descriptor with value V. Used by struct/struct_exact/tuple to strip the
-- Schema wrapper from each field's type when building the output struct type.
--:: UnwrapField<F> = match F {
--::   { key: K, value: { __schema: V }, optional: O, readonly: R } => { key: K, value: V, optional: O, readonly: R },
--:: }

--[[@type Schema<integer>]]
--[[@diagnostic disable-next-line: assign-type-mismatch]]
mod.integer = { type = "integer" }
--[[@type Schema<number>]]
--[[@diagnostic disable-next-line: assign-type-mismatch]]
mod.number = { type = "number" }
--[[@type Schema<string>]]
--[[@diagnostic disable-next-line: assign-type-mismatch]]
mod.string = { type = "string" }
--[[@type Schema<boolean>]]
--[[@diagnostic disable-next-line: assign-type-mismatch]]
mod.boolean = { type = "boolean" }
--[[@type Schema<nil>]]
--[[@diagnostic disable-next-line: assign-type-mismatch]]
mod["nil"] = { type = "nil" }
--[[@generic T]]
--[[@return Schema<T>]]
--[[@param value T]]
mod.literal = function(value) return { type = "literal", value = value } end
--[[@generic T: {}]]
--[[@return Schema<$EachField<T, UnwrapField>>]]
--[[@param shape T]]
mod.tuple = function(shape) return { type = "tuple", shape = shape } end
--[[@generic T: {}]]
--[[@return Schema<$EachField<T, UnwrapField>>]]
--[[@param shape T]]
mod.struct = function(shape) return { type = "struct", shape = shape } end
--[[@generic T: {}]]
--[[@return Schema<$EachField<T, UnwrapField>>]]
--[[@param shape T]]
mod.struct_exact = function(shape) return { type = "struct_exact", shape = shape } end
--[[@generic T]]
--[[@return Schema<T[]>]]
--[[@param item Schema<T>]]
mod.array = function(item) return { type = "array", item = item } end
--[[@generic K, V]]
--[[@return Schema<table<K, V>>]]
--[[@param key Schema<K>]]
--[[@param value Schema<V>]]
mod.dictionary = function(key, value) return { type = "dictionary", key = key, value = value } end
--[[@generic T]]
--[[@return Schema<T?>]]
--[[@param t Schema<T>]]
mod.optional = function(t) return { type = "optional", inner = t } end
--[[@generic T, U, V, W, X, Y, Z, A, B]]
--[[@return Schema<T | U | V | W | X | Y | Z | A | B>]]
--[[@param t Schema<T>]]
--[[@param u? Schema<U>]]
--[[@param v? Schema<V>]]
--[[@param w? Schema<W>]]
--[[@param x? Schema<X>]]
--[[@param y? Schema<Y>]]
--[[@param z? Schema<Z>]]
--[[@param a? Schema<A>]]
--[[@param ... Schema<B>]]
mod.any_of = function(t, u, v, w, x, y, z, a, ...) return { type = "any_of", types = { t, u, v, w, x, y, z, a, ... } } end
--[[@generic T]]
--[[@return Schema<T>]]
--[[@param t Schema<T>]]
--[[@param ... unknown]]
--[[NOTE: all_of should return an intersection type; not yet expressible]]
mod.all_of = function(t, ...) return { type = "all_of", types = { t, ... } } end

--[[@generic T]]
--[[@return T]]
--[[@param t Schema<T>]]
--[[@diagnostic disable-next-line: undefined-field]]
local unwrap = function(t) return t.shape end
mod._unwrap_struct = unwrap
mod._unwrap_tuple = unwrap
mod._unwrap_struct_exact = unwrap

return mod
