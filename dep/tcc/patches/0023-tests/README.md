# `0023-run-unplaced-section-relocs.patch` — `-run` and sections with no address

The defect `0004` exposed, `0021` moved out of the way, and this patch
removes.

## What was wrong

Under `-run`, `tccrun.c` hands out runtime addresses to `SHF_ALLOC` sections
only — the `shf[]` table in `tcc_run_prepare()` matches exactly three
`ALLOC|WRITE|EXECINSTR` combinations, and everything else keeps `sh_addr == 0`
and is never copied into the run memory at all. `relocate_sections()`
relocated those sections anyway, against an address they do not have, while
the symbols they referred to had real heap addresses. So:

* a PC-relative relocation computed `symbol - 0` →
  `tcc: error: relocation '2' out of range`;
* an absolute 32-bit one wrote the symbol's real address →
  `tcc: error: relocation 'R_X86_64_32[S]' out of range`;
* an absolute 64-bit one did fit, and quietly wrote a live pointer into bytes
  nobody will ever map.

The first two aborted the run. Linking to a file never had the problem: a real
linker computes these against `sh_addr == 0` too, and the answers are just as
unread but no longer wild.

`0021` fixed the case where a section was **wrongly** non-allocated —
`.data.ignore` and bare `.section .rodata`, which `as` considers allocatable
and tcc did not between `0004` and `0021`. This is the case underneath it: a
section that is **correctly** non-allocated, which no name table can make go
away. `notspecial` in the test sources is a name `as` has no opinion about
either, so `as` and tcc agree it is not allocated.

## The fix, and why it is not "skip all non-`SHF_ALLOC` sections"

The lead recorded in `TODO.md` was "do not relocate non-`SHF_ALLOC` sections
under `TCC_OUTPUT_MEMORY`", flagged as needing its own verification because it
touches DWARF sections. Checking that out:

* the debug sections tcc's own runtime backtrace reads are **already**
  `SHF_ALLOC` under `-run`, deliberately — `tccdbg.c`'s `tcc_debug_new()` sets
  `do_backtrace` whenever `do_debug && output_type == TCC_OUTPUT_MEMORY` and
  then creates `.debug_info`/`.debug_line`/`.debug_str`/`.stab` with
  `shf = SHF_ALLOC`, with the comment "have debug data available at runtime".
  They get addresses and go on being relocated normally;
* the `rt_context` the backtrace reads is built in `.data` (`tcc_add_btstub`),
  an allocated section, and its `put_ptr`s point *at* those now-allocated
  debug sections. Nothing in `tccrun.c` reads content out of a section that
  did not get an address.

So the blanket skip would not have broken the backtrace. It would still have
thrown away one thing that is not garbage: the dwarf-to-dwarf `R_DATA_32DW`
case in `relocate_section()` subtracts the *target* section's own `sh_addr`
back out, so it yields the same section-relative offset whether or not either
section was placed. That one is correct without an address by construction,
and it is the only relocation in an unplaced section that is. The patch keeps
it running and skips the rest, which costs one condition and loses nothing.
(Reachable for a merged foreign `.debug_loc` and the six siblings
`tcc_debug_new()` creates with `shf = 0`; tcc never writes those itself.)

Gated on `output_type == TCC_OUTPUT_MEMORY`. Linking to a file is unchanged.

## Tests

`run.sh /path/to/tcc` — 12 checks. Unlike `0021-tests` and `0022-tests` this
one cannot be pointed at gcc, since `-run` has no gcc equivalent; instead every
numeric expectation is checked twice, once through `-run` and once by building
the same source into an ordinary executable with `$CC` and running that. The
two arms have to agree, which is what keeps the expectations honest.

* `t0` PC-relative, `t1` absolute 32-bit, `t2` absolute 64-bit, each in a
  genuinely non-allocated section. `t1` is not redundant: a fix that skipped
  only PC-relative relocations passes `t0` and still fails it.
* `t3` is the control in the other direction — an allocated section with an
  unrecognized name, whose relocation is still real work. The program
  dereferences the relocated pointer, so a fix that widened into "skip
  relocations under `-run`" segfaults here rather than printing a wrong
  number.
* `t4` is `-run -g`: `run.sh` checks the three backtrace frames resolve to
  `file:line`, not just that the process exited.

Results: **12/12** with `0023`; 10/12 on the `0001`–`0022` baseline, failing
exactly `t0` and `t1` with the two messages above. tcc's own `make test`
reaches `ALL TESTS PASSED` either side (alpine/musl, `./configure
--config-musl`) — including its `btest` backtrace suite — and `-run -g`
backtraces are unchanged in dwarf-4, dwarf-5 and stabs modes.
