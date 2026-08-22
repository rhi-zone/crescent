# Negative-repeat-count test cases (for `0031-asm-space-negative-repeat-count.patch`)

A harness that compares a tcc build's diagnostics against real GNU `as` on a
negative repeat count in `.skip` / `.space` / `.zero`.

    ./run.sh /path/to/patched/tcc

38 checks, no committed `.S` files — the cases differ by a directive or two
and are generated in a temp directory.

`as` warns `.space repeat count is negative, ignored` for a negative count in
every section type. tcc clamped the count to zero and said nothing.

## Why it was worth closing

This is the gap `0029` measured and deliberately left alone, recorded in its
own README under "Deliberately absent" and in TODO.md. `0029` flagged the
count *before* the existing `if (n < 0) n = 0;` clamp specifically so that
this patch needed no rework, and it did not: the code change is one more
flag set next to the existing one and one `else if` next to the existing
warning.

Silently clamping is the same class of problem `0029` closed. A negative
count is nearly always a bug in the source — a subtraction that came out the
wrong way round, a symbol difference computed backwards — and the assembler
quietly assembling zero bytes is what hides it.

## The discriminator

Three messages meet in this area, and which one applies is decided by the
count and the directive together, not by either alone:

| input | `as` says |
|---|---|
| `.skip -1,7` in NOBITS | negative repeat count |
| `.skip 0,7` in NOBITS | zero repeat count (`0029`) |
| `.skip 4,7` in NOBITS | ignoring fill value (`0024`) |

The negative and zero counts are separate exits in `as`, not one message with
two spellings, and both are taken ahead of the fill-value check — measured
against binutils 2.44, not inferred. The middle row is in the cases as a
guard in its own right: a fix that widened `0029`'s message to cover negative
counts would still "warn", and would still fail here.

The whole script also passes unchanged against a real gcc
(`./run.sh "$(command -v gcc)"`), which is what makes it a reference rather
than this patch's own opinion. That cross-check was run here, against
binutils 2.44; CI invokes every harness against the built tcc only, so
nothing in this one's CI result depends on which binutils the container
ships.

## Baselines

| build | result |
|---|---|
| the stack up to `0030` | `pass=19 fail=19` |
| plus this patch | `pass=38 fail=0` |

The 19 that already passed are the `0024`/`0029` rows and the
positive-count rows, which this patch must not disturb; the 19 that failed
are the negative-count ones.

## Deliberately absent

**A negative *alignment*.** `as` rejects `.align -1` / `.balign -1` with
`Error: alignment not a power of 2`; tcc rejects it too, with
`error: alignment must be a positive power of two`. Both refuse the input, so
nothing is silently mis-assembled and there is no correctness gap here —
only a wording difference, which is not what this patch is about. (`.p2align
-1` is a third story: `as` 2.44 tries to allocate 2^63 bytes and dies with
`out of memory`. Measured while writing this. Not something to match.)

**`.org` with a negative operand.** A different directive with a different
message in `as` (`attempt to move .org backwards`), reached from a different
handler, and it shares only the `zero_pad` label in tcc. Left to its own
patch, per the precedent `0024` set and `0029` followed.
