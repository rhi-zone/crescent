# `.value` directive test cases (for `0012-asm-value-directive.patch`)

Assembly inputs for GAS's `.value` directive, plus a harness that diffs a tcc
build's output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Each case is compared byte-for-byte (PROGBITS content plus the normalized
relocation table). On top of that the run asserts the equivalence the patch
rests on directly, in both assemblers: the `.short` control and the `.value`
file carry identical content, so `as`'s two outputs must match each other and
tcc's two outputs must match each other.

| case | what it pins down |
|---|---|
| `t0_short_control` | the same content written with `.short`, which tcc already had; passes before and after |
| `t1_value` | the identical content written with `.value` — constants, comma-separated lists, negatives, expressions, a label difference |
| `t2_value_ghash_table` | the shape that actually blocked libressl: a long `.value` lookup table in `.rodata`, from `ghash-elf-x86_64.S`'s `.Lrem_8bit` |

Against the `0001`–`0011` baseline the same harness reports `pass=1 fail=4`:
only the `.short` control passes, `t1_value` fails with `unknown opcode
'.value'` and `t2_value_ghash_table` with `incorrect number of operands` (the
directive was not recognized, so it fell through to opcode parsing).

A bare symbol operand (`.value sym`) is deliberately absent from the cases.
tcc's 2-byte data directives reject one — `constant expected`, no
`R_X86_64_16` — and that is a pre-existing limitation of `.short`/`.word`
which `.value` correctly inherits by being an alias. `.long sym` works, so it
is specific to the 2-byte width. Tracked separately in TODO.md; not this
patch's subject.
