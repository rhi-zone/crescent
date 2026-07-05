# Abstract kernel candidate: claim-as-executable-checker

Seat: design-it-twice, "different conceptual primitive" framing. Committing fully
to one noun: **a claim is not a record, it is a callable** — a function from an
opaque witness to a three-valued local verdict. Everything the kernel is
allowed to know about a claim is that it can be *invoked*. Meaning is
self-carried in the closure's body, never in an out-of-band key.

## 1. The design

### 1.1 The noun

The dead draft's noun was `Claim = { site, slot, stratum, ... }` — a labeled
record. Two claims were compared by comparing labels (a `claim.key` built from
site/slot/stratum), and the 2174-shrug outcome was a direct consequence: claims
whose *labels* didn't line up were never brought into contact, even when they
were about the same runtime fact (kill-test instance #1 below is exactly this:
the mined obligation and the would-be axiom hypothesis use different site/slot
vocabulary for "the value bound to `self`," so a label-keyed design never
lets them meet).

Replace the noun. A **claim is an executable checker**:

```
Claim = {
  check: (witness) -> "accept" | "reject" | "unknown",
}
```

That's the entire interface. `witness` is opaque to the kernel — a concrete
execution fact, a trace fragment, a binding snapshot, a symbolic fact, a proof
object — the kernel never inspects its shape. Only the claim (and whatever
producer built it) knows how to read a witness and only insofar as it
recognizes the witness's shape; if it doesn't recognize the shape, it must
answer `"unknown"`, never error, never guess.

