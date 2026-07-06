// engine-invert.js
//
// Reproduces candidates/invert.md: Claim = { id, holds: Trace* -> boolean },
// a trusted evaluator (mechanized Lua stepper), a small fixed structural
// proof calculus (seq_compose / induct_trace / const_fold), Certificate =
// Witness | Proof, and a dependency-graph acyclicity check as the one law.
//
// Faithfully reproduces judgments/invert-attack.md "1. The five
// witness/proof walkthroughs don't actually go through as formalized
// (FATAL)": the self-non-nil certificate, as narrated in invert.md §3.1
// instance 1, cites a "static parse fact: is this method defined with `:`
// syntax?" premise -- but invert.md's own §1.2(a) says colon-vs-dot syntax
// is already erased by the evaluator's own R-METHODCALL desugaring before
// any Trace event exists, and the formal Certificate type (§2, only
// `witness`|`proof`) has no third certificate kind to carry a static parse
// fact. This engine, faced with that exact requirement, cannot construct
// the certificate either -- and reports UNDERSPECIFIED rather than
// inventing a third certificate kind that isn't in the doc.
//
// For the HEX/FIFO shape, Attack 1 finds a DIFFERENT problem: the
// certificate IS constructible (witness replay + a trace-scan), but it only
// establishes the fact for the one witnessed run, not universally -- a
// genuinely unsound "Proved" that the trusted code, run faithfully, would
// still mint (the calculus has no rule to catch this itself). This engine
// reproduces that: it builds the certificate, the (real) check() accepts
// it, and mints Proved, flagged as unsound per Attack 1.

window.runInvertEngine = function (scenario) {
  const f = scenario.facts;
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    snaps.push(s);
  }

  function runSelfShape(funcName) {
    snap(
      "Claim.holds closure built: function(tr) return tr:binding_at_entry(\"self\") ~= nil end " +
        "(invert.md §3.1 instance 1) for " + funcName,
      { pool: [{ id: "claim:self-nonnil", kind: "Claim.holds closure" }] }
    );
    snap(
      "Attempting a `Proof` certificate via `seq_compose`, premises = [the evaluator's own " +
        "R-METHODCALL stepping rule instantiated at this call site (a Witness-checkable " +
        "fact about this program's AST: is " + funcName + " defined with `:` syntax?), " +
        "the pool's err-absence axiom]",
      { pool: [{ id: "claim:self-nonnil" }], attemptedCertificate: { rule: "seq_compose", premises: ["static-parse-fact: colon-vs-dot", "err-absence-axiom"] } }
    );
    return {
      description:
        "UNDERSPECIFIED in invert.md — cannot proceed without a decision: the certificate " +
        "cited for self-non-nil requires a premise \"is this method defined with `:` " +
        "syntax?\" as a *static parse fact*, but invert.md §1.2(a) states colon-vs-dot " +
        "surface syntax is already erased by the evaluator's own R-METHODCALL desugaring " +
        "before any Trace event exists, and the formal `Certificate` type (§2) has only " +
        "two shapes (`witness`, `proof`) — no third \"static parse fact\" certificate kind " +
        "is specified anywhere in the trusted core to carry this premise. See " +
        "judgments/invert-attack.md \"1. The five witness/proof walkthroughs don't " +
        "actually go through as formalized (FATAL)\": \"Either a third certificate kind " +
        "('static parse fact') is needed and isn't specified anywhere in the trusted " +
        "core... or the parse-fact premise is actually unnecessary... Either way, " +
        "instance 1's certificate, as narrated, is not constructible by the trusted code " +
        "sketched two sections earlier in the same document.\"",
      state: { pool: [{ id: "claim:self-nonnil" }], attemptedCertificate: { rule: "seq_compose", premises: ["static-parse-fact: colon-vs-dot (UNCONSTRUCTIBLE)", "err-absence-axiom"] } },
      verdict: "Underspecified-stopped",
    };
  }

  function runSingleAssignShape(name, useLine) {
    snap(
      "Claim.holds closure: function(tr) return tr:binding_at(\"" + name + "\", " + useLine +
        ") ~= nil end",
      { pool: [{ id: "claim:" + name + "-nonnil" }] }
    );
    snap(
      "Witness certificate: base case = table-constructor witness replay (constructors " +
        "never produce nil — a trusted evaluator rule). Inductive step = a syntactic scan " +
        "asserting no further bind(_, " + name + ", _) event exists between the " +
        "construction point and the deref, submitted as a Witness-checkable claim over the " +
        "trace ITSELF (induct_trace, invert.md §3.1 instance 2).",
      { pool: [{ id: "claim:" + name + "-nonnil" }], attemptedCertificate: { rule: "induct_trace", premises: ["table-constructor-witness", "no-rebind-scan-over-ONE-trace"] } }
    );
    snap(
      "kernel/check.lua's check() recursively verifies both premises against the ONE " +
        "replayed trace and accepts the induct_trace rule's structural precondition — " +
        "mechanically, this DOES pass, exactly as the trusted code is written.",
      { pool: [{ id: "claim:" + name + "-nonnil" }] }
    );
    return {
      description:
        "Proved via induct_trace — BUT per judgments/invert-attack.md Attack 1: \"A " +
        "`Witness` produces one finite trace from one `ConcreteInput`... Scanning that " +
        "one trace for absent rebinds proves, at most, 'in this one witnessed run, " +
        name + " was never rebound'... The claim being certified is universal... No " +
        "finite number of witnessed traces closes that gap... The only sound argument is " +
        "a genuinely new rule... not in §1.2(b)'s sketch... its 'Proved' verdict is " +
        "unsound as narrated.\" This engine mints Proved because the trusted code, run " +
        "faithfully, does — that IS the flaw, not a deviation from it.",
      state: { pool: [{ id: "claim:" + name + "-nonnil" }] },
      verdict: "False-Proved-flagged",
    };
  }

  let result;
  if (f.shape === "colon_self_nonnil") {
    result = runSelfShape(f.funcName);
    snaps.push({ step: ++stepNo, description: result.description, state: result.state, verdict: result.verdict });
  } else if (f.shape === "colon_self_nonnil_multi") {
    result = runSelfShape(f.funcName + " (amortized: one universal certificate, 4 site-specific projections, invert.md §3.1 instance 4)");
    snaps.push({ step: ++stepNo, description: result.description, state: result.state, verdict: result.verdict });
  } else if (f.shape === "single_assign_nonnil") {
    result = runSingleAssignShape(f.name, f.useLine);
    snaps.push({ step: ++stepNo, description: result.description, state: result.state, verdict: result.verdict });
  } else if (f.shape === "branch_reachable") {
    snap(
      "Cheapest move: look for a Witness certificate (a concrete input for which the " +
        "evaluator actually reaches the site) or its dual (a full unreachability proof). " +
        "Neither is available in this scenario (invert.md §3.1 instance 5).",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName);
    const rB = runSelfShape(b.funcName);
    snap(
      "invert's pool is a dependency graph over certificate ids, never a rewrite/merge " +
        "system — no equivalence classes exist to collapse. Both " + a.funcName + " and " +
        b.funcName + " independently hit the SAME unconstructible-certificate problem " +
        "(Attack 1) and both stop Underspecified, for the identical reason, but as two " +
        "separate, non-interacting pool entries.",
      {},
      "A=Underspecified-stopped, B=Underspecified-stopped (no amplification possible)"
    );
  }

  return snaps;
};
