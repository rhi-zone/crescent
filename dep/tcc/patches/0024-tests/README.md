# `0024-asm-nobits-content.patch` — content in a `SHT_NOBITS` section

`0022-asm-section-type.patch`'s README ends with a section called "What is
**not** fixed", and this is that thing.

## What was wrong

A `SHT_NOBITS` section has a size in the object file and no bytes. It says
"reserve this much zeroed space", and there is nowhere in it for a non-zero
byte to live. GNU `as` refuses the attempt. tcc reserved the space, dropped
the value, and said nothing — so

```
.section .bss.foo,"aw"
.long 0xdeadbeef
```

assembled quietly and produced four zero bytes at run time.

The silent drop is **not** new and is not `0022`'s doing: tcc's own built-in
`.bss` has always been `SHT_NOBITS`, and always swallowed writes into it. What
`0022` changed is the reach. Once the section type is derived from the name and
from `@type`, every name `as` calls `NOBITS` — `.bss.foo`, `.tbss*`,
`.gnu.linkonce.b*`, and any name declared `,@nobits` — lands on the same
silent drop that only `.bss` used to. Widening a gap is a reason to close it.

## What `as` actually does

Not one message. Three errors and a warning, and which one you get depends on
the **directive**, not on the value:

| directive | `as` | frequency |
| --- | --- | --- |
| `.byte` `.word` `.short` `.value` `.int` `.long` `.quad` `.uleb128` `.sleb128` | Error: `attempt to store non-zero value in section `NAME'` | once per offending **value** |
| `.ascii` `.asciz` `.string` | Error: `attempt to store non-empty string in section `NAME'` | once per non-zero **byte** |
| `.fill` | Error: `attempt to fill section `NAME' with non-zero value` | once per **directive** |
| `.skip` `.space` `.align` `.balign` `.p2align` with a fill value | **Warning**: `ignoring fill value in section `NAME'` | once per directive |

That last row is the one it is easiest to get wrong in the direction of a
spurious error. The *size* those directives ask for is entirely legitimate —
reserving zeroed space is the whole purpose of a NOBITS section — and only the
fill byte has nowhere to go, so `as` drops the byte, warns, and carries on
with a successful assembly. tcc already ignored the fill; it just did so
without saying anything.

Two details of `as`'s test read backwards from the obvious guess, so both are
pinned in `run.sh`:

* The value is tested **as written, before truncation** to the field.
  `.byte 256` stores a zero byte and is still an error; so is
  `.fill 4,1,256`.
* Constant folding happens **first**, and a relocation counts as non-zero
  whatever its addend — the linker is going to write something there.
  `.long 1-1` and `foo: .long foo-foo` fold away to nothing and pass, while
  `foo: .long foo` is an error even though `foo` sits at offset 0.

`as` does not police machine instructions at all: `nop` in `.bss` assembles,
grows the section by two bytes and warns about nothing. tcc's instruction path
is therefore left alone.

Errors use `tcc_error_noabort`, so that like `as` every offending value in a
directive is reported and the assembly then fails, rather than the first one
aborting the run.

## What stays legal

Everything a NOBITS section is actually for, all silent, all reserving exactly
as much space as before: `.byte 0`, `.long 0`, `.quad 0`, `.uleb128 0`,
`.skip N`, `.skip N,0`, `.space N`, `.fill N,M,0`, `.fill` with no fill
argument, `.align N`, `.org N`, `.asciz ""`, and an embedded `\0`. A fill that
emits no bytes at all (`.fill 0,1,7`, `.fill 4,0,7`) never reaches `as`'s check
and does not error either.

`PROGBITS` sections are untouched — including `.section .bss.foo,"aw",@progbits`,
which by `0022`'s precedence rule really is a writable PROGBITS section despite
the name.

## What is **not** fixed

* **`.zero N`** — `as`'s third spelling of `.skip`/`.space` — is absent from
  tcc entirely. It is `unknown opcode '.zero'` in `.text` just as much as in
  `.bss`, so it is a missing directive rather than a NOBITS diagnostic, and
  not this patch's to add. `TODO.md` carries it.
* `.skip 0,<non-zero>` warns `ignoring fill value` here where `as` says
  `.space repeat count is zero, ignored` instead. That second warning is not a
  NOBITS matter at all — `as` emits it in `.text` and in `PROGBITS` sections
  too — so it is its own gap, also in `TODO.md`.
* `.org` still ignores a second (fill) argument rather than parsing it, which
  predates this patch and is why `.org` appears in `run.sh` only in its
  one-argument form.

## Tests

`run.sh /path/to/tcc` — 62 checks, generated rather than committed as ~62
near-identical `.S` files. Each case pins a *classification* (silent success
with an exact section size / warning / error), the message text, and for
errors and warnings the **number** of times the message appears, which is what
catches a once-per-directive rule implemented once-per-byte or vice versa.

* against the patched tcc: **62/62**
* against a real gcc (binutils 2.44 `as`): **62/62** — which is what makes the
  expectations a reference and not this patch's own opinion
* against the `0001`–`0023` baseline: 28/62

`0005`–`0023`'s own harnesses all still pass against the patched binary, and
tcc's own `make test` reaches `ALL TESTS PASSED` both on glibc
(`debian:bookworm`) and on musl (`alpine:latest`, `./configure --config-musl`),
with and without `0024`. A freshly generated luajit `lj_vm.S` and all seven
libressl `crypto/*/*-elf-x86_64.S` objects are byte-identical either side of
the patch and draw no new diagnostics, and a luajit relinked against the
tcc-assembled `lj_vm.o` runs with the JIT enabled.
