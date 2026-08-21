# Input-side reserved-section tests (for `0009-reserved-section-input-side-gate.patch`)

Fixtures and a harness for the ordering `0007` could not see — tcc creates a
reserved section for one of its roles, and input claims the name afterwards —
plus guards for what must not change.

    ./run.sh /path/to/tcc [-B<tccdir>]

Needs `readelf` on `PATH`. The `.tcov` cases need an environment where
`-ftest-coverage` links at all (it pulls in tcc's tcov runtime, which calls
into libc); where it does not, they skip rather than fail.

Expected: **10 passed** against a tcc with `0001`–`0009` applied, and **3
failures** against an `0001`–`0008` baseline — the three orderings `0009`
fixes. The other seven pass on both: they are the regression guards.

| case | what it pins down |
|---|---|
| input object merged into tcc's `.tcov` | The gap itself. `-ftest-coverage` creates `.tcov` while compiling, before any object is merged, so the creation gate has already run; `tcc_load_object_file()`'s merge loop then matches by name and merges the input's content into tcc's coverage table. On baseline this links with exit 0 and no diagnostic at all. |
| asm `.section .tcov` | The assembler's half of the same collision: `find_section()` returns tcc's existing section, so the directive assembles straight into it. Same silent success on baseline. |
| asm `.pushsection .tcov` | Same path, second directive. A fix covering only `.section` would leave the rule trivially avoidable. |
| the reverse ordering, still refused | Guard *and* the point of the patch: the object named before the compiled source has been refused since `0007`. Asserting both directions in one harness is what pins them to the same verdict. |
| input `.tcov` without `-ftest-coverage` | Guard: the reservation follows the role, not the name. With no coverage role there is no tcc `.tcov`, so an input section may use the name — it links, runs (exit 42, read back through `foreign_value()`), and survives as exactly one ordinary section. |
| asm `.section .tcov` without `-ftest-coverage` | Same guard on the assembler path. |
| `.eh_frame` in the same ordering | Guard for `SECTION_ROLE_SHARED` through the new check. tcc creates `.eh_frame` at its first FDE while compiling `eh_main.c`, then `foreign_eh.o` is merged into it — "tcc first, input second", on a role whose answer is yes. Exit 42 is read out of the input object's section, so it proves the content merged rather than merely that nothing errored, and the section count proves one section, not two. |
| ordinary compile/link/run | Guard: refusing more must not turn into refusing everything. |

## Not covered here

`.tcov` is the only role reachable in this ordering today — every other
`SECTION_ROLE_PRIVATE` role is created during `elf_output_file()`, after all
input is merged, so input cannot arrive second for it. The gate is keyed on the
role rather than on the name, so those roles are covered by construction, but
this harness cannot exercise them from that direction.

The `.symtab` family is `SECTION_ROLE_SHARED` by deliberate decision (`0007`,
and GNU `as` does not protect it either), so nothing here asserts against it.
