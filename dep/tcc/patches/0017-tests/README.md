# Assembler macro and conditional test cases (for `0017-asm-macro-and-conditional-directives.patch`)

Assembly inputs for `.macro`/`.endm` and `.if`/`.elseif`/`.else`/`.endif`,
plus a harness that diffs a tcc build's `.text` against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Accepted cases are compared byte-for-byte. What is under test — which arm was
taken, how many times a body expanded, what an argument turned into — is
exactly what `.text` ends up containing, and every file is straight-line so no
branch-form freedom is left for the assemblers to differ within. The bodies
avoid `addq $imm, %reg` and `shr $1`, forms where tcc legitimately picks a
longer encoding than gas; that difference is pre-existing, unrelated, and
would only obscure what these cases are for.

| case | what it pins down |
|---|---|
| `t0_conditionals` | conditionals alone, before macros enter: `.elseif` chains, `.else`, `%`/`==`/`<` expressions, a conditional inside a taken arm and inside a skipped one (the skip has to match `.endif` to `.if`, not stop at the first `.endif`) |
| `t1_macros` | zero, one and two parameters; `\name` in operand position, in an expression, and as a whole register operand |
| `t2_macro_conditional` | the shape the s2n-bignum sources use: a body branching on arithmetic over its own parameters, so each invocation assembles a different arm — the case that needs the two directives to compose |
| `t3_macro_nested` | a body invoking another macro and passing its own parameter through |
| `t4_macro_relaxed` | expansion in a unit that needs a second layout pass, the same capture-suppression question patch `0016` settles for `.rept` |
| `t5_macro_in_rept` | a macro invoked from inside `.rept`, and `.rept` inside a macro body — the two replay mechanisms nested, both ways round |
| `n0_endif_without_if` | `.endif` with nothing open |
| `n1_unterminated_if` | a conditional left open at end of file |
| `n2_unknown_parameter` | `\b` where the macro has no parameter `b` |
| `n3_macro_redefined` | the same macro defined twice in one unit |
| `n4_too_many_args` | more arguments at a call site than the macro has parameters |
| `u0_parameter_default` | `\name=value` — a real GAS feature, not implemented here |
| `u1_expansion_counter` | `\@`, GAS's per-expansion counter |
| `u2_stray_endm` | `.endm` with no `.macro` open |

The three categories answer different questions. `n*` are inputs GNU `as`
itself rejects, and tcc must too — a macro system that quietly accepted a
malformed definition would pass every positive case above. `u*` are inputs
GNU `as` **accepts** and this tcc deliberately does not; what is asserted is
that each is refused with a diagnostic rather than misread, since the failure
that matters is silently assembling something nobody wrote. Treating `a=5` as
a parameter named `a` would make every call site relying on the default expand
to nothing at all, and quietly.

`u2_stray_endm` is a strictness difference rather than a missing feature: GNU
`as` warns and carries on, this tcc errors. A file containing a stray `.endm`
is malformed either way.

Also not implemented, and not represented as a case because tcc's behaviour on
it is not a clean refusal: GAS's `<...>`-quoted macro arguments, which let an
argument contain a comma. Arguments here split on every top-level comma, which
is GAS's behaviour for unquoted arguments. Recorded in TODO.md.

Against the `0001`–`0016` baseline the same harness reports `pass=8 fail=6`:
all six `t*` cases fail with `unknown opcode '.macro'` or `'.if'`, and the
`n*`/`u*` cases pass for the wrong reason — the directives do not exist there,
so everything containing one is rejected.
