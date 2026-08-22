# 0037 — `.eh_frame_hdr` indexes CIEs that carry a personality routine

## The defect

`tccdbg.c`'s `tcc_eh_frame_hdr()` walks `.eh_frame` and writes the sorted
binary-search table that `_Unwind_Find_FDE` consults after finding
`PT_GNU_EH_FRAME`. The walk recognised exactly one CIE shape — version 1 or 3,
augmentation string exactly `"zR"`, augmentation data exactly one byte equal to
`FDE_ENCODING` — and `goto next`'d past anything else without recording it.

The header it produced was still well-formed: correct version, correct encoding
bytes, a count field, a sorted table. It was just short, and nothing in the
output says by how much. `readelf` reports the section as present either way.

A CIE gets an augmentation entry beyond `R` as soon as a translation unit names
a personality routine. gcc writes `"zPR"`; `.cfi_personality` in hand-written
assembly produces the same; with an LSDA it is `"zPLR"`; `.cfi_signal_frame`
adds `S`. Every one of those was dropped.

LuaJIT's interpreter CIE is written by hand in `vm_x86.dasc` and names
`lj_err_unwind_dwarf` as its personality — augmentation `"zPR"`, `P` and `R`
both `0x1b` (`DW_EH_PE_pcrel|DW_EH_PE_sdata4`), augmentation length 6. It is a
single CIE covering the whole interpreter, so exactly one FDE went missing from
a table of 2402 — and it was the one frame LuaJIT's error handling needs, which
is why `pcall` panicked with `unprotected error in call to Lua API` on a
tcc-linked build while everything else about the binary looked right.

## The fix

`dwarf_cie_fde_encoding()` parses the augmentation string as the LSB CFI
convention defines it, rather than comparing it to one literal. A leading `z`
introduces a length-prefixed augmentation data block; each further character
describes one entry in that block, in order:

| char | augmentation data |
| ---- | ----------------- |
| `L`  | one byte: the LSDA encoding |
| `P`  | one byte: the personality encoding, then a pointer stored in that encoding |
| `R`  | one byte: the encoding of the FDE's `initial_location` |
| `S`  | nothing; the frame is a signal frame |

Only `R` is wanted, but the entries ahead of it have to be parsed to find where
it sits — which is why `P` needs `dwarf_skip_eh_pointer()`, a size-of-encoding
helper. The walk is then checked against the block's declared length: if the
two disagree, the CIE is refused rather than read at a guessed offset.

Two details worth keeping straight:

- The FDE encoding is still required to equal `FDE_ENCODING`
  (`DW_EH_PE_pcrel|DW_EH_PE_sdata4`, `0x1b`), because the table's own entries
  are 4-byte data-relative and the offset arithmetic assumes it. What changed is
  *finding* that byte, not what is accepted once found. LuaJIT's CIE uses
  `0x1b`, as does everything gcc emits on x86-64.
- The return-address column is a `ubyte` in CIE version 1 and a ULEB128 from
  version 3 on. The old walk read one byte in both cases. No real target has a
  return-address register number above 127, so this never differed in practice;
  it is written correctly now because the parse was being rewritten anyway.

Shapes still refused, all of which leave the FDE out of the table rather than
guessing at it: an augmentation string without a leading `z`, an `R` encoding
other than `0x1b`, `DW_EH_PE_aligned` anywhere (its padding depends on the
record's load address, unknown here), and any augmentation character outside
the four above.

## What the harness pins

`run.sh <cc>` builds each CIE shape from hand-written assembly — the assembler
is the only thing that will emit a chosen augmentation string on demand —
links it with the compiler under test, decodes `.eh_frame_hdr` out of the
resulting image, and asserts:

- every FDE in `.eh_frame` has exactly one table entry;
- the entries' pc values are the FDE start addresses, and their fde values
  point at the FDE records;
- the table is sorted by pc, which is what makes it binary-searchable at all;
- a CIE this table cannot represent is *skipped*, and the entries that remain
  are still real, still sorted — soundness, not completeness, because an entry
  computed from a misread encoding is worse than an absent one;
- end to end, `_Unwind_Backtrace` walks *past* a personality-bearing frame and
  reaches `main`. That is the runtime shape of the bug: with the frame missing
  from the table, `_Unwind_Find_FDE` comes up empty and the walk stops.

Every assertion also holds for `gcc` + GNU `ld` (`run.sh "$(command -v gcc)"`),
which is what makes them reference properties rather than a restatement of this
patch. Measured at the time of writing: 12 pass / 0 fail for both the patched
tcc and gcc; 6 pass / 6 fail for a tcc built from the same patch stack without
this change, so the harness discriminates.

The end-to-end group needs a linkable libgcc unwinder. `run.sh` tries
`-lgcc_eh`, `-lgcc_s`, `-lgcc` in that order and prints `SKIP` if none resolve,
rather than failing on a toolchain-layout difference; the structural assertions
above cover the same property and always run.

## What it does not pin

The byte layout of `.eh_frame`, the number or ordering of CIEs, which
augmentation characters a compiler chooses to emit, the table's own encoding
bytes, or the contents of the CFI programs.

It also does not pin anything about a **link-only** invocation, because as of
this patch there is nothing to pin: `s1->eh_frame_section` is only ever
assigned during compilation, so `tcc -c` followed by `tcc -o` emits no
`.eh_frame_hdr` at all and the generator this patch fixes is never reached.
Every case here therefore compiles and links in one step. That remaining defect
is tracked in `TODO.md`; its fix is a separate, still-open question.

## A case that was written and then removed

A CIE whose declared augmentation-data length disagrees with what its
augmentation string describes (string `"zPR"`, which needs 6 bytes; length
field says 5) is refused by the new parse — measured: the FDE is skipped and
the rest of the table stays correct and sorted. It is not in `run.sh` because
the same input does *not* produce equivalent behaviour under gcc + GNU `ld`:
ld's table came out naming an address that is not any FDE's start. Whether that
is ld mis-parsing deliberately malformed input, or ld's `.eh_frame`
recombination legitimately moving the record before the table is built, was not
determined. Asserting it either way would have been a claim about GNU ld that
this patch has not earned, and gating on it would have made the harness fail
against its own reference — so the length check stays in the code as a
defensive guard and the case is written down here instead of asserted.
