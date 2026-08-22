# `0022-asm-section-type.patch` — section `sh_type`

`0021-asm-section-name-attrs.patch` taught tcc that a section NAME carries
flags, and said in its own comment that it was deliberately leaving `sh_type`
alone rather than half-doing it inside a flags table. This is that other half.

## What was wrong

tcc left every section its `.section` directive created `SHT_PROGBITS`. It
derived the type from neither of the two places GNU `as` derives it from:

* the section **name** — `bfd_elf_special_sections` in binutils' `bfd/elf.c`
  gives `.bss*` and `.tbss*` `SHT_NOBITS`, `.note*` `SHT_NOTE`,
  `.init_array*` / `.fini_array*` / `.preinit_array*` the three array types,
  `.dynamic` `SHT_DYNAMIC`;
* the directive's own **`@type` argument** — `.section name,"flags",@nobits`.
  tcc parsed that argument and threw it away: two bare `next()` calls in the
  `TOK_ASMDIR_section` handler consumed the `@` and the word after it and did
  nothing with either.

Visible cost: a tcc-assembled `.bss.foo` occupied file space where an
`as`-assembled one does not, and `@nobits` — the way to ask for that on a name
with no special meaning — did nothing at all.

## What `as` actually does

The name-vs-argument interaction is **not** the same rule as `0021`'s
flags rule, so it is worth stating exactly. When both apply and disagree, `as`
honours the argument and warns `setting incorrect section type`, with one
exception it spells out in `gas/config/obj-elf.c`: for `SHT_INIT_ARRAY`,
`SHT_FINI_ARRAY` and `SHT_PREINIT_ARRAY` it keeps the **name's** type and warns
`ignoring incorrect section type` instead, because older gcc emitted

```
.section .init_array,"aw",@progbits
```

for `__attribute__((section(".init_array")))` and `as` refuses to believe it.
So:

```
.section .bss.foo,"aw",@progbits        ->  PROGBITS   (argument wins)
.section .init_array.1,"aw",@progbits   ->  INIT_ARRAY (name wins)
```

A rule of "argument always wins" and a rule of "name always wins" each get one
of those wrong; both directions are in `run.sh`.

`as` reaches any of this only for a section the directive is *creating* — an
existing section keeps what it had, warning `ignoring changed section
attributes`. tcc's handler was already gated on exactly that
(`old_nb_section != s1->nb_sections`), which is why the patch needs no new
gate. `as` warns on every mismatch and tcc says nothing; that is the same
diagnostic gap `0021` left, not a layout one.

Three further details the table encodes, each measured rather than assumed:

* `.note` matches **any** suffix (binutils `suffix_length == -1`), so
  `.notefoo` is a note section — unlike `.text`/`.bss`/`.data`, which take a
  dotted suffix only.
* `.note.GNU-stack` is its own exact entry ahead of `.note`, because `as`
  gives the bare name `SHT_PROGBITS` and only `.note.GNU-stack.something`
  falls through to `SHT_NOTE`. tcc records stack requirements against that
  section (`create_gnu_stack_section`, patches `0014`/`0019`), so a wrong type
  there would have been visible immediately.
* `.gnu.linkonce.b*` is `SHT_NOBITS` with `SHF_ALLOC|SHF_WRITE`. `0021`'s
  table omitted it; `0022` adds the row, so it incidentally closes that flags
  gap too.

An unrecognized type name (`@bogus`) behaves as if no argument had been given,
which is `as`'s own fallback after its `unrecognized section type` warning. A
bare number is accepted, as `as` accepts it — `@0x70000001` really does come
out `SHT_X86_64_UNWIND`.

## What is **not** fixed

`as` refuses a non-zero store into a `SHT_NOBITS` section
(`attempt to store non-zero value in section '.bss.foo'`); tcc drops the bytes
silently. That divergence is not new — tcc already did it for its own built-in
`.bss` — and `0022` only extends the set of names it applies to. Zero fill is
byte-identical to `as`. There is a `TODO.md` item.

## Tests

`run.sh /path/to/tcc` — 44 checks, generated rather than committed as ~44
near-identical one-line `.S` files, since the table *is* the test. Covers
name-implied types, names that imply `PROGBITS` (so a wrong row shows up
rather than silently agreeing with the default), the match boundaries in both
directions, every `@type` spelling including `%` and a bare number, and both
directions of the precedence rule.

* against the patched tcc: **44/44**
* against a real gcc (binutils 2.44 `as`): **44/44** — which is what makes the
  expectations a reference and not this patch's own opinion
* against the `0001`–`0021` baseline: 16/44

`0021-tests/run.sh` still scores 61/61 against the patched binary, so the table
restructure moved no flags. tcc's own `make test` reaches
`ALL TESTS PASSED` with and without `0022` (alpine/musl, `./configure
--config-musl`), and the vendored luajit `lj_vm.S` and all seven libressl
`crypto/*/*-elf-x86_64.S` objects are byte-identical either side of it.