This is deliberately the SAME move as "program = operational semantics taken
as given" from the pre-collapse draft's J1, pushed one level up: the kernel
doesn't need to know what a claim *means* semantically, because the claim
*is* the executable embodiment of its own meaning. There is no separate
denotation to go check the checker against — `check` **is** the semantics,
by construction. (This is why it beats claim-as-set-of-behaviors as a
foundation: a set of traces still needs a decision procedure bolted on to be
usable by a kernel; making the decision procedure the claim collapses two
things the record-based draft needed a whole judgment form each for — J1's
`⊨` and the harvester's claim atoms — into one artifact.)

### 1.2 Witnesses and witness sources

A **witness source** is a capability: `() -> witness | nil`, called repeatedly
until it's exhausted (returns `nil`) or a budget runs out. Witness sources are
100% open — a producer can supply one backed by a concrete interpreter run, a
static AST walk, a symbolic executor, a replayed test trace, anything. The
kernel treats a witness source exactly like it treats a claim: an opaque
callable it invokes and gets an opaque value back.

### 1.3 The one law, made computable

Certified law: *"a claim used as a hypothesis must independently survive as
an obligation."* Under this noun, "surviving as an obligation" cashes out
operationally: a claim `h` used to restrict the execution set (hypothesis
role) must be *checked* — via its own `check`, called on real witnesses drawn
from sources it did not itself supply — exactly the way every obligation is
checked. There is no privileged fast path for hypotheses. Concretely:

- **Refuted**: two claims `a`, `b` in the pool disagree on some witness `w`
  drawn from an available source — `a.check(w) = "accept"` and
  `b.check(w) = "reject"` (or vice versa). The disagreement *is* the finding;
  `w` is the receipt.
- **Open**: no disagreement was found within budget, and no claim in the pool
  can certify exhaustion of the relevant witness space.
- **Proved**: a claim (or a distinguished third-party checker acting as its
  certificate) supplies a witness source that self-reports **closed** — it
  terminates having yielded every witness in some domain the kernel can
  verify was actually exhausted by running the source to completion — and no
  disagreement occurred across that exhaustive run. The kernel's trust here
  is minimal and explicit: *"I called this generator until it returned nil,
  and nothing disagreed."* It never trusts an out-of-band assertion of
  completeness (see §4 — this is the thinnest part of the design and is
  flagged honestly, not glossed).

None of this branches on *what kind* of claim `a` or `b` is, what its site,
slot, or stratum is, or which of the three sources produced it. The kernel's
only two operations are "call a claim on a witness" and "call a witness
source." That is the entire trusted vocabulary — genuinely zero claim forms
baked in.

### 1.4 Sources, unprivileged

Stated annotations, universal axioms, and mined beliefs all enter the pool as
the *same* thing: a claim (callable) plus, optionally, a witness source it can
contribute. Nothing in the kernel dispatches on which of the three produced a
given claim. Grade (credence) is carried as a field *alongside* the claim for
the reporting layer, exactly per the owner's addendum — the checking law in
§1.3 never reads it. A source is "unprivileged" in the strongest available
sense: it is opaque data to the algorithm that decides Proved/Refuted/Open;
grade only shapes how a *result* is narrated afterward.

## 2. Concrete realization (Lua-shaped)

### 2.1 The kernel (the entire trusted core)

```lua
-- lib/declc/kernel.lua — trusted core. No claim vocabulary. No claim-kind
-- branching anywhere in this file. This is the whole trust boundary.

--:: type Witness = unknown
--:: type Verdict = "accept" | "reject" | "unknown"
--:: type Claim = { check: (fun(witness: Witness): Verdict) }
--:: type WitnessSource = fun(): (Witness | nil)

local Kernel = {}

-- Search for a witness on which `a` and `b` disagree, within budget.
--:: function Kernel.find_disagreement(a: Claim, b: Claim, sources: WitnessSource[], budget: integer): (Witness, Verdict, Verdict)?
function Kernel.find_disagreement(a, b, sources, budget)
  local tried = 0
  for _, source in ipairs(sources) do
    local w = source()
    while w ~= nil and tried < budget do
      tried = tried + 1
      local ra, rb = a.check(w), b.check(w)
      if (ra == "accept" and rb == "reject")
      or (ra == "reject" and rb == "accept") then
        return w, ra, rb
      end
      w = source()
    end
  end
  return nil
end

-- Run a witness source to exhaustion; nil if it never terminates within
-- budget (kernel refuses to call anything "closed" it did not itself
-- observe terminating).
--:: function Kernel.exhaust(source: WitnessSource, on_witness: fun(Witness), budget: integer): boolean
function Kernel.exhaust(source, on_witness, budget)
  local n = 0
  local w = source()
  while w ~= nil do
    on_witness(w)
    n = n + 1
    if n > budget then return false end
    w = source()
  end
  return true
end

-- The one law, over a pool. Every claim plays both hypothesis and
-- obligation role against every other claim; there is no fast path.
--:: function Kernel.check_pool(pool: Claim[], sources: WitnessSource[], budget: integer): table[]
function Kernel.check_pool(pool, sources, budget)
  local findings = {}
  for i = 1, #pool do
    for j = 1, #pool do
      if i ~= j then
        local w, ra, rb = Kernel.find_disagreement(pool[i], pool[j], sources, budget)
        if w ~= nil then
          findings[#findings + 1] = {
            verdict = "Refuted", a = pool[i], b = pool[j], witness = w,
          }
        end
      end
    end
  end
  return findings
  -- Absence of a Refuted finding for a given claim is not, by itself,
  -- Proved — see closed_domain path in kernel_proved.lua sketch, §1.3.
end

return Kernel
```

That is the whole kernel: two loops and an equality-of-disagreement check.
No `site`, `slot`, `stratum`, `entry(f)`, `arrives`, or any claim-shaped word
appears in it.

### 2.2 An axiom producer (open, untrusted, ordinary Lua)

```lua
-- lib/declc/producers/axiom_colon_self.lua
-- OPEN layer. The kernel never requires or knows about this file.

local M = {}

-- This producer defines ITS OWN witness shape. The kernel never
-- interprets it; only this claim (and whatever harvester built the
-- matching witness) agrees on the shape.
function M.claim()
  return {
    check = function(witness)
      if type(witness) ~= "table" or witness.kind ~= "binding" then
        return "unknown"
      end
      if witness.via == "colon_call_self" then
        -- Lua 5.1's calling convention (taken as given, per J1) makes
        -- this universally true for any colon-call receiver.
        return "accept"
      end
      return "unknown"
    end,
  }
end

return M
```

### 2.3 A mined producer + matching witness source

```lua
-- lib/declc/producers/mined_deref_nonnil.lua

local M = {}

function M.obligation(site)
  return {
    check = function(witness)
      if type(witness) ~= "table" or witness.kind ~= "binding" then
        return "unknown"
      end
      if witness.site ~= site then return "unknown" end
      if witness.value ~= nil then return "accept" end
      if witness.value == nil then return "reject" end
      return "unknown"
    end,
  }
end

-- A harvester builds the witness independently of any claim's existence —
-- it walks the concrete binding at a deref site (from a real interpreter
-- run, or, absent one, a static fact about how the name got bound).
function M.witness_source(site, binding_info)
  local emitted = false
  return function()
    if emitted then return nil end
    emitted = true
    return { kind = "binding", site = site, via = binding_info.via, value = binding_info.value }
  end
end

return M
```

### 2.4 Wiring one corpus instance together

```lua
local kernel = require("lib.declc.kernel")
local axiom = require("lib.declc.producers.axiom_colon_self")
local mined = require("lib.declc.producers.mined_deref_nonnil")

local site = "lru/init.lua:155:deref:self"
local binding_info = { via = "colon_call_self", value = nil } -- harvester
  -- has no concrete runtime value (static analysis only) but DOES know
  -- the structural fact `via`.

local pool = { axiom.claim(), mined.obligation(site) }
local sources = { mined.witness_source(site, binding_info) }

local findings = kernel.check_pool(pool, sources, 100)
-- findings is empty: axiom.check(w) = "accept" (via matches), mined
-- obligation.check(w) = "unknown" (no concrete value) -> no disagreement.
-- This alone is still Open under check_pool's Refuted-only semantics.
```

Getting from here to **Proved** for instance #1 needs one more honest
ingredient: an explicit **corroboration** rule, not a disagreement rule —
"if an obligation returns `unknown` on a witness but an *independently
admitted* claim returns `accept` on that same witness, and no other pool
member ever returns `reject` on it, treat the obligation as
provisionally-closed for that witness, receipt = the accepting claim + the
witness." This is a second, distinct kernel primitive from disagreement-search
(`Kernel.find_corroboration`), still claim-vocabulary-free (still just calling
`check` and comparing three string values), and it is the piece that actually
closes instance #1 — I did not have it in the first kernel sketch above and
want to be explicit that it's required, not implied. See §4 for the honest
accounting of why this is a second primitive and not free.

## 3. Kill-test walkthroughs

### 3.1 The 5 corpus instances

**#1 `lru/init.lua:155` `self` non-nil.** Producers: `axiom_colon_self` (one
producer, written once, referencing nothing site-specific) and
`mined_deref_nonnil` (one producer, parameterized by `site` + harvested
`binding_info`, written once, applied per-deref-site by the harvester — not
per-instance code). Witness: a `{kind="binding", site, via, value}` table the
harvester builds from the AST fact "this name is the first parameter of a
method defined with `function T:m(...)`." Kernel calls: `find_disagreement`
(none) then `find_corroboration` (axiom accepts, obligation is `unknown`,
nothing rejects) → **Proved**, receipt = `(axiom_colon_self, witness)`. No
renaming, no hardcoded "lru.self is fine" — the axiom is general over any
witness tagged `via = "colon_call_self"`.

