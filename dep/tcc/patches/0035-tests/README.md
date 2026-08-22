# FDE PC-Begin addend test cases (for `0035-eh-frame-fde-pc-addend.patch`)

A harness that checks each `.eh_frame` FDE a tcc build emits names the function
it actually covers, and that GNU ld accepts the result.

    ./run.sh /path/to/patched/tcc

23 checks, no committed `.c` files — every case is a handful of functions and
they are generated in a temp directory.

## The gap

`tcc_debug_frame_end()` in `tccdbg.c` wrote each FDE's PC-Begin as an in-place
word

    dwarf_data4(eh_frame_section, func_ind);   // PC Begin

while emitting the accompanying relocation with `r_addend = 0`. tcc's own
linker adds the in-place word back in, so tcc-linked output came out right and
nothing looked wrong from inside tcc.

On a RELA target GNU ld ignores the in-place word entirely — the addend is the
whole story. So every FDE in a tcc-produced object resolved to `.text+0`. They
all overlap, and ld refuses the object outright:

    ld: .eh_frame_hdr refers to overlapping FDEs
    ld: final link failed: bad value

Which is a link-time refusal of the *whole object*, not a degraded unwind
table: nothing tcc compiled could be handed to GNU ld at all, whether or not
the program ever unwound anything.

## The fix

The offset moves into `r_addend`: a `dwarf_reloca()` taking an addend, with the
existing `dwarf_reloc()` kept as the zero-addend wrapper so no other call site
changes.

Guarded `#if SHT_RELX == SHT_RELA`, because i386 and arm are REL targets with
no addend field at all — there the offset has to stay in place. tcc's own
`make test` catches an unguarded version loudly, with `non-zero addend on REL
architecture` out of the 32-bit cross tests.

## What this unblocked

tcc-compiled LuaJIT objects could not be linked by GNU ld at all before this.
With the patch, `tcc` compiles the whole LuaJIT tree and GNU ld links it into a
working `luajit` — JIT, `pcall`, coroutines, FFI and FFI callbacks all passing.
(Owner-reported, and the reason the patch exists; this harness does not rebuild
LuaJIT.)

A fully *tcc-linked* luajit still fails `pcall`, for an unrelated reason: tcc's
linker emits no `.eh_frame_hdr` and no `PT_GNU_EH_FRAME`, so the libgcc
unwinder cannot find the table however correct it is. That is a separate known
gap, not something this patch was meant to close, and nothing here asserts
against it.

## Why this one is not a byte-parity harness

The pure-assembler harnesses next door (`0032`, `0027`, …) compare tcc's output
byte-for-byte against real `as`. That is not available here. gcc and tcc
generate structurally different `.eh_frame`: different CIE augmentation,
different CFI programs, and gcc puts `main` in `.text.startup` where tcc puts
everything in `.text`. Byte equality is not a property either compiler owes the
other, and demanding it would pin dozens of choices this patch has no opinion
about.

So the reference is GNU ld's **acceptance**, plus the **semantic content** of
the tables — which offsets the FDEs name, whether they are distinct, whether
they agree with the symbol table, whether an unwinder can walk them. Every
assertion is written as a property that holds for gcc too, which is what makes
it a reference rather than a restatement of this patch: the whole script passes
unchanged against a real gcc (`./run.sh "$(command -v gcc)"`).

## What this pins, and what it deliberately does not

It pins:

* in an **object**, that the `.rela.eh_frame` PC-Begin entries are pairwise
  distinct as `(symbol, addend)` pairs, that there is one per function, and
  that their addends are exactly the offsets of the object's `FUNC` symbols;
* that **GNU ld** links such objects — alone, several at once, mixed with gcc
  objects, out of an `ar` archive, and into a `.so` — and specifically that it
  does not report overlapping FDEs;
* in a **linked image**, that no two FDEs start at the same address and that
  each named function has an FDE starting exactly at its address, under GNU ld
  **and** under the compiler's own linker;
