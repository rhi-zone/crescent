local mod = {}

--[[@alias type_ {type:"integer"|"number"|"string"|"boolean"|"nil"}]]
--[[@alias type_type "integer"|"number"|"string"|"boolean"|"tuple"|"struct"|"struct_exact"|"array"|"dictionary"|"optional"]]

-- Schema<T> wraps a value type T as a nominal opaque type.
-- Two Schema<T> values with the same T are the same type; Schema<T> and Schema<U>
-- with different T/U are distinct and incompatible. The underlying T is accessible
-- through unwrap operations but Schema itself is not structurally matchable.
--:: Schema<T> = $Opaque<T>

-- UnwrapField maps a $EachField descriptor whose value is Schema<V> to a
-- descriptor with bare value V, used by struct/tuple constructors to strip the
-- Schema wrapper from each field so the output struct type holds plain values.
--:: UnwrapField<F> = match F {
--::   { key: K, value: { __schema: V }, optional: O, readonly: R } => { key: K, value: V, optional: O, readonly: R },
--:: }

mod.integer = ({ type = "integer" } --[[: any]]) --[[: Schema<integer>]]
mod.number  = ({ type = "number"  } --[[: any]]) --[[: Schema<number>]]
mod.string  = ({ type = "string"  } --[[: any]]) --[[: Schema<string>]]
mod.boolean = ({ type = "boolean" } --[[: any]]) --[[: Schema<boolean>]]
mod["nil"]  = ({ type = "nil"     } --[[: any]]) --[[: Schema<nil>]]

--: <T>(T) -> Schema<T>
mod.literal = function(value) return { type = "literal", value = value } --[[: any]] end

--: <T: {}>(T) -> Schema<$EachField<T, UnwrapField>>
mod.tuple = function(shape) return { type = "tuple", shape = shape } --[[: any]] end

--: <T: {}>(T) -> Schema<$EachField<T, UnwrapField>>
mod.struct = function(shape) return { type = "struct", shape = shape } --[[: any]] end

--: <T: {}>(T) -> Schema<$EachField<T, UnwrapField>>
mod.struct_exact = function(shape) return { type = "struct_exact", shape = shape } --[[: any]] end

mod.array = (function(item) return { type = "array", item = item } end) --[[: <T>(Schema<T>) -> Schema<T[]>]]

mod.dictionary = (function(key, value) return { type = "dictionary", key = key, value = value } end) --[[: <K, V>(Schema<K>, Schema<V>) -> Schema<{ [K]: V }>]]

mod.optional = (function(t) return { type = "optional", inner = t } end) --[[: <T>(Schema<T>) -> Schema<T | nil>]]

mod.any_of = (function(t, u, v, w, x, y, z, a, ...) return { type = "any_of", types = { t, u, v, w, x, y, z, a, ... } } end) --[[: <T, U, V, W, X, Y, Z, A, B>(Schema<T>, Schema<U> | nil, Schema<V> | nil, Schema<W> | nil, Schema<X> | nil, Schema<Y> | nil, Schema<Z> | nil, Schema<A> | nil, ...Schema<B>) -> Schema<T | U | V | W | X | Y | Z | A | B>]]

-- NOTE: all_of should return an intersection type; not yet expressible.
mod.all_of = (function(t, ...) return { type = "all_of", types = { t, ... } } end) --[[: <T>(Schema<T>, ...unknown) -> Schema<T>]]

local unwrap = (function(t) return (t --[[: any]]).shape end) --[[: <T>(Schema<T>) -> T]]
mod._unwrap_struct       = unwrap
mod._unwrap_tuple        = unwrap
mod._unwrap_struct_exact = unwrap

return mod