**#4 `deque/init.lua:62-65`, four `self` sites.** Same two producers, called
four times with four different `site` values by the harvester loop that
already walks every deref in the file. Zero new code. This is the concrete
demonstration that H1's payoff (per the first-slice-run report) is
per-*producer*, not per-claim: one axiom producer plus one harvester loop
closes all four.

**#2 `json/init.lua:125` `HEX` non-nil (single-assignment).** New producer,
general-purpose: `mined_single_assignment(name, scope)` whose `check` accepts
a witness `{kind="assignment_trace", name, scope, assignments}` iff
`#assignments == 1` and no assignment event's position is after the deref
event's position. The witness source here is a *file-level* scan (a
different producer: `dataflow_scan_witness_source(file, name, scope)`) that
the kernel never has to understand — it is handed an opaque assignment-trace
table. Same corroboration path: the dataflow producer's own `check`
(operating on the *same* witness type it emits, since the producer here plays
both the witness-supplying role and, via a companion axiom-like general rule
"single assignment before use implies stable value," the corroborating role)
resolves to accept, obligation resolves to accept → **Proved**.

**#3 `queue/init.lua:157` `FIFO` non-nil.** Literally the same producer as
#2, called with a different `(name, scope)` pair — `name = "FIFO"`. This is
the strongest evidence for the executable-checker noun: #2 and #3 are
*string-identical producer code*, differing only in the opaque argument
handed to a witness source. A record-based/site-keyed design would have
needed two separate claim *topics* to line up by construction; here there is
one producer, reused.

