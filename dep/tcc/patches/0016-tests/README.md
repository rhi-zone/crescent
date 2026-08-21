# `.rept` replay test cases (for `0016-asm-rept-replay-double-capture.patch`)

Assembly inputs for `.rept` in a unit that needs a second layout pass, plus a
harness that diffs a tcc build's `.text` against real GNU `as`.

    ./run.sh /path/to/patched/tcc

The bug this patch fixes only appears when two mechanisms meet. `.rept`
replays its body by pushing the recorded tokens back through the assembler
(`begin_macro`). LEB128 relaxation (patch `0005`) records the *whole* token
stream on the first pass and re-assembles from it if a `.uleb128` width guess
was too small. Before this patch the replayed body was recorded too — landing
in the stream immediately after the `.rept`/`.endr` that produces it — so the
second pass expanded the body and then found another copy of it sitting there.

Each `t*.S` is compared byte-for-byte. That bar is right here because the
files are straight-line and the entire question is how many copies of a body
reached `.text`, which is exactly what the bytes say.

| case | what it pins down |
|---|---|
| `t0_rept_control` | `.rept` with nothing forcing a second pass — worked before this patch, and separates a regression in `.rept` itself from one in the interaction |
| `t1_rept_relaxed` | `.rept` plus a forward `.uleb128` label difference wide enough to force a replay: the minimal form of the bug |
| `t2_rept_around_relaxation` | three `.rept` blocks on both sides of the relaxation site, so a suppression that leaked (never restored) and one that never applied both show up |

Against the `0001`–`0015` baseline the same harness reports `pass=1 fail=2`:
the control passes, and both relaxed cases fail with `end of line expected` —
the doubled body desynchronizes the statement loop before it can even emit the
extra copies.

Nested `.rept` is deliberately absent. tcc's body scan stops at the first
`.endr` rather than counting depth, so nesting has never worked, before this
patch or after it. Recorded in TODO.md; not this patch's subject.
