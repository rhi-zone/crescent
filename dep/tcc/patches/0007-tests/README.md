# Reserved-section / eh_frame tests (for `0007-reserved-section-gate-and-eh-frame-retention.patch`)

Fixtures and a harness for the three behaviours `0007` changes, plus guards for
the behaviours it must *not* change.

    ./run.sh /path/to/tcc [-B<tccdir>]

Needs `gcc` and `readelf` on `PATH`. Several cases assert equality with GNU
`as` output rather than against a hardcoded expectation, so they stay honest if
the reference toolchain changes.

Expected: **18 passed** against a tcc with `0001`–`0007` applied, and **8
failures** against an `0001`–`0006` baseline — the eight that `0007` fixes.
The other ten pass on both, which is the point: they are the regression guards,
not the feature.

| case | what it pins down |
|---|---|
| no `.eh_frame` for pure asm | The orphan CIE. tcc wrote its `.eh_frame` CIE at session start, before reading any input, so assembling a `.S` file produced a section holding a CIE with no FDE after it — describing nothing. GNU `as` emits no such section, and the harness asserts against `as` rather than against a fixed count. |
| `.eh_frame` byte-identical to GNU `as` | `ehown.S` carries its own hand-written CIE + FDE, the shape `buildvm` emits for LuaJIT's `lj_vm.S`. tcc generates no FDEs for a `.S`, so it must contribute *nothing* here. On baseline tcc's own CIE is prepended (on real `lj_vm.S`: 144 bytes where `as` produces 120). |
| retention with unwind generation off | The hard failure, not a quality bug. `ehref.S` relocates into its own `.eh_frame`; linked with `-fno-asynchronous-unwind-tables` the input section used to be dropped, leaving the relocation dangling — baseline reports `Invalid relocation entry [ 8] '.rela.text'`. Checked by exit code (42, read back out of the retained section) so it proves the link produced *working* code, not merely no error. |
| same link with unwind generation on | Guards the case that already worked, so the retention change cannot be "fixed" by breaking the other direction. |
| one shared `.eh_frame` across producers | The `SECTION_ROLE_SHARED` path: `unwind.c` (tcc generates FDEs) linked with `ehref.o` (input `.eh_frame`) must yield exactly **one** section, not two, with the merged CIE/FDE chain still walkable by `readelf --debug-dump=frames`. Exit code 43 proves both producers' content survived. |
| `.got`/`.interp`/`.dynamic`/`.dynsym` refused | The `SECTION_ROLE_PRIVATE` path. On baseline each of these links with **no diagnostic at all** and produces an executable containing two sections of that name. The harness asserts both halves: the diagnostic appears *and* no output file is written. Each fixture is self-contained (its own `_start`) so the reserved-name error is the only thing that can fail the link. |
| `.plt` refused | Same policy, separate case because `.plt` only comes into being when a `JMP_SLOT` relocation needs it — that requires a real dynamic link, so this one uses libc instead of the `-nostdlib` path and skips if the environment cannot link dynamically at all. |
| ordinary compile/link/run | Guard: tcc must still emit its own `.eh_frame` when it *does* have FDEs, and ordinary code must still build and run. Laziness must not turn into never. |

## Not covered here

The gate protects a role only when input names the section *before* tcc's
internal creator runs. The reverse order — `.tcov` under `-ftest-coverage`, and
the `.symtab` family, both created before input objects are merged — is a known
open asymmetry recorded in `TODO.md`, not a case this harness asserts.