**#5 `bigint/init.lua:115` branch reachability.** Honestly **stays Open**
under this design too, and should — no producer sketched above supplies a
reachability witness source (that requires either a concrete-execution
harness that actually drives the function with some input, or a symbolic
executor). The kernel doesn't need new vocabulary to accept such a producer
when it's built: a `reachability_witness_source(function_ref, inputs)` would
emit `{kind = "branch_taken", site, taken = true/false}` witnesses, and a
mined obligation `check` would accept iff `taken == true` was ever observed.
Nothing about the kernel changes to support this — it is exactly H1's
"derivation layer," and this design correctly reports it as future producer
work rather than quietly hardcoding `bigint.lua:115 => Proved` to make a
number look better.

### 3.2 Self-carried semantics / why this isn't string comparison

The old failure mode: 2174 claims never got compared because comparison was
gated on `claim.key` (site/slot/stratum string) equality *before* any
semantic content was consulted — two claims about the literal same runtime
fact (self non-nil) never met because their harvesters used different key
vocabularies. Under claim-as-executable-checker, there is no key gate at all.
Every claim is offered every witness any source can produce; contact happens
by *actually invoking* `check` and looking at the three-valued result, never
by matching a label. The witness itself is the only thing carrying "aboutness,"
and witnesses are built by whichever producer needs them to have a matching
shape — shape-matching is a *producer* convention (my axiom and my mined
obligation agree `witness.kind == "binding"` and `witness.site` is a
string), never a kernel rule. If two producers use incompatible witness
shapes, the correct, safe behavior is built into the interface contract
itself: an unrecognized shape returns `"unknown"`, not an error and not a
default accept — so the failure mode degrades to (permanent) Open, never to
a false Proved. This is why the law doesn't degrade to string comparison:
the kernel's decision is always the result of *running code against a
concrete or opaque-but-real witness value*, and "two claims are about the
same thing" is discovered empirically (they both produce non-`"unknown"`
answers on a witness one of them or a third party supplied), never declared
by a matching key.

### 3.3 Ceiling

The kernel imposes exactly one ceiling: **decidability of a single
`check(witness)` call within a caller-set budget.** A producer's `check` can
internally invoke anything — a SAT/SMT call, a full abstract interpreter, an
LLM (inadvisable per the open-threads convergence-evidence ruling, but not
kernel-forbidden), a symbolic executor — the kernel is indifferent to the
cost or sophistication behind the three-valued answer. Undecidable questions
are handled by convention, not by kernel special-casing: a producer that
cannot decide within its own budget must return `"unknown"`, never hang.
(Pure-Lua/LuaJIT enforcement note: `check` calls should be wrapped by the
*caller* — not the kernel — in a coroutine with a step-budget, since Lua 5.1
has no preemption; this is a producer-discipline concern, and misbehaving
producers degrade the system to slow-Open, never to unsound Proved, because
the kernel only ever reads the return value, never partial state.) Proved is
capped by whatever `Kernel.exhaust` actually observes terminate — the kernel
will never assert a witness space was exhausted that it did not itself
iterate to a `nil`. This directly answers the "unlimited short of
uncomputable" question: the kernel puts no upper bound on producer power, and
the only floor is that *closure* claims (Proved) must be empirically
exhausted by the kernel's own loop, not asserted by a producer's self-report.
That is a real, load-bearing ceiling — it means some true facts will
correctly sit at Open forever unless someone writes a producer whose witness
space is provably finite and small enough to actually iterate — and that
ceiling is inherent to any sound design, not an artifact of this one.

## 4. What it hides / assumes

