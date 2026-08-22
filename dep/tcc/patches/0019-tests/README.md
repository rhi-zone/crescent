# `0019-note-gnu-stack-merge-raise.patch` tests

```
run.sh /path/to/tcc
```

Nine checks. Against a tcc built with patches `0001`–`0018` but not `0019`,
three fail; with `0019` applied, all nine pass. Running the same script against
a real gcc (`run.sh "$(command -v gcc)"`) also passes all nine — gcc's
`-r -nostdlib` hands the merge to the same GNU `ld`, so the reference is a
toolchain rather than this patch's reading of one.

Only three of the nine discriminate base from patched (`t1`, `t2`, `t3`). The
other six guard behaviour this patch must not break, and half of them exist
specifically because the obvious over-broad version of the rule would fail
them. Reading 6/9 → 9/9 as "three shapes fixed" is right; reading it as "nine
fixed" is not.

## What was wrong

`0014-note-gnu-stack-object-marker.patch` taught tcc to *create* the marker,
and to create it executable when an input that declared nothing shares the
object — which is what `ld -r` does. But it only ever created. When some input
already supplied a `.note.GNU-stack` section, tcc adopted it verbatim.

`ld -r` does not adopt verbatim. Measured on binutils 2.44, merging an object
that supplies an unflagged marker with one that supplies none yields a merged
marker carrying `SHF_EXECINSTR` — the unmarked input's implicit *I may need an
executable stack* survives the merge instead of being silently answered "no"
on its behalf. tcc dropped it.

Three shapes reached the gap, and all three are here:

- `t1` — asm sources only, one declaring and one not. No compilation, so
  `0014`'s create path never ran.
- `t2` — prebuilt objects, no source of any kind on the command line.
- `t3` — compilation *does* happen, but a marker already exists because an
  input supplied it, so again nothing was created and nothing was raised.

## The rule, and why it does not contradict `0014-tests` `t3`

Raising the flag only ever **strengthens** the statement a section already
makes; it never weakens one. An input's explicit `"x"` is never cleared, and an
input-supplied section is never replaced. `0014-tests` `t3` protects that
direction and still passes unchanged; `t0` and `t8` here hold the same line
from the other side.

The asymmetry is not aesthetic. A marker that is executable when it need not be
costs a more permissive stack. A marker that is non-executable when something
in the object did need one costs a segfault. `ld -r` resolves the merge in the
first direction, and so does tcc.

## The six guards

- `t0` — `-c` on an input declaring `"x"` leaves the `"x"` alone.
- `t4` — `ld -r` over a single unmarked object produces *no* marker, and
  neither may tcc. Inventing an unflagged one here would convert an implicit
  requirement into an explicit denial of it — worse than emitting nothing.
- `t5` — flag union across two input-supplied markers. This already worked via
  ordinary section merging; it is here because the raise now runs on that same
  section and must not disturb it.
- `t6`, `t7` — no undeclared input anywhere, so no raise. A false raise here is
  the failure mode of a rule scoped too broadly, which is the specific way this
  patch could go wrong.
- `t8` — the create path meeting an explicit `"x"`: the marker comes from the
  input, compilation also happened, and the `"x"` survives.

## The files

- `t0_declares_marker.S`, `t1_declares_marker_two.S` — declare an unflagged
  marker. Two of them, with distinct symbols, so `t7` can merge them without a
  duplicate-definition error.
- `t2_undeclared.S` — says nothing, the way `as`, `gcc -c` and `clang -c` all
  leave hand-written asm.
- `t3_requests_exec_stack.S` — declares `"x"`, an explicit requirement.
- `t4_plain.c` — compiled input, so tcc's own code generator contributes and
  `0014`'s create path is reachable.
