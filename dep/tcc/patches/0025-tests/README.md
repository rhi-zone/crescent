# `.zero` directive test cases (for `0025-asm-zero-directive.patch`)

Assembly inputs for GAS's `.zero` directive, plus a harness that diffs a tcc
build's output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Each case is compared on every section's type, flags and size, plus the hex
contents of the sections that have contents and the normalized relocation
table. Sizes are in the comparison rather than hex alone because half these
cases are `SHT_NOBITS`, where two empty hex dumps would agree with each other
regardless of how much space either assembler actually reserved.

On top of the per-case comparison, the run asserts the equivalence the patch
rests on directly, in both assemblers: `t0`, `t1` and `t2` carry byte-identical
content differing only in the directive spelling, so `as`'s three outputs must
match each other and tcc's three must match each other.

| case | what it pins down |
|---|---|
| `t0_skip_control` | the content written with `.skip`, which tcc already had; passes before and after |
| `t1_zero` | the identical content written with `.zero` — including the fill-value forms |
| `t2_space` | the identical content written with `.space`, so the agreement is three-way and stated, not inferred |
| `t3_zero_shapes` | computed counts, a label difference as the count, and the `.globl`/`.type`/`.size`/`.zero` zero-initialised-object idiom gcc emits |

Against the `0001`–`0024` baseline the same harness reports `pass=2 fail=4`:
the `.skip` and `.space` spellings pass, `t1_zero` and `t3_zero_shapes` fail
with `unknown opcode '.zero'`, and both equivalence checks fail for want of a
dump to compare.

The whole script also passes unchanged against a real gcc
(`./run.sh "$(command -v gcc)"`), which is what makes it a reference rather
than this patch's own opinion.

## The thing that reads backwards

`.zero` is *not* "`.space` with the fill argument fixed at zero", which is the
natural reading of the name and is wrong. GNU `as` routes `.skip`, `.space`
and `.zero` into one handler, fill operand included: `.zero 4,5` in `.text`
assembles to `05 05 05 05`, exactly like `.skip 4,5`. Measured against
binutils 2.44 before the patch was written, which is why the control content
carries fill values instead of only bare counts.

## Deliberately absent

**Zero and negative repeat counts.** `.zero 0` warns
`.space repeat count is zero, ignored` in `as` and (as of this patch) nothing
in tcc; `.zero -1` warns `.space repeat count is negative, ignored` and tcc
silently clamps. Both are gaps in the shared `.skip`/`.space` handler that
predate `.zero` and are recorded separately in TODO.md. Adding `.zero` changes
what tcc *accepts*, not what it *says*, so no case here uses a zero or
negative count.

**`.align`.** tcc's alignment padding in an executable section differs from
`as`'s for reasons unrelated to anything here (recorded in TODO.md). A case
that fails for a known unrelated reason is worse than no case.
