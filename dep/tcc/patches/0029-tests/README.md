# Zero-repeat-count test cases (for `0029-asm-space-zero-repeat-count.patch`)

A harness that compares a tcc build's diagnostics against real GNU `as` on a
zero repeat count in `.skip` / `.space` / `.zero`.

    ./run.sh /path/to/patched/tcc

36 checks, no committed `.S` files — the cases differ by a directive or two
and are generated in a temp directory.

`as` warns `.space repeat count is zero, ignored` for a zero count in every
section type, and takes that exit *ahead of* every other check it makes about
the directive. tcc said nothing.

## Why it was worth closing

The omission was already visible, not merely theoretical:
`.skip 0,<non-zero>` in a `SHT_NOBITS` section got `0024`'s
`ignoring fill value in section` warning out of tcc, because tcc reached a
fill-value test `as` never gets to. Two assemblers warning about two
different things on the same input is worse than one of them being quiet.

## The discriminator

Which warning applies is decided by the **directive**, not by the size:

| input | `as` says |
|---|---|
| `.skip 0,7` in NOBITS | zero repeat count — size is 0 *and* it came from `s_space` |
| `.skip 4,7` in NOBITS | ignoring fill value — from `s_space`, size not 0 |
| `.align 1,5` in NOBITS | ignoring fill value — size *is* 0, but not `s_space` |

That last row is why the fix cannot be "warn when the size works out to
zero". `.align`/`.balign`/`.p2align` are a different handler in `as` with no
repeat count to be zero: `.align 1` at an already-aligned offset contributes
nothing and is silent, while `.align 1,5` in a NOBITS section still reports
the fill it cannot store. All three rows are in the cases.

Every expectation was measured against binutils 2.44 before being written
down, and the whole script passes unchanged against a real gcc
(`./run.sh "$(command -v gcc)"`) — which is what makes it a reference rather
than this patch's own opinion.

## Baselines

| build | result |
|---|---|
| the stack up to `0024` | `pass=15 fail=21` |
| plus `0025` (`.zero`) | `pass=18 fail=18` — the three `.zero` cases start assembling; still no warning |
| plus this patch | `pass=36 fail=0` |

`0026`–`0028` sit between `0025` and this patch and touch nothing it tests;
the middle row is the baseline that matters, since a `.zero` case cannot
report the right warning in a build that cannot assemble `.zero` at all.

## Deliberately absent

**A negative repeat count.** `as` warns
`.space repeat count is negative, ignored` for `.skip -1`; tcc clamps to zero
and says nothing. Measured while writing this, and left alone: it is a
different message for a different input, `0024` set the precedent of leaving
an adjacent measured gap to its own patch rather than folding it in, and the
fix here deliberately flags the count *before* the existing clamp so that
adding the negative message later needs no rework. Recorded in TODO.md.
