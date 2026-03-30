# Tuple Type Syntax

## Grammar

```
tuple_type ::= "(" ")"                                          -- empty tuple (zero elements)
             | "(" type_expr "," ")"                            -- 1-tuple (trailing comma)
             | "(" type_expr ("," type_expr)+ ("," "..." name)? ")"  -- N-tuple (N >= 2)
             | "(" "..." name ")"                               -- spread-only tuple
```

The trailing comma after a single element distinguishes a 1-tuple from a parenthesized
(grouped) type expression:

| Syntax   | Meaning               |
|----------|-----------------------|
| `(T)`    | grouping — same as T  |
| `(T,)`   | 1-tuple               |
| `(T, U)` | 2-tuple               |
| `()`     | empty tuple (0 elements) |

## Motivation

1-tuple syntax is needed wherever a uniform "zero or more elements" return type is
required. The primary use case is `$EachField`'s F aliases, where F always returns a
tuple of field descriptors:

- `()` — drop this field (zero descriptors)
- `(D,)` — emit this field unchanged (one descriptor)
- `(D1, D2)` — expand to two fields (two descriptors)

Without trailing-comma 1-tuples, there is no way to write "exactly one element" as a
tuple — `(D)` would be parsed as grouping.

## Relation to `...` spread

`(A, ...R)` (spread in last position) and `(T,)` (1-tuple) are orthogonal:

- `(T,)` is a static 1-tuple literal
- `(A, ...R)` is a tuple with a dynamic tail — `...R` splices R's elements at evaluation
  time (see docs/spread-in-tuple-position-spec.md)

A 1-tuple with a spread: `(...R,)` = `(...R)` — both mean "spread R into a tuple." The
trailing comma is redundant here but not an error.

## Implementation

In `ann.lua` `parse_tuple`: after parsing one type expression, if the next token is `,`
followed by `)`, consume both and return a 1-element TAG_TUPLE. This check happens before
the general N >= 2 path.
