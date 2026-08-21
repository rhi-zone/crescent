# `$` immediates through a macro (for `0013-asm-macro-body-dollar-lexing.patch`)

Assembly inputs where a `$` immediate is reached through a preprocessor macro
in a `.S` file, plus a harness that diffs a tcc build's output against real GNU
`as`.

    ./run.sh /path/to/patched/tcc

The reference side is `gcc -x assembler-with-cpp` rather than bare `as`, since
`as` does not preprocess. tcc is invoked directly on the `.S` file so its
integrated preprocessor is what runs — feeding it `tcc -E` output first would
assemble already-expanded text and step around the thing under test.

## What the bug was

`parse_define()` clears `PARSE_FLAG_ASM_FILE` while tokenizing a `#define`, so
that `#` stays the stringize operator instead of becoming a line comment. But
the lexer decides `$` is a plain token from that same flag, not from the
identifier table. So for the duration of every `#define` in a `.S` file, `$`
became an identifier character and `$5` lexed as **one identifier token**.

Two different failures follow, and only one of them is loud:

- shift and rotate opcodes require an 8-bit immediate, so the operand — now an
  absolute address — was rejected: `bad operand with opcode 'roll'`.
- `mov`, `add`, `and`, `cmp`, `or` accept a 32-bit immediate, so the same
  wrong operand **assembled**, with no diagnostic, as a load from the address
  of an undefined symbol literally named `$5`.

`t5` pins the silent half: against the baseline it produces a relocation table
reading `R_X86_64_32S $5 + 0`. That is why every case here is compared byte for
byte instead of by exit status.

## Cases

| case | what it pins down |
|---|---|
| `t0_literal_control` | the reference instruction sequence, no macro anywhere; passes before and after |
| `t1_object_macro_imm` | the same sequence with every immediate through an object-like macro, both spellings (`$5` in the macro, and `$` + a macro holding `5`) |
| `t2_function_macro_imm` | the same sequence with every immediate inside a function-like macro body — the reported shape |
| `t3_imm_forms` | the other `$` operand spellings the corpus uses, each through a macro: hex, parenthesised expression, negative, arithmetic, a symbol, a symbol plus offset |
| `t4_sha1_generic_shape` | the construct as libressl writes it, condensed from `crypto/sha/sha1_amd64_generic.S` — macro-named registers, multi-line round macro, rotate amounts as immediates inside it |
| `t5_silent_wrong_bytes` | only 32-bit-immediate opcodes, so the baseline assembles it and is silently wrong |

On top of comparing each file to `as`, the run asserts the equivalence the
patch rests on directly: `t0`, `t1` and `t2` carry the same instruction
sequence written three ways, so all three must produce identical output — in
`as` (the premise) and in tcc (the claim).

Against the `0001`–`0012` baseline the same harness reports `pass=1 fail=9`:
only the literal control passes.

## Deliberately absent

Two encodings are kept out of the cases because tcc and `as` already disagree
on them with no macro involved, which would make every case mismatch for an
unrelated reason:

- shift by one — `as` picks the `D1 /r` short form, tcc picks `C1 /r ib`.
- an immediate added to `%eax` — `as` picks `83 /0 ib`, tcc picks the `05 id`
  accumulator form.

Both are pre-existing tcc encoding choices, both assemble to correct code, and
both are tracked in TODO.md rather than in this patch.

A C-mode case is absent for a different reason: the change cannot reach C. It
fires only when the enclosing file was already being parsed with
`PARSE_FLAG_ASM_FILE` set, which no C compilation does — inline `asm` in C goes
through `tcc_assemble_inline()`, which runs with preprocessing off and so
processes no `#define` at all. `-fdollars-in-identifiers` keeps working in C
exactly as before.
