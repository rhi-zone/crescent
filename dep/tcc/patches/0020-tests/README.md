# `0020-tinyc-version-predefine.patch` tests

```
run.sh /path/to/tcc
```

Five checks. Against a tcc built with patches `0001`–`0019` but not `0020`,
three fail; with `0020` applied, all five pass.

Unlike `0019-tests`, this script is **not** meaningful against a real gcc —
`__TINYC__` is tcc's own identity macro, so `run.sh "$(command -v gcc)"`
fails t1–t4 by construction and that is not a signal. The external reference
here is upstream tinycc's `VERSION` file at the pinned commit, quoted below,
not another toolchain.

## What was wrong

Upstream computes `__TINYC__` by slicing its own version string, in
`tccpp.c`'s `tcc_predefs()`:

```c
cstr_printf(cs, "#define __TINYC__ 9%.2s\n", &TCC_VERSION[4]);
```

`"0.9.XX"` → `9XX`. `TCC_VERSION` is whatever `./configure` (or
`win32/build-tcc.bat`) read out of the `VERSION` file.

crescent overwrites `dep/tcc/VERSION` with the vendored mob-branch commit SHA,
following the `dep/<name>/VERSION` convention every vendored dep uses — mob is
untagged and rolling, so a SHA is the only pin that can name this exact source.
The slice then ran over a SHA. Offset 4 of
`2ba12e83b3599ca8f5d50c179fe5138fe956f0c9` is `2e`, so tcc predefined:

```
#define __TINYC__ 92e
```

which is not a preprocessor number. Every `#if __TINYC__` in every source that
tcc compiled failed with `error: exponent digits expected` — including tcc's
own `tests/tcctest.c:338`, which is why `make test1` / `make test3` could never
pass. This predates the entire patch stack; it is a consequence of vendoring,
present on a pristine unpatched tree.

## What the fix does

The two meanings that got conflated are split apart rather than one being
chosen over the other:

- `TCC_VERSION` keeps meaning **which commit is vendored**. It stays the SHA;
  `tcc -v`, the DWARF producer string and `tcc.1` still report it. Nothing
  about the reproducibility pin moves or changes.
- A new `TCC_UPSTREAM_VERSION` in `tcc.h` means **what this source calls
  itself**, and is what the slice reads.

Its value is upstream's, not an invention: tinycc's own `VERSION` file at
commit `2ba12e83b3599ca8f5d50c179fe5138fe956f0c9` contains `0.9.28rc`
(corroborated in-tree by `Changelog`'s top entry, `version 0.9.28:`, and by
`win32/tcc-win32.txt`, which names "TinyCC 0.9.28rc"). Upstream's own rule then
gives `928`, so a tcc built from this tree now reports exactly what a tcc built
from unmodified upstream at that commit would.

**Re-vendoring:** if the pin moves to a commit whose upstream `VERSION` differs,
`TCC_UPSTREAM_VERSION` in this patch must be updated to match it, and `t1`/`t2`'s
expected `928` with it. The comment in `tcc.h` says so at the definition site.

## The checks

| | discriminates? | |
|---|---|---|
| `t0` | yes | plain `#if __TINYC__`, the shape at `tests/tcctest.c:338`. A `#ifdef` would pass either way and would not discriminate. |
| `t1` | yes | `__TINYC__ == 928` exactly. Merely *parsing* is not enough — real code writes `#if __TINYC__ >= 927`, so the number has to mean what upstream means by it. |
| `t2` | yes | same, for a `.S` input. `tcc_predefs()` runs for asm too (its `is_asm` argument), so the bug reached preprocessed assembly — the file kind this whole patch series exists to assemble. |
| `t3` | no | `__TINYC__` is still defined at all. Guards against the cheapest wrong fix — dropping the predefine — which would break every `#ifdef __TINYC__` in tcc's own `tcc.h`, `lib/` and `tests/`. |
| `t4` | no | `tcc -v` still reports the pin, read from `dep/tcc/VERSION` rather than hardcoded. Guards against the other tempting wrong fix — putting a real version back into `VERSION`, which silently discards the vendoring pin. |
