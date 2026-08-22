# `0018-elf-target-predefine.patch` tests

```
run.sh /path/to/tcc
```

Five checks. Against a tcc built with patches `0001`–`0017` but not `0018`,
**all five fail**; with `0018` applied, all five pass. Running the same script
against a real gcc (`run.sh "$(command -v gcc)"`) also passes all five — the
reference is an actual toolchain, not this patch's own opinion.

Unlike `0014-tests`, every case here discriminates base from patched. There is
no "guard against breaking what already worked" half, because nothing about
`__ELF__` worked before: tcc defined it in exactly one place, and that place
was unreachable on every target anyone builds for.

## What was wrong

`include/tccdefs.h` carried a single `#define __ELF__ 1`, inside the
`#elif defined __NetBSD__` arm. On Linux — and on FreeBSD, OpenBSD, Android
and every other ELF target tcc supports — `__ELF__` was simply absent, while
gcc and clang define it on all of them. gcc scopes it on the target's object
format, not per-OS.

The absence is not cosmetic. The commonest real-world use of `__ELF__` is

```
#if defined(__linux__) && defined(__ELF__)
.section .note.GNU-stack,"",%progbits
#endif
```

in hand-written assembler. Under tcc that guard evaluated false, the directive
was preprocessed away, and the object came out with no marker — which GNU `ld`
reads as *this object requires an executable stack*. A file that had correctly
declared it does **not** need one silently got the opposite outcome, and one
such object makes the whole link `RWE`.

That is measured here rather than assumed: on an unpatched tree `t3` reports
`GNU_STACK is RWE`, and binutils 2.44 emits
`missing .note.GNU-stack section implies executable stack`.

All 21 of `dep/libressl/crypto/bn/arch/amd64/att/bignum_*.S` end with exactly
that idiom, as do `crypto/bn/arch/amd64/*.S` and `crypto/sha/*.S`. Before this
patch, none of the 21 came out of tcc with a marker; after it, all 21 do, with
flags matching gcc's byte for byte.

## Why the fix is in `tccpp.c`, not `tccdefs.h`

`tcc_predefs()` pulls `tccdefs.h` in only when `!is_asm`. A macro defined there
is invisible while preprocessing a `.S` file — which is precisely the mode the
idiom above lives in. Moving the define into `tccpp.c`'s `target_os_defs`
table fixes both modes at once, and puts it beside the PE/Mach-O split that
already keys on output format.

`t1` is the case that discriminates the two candidate fixes: it asserts
`__ELF__` from inside a `.S`, which a `tccdefs.h`-only change would still fail.

## Scope

`target_os_defs` is already structured on the axis that matters, because
`tcc_output_file()` dispatches on exactly three formats. `__ELF__` is defined
for everything that is not PE, not Mach-O, and not `TCC_TARGET_COFF` (which
`tcc.h` sets for `TCC_TARGET_C67`, routing to `tcc_output_coff()`). That
leaves precisely the ELF-writing targets: Linux/Android, FreeBSD,
FreeBSD_kernel, NetBSD and OpenBSD.

Verified by building the cross compilers and reading their predefines:
`x86_64-win32-tcc`, `x86_64-osx-tcc` and `c67-tcc` report no `__ELF__` in
either C or assembler mode; `x86_64-tcc`, `i386-tcc` and `arm64-tcc` report it
in both. The BSD arms were checked by preprocessing the table itself under each
`TARGETOS_*` combination.

NetBSD keeps `__ELF__` despite the `tccdefs.h` line being removed — it is an
ELF target, so the new scope covers it, and it now gets the macro in assembler
mode too, which it never did before.

## The files

- `t0_elf_defined.c` — `#error`s unless `__ELF__` is defined and equal to `1`.
- `t1_elf_defined.S` — exports `elf_was_defined_in_asm` only inside
  `#ifdef __ELF__`; the symbol's presence is the measurement. Uses a symbol
  rather than `.error` because not every assembler this script runs against
  supports the latter.
- `t2_guarded_marker.S` — the real-world idiom verbatim.
- `t3_link_main.c` — a `main` so `t2`'s object can be linked by a real `ld`.

`t2` and `t3` skip off Linux, since the guard they exercise also tests
`__linux__`.
