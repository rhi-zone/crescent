# `0030-malformed-object-bounds-checks.patch` — a malformed `.o` is a diagnostic, not a crash

## What was wrong

`tcc_load_object_file()` in `tccelf.c` read an ELF object file by trusting
every field in it. Nothing in the function compared a file offset against the
size of the file, an index against `e_shnum`, or a string-table offset
against the size of that string table. `load_data()` — the one reader used
throughout — `malloc()`s the requested size, seeks, does a **short** read
when the file is smaller than that, and returns the buffer with its tail
uninitialised, so a truncated file did not fail: it produced section headers
made of heap garbage, which the loader then followed.

Recorded in `TODO.md` as two cases (a truncated object, and one whose
`sh_name` points past the end of `.shstrtab`), noticed while regression
testing `0014` and pre-existing to it. Measured before touching anything, on
a build of the then-current patch stack: of 21 hand-built malformations, **11
terminated tcc with SIGSEGV** and the rest were accepted or misdiagnosed.
Random mutation of a real object (see "How this was checked" below) put the
rate at **roughly one crash or hang in every five mutated objects**.

The scope was larger than the two recorded cases. Every one of these was
reached with no check at all:

| read | how it goes wrong |
| --- | --- |
| `shdr = load_data(…, sizeof(Shdr) * e_shnum)` | truncated file, or `e_shoff` past the end |
| `shdr[e_shstrndx]` | `e_shstrndx` ≥ `e_shnum`, or 0 |
| `strsec + sh->sh_name` | `sh_name` past the end of `.shstrtab`, or a `.shstrtab` that does not end in a NUL |
| `shdr[sh->sh_link]` (`.symtab` → `.strtab`) | `sh_link` ≥ `e_shnum`, or 0 |
| `shdr[sh->sh_info]` (relocation → target) | `sh_info` ≥ `e_shnum` |
| `sm_table[sh->sh_info].s->sh_num` | in-range `sh_info` naming a section that was never merged |
| `sm_table[sym->st_shndx]` | `st_shndx` < `SHN_LORESERVE` but ≥ `e_shnum` |
| `strtab + sym->st_name` | `st_name` past the end of `.strtab` |
| section contents `full_read(fd, ptr, size)` | `sh_offset`/`sh_size` describing bytes the file does not have |
| `section_add(s, size, sh->sh_addralign)` | `sh_addralign` not a power of two — not a wild read but an unbounded allocation |
| `ptr = s->data + rel->r_offset` in `relocate_section()` | `r_offset` outside the section being relocated |

The last one is in a different function and a different stage — relocation
*application*, not object *parsing* — and is the reason this patch is not
confined to `tcc_load_object_file()`. It was found by fuzzing after the
parser was already checked: with the reader sound, every remaining crash was
in `relocate()`, reached through that one line.

## The fix

Validation happens once, up front, so that the loader below reads as it did
rather than growing a check per dereference:

* `range_in_file()` answers "does this byte range exist in the file", forming
  no sum that a crafted offset could wrap.
* `load_data_bounded()` is `load_data()` plus that question, returning NULL
  instead of a buffer with an undefined tail.
* `validate_shdr_table()` walks the section header table once and rejects the
  first `sh_name`, `sh_link`, `sh_info`, extent or `sh_addralign` that does
  not hold. After it returns, the rest of the function's indexing is sound by
  construction.
* The two string tables are checked to end in a NUL when they are loaded, so
  an in-range offset is a string that terminates in range — a property of the
  table, checked once, rather than a scan per name.

Six diagnostics, chosen to sit next to the ones `tccelf.c` already emits
(`invalid object file`, `invalid archive`, `section type conflict`) rather
than to introduce a new convention. `unexpected end of file` is not new
wording at all — `tccelf.c`'s linker-script parser already uses it.

| | |
| --- | --- |
| `unexpected end of file` | a header or section extends past the end of the file |
| `invalid section name offset` | `sh_name` outside `.shstrtab` |
| `invalid section name table` | `.shstrtab` empty, or not NUL-terminated |
| `invalid symbol name offset` | `st_name` outside `.strtab` |
| `invalid symbol name table` | `.strtab` empty, or not NUL-terminated |
| `invalid section header index` | `e_shstrndx`, `sh_link`, `sh_info` or `st_shndx` naming no section |
| `invalid section alignment` | `sh_addralign` neither 0 nor a power of two |
| `relocation offset out of range in section '%s'` | `r_offset` outside the section it patches |

