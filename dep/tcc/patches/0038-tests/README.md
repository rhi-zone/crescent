# 0038 — `.eh_frame_hdr` for a link-only invocation

## The defect

`tccdbg.c`'s `tcc_eh_frame_hdr()` reads `s1->eh_frame_section` on its first
line and returns if it is NULL. That field is set by `tcc_eh_frame_start()`,
which runs only while tcc is **compiling** — it is the handle the code
generator appends its own CIE and FDEs to.

So `tcc -c a.c` followed by `tcc -o exe a.o`, the shape every real multi-file
build uses, left the field NULL. The link itself was fine: the merge loop built
a complete, correctly relocated output `.eh_frame` out of the input objects'
sections (`0007` made that retention unconditional). The generator simply never
looked at it, and the output carried `.eh_frame` with no `.eh_frame_hdr` and no
`PT_GNU_EH_FRAME`.

That is the last of the two defects that kept a fully tcc-compiled **and**
tcc-linked LuaJIT from working. `libgcc`'s `_Unwind_Find_FDE` locates FDEs by
walking `dl_iterate_phdr` for `PT_GNU_EH_FRAME`; with no such header the search
phase finds nothing, LuaJIT's `lj_err_unwind_dwarf` personality is never
consulted, and any `pcall` of an error becomes `PANIC: unprotected error in
call to Lua API`. `0037` closed the other one (the CIE walk dropped every
personality-bearing CIE, LuaJIT's interpreter frame among them); neither alone
is enough.

## The fix

`tcc_eh_frame_adopt_output()` in `tccelf.c` binds `s1->eh_frame_section` to the
`.eh_frame` the link produced, just before the generator runs.

It **adopts only, never creates**. `reserved_section()` would create the section
when no input supplied one, and an empty `.eh_frame` in the output is content
this link does not have — real `ld` emits neither section nor header in that
case. So it looks the name up first and binds through the reserved-section gate
only on a hit, which is what keeps the role, the header fields the role depends
on, and the input-side claim gate (`0007`, `0009`) all agreeing.

The role is `SECTION_ROLE_SHARED`, the same role `tcc_eh_frame_start()` uses.
That is not a coincidence and not a second meaning for the field: compiling
appends into the same output section that a link-only run merely inherits. The
field means "the output `.eh_frame` this link is emitting" in both modes; what
changes is when it gets set, not what it denotes.

## What the harness pins

The reference behaviour, measured against GNU ld 2.44 and GNU gold on x86-64
rather than assumed:

- a final link, executable or shared, emits `.eh_frame_hdr` and
  `PT_GNU_EH_FRAME` whenever the merged output has `.eh_frame` content — and
  gcc's link driver passes `--eh-frame-hdr` by default for both `-o exe` and
  `-shared`;
- whether unwind-table *generation* happened at compile time does not enter into
  it. Objects built with `-fno-asynchronous-unwind-tables` still produce a header
  if any other input carried `.eh_frame`. This is the same T3 distinction `0007`
  drew for `.eh_frame` *retention*: `-f[no-]asynchronous-unwind-tables` is a
  question for tcc's own C compiler, never for what the linker does with unwind
  info that already exists in its inputs;
- a link whose inputs carry no `.eh_frame` at all gets no header — `ld` emits
  none even when `--eh-frame-hdr` is passed explicitly. An empty header is not
  the answer; no header is;
- `-r` never gets one, from either linker, even with `--eh-frame-hdr` passed
  explicitly. `-r` output has no program headers at all. tcc agrees for free:
  `TCC_OUTPUT_OBJ` goes to `tcc_output_object()` and never reaches
  `elf_output_file()`.

Plus, for every case that should have a header: the binary-search table names
every FDE in the image, its entries agree with the FDE addresses, and it is
sorted — which is what makes it searchable at all. Those table properties hold
for gcc + GNU ld too, which is what makes them reference properties rather than
a restatement of the patch.

The harness fails 8 checks against the pre-`0038` tcc and passes fully against
`gcc`, so it detects the defect rather than describing the fix.

## What it deliberately does NOT pin: `-static`

The two references disagree there, so nothing here asserts either answer.

GNU ld emits the header for a static link when asked — `ld -static
--eh-frame-hdr` produces `.eh_frame_hdr` and `PT_GNU_EH_FRAME`, bfd and gold
alike. gcc's driver does not ask: its link spec reads
`%{!static|static-pie:--eh-frame-hdr}`, so a plain `gcc -static` link gets no
header while `gcc -static-pie` does.

tcc is both driver and linker, so it would have to pick one. It currently
behaves like gcc's driver — the `tcc_eh_frame_hdr()` call site sits inside
`if (!s1->static_link)` — and this patch leaves that untouched rather than
minting an answer to a question the measurement did not settle. Recorded as an
open call in `TODO.md`.

The `-nostdlib` group in the harness is not that case: `-nostdlib` is an
ordinary dynamic link that simply has no libc inputs, so it is exactly the
link-only path with the crt files taken out of the picture.

## Running it

```sh
bash patches/0038-tests/run.sh "$PWD/tcc"
bash patches/0038-tests/run.sh "$(command -v gcc)"    # the reference
```

Needs `gcc`, `ld` (via gcc) and `readelf`. The end-to-end group additionally
needs a libgcc unwinder and reports `SKIP` if none of `-lgcc_eh`/`-lgcc_s`/
`-lgcc` links — which is what happens on a NixOS box, where tcc's configured
library paths do not include libgcc. It runs for real in the Alpine container CI
uses.
