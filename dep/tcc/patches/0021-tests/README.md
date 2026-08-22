# `0021-asm-section-name-attrs.patch` tests

```
run.sh /path/to/tcc
run.sh "$(command -v gcc)"      # the reference; must also pass
```

61 checks. Against a tcc built with patches `0001`–`0020` but not `0021`,
26 fail; with `0021` applied, all 61 pass, and so do all 61 against a real
gcc — that second run is what makes the expected values a measurement of
binutils 2.44 `as` rather than this patch's own opinion.

Needs `readelf` on `PATH`.

## What was wrong

`0004-asm-section-flags-alloc.patch` fixed a real upstream bug. Upstream
tcc initialised `.section`'s flags to `SHF_ALLOC` unconditionally and never
parsed `a` out of the flags string at all, so `.section foo,"w"` came out
allocatable and it was structurally impossible to get a section *without*
`SHF_ALLOC`. `0004` changed the default to `0` and taught the loop to parse
`a`.

That is the right answer for a section name GNU `as` has no opinion about,
and the wrong answer for one it does. Real `as` derives a section's flags
from its **name** first (binutils `bfd_elf_special_sections`, `bfd/elf.c`),
and the flags string only gets to add to them. `0004` was verified against
`as` on made-up names, where the two rules agree; on recognized names they
do not, and after `0004` the ordinary hand-written spelling

```asm
    .section .rodata
```

produced a section with **no `SHF_ALLOC`** — silently dropped from every
linked image. Four of crescent's own seven vendored libressl
`crypto/*/*-elf-x86_64.S` files (`aes`, `aesni`, `ghash`, `mont5`) spell it
exactly that way; their constant tables were non-allocated in every object
tcc produced from them.

The same defect is what broke tcc's own `make test1` / `make test3`, by a
route that looks nothing like a flags bug. `tests/tcctest.c` pushes into
`.data.ignore` — a `.data.` name, so allocatable to `as` — and puts a
`.long 661b - .` in it. `tccrun.c` assigns run-time addresses only to
`SHF_ALLOC` sections, but `tccelf.c`'s `relocate_sections()` relocates every
section that has relocations, so that `R_X86_64_PC32` computed
`symbol - 0`. Under `-run` the symbol is a real heap pointer, the difference
does not fit in int32, and the whole thing surfaced as:

```
tcc: error: relocation '2' out of range
```

`'2'` is the relocation *type* number, `R_X86_64_PC32`. It reads like a
JIT memory-placement problem and is not one: the section simply had no
address. Under `-c`/link the same relocation is computed against
`ELF_START_ADDR`-scale values, fits, and lands in a section nobody reads —
which is why compiled output stayed byte-identical to gcc's throughout, and
only `-run` ever complained.

## What the fix does

Adds binutils' name table to `tccasm.c`, for the entries that carry flags,
plus `as`'s precedence rule. The rule is **not** "default when no flags
string is given":

* name-implied flags win outright — `.section .text,"w"` is still `AX`,
  `.section .rodata,""` is still `A`;
* *unless* the flags string is a strict superset of them, in which case the
  flags string wins — `.section .rodata,"aw"` is `WA`.

`as` warns on both mismatch directions (`ignoring changed section
attributes` / `setting incorrect section attributes`); tcc says nothing.
That is a diagnostic divergence, recorded in `TODO.md`, not a layout one.

The subset half of the rule is why this patch also **subsumes** upstream's
hand-written `.init`/`.fini` → `SHF_EXECINSTR` special case, which it
deletes: `.section .init,"a"` has to stay executable (musl's crt asm relies
on it), and a plain default-if-absent rule would have dropped it. Upstream's
two-name `strcmp` was a fragment of this table; it is now the table.

Name matching reproduces binutils' `suffix_length` field: `-2` means "the
name exactly, or the name followed by `.` and any suffix" (`.text`,
`.text.hot` — but not `.textfoo`), `0` means exactly (`.init` but not
`.init.foo`, `.got` but not `.got.plt`). Both boundaries are checked, in
both directions: too loose marks unrelated sections allocatable, too tight
puts the original bug back for `.text.hot` and friends.

## Deliberately not in scope

**`sh_type` is still never derived.** `as` gives `.bss*` `SHT_NOBITS`,
`.note*` `SHT_NOTE`, `.init_array*` `SHT_INIT_ARRAY`, and also honours the
directive's `@type` argument — which tcc's `.section` handler parses and
throws away. tcc derives `sh_type` from neither, and never did; `0004`
did not touch it and neither does this. It is an older, separate gap, in
`TODO.md` under its own item, not something this table quietly half-fixes.

**`-run` still cannot relocate a genuinely non-allocated section.** With
this patch `.data.ignore` is allocatable, so `tcctest.c` no longer reaches
that path, but a PC-relative relocation inside a section `as` also considers
non-allocated (`.pushsection notspecial` + `.long 1b - .`) still fails
under `-run` with the same message, and still links and runs correctly
without it. That is the underlying `tccrun.c`/`relocate_sections()` defect,
which predates the whole patch stack and which `0004` merely exposed. It has
its own `TODO.md` item.

## Relationship to `0020`

`0020-tests`' README says the `__TINYC__` slice bug is "why `make test1` /
`make test3` could never pass". That was one of two blockers, and the one
that fired first. With `0020` alone the run gets past
`tcctest.c:338` and then dies on `relocation '2' out of range`; only
`0020` and `0021` together let `make test` complete. Verified by building
all three combinations.
