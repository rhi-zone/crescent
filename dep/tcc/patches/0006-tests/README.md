# Dwarf section-flag / debug-retention tests (for `0006-dwarf-section-flag-and-debug-retention.patch`)

Fixtures and a harness for the two behaviours `0006` changes, plus guards for
the behaviours it must *not* change.

    ./run.sh /path/to/tcc [-B<tccdir>]

Needs `gcc`, `readelf` and `objcopy` on `PATH` to build the foreign objects.
Exits 77 if this `gcc` cannot produce a `.debug_types` section.

Expected: **10 passed** against a tcc with `0001`–`0006` applied, and **3
failures** against an `0001`–`0005` baseline — the three that `0006` fixes.
Everything else passes on both, which is the point: they are the regression
guards, not the feature.

| case | what it pins down |
|---|---|
| `.debug_types` under `-gdwarf` | The bug. A `gcc -fdebug-types-section` object merges `.debug_types` outside tcc's `dwlo..dwhi` block, so its references to tcc's own (`SHF_ALLOC`, high-address under `-run`) `.debug_abbrev`/`.debug_str`/`.debug_line` were resolved as absolute addresses and overflowed. Fails on baseline with six `relocation 'R_X86_64_32[S]' out of range`. Checked by exit code (8 = `g_obj.a + 1`), so it proves the link produced *working* code, not merely no error. |
| same object under `-g0`/`-g`/`-gstabs` | The other `-g` levels never hit the overflow (tcc's debug sections are not `SHF_ALLOC` there). Guards against the fix breaking them. |
| retention without `-g` | `tccelf.c`'s `!s1->do_debug` gate dropped foreign debug sections entirely, and `set_sec_sizes` left `sh_size` unpublished so they were dropped even once retained. Both are fixed; the harness also checks the retained info actually *parses* and names the foreign CU, not just that sections are present. |
| non-debug object at `-g0` | Guard: nothing invents debug sections that were never there. |
| compressed debug sections | Guard on a **documented limitation**, not a feature: tcc cannot decompress `SHF_COMPRESSED`, so it skips retention for the whole object. This must stay a silent skip. Since modern gcc compresses by default, this is why retention rarely helps against real-world gcc output. |
| foreign `.stab` at `-g0`/`-gstabs` | Guard on a deliberate scoping decision. `.stab` is **not** retained without `-g`: the out-of-range suppression in `x86_64-link.c` is scoped to tcc's own `stab_section`, so retaining a foreign `.stab` would turn these working links into hard errors. Passes on both baseline and patched — that is what "deliberately unchanged" looks like. |

## Fixture notes

`fstab.S` declares its sections as `.xstab`/`.xstabstr` and `run.sh` renames
them with `objcopy` afterwards. GNU `as` 2.44 hits an internal error on a
literal `.section .stab` (stabs support is being withdrawn from binutils), so
the names cannot be written directly.

`main.c` is used for `-run` cases and `start.c` for link-to-file cases: a
`-nostdlib` link to an output file needs `_start`, not `main`.

## Not covered here

The byte-identity comparisons against an unpatched baseline (`-c` and link ×
`-gdwarf`/`-g`/`-gstabs`/`-g0`/`-O2`, merged dwarf-4 and dwarf-5 objects, PE
cross-compiled output, `dep/luajit/src/lj_vm.S`) were run during development
and are recorded in `TODO.md`. They need two tcc builds to compare, so they
are not part of this single-binary harness.
