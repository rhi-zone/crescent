# `0014-note-gnu-stack-object-marker.patch` tests

```
run.sh /path/to/tcc
```

Eleven checks. Against a tcc built with patches `0001`–`0013` and
`0015`–`0017` but not `0014`, five fail; with `0014` applied, all eleven pass.
Running the same script against a real gcc (`run.sh "$(command -v gcc)"`) also
passes all eleven — the reference is an actual toolchain, not this patch's own
opinion.

Only five of the eleven discriminate base from patched (`t0`, `t4`'s pair,
`t5`, `t8`). The rest pass on both, and are here to guard behaviour the patch
must not break rather than behaviour it introduces — `t1`, `t2`, `t3`, `t6`,
`t7` and `t9` all cover input that supplied its own statement, which neither
tree touches. Reading 6/11 → 11/11 as "five new cases fixed" would be right;
reading it as "eleven cases fixed" would not.

## What the marker is for

GNU `ld` decides an executable's `PT_GNU_STACK` permissions from the
`.note.GNU-stack` sections of its inputs, and its default for an input that
has none is *this object requires an executable stack*. One unmarked object
is enough to make the whole link `RWE`. binutils 2.44 also warns:
`missing .note.GNU-stack section implies executable stack`.

`0008` covers the case where tcc itself performs the final link — it writes a
`PT_GNU_STACK` program header directly. That code (`layout_sections()`) never
runs for `tcc -c`, and a `-c` object's fate is usually decided by an `ld` that
executes no tcc code at all. The two halves are independent; neither
substitutes for the other.

## The cases

| case | input | expected |
| --- | --- | --- |
| `t0_plain_c` | ordinary C | marker present, empty, align 1, unflagged |
| `t1_plain_asm` | `.S`, says nothing about the stack | **no marker** |
| `t2_asm_declares_marker` | `.S` with `.section .note.GNU-stack,"",@progbits` | the input's own section, unchanged |
| `t3_asm_requests_exec_stack` | `.S` with `,"x",` | the input's own section, `X` preserved |
| `t4_link_gnu_stack` | C object linked by real `ld` | `GNU_STACK` not executable |
| `t4_link_no_warning` | same link | no `missing .note.GNU-stack` warning |
| `t5_r_c_plus_undeclared_asm` | `-r` over C + undeclared `.S` | merged marker **`X`** |
| `t6_r_c_plus_declared_asm` | `-r` over C + `.S` declaring `,"",` | merged marker unflagged |
| `t7_r_c_plus_exec_asm` | `-r` over C + `.S` declaring `,"x",` | merged marker `X` |
| `t8_r_c_plus_unmarked_object` | `-r` over C + prebuilt unmarked `.o` | merged marker **`X`** |
| `t9_r_c_plus_marked_object` | `-r` over C + prebuilt marked `.o` | merged marker unflagged |

`t1` and `t3` are the cases about *not* acting, and they are why the patch is
not simply "always create the section":

- `t1` — measured, not assumed: neither `as` nor `gcc -c` marks a
  hand-written `.S` (binutils 2.44 / gcc 15.2.0). The convention is that asm
  authors declare their own stack-execution needs. A compiler that answers on
  their behalf is answering for code it did not generate, and an `.S` that
  genuinely needs an executable stack but forgot to say so would start
  crashing.
- `t3` — `"x"` is a real requirement. Adopting that section into a tcc role
  and re-flagging it would discard the requirement silently, and the failure
  mode is a runtime crash rather than a diagnostic.

`t5` is the counter-intuitive one and the reason the `-r` cases exist. The
marker belongs to the object, not to the input, so merging inputs that made
different statements forces a reconciliation. GNU `ld -r` upgrades: a marked
object merged with an unmarked one produces a marker carrying
`SHF_EXECINSTR`, keeping the unmarked input's implicit requirement alive
(measured on binutils 2.44; the final link then reports `requires executable
stack (because the .note.GNU-stack section is executable)` and gives
`GNU_STACK ... RWE`). Emitting an unflagged marker there would drop a
requirement silently, so tcc upgrades the same way. All three cases pass
against gcc unchanged, which is what pins them to measured `ld` behaviour
rather than to a reading of it.

`t8` is `t5` reached through a prebuilt object instead of a source, and it
exists because an earlier revision of this patch got it wrong: reconciliation
keyed only on assembled sources, so `-r file.c unmarked.o` created a marker
and flagged it *non*-executable — worse than emitting nothing, since it
converts the object's implicit requirement into an explicit denial of it. An
input object with no marker makes the same statement an undeclared `.S`
source makes, and both now feed the same flag.

`t4` uses a C input rather than asm, and passes `-fno-asynchronous-unwind-tables`:
tcc's `.eh_frame` output trips a separate, unrelated binutils error
(`.eh_frame_hdr refers to overlapping FDEs`) that aborts the link before
`GNU_STACK` can be read. That defect is tracked on its own; suppressing
`.eh_frame` keeps this harness measuring one thing.

## Not covered here

The two `-r` shapes where no marker gets created: asm sources only with one
declaring the marker and another not, and `tcc -r a.o b.o` with no compilation
at all. `ld -r` raises `SHF_EXECINSTR` on the merged marker in both; tcc
leaves the existing section alone or creates nothing, because rewriting an
input-supplied section is the one thing the patch refuses to do. Deliberate
divergences, open in `TODO.md`, not cases this harness asserts either way.

The deprecation binutils 2.44 prints alongside its missing-marker warning
("this behaviour is deprecated and will be removed"). `t1` leans on that rule
meaning what it means today, so if it goes, `t1`'s expectation is worth
revisiting — which is also why `t5`/`t8`'s explicit `X` matters more over time
than an absence that currently happens to mean the same thing.

Guarded markers in real-world asm. The common idiom is

```
#if defined(__linux__) && defined(__ELF__)
.section .note.GNU-stack,"",%progbits
#endif
```

and tcc does not define `__ELF__` on Linux targets (`include/tccdefs.h`
defines it only under the NetBSD branch), so the directive is preprocessed
away and the object comes out unmarked. `dep/libressl`'s AT&T bignum mirror
is affected. That is a separate preprocessor-conformance gap, tracked in
`TODO.md`, and no part of it is addressed by this patch.