### The bound is the file, not the archive member

Objects also arrive through `tcc_load_archive()`, which calls
`tcc_load_object_file()` with a `file_offset` into the `.a`. The checks bound
against the end of the **file**, not the end of the member, so a malformed
member can still read bytes belonging to the member after it. That is bounded
memory that came off disk either way — not an out-of-bounds access — and
tightening it would mean threading the member size through
`tcc_load_object_file()`'s signature. Stated here so the looseness is a
choice on the record rather than an oversight.

### What is deliberately still open

Two residuals, both in `TODO.md` rather than papered over:

* A relocation *starting* inside a section can still write up to 8 bytes past
  its end. Closing that needs the per-relocation-type write width, which only
  each target's `relocate()` knows — substrate that does not exist, not a
  check that was skipped.
* `sh_addralign` is checked for the property ELF actually states (0 or a
  power of two). A legal power of two can still be absurd — 2^40 is a valid
  alignment and an unreasonable allocation — but any cap on it is a policy
  number ELF does not supply, so none was invented here.

`tcc_load_dll()` reads `.so` files with the same shape of unchecked reads and
crashes on the same kind of input; it is a separate function on a separate
path and is recorded in `TODO.md` as its own item, not silently folded in.

## How this was checked

`run.sh` takes a tcc, compiles a small object with it, and pokes one field
per case — so each malformed input differs from a working link in exactly one
way. Every case asserts three things in order: not killed by a signal,
non-zero exit, and the expected phrase. The three controls at the end are
load-bearing, since the cheapest way to pass a harness like this is to start
rejecting everything; two of the new checks (`sh_addralign`, and the
relocation offset bound) sit on paths that every legitimate object also
takes.

Against the patched tcc: 29 pass, 0 fail. Against the same tcc without
`0030`, the identical script gives 6 pass / 23 fail, **14 of the failures
being SIGSEGV**, with all three controls still passing on both.

Beyond the fixed cases, a random-mutation fuzz (biased toward the ELF header
and the section header table, since uniform byte flips almost never land on a
size or an index) was run over a real object:

* unpatched: the driver's 40-finding cutoff was reached after ~190 inputs on
  each of two seeds — about one signal or hang in five;
* patched: **40 000 mutated objects across 10 seeds, zero signals and zero
  hangs** — every input either linked or produced a diagnostic.

An intermediate build, with the object reader checked but
`relocate_section()` not yet, still crashed 8 times in 4000 — all of them in
`relocate()`. That is how the eleventh row of the table above was found, and
why it is in this patch.

The fuzz driver is not committed; it is a throwaway next to `run.sh`, which
is the reproducible artifact. What it contributed is the assurance that the
committed cases are not merely the ones that happened to be thought of.

Regression, on the full patch stack, both libcs: tcc's own `make test` →
`ALL TESTS PASSED` on glibc (`debian:bookworm`) and on musl (`alpine:latest`,
`./configure --config-musl`); all sibling `patches/*-tests/` harnesses pass
on both.

That legitimate input sees **no** change was measured rather than assumed.
A tcc with and a tcc without this patch each compiled the same 479 sources —
sqlite3, all 15 zlib `.c`, all 21 amd64 AT&T bignum `.S`, 442 libressl `.c` —
giving **479 byte-identical objects and 0 differing**; the 7 sources that do
not compile under tcc fail identically, diagnostic for diagnostic. Also
byte-identical: the linked zlib, sqlite3, bignum and libressl-SHA programs,
each tcc's own `libtcc1.a`, a 4.7 MB `libcrypto.a`, `lj_vm.o` assembled from
freshly generated buildvm output, and the linked LuaJIT interpreter, which
runs with the JIT active and matching output. Objects from the two are
interchangeable rather than merely self-consistent: linking one tree's
objects with the other tree's tcc gives the same binary. Foreign producers
were covered too — gcc objects at `-O2`, `-O0 -g`, `-gz`, and
`-ffunction-sections`, plus an `ar` archive of them, all link and run, which
is where added strictness would show up first.
