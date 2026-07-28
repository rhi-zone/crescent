# Dispatch determinacy survey: ground-truth fold catalog

## Purpose and scope

This is **not** a prevalence survey and does not deliver a verdict on whether
"enumeration + rule + deviations" is a good model. That framing was tried and
retracted mid-survey (see history below) because it asks the wrong question.

The corrected question: a generator is a deterministic function from context
to output. Where a rule determines an arm, that arm is **forced** — it costs
the encoding nothing, however many times it repeats. Where nothing in context
determines an arm, that arm is a **free decision** and must be recorded in
full. Some dispatch sites are **folds**: one enumeration plus one rule that
forces every arm. If a fold-shaped site exists in `lib/` and an encoder cannot
express it as a fold, the encoder will record N free decisions where exactly
one exists — that is a correctness bug in the encoder, not a coverage gap, and
it does not matter whether folds are common or rare. Conversely, a site that
looks like a fold on its enumeration but whose arms are genuinely independent
must **not** be forced into fold shape; the arms are real free decisions, and
that is the expected, correct outcome for irreducible code.

This document exists to give the encoder work concrete ground truth: real
fold and partial-fold sites, with the exact forced/free split, and real
non-fold sites, so neither shape gets misencoded in either direction. It
carries no aggregate deviation-rate statistics and no prevalence claim,
because prevalence was never the question — one missed fold is a wrong
reading regardless of how the rest of the sample looks.

**Methodology note on this document's own history**: the original brief for
this survey asked for per-site "deviation rates" and an aggregate verdict.
That framing was corrected twice by the project owner mid-survey: first to
require shape classification before counting (not every switch is a fold),
then to drop prevalence and verdict scoring entirely, since a fold the
encoder can't express is a false reading independent of how often folds
occur. The raw per-site reads below were gathered under the earlier framing
but are reported here reclassified by shape, per the corrected model. No
percentage-based conclusion appears in this document.

All citations below were read directly from source, either by the surveying
agents or (for the three flagship fold examples) re-verified directly against
the file in this session.

---

## Part 1 — Fold and partial-fold sites (ground truth)

These are the cases an encoder must be able to express as a fold (or as a
fold plus a small, explicit free set), because the codebase itself contains
only that much information at these sites.

### 1.1 JSON decoder value dispatch — clean fold

`lib/format/json/pure.lua:471-633` (`decode_raw`, function body inside a
`goto`-based loop; the arms are the `elseif b == <byte>` branches at lines
471, 475, 481, 487, 493, 551, 576, with a final `else` at 631).

- **Enumeration**: JSON's 7 value productions (RFC 8259: object, array,
  string, number, `true`, `false`, `null`), keyed by the value's leading
  byte. Closed by the JSON grammar — there is no 8th production to add.
- **Rule**: "leading byte b selects the production; consume the fixed literal
  or invoke the value's specialized sub-parser."
- **Forced**: all 7 arms, plus the terminal `else decode_error(...)` (line
  631-632), which is itself forced by the same rule ("anything not matching
  one of the 7 productions is a syntax error" — RFC 8259 defines no other
  outcome). This is 8 forced elements over a closed enumeration with zero
  free arms.
- **Free**: nothing at the arm level. One structural note, not a deviation:
  the number arm (493-549) inlines a copy of `decode_number` rather than
  calling it, for performance (comment at 440-443 in the same file explains
  this as a goto/iterative rewrite). That is an implementation-strategy
  choice about *how* to execute the forced logic, not a different forced
  outcome — worth flagging so an encoder doesn't mistake code duplication
  for semantic deviation.
- **Exhaustiveness**: mechanically checkable — the byte space partition is
  closed and the default branch is explicit and unconditional.

### 1.2 JSON string escape dispatch — fold with one differently-forced arm

`lib/format/json/pure.lua:333-368` (inside `decode_string`).