- **Witness-shape interoperability is a convention, not a kernel guarantee.**
  Two producers only ever make contact if they happen to agree on witness
  shape (as `axiom_colon_self` and `mined_deref_nonnil` do, by the harvester
  author's design). Nothing in the kernel enforces or discovers this
  agreement; a whole family of true corroborations can be silently missed
  because no producer built a witness type both sides recognize. This is
  the same "topic alignment" problem the old design had, *demoted from a
  kernel concern to an open-layer concern* — which is the right place for
  it, but it does not disappear. An (open, unverified) witness-type registry
  or adapter layer is future work this design explicitly leaves undone.
- **Corroboration is a second primitive I had to add, not a free
  consequence of disagreement-search.** §2.4 shows the first kernel sketch
  (disagreement-only) cannot produce Proved for instance #1; I added
  `find_corroboration` to close it. This second primitive needs its own
  soundness argument (is "accept + unknown, no reject, from an independently
  admitted claim" actually safe to call closed for that witness, forever?)
  that I have not exhaustively made here — I believe it is sound *per
  witness* (it never asserts anything about witnesses not yet seen) but
  Proved-for-a-claim (as opposed to Proved-for-a-witness) still needs the
  `exhaust`-to-completion path in §1.3, which is the thinnest part of this
  design.
- **Budget/termination discipline is assumed cooperative.** In pure Lua
  5.1 there's no way for the kernel to forcibly interrupt a producer's
  `check` call; a misbehaving producer can hang the whole run. This needs an
  explicit coroutine-based cooperative-yield convention documented for
  producer authors, not enforced by the type system or the kernel.
- **Grade is fully inert to soundness**, exactly as owner-directed — it's
  carried as sidecar metadata for the reporting layer and never touched by
  `check_pool`/`find_disagreement`/`find_corroboration`. This design takes
  the owner's addendum as binding even though the addendum itself is
  flagged `[ORCHESTRATOR-DERIVATION]`/uncertified in the source doc — worth
  the owner re-confirming, since this design leans on it structurally.
- **The kernel does not know or care about program structure at all** — no
  notion of function, module, file, control flow. All of that lives in
  witness shapes chosen by producers. This is the maximal-distance move the
  brief asked for; it also means literally nothing in `docs/typechecker-
  reference.md`'s per-feature vocabulary is kernel-visible, which is
  correct per the brief but worth flagging as a large distance from where
  `lib/declc/claim.lua`'s current fields (site/slot/stratum) sit today —
  every existing harvester in `lib/declc/harvest.lua` needs to be rewritten
  to emit closures + witness sources, not records. That's a real migration
  cost, not a free refactor.

## 5. Honest trade-offs

**Strong:**
- Genuinely two primitives in the trusted core (`check` a claim on a
  witness; run a witness source to exhaustion). No claim-kind branch exists
  to special-case, because there is no claim-kind field to branch on.
- Directly explains, mechanically, why the old design produced 2174 shrugs
  (label-gated contact) and why this one doesn't (contact is empirical,
  via invocation, never via key match).
- New claim forms are Lua closures — zero kernel changes, zero new judgment
  rules, ever, to add a new kind of fact. This satisfies "no fixed set of
  claim forms" about as literally as is possible in Lua.
- Composes cleanly with the certificate-kernel language from the ceiling
  survey (`judgment.md §5`, "soundness lives solely in a tiny certificate
  checking kernel") — this design's kernel is that tiny checker, almost
  word for word.

**Thin:**
- Pairwise `check_pool` is O(n²) over the pool with no topic-key shortcut to
  prune it — at the first-slice-run's scale (2401 raw claims) that's
  ~5.7M ordered pairs before even considering multiple witnesses each. Real
  throughput requires an (open, untrusted) pairing-heuristic layer to
  suggest which pairs are worth trying — exactly the LCF-style
  "untrusted premise selection, trusted small checker" architecture, but it
  means the *practical* system still needs something shaped like the old
  site/slot heuristics, just demoted to an unverified performance hint that
  can never cause an unsound verdict (only a slower or more Open one).
- The Proved story (§1.3, §4) is the least developed part of this design —
  I have a believable sketch (`exhaust` to observed termination,
  corroboration per-witness) but not a full soundness argument for compound
  claims built from partial corroboration across many witnesses. This
  mirrors the open-threads record's own honesty that the derivation
  layer (H1) is unbuilt; I did not want to manufacture false completeness
  here to make the design read as more finished than it is.
- Migrating `lib/declc/harvest.lua`'s current record-shaped output to
  closures is a genuine rewrite, not a compatibility shim — every harvester
  function changes shape. This is fine per the brief (not a compatibility
  constraint) but is a real, non-trivial cost to flag for whoever schedules
  the build order.