* that an unwinder walks four frames the compiler produced and names each one.

It does **not** pin: byte layout of `.eh_frame`, the number or contents of
CIEs, CFI opcode choice, which section a function is placed in, FDE ordering
within `.eh_frame`, or ld's error wording. That last one is asserted only in
the negative — `overlapping FDEs` must *not* appear — so a future ld that words
the failure differently still passes, and the exit status is the real gate.

### Two things the assertions are careful about

**"Nonzero addend" is the wrong property.** The first function in a section
sits at offset 0, so its FDE legitimately carries addend 0 — and a
single-function TU is a case where the bug is invisible end to end, since one
FDE cannot overlap anything. The property is *distinct, and equal to the
function offsets*, which is what is checked.

**Distinctness is on the pair, not the addend.** A compiler may spread
functions across sections; gcc puts `main` in `.text.startup`, so two FDEs
legitimately carry addend 0 against two different section symbols. Comparing
addends alone would fail a correct gcc.

## The cases

| group | what it holds |
|---|---|
| object | four functions in one TU; a lone function; file-local functions; twelve functions with offsets past `0xff`; the same four under `-g` |
| GNU ld accepts | one object; two objects; mixed with a gcc object; from an `ar` archive; `-shared`; the twelve-function object — each linked, and the executables run |
| linked table, GNU ld | an FDE at each of `f1 f2 f3 main`, all FDE starts in the image distinct |
| linked table, own linker | the same, via the compiler under test doing its own link |
| end to end | `_Unwind_Backtrace` through three tcc frames plus `main`, each frame resolved by name |

The own-linker rows are the "tcc's own output did not regress" half, and they
matter more here than they would elsewhere: tcc's linker *does* add the
in-place word, so it is exactly the consumer a fix of this shape could break.

The linked-image rows build with `-rdynamic`. That is only so the function
names survive into a symbol table both linkers write — tcc's linker emits no
`.symtab` into an executable, so the names are read out of `.dynsym`. It has
nothing to do with what is being checked.

The unwind case resolves frames through `dladdr` rather than by comparing
addresses against `nm` ranges, so it does not assume the compiler emits
functions in source order — an assumption that a first draft made and that tcc
promptly broke. It was run 20 times over for flakiness; 20 clean.

## Baselines

| build | result |
|---|---|
| the stack up to `0034` | `pass=4 fail=19` |
| plus this patch | `pass=23 fail=0` |
| a real gcc | `pass=23 fail=0` |

The four that already passed on the unpatched build are the single-function
object (where one FDE cannot overlap) and the three own-linker rows — i.e.
exactly the behaviour this patch must not disturb. Every other row failed, and
the object-level ones failed by printing four identical `.text 0` pairs, which
is the bug stated as directly as it can be.

## Deliberately absent

**Unwinding through a tcc-*linked* binary.** It does not work, for the
`.eh_frame_hdr` reason above, which is a different gap. Asserting either
outcome here would tie this harness to a bug it does not own.

**A C++-style forced unwind.** There is no C++ compiler in the picture, and
`_Unwind_Backtrace` exercises the same table walk through the same frames.

**REL targets (i386, arm).** The `#if SHT_RELX == SHT_RELA` guard means those
targets keep the in-place word and are unchanged by this patch, and the
vendored build is x86_64-only, so there is nothing here to run against. tcc's
own `make test` cross-tests are what cover that half.

**A negative control for the unwind case.** The unpatched build cannot produce
a GNU-ld-linked binary at all, so there is no "same program, broken table" to
run — the before/after for that row is the link refusal, not a bad backtrace.

**gcc's `-O2` collapsing the file-local case.** Under an optimising reference
compiler the two `static` functions are inlined away and the case degenerates
to a single FDE; it still passes, but it carries weight only for tcc. Forcing
it with `noinline` would put an attribute in the path that tcc and gcc need not
agree about.