- **Enumeration**: JSON's 9 permitted escapes (RFC 8259 §7): `" \ / b f n r
  t u`. Closed by spec.
- **Rule A** (forces 8 of 9 arms): "for escape byte E, append E's single
  fixed replacement character."
- **Rule B** (forces the 9th arm, `\u`, lines 341-365): "parse 4 hex digits
  following `u`; if the result is a high surrogate, look for a following
  low-surrogate escape and combine them per UTF-16 surrogate-pair rules."
  This is a second rule, not a deviation from Rule A — any correct JSON
  decoder must implement it exactly this way; a generator with the JSON
  spec in context derives Rule B the same way it derives Rule A.
- **Forced**: 9/9, under two rules rather than one. **Free**: none. This is
  the clearest example in the survey of "more than one rule, still zero free
  arms" — important because it shows fold-shape does not require a single
  uniform rule, only that every arm be *determined* by *some* statable rule.
- **Exhaustiveness**: explicit default (`error("invalid escape sequence")`,
  366-367), forced by spec closure.

### 1.3 `asm/cpu.lua` arch × OS feature detection — clean fold, exhaustive by construction

`lib/asm/cpu.lua:173-214` (verified directly, lines 160-217 read in full this
session).

- **Enumeration**: `M.arch ∈ {x86_64, aarch64, else}` × `os_jit ∈ {Linux,
  OSX, else}` — 9 leaf cells, 6 real + 3 "unknown" collapse cells.
- **Rule**: "for (arch, os), attempt the matching `detect_<os>_<arch>`
  function inside `pcall`; on any failure (or on an unrecognized OS/arch),
  reset that architecture's flags to false and set that architecture's
  spec-mandated baseline flag true (`sse2` for x86-64, `neon` for aarch64)."
- **Forced**: all 9 cells. The 6 real (arch, OS) pairs share the pcall/reset
  pattern exactly; the 3 "other OS" cells collapse cleanly into "skip
  detection, apply baseline" under the same rule; the final `else` (unknown
  arch, line 210-213) is the rule's own base case, not an exception to it —
  it sets both architectures' flags false because neither applies.
- **Free**: none found. The one piece of real content is not an arm at all —
  it's the two baseline-flag facts ("sse2 is mandatory for x86-64," "neon is
  the effective aarch64 baseline"), which are external ISA facts the rule
  cites, not decisions made at this dispatch site.
- **Exhaustiveness**: mechanical — every branch has an explicit `else`, no
  path returns without setting all flags.

### 1.4 `narrow.lua` — `info_name_id`: fold with one genuine exception and one drift arm

`lib/type/static/narrow.lua:529-556` (verified directly this session).

- **Enumeration**: the 8 `NarrowInfo.kind` string tags used throughout this
  file: `negation, nil_check, field_disc, lit_eq, enum_eq, field_presence,
  type_check, guard_check`. Not declared as a table anywhere — implicit in
  which `elseif` arms exist across this file's several dispatchers.
- **Rule**: "return `info.name_id`, the name this narrowing info targets."
- **Forced**: 6 of 8 kinds (`nil_check, type_check, lit_eq, guard_check,
  field_disc, enum_eq` — lines 530-534, 537-538) all return the literal
  `info.name_id`, written as three separate `elseif` conditions (530-532,
  533-534, 537-538) rather than one combined condition, but the *value*
  every one of them returns is identical and forced by the same rule.
- **Free, genuine**: `field_presence` (535-536) returns `info.obj_name_id`
  instead — a real, principled exception: this kind targets a *field on* an
  object rather than a bare variable, so the name it targets is structurally
  a different field. This is one free fact ("field_presence targets the
  object, not itself") that must be recorded.
- **Free-looking but actually drift**: `negation` (539-554) does not recurse
  into `info_name_id(info.inner)` — even though the *sibling* dispatcher in
  the same file, `apply_narrowing` (line 347-349), handles `negation` by
  recursing exactly that way one function above. Instead it re-implements
  the entire 6-vs-1 dispatch inline a second time (541-549). The *output*
  this arm produces is fully determined by the same forced rule applied
  recursively — nothing new is being decided here — but the code expresses
  that forced result through duplicated logic instead of the one-line
  recursive call available in the same file. This is not a free decision to
  record; it's an inconsistency between two functions that should encode
  the same forced fact once. Flagging it as drift, not as content.
- **Exhaustiveness**: falls through to `return nil` (555) for any
  unrecognized kind or a nested negation-of-negation — silent, undiagnosed.

### 1.5 `narrow.lua` — `apply_narrowing`: partial fold, most arms genuinely free

`lib/type/static/narrow.lua:344-525` (verified directly this session), same
8-kind enumeration as 1.4, different dispatcher.

- **Forced (clean, 1 arm)**: `negation` (347-349) — "recurse with the
  truthy/falsy direction flipped." A one-line, fully general rule.
- **Forced (shared rule, written twice, 2 arms)**: `type_check` (472-495)
  and `guard_check` (496-520) are line-for-line the same algorithm ("build a
  target type; if truthy-branch direction matches, keep union members
  unifying with target (or return target directly for non-unions);
  otherwise subtract target from the type") — the two arms are forced by
  one rule but implemented as two independent copies rather than one shared
  helper. Same drift pattern as 1.4's `negation` arm: the *content* is
  forced (zero free information beyond "same rule as guard_check"), but the
  code doesn't express the sharing.
- **Free (3 arms, genuinely)**: `field_disc`, `lit_eq`, `enum_eq` (399-462)
  share only a loose two-branch shape ("truthy narrows to match, falsy
  subtracts") — the *test* used to decide "match" differs per arm
  (`narrow_by_field` vs. literal `try_unify` vs. enum-member `try_unify`,
  each against a different value shape). A generator would need to be told,
  per arm, what the match test is — that is exactly the free information a
  fold cannot absorb. These 3 arms are real decisions.
- **Free (1 arm, documented exception)**: `field_presence` (463-471) departs
  from even the loose two-branch shape on purpose — its falsy branch is
  explicitly conservative and does *not* mirror the truthy branch (comment:
  "don't narrow to nil in the falsy direction"). This is a real, named
  design decision, not drift.
- **Free (1 arm, irreducible)**: `nil_check` (350-398) is the most complex
  arm in the function — it additionally handles deferred `TAG_VAR`
  resolution via a `C_NARROW_NIL` constraint (356-368) and subtracts the
  literal-false member for boolean truthiness (371-374), neither of which
  has an analogue in any other arm.
- **Net for this site**: of 8 arms, 1 is cleanly forced, 2 are forced-but-
  duplicated (drift, not free content), and 5 are genuinely free decisions
  (3 with a shared loose shape but per-arm-free match logic, 2 fully
  independent). This is a partial fold where the free set is the majority —
  reported plainly as such, per the corrected model: that is the correct
  reading, not evidence against the fold model. The fold model correctly
  identifies the 1 (or 3, counting the duplicated pair) forced arms as free
  of cost; it does not claim the other 5 should have been forced.

### 1.6 `solve.lua` — constraint-kind dispatch: partial fold, 2 of 16 forced by a stated rule

`lib/type/static/solve.lua:4225-4241` (dispatch table), functions spanning
597-4280.

- **Enumeration**: 16 `C_*` constraint-kind constants (defined in
  `constrain.lua`, imported at solve.lua:58-74): `C_UNIFY, C_SUB, C_INDEX,
  C_CALLABLE, C_ARITH, C_RETURN, C_COMPARE, C_BOUND, C_OR, C_AND,
  C_BIND_GENERICS, C_CHECK_ARGS, C_OVERLAP, C_NARROW_NIL, C_ESCAPE_CHECK,
  C_HKT_DECOMPOSE`.
- **Forced (2 arms)**: `solve_or` and `solve_and` are explicitly marked in
  a code comment ("Symmetric with solve_or", ~line 1023-1027) as sharing one
  rule: "defer if the left side is still a free type variable; otherwise
  compute the truthy/falsy part of the left side combined with the right
  side via a shared `falsy_part`/`truthy_part` helper." Both functions call
  the same two named helpers — this is a rule stated *in the code itself*,
  not inferred from outside, which makes it strong ground truth for a fold.
- **Free (14 arms)**: every other constraint kind implements a distinct
  algorithm with no attempted or findable shared rule — function lengths
  range from 17 lines (`solve_unify`) to 666 lines (`solve_index`) with no
  common shape between them (subtyping vs. unification vs. arithmetic
  overload resolution vs. generic instantiation are different problems by
  construction). These 14 are free decisions in the fullest sense: each is
  its own algorithm and none of it is derivable from "this is a constraint
  solver."
- **Reading**: 2/16 forced is a small forced set, but it is a real one,
  named in the code's own comments — exactly the kind of fold an encoder
  must not miss just because most of the table isn't fold-shaped.

### 1.7 `lib/locale/init.lua` — `PLURAL_RULES`: fold at the aliasing layer

`lib/locale/init.lua:341-401`.

- **Enumeration**: 14 language codes.
- **Rule**: "assign each language code to one of 5 CLDR plural-rule-family
  functions; languages in the same family point at the literal same
  function object" (aliasing at lines 354-366, 381).
- **Forced**: 9 of the 14 language-code arms are forced once their family is
  chosen — `de, nl, es, it, pt` cost nothing beyond "alias to the same
  function as `en`"; `ja, zh, ko` cost nothing beyond "alias to the same
  function as `tr`"; `uk` costs nothing beyond "alias to `ru`." These are
  forced in the strongest sense available in this survey: they are
  the identical function object, not merely similar logic.
- **Free**: the 5 family-defining functions themselves, and which family
  each of the 14 languages belongs to. This is real information (a
  linguistic fact per language) — CLDR plural categories are not derivable
  from the language code string, they come from an external authority the
  generator would need in context. `M.plural_rule`'s fallback to `"en"` for
  any unlisted code (405-408) is a forced default given the rule "unknown
  language uses the en-family rule."
- **Reading**: this is the cleanest example in the survey of a fold whose
  enumeration element is *shared reference*, not *shared shape* — 9 arms
  are literally zero marginal code once the 5 rule-bodies and the
  family-assignment table exist.

### 1.8 `lib/locale/init.lua` — relative-time templates: partial fold, and a second finding about dispatch *shape* affecting the free/forced split

`lib/locale/init.lua:135-192`.

- **Enumeration**: 6 time units (second, minute, hour, day, month, year;
  shared with `REL_THRESHOLDS`, 123-130).
- **Rule**: "for unit U, produce `n==1 and '1 U ago' or n..' Us ago'`
  (English past tense; future tense mirrors it)."
- **In the `en` table** (past and future each): 3 of 6 arms are forced by
  this rule (second, minute, hour); 3 of 6 are free — day/month/year use
  idiomatic irregular forms ("yesterday," "last month," "last year") that
  the pluralization rule cannot produce. These 3 are genuine free content
  (irregular linguistic forms), not drift.
- **In the `de` and `fr` tables**, the *same 6-unit enumeration and the same
  underlying linguistic facts* are expressed through a different dispatch
  shape: 3 explicit arms for the irregular units (day/month/year) plus one
  shared generic branch covering second/minute/hour/(and, in this
  restructuring, also year in one case) via a single `n==1`-conditioned
  template. Reading `de.past` (179-189) directly: only 1 true free arm
  remains explicit outside the generic rule.
- **Reading, not a verdict**: this is not evidence that "the model doesn't
  fit `en`" — the *linguistic* free content is identical in both tables (3
  irregular units, 3 regular ones); only the *code's chosen dispatch shape*
  differs, and the more compact `de`/`fr` shape happens to make the
  forced/free split more visible in the code itself. This matters for an
  encoder: the same underlying fold/free split can be hidden or exposed by
  how the arms happen to be grouped in source, so an encoder cannot rely on
  "one `elseif` per enumeration element" as a signal of anything.

### 1.9 CBOR `read_simple` (major type 7 sub-dispatch) — fold, two forced rules, one real gap

`lib/format/cbor/init.lua:466-478`.

- **Enumeration**: CBOR "simple/float" info values 0-31 (RFC 8949 Table 2).
- **Rule A** (forces 8 arms, lines 468-475): "for info value in {20, 21, 22,
  23, 25, 26, 27, 31}, return the spec-fixed meaning (false, true, null,
  undefined, half-float, float, double, break)."
- **Rule B** (forces 1 arm, line 467): "info value 24 means: read one more
  byte and use *that* as the simple value" — a length-extension mechanism,
  not a value-to-meaning mapping. Still fully forced by spec; a generator
  with RFC 8949 in context derives this the same way it derives Rule A.
- **Forced**: 9/9 explicit arms, under two rules.
- **Free/gap**: none in the arms themselves; the explicit default
  (`opts.simple or simple(value)`, 476-477) is itself forced by spec
  (reserved/unassigned codes 0-19, 28-30 and post-extension byte values
  32-255 have no fixed meaning, so passing through to a caller-supplied
  handler is the only spec-compliant behavior).

### 1.10 msgpack decoder format-byte dispatch — fold, one small documented free decision

`lib/format/msgpack/init.lua:331-673`.

- **Enumeration**: msgpack's format-byte space 0x00-0xFF, spec-fixed.
- **Rule**: "for format byte(s) assigned to type T, read T's length/value at
  T's fixed width and return the decoded value (recursing for
  array/map element/pair counts)."
- **Forced**: 28 of 30 named arms match this rule exactly (fixints, fixmap,
  fixarray, fixstr, nil, false, true, bin8/16/32, float32/64,
  uint8/16/32/64, int8/16/32/64, str8/16/32, array16/32, map16/32) — all
  spec-derived widths, no per-arm authorial choice.
- **Forced (spec-mandated error)**: `0xc1` (line 388) is spec-reserved and
  never assigned a meaning; returning an error for it is forced by the spec,
  not a choice.
- **Free (named, documented)**: ext types (`0xc7-0xc9`, `0xd4-0xd8`, lines
  434-436) are a real free decision — the comment states "Not implemented
  in v1; skip with error." Ext types are a legitimate msgpack feature (e.g.
  timestamps); choosing not to implement them is an authorial scope
  decision that must be recorded, not something forced by the spec.
- **Structural note, not a deviation**: the byte space 0x00-0xFF is fully
  partitioned by the preceding ranges, which makes the file's own terminal
  default branch (line 672) unreachable given the current ranges — a
  redundancy in the code, not a free decision or a gap.

---

## Part 2 — Sites that are not fold-shaped, and what determines their arms

These are reported briefly, per the corrected framing: they are not a
competing category to be tallied against the fold sites, and their arm count
is not a "failure rate." They are simply where the free decisions in these
files live.

- **`ExprRule` table, `lib/type/static/constrain.lua:1760-3402`** (13 arms
  over expression-shaped AST node kinds). Not fold-shaped: each arm computes
  a different runtime operation's type (literal typing, field access rules,
  arithmetic, table construction, calls), and several arms internally
  dispatch again on a second discriminant (e.g. `BINARY_EXPR` on operator,
  `INDEX_EXPR` on three distinct key-shape cases at 2061-2116). What
  determines each arm: the operational semantics of that specific
  expression form — irreducible per-case logic, correctly free.

- **`StmtRule` table, `constrain.lua:3716-4650+`** (12 arms over statement
  kinds). `DO_STMT`/`WHILE_STMT`/`REPEAT_STMT` share a loose "child scope +
  gen_block + condition" shape, but the condition's placement relative to
  the block differs by construct (WHILE tests before, REPEAT after, DO not
  at all) in a way forced by Lua's own execution semantics rather than by
  authorial choice — arguably forced-by-external-spec the same way the JSON
  and CBOR sites are, just harder to state as a single line. The other 9
  arms (`LOCAL_STMT`, `ASSIGN_STMT`, `IF_STMT`, `FOR_NUM`, `FOR_IN`,
  `RETURN_STMT`, `EXPR_STMT`, `BREAK_STMT`, `FUNC_DECL`) have no shared rule
  with any sibling — each is its own bespoke logic (e.g. `LOCAL_STMT`,
  ~156 lines, handles multi-return slot binding, tuple-annotation checks,
  and enum promotion together). Free by construction.

- **`unify.lua` (~383-520+) and `match.lua` (~201-843) pairwise-tag
  matching**. Not enumeration-over-a-set at all: these are ordered
  compatibility matrices keyed by a *pair* of type tags, where earlier
  branches (`TAG_ANY`/`TAG_UNKNOWN`, checked first) must shadow later,
  more-specific ones for correctness. Order is load-bearing, so arms are
  not independent — this is the "order-dependent chain" shape, not a map
  over an enumeration, and forcing it into fold shape would misreport the
  ordering itself as absent information when it is in fact required
  content.

- **`lib/vm/init.lua:118-272` opcode handlers** (30 handlers in 8 groups:
  stack, arithmetic, comparison, logic, memory, control-flow, I/O,
  special). Not a single fold: the 8 groups are structurally unrelated to
  each other. Within the arithmetic/comparison cluster specifically
  (11 handlers), ADD/SUB/MUL are forced by "pop b, pop a, push a∘b";
  DIV/MOD add a zero-check forced by the domain (any correct
  implementation needs it, not an authorial choice); the 6 comparison ops
  are forced by a second, related rule (same shape plus bool→1/0
  coercion). So this cluster is close to a two-rule fold internally, but
  the file as a whole is not — the other groups need individual reading,
  not assumed uniformity.

- **`lib/pretty_print/init.lua:23-104`**, `type(value)` dispatch (9 arms).
  5 arms forced by "print `<luatype>`"; 2 are a near-miss variant (same
  literal, no wrapper) forced by a second, related rule; `number`, `string`,
  `table` are free — each requires genuinely different logic (int/float
  formatting; escape-table substitution; ~55 lines of cycle-detection and
  key-ordering for tables). What determines the free arms: the actual
  printable structure of that Lua type, not derivable from the others.

- **`lib/locale/init.lua:668-727` — `format_date` style × lang (12 leaf
  arms)**. Worth flagging precisely because it looks fold-shaped (every arm
  follows "build a string via `string.format`") while being almost entirely
  free content: the *rule* only fixes the control flow ("call
  string.format"), but each arm's literal template string encodes locale
  word order — real, non-derivable information every arm carries. An
  encoder that scores this site by "does every arm follow the control-flow
  rule" would wrongly call it forced; what must actually be recorded is the
  12 template strings themselves.

- **`lib/log_parser/init.lua:502-535` — `M.pattern`, two dispatches over one
  declared 5-type enumeration** (`str, int, float, ip, timestamp`,
  documented at line 470). The first dispatch (regex literal per type,
  503-513) touches all 5 types — fold-shaped in structure, but each regex
  is itself free content, same pattern as `format_date` above. The second
  dispatch (value coercion, 529-535) only distinguishes 3 outcomes
  (`int`/`float` both map to `tonumber`, everything else — including the
  declared `ip` and `timestamp` types — passes through as a raw string).
  This is a real cross-dispatch inconsistency over the *same* enumeration:
  two dispatch sites in the same function family disagree about how many
  of the 5 declared types are actually differentiated. Noted here because
  it is exactly the kind of gap that "count deviations within one site
  at a time" cannot see, and an encoder should not silently paper over it
  by picking whichever of the two dispatches looks cleaner.

---

## Part 3 — Notes for whoever builds the encoder

- **A fold can be split across more than one rule and still be a fold with
  zero free arms** (1.2, 1.9, 1.10). "One rule" is not required; "every arm
  determined by *some* stated rule" is.
- **Shared-reference aliasing (1.7) is a stronger form of forced than
  shared-shape.** When two enumeration elements literally point at the same
  function, there is no risk of drift between them; when they're
  independently-written copies of the same logic (1.4's `type_check`/
  `guard_check`, 1.5's duplicated pair), the content is still forced but the
  *code* carries a latent drift risk the encoder should probably flag
  separately from true free content.
- **"Forced but duplicated" (drift) is a distinct category from "free."**
  1.4's `negation` arm and 1.5's `type_check`/`guard_check` pair produce
  results fully determined by an existing rule, but the source doesn't
  express that — re-implementing instead of reusing. Recording these as
  free decisions would fabricate information that isn't there; recording
  them as forced-and-clean would miss a real (if minor) codebase
  inconsistency. They need their own bucket.
- **Fold-looking control flow can carry 100% free content per arm** (1.8's
  `format_date`, `log_parser`'s regex dispatch). The discriminator is
  whether the *rule* determines the arm's actual output, not whether the
  arms share a visible code template. An encoder keyed on "similar AST
  shape across arms" will misclassify these as forced.
- **Dispatch shape in source is not stable evidence of the underlying
  forced/free split** (1.8's `en` vs. `de`/`fr` tables encode the identical
  linguistic facts with different visible deviation counts, purely because
  of how the arms are grouped).
- **Order-dependent chains and pairwise compatibility matrices are a
  different shape from enumeration dispatch entirely** (Part 2, `unify.lua`
  / `match.lua`) and must not be forced into the fold/deviation frame at
  all — their ordering is itself required content.
