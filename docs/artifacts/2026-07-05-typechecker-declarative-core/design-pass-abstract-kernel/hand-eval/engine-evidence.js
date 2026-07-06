// engine-evidence.js
//
// Reproduces candidates/evidence.md: an Oracle (mechanized stepper exposing
// entries/step/replay/cfg_at), an Address term algebra + unify, a Predicate
// protocol (decide: Oracle,State -> true|false|unknown), check_box
// (universal claims via invariant entry/step-closure/implies checking) and
// check_witness (existential/refutation via concrete replay), plus a
// citation-graph acyclicity+groundedness law.
//
// Faithfully reproduces judgments/evidence-attack.md "Attack 4" (referenced
// in synthesis.md §4.1): the self-non-nil invariant is certified via
// `oracle.entries(method)`, described as a STATIC enumeration of colon-call
// sites, with no argument that this enumeration soundly over-approximates
// every actual invocation. When a scenario's ground truth includes a
// counterexample call (e.g. a first-class function-value escape / dot-call),
// this engine's `entries()` still only enumerates the syntactic colon-call
// sites (exactly as evidence.md describes it), so `check_box` mechanically
// reports the invariant holds at every ENUMERATED entry -- and mints a false
// Proved, because the enumeration itself was never sound.

window.runEvidenceEngine = function (scenario) {
  const f = scenario.facts;
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    snaps.push(s);
  }

  function runSelfShape(funcName, hasEscape, counterexampleCall) {
    const addr = { functor: "param_binding", args: [{ atom: "self" }, { atom: funcName }] };
    snap(
      "Address term built: " + JSON.stringify(addr) + " (evidence.md §1: an Address is a " +
        "first-order term the kernel never interprets)",
      { pool: [{ id: "addr", term: addr }] }
    );
    snap(
      "oracle.entries(" + funcName + ") — a STATIC enumeration of this method's colon-call " +
        "sites (evidence.md §2, \"static shape only, no semantic claim\"). " +
        (hasEscape
          ? "A first-class escape of the method value exists in this scenario (" +
            counterexampleCall + "), but oracle.entries() as described only walks syntactic " +
            "call sites — the escape is invisible to this enumeration."
          : "No escapes exist in this scenario; the enumeration is complete."),
      { pool: [{ id: "addr", term: addr }], entries: hasEscape ? ["colon-call sites only (escape invisible)"] : ["colon-call sites (complete)"] }
    );
    snap(
      "check_box: entries_satisfy(invariant, oracle, claim) walks every ENUMERATED entry " +
        "state and finds the invariant \"first bound parameter == receiver expr's value\" " +
        "holds at each one; preserved_by_every_step holds trivially (no further steps " +
        "change it); implies(invariant, claim) is identity here.",
      { pool: [{ id: "addr", term: addr }] }
    );
    if (hasEscape) {
      return {
        description:
          "FALSE PROVED — see judgments/evidence-attack.md \"Attack 4\" (cited in " +
          "synthesis.md §4.1): the self-non-nil invariant is certified via " +
          "`oracle.entries(method)`, described as a static enumeration of colon-call " +
          "sites, with no argument that this enumeration soundly over-approximates every " +
          "actual invocation — \"extracting the function value directly... a first-class " +
          "escape of the method value is silently invisible to the invariant check.\" " +
          "Mechanically walking oracle.entries() as specified never sees " + counterexampleCall +
          ", so check_box reports the invariant holds everywhere it looked and mints Proved.",
        verdict: "False-Proved-flagged",
      };
    }
    return { description: "check_box succeeds honestly — no escape exists in this scenario, so the (incomplete-in-general) static enumeration happens to be complete here.", verdict: "Proved" };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall);
    snap(r.description, {}, r.verdict);
  } else if (f.shape === "colon_self_nonnil_multi") {
    const r = runSelfShape(f.funcName, false, null);
    snap(r.description + " (applied uniformly across all 4 sites, evidence.md §3.1 instance 4)", {}, r.verdict);
  } else if (f.shape === "single_assign_nonnil") {
    const addr = { functor: "no_reassign", args: [{ atom: f.name }] };
    snap("Address term: " + JSON.stringify(addr), { pool: [{ id: "addr", term: addr }] });
    snap(
      "Invariant: \"no bind event to " + f.name + " has occurred since def_site\" " +
        "(evidence.md §2, producers/no_reassign.lua). A second producer mints " +
        "non_nil_at_construction(" + f.name + ", def_site) grounded directly in the fixed " +
        "operational semantics (table-constructor eval never produces nil).",
      { pool: [{ id: "addr", term: addr }] }
    );
    snap(
      "check_box walks the (finite, syntactically local) CFG span and confirms step-closure " +
        "— cites two independently-grounded claims (no-reassign, non-nil-at-construction), " +
        "satisfying the one law without the kernel ever knowing \"" + f.name + "\" or " +
        "\"table\" mean anything (evidence.md §2 walkthrough).",
      { pool: [{ id: "addr", term: addr }] },
      "Proved"
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "Test-trace-harvesting producer: feeds bin/cr test's recorded event traces through " +
        "oracle.replay. No harvested trace covers this branch in this scenario (no test " +
        "exercises it) — evidence.md §3.1 instance 5: \"Where no test trace covers a " +
        "branch, the claim stays Open honestly — that's a real coverage gap report, not a " +
        "bug.\"",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall);
    const rB = runSelfShape(b.funcName, false, null);
    snap(
      "evidence's citation graph never merges/unifies pool entries into a shared identity " +
        "— `unify` (rejected as a kernel primitive by synthesis.md graft 5 anyway) only " +
        "ever reconciles term VARIABLES at citation time, never collapses two DIFFERENT " +
        "claims' truth values into one. " + a.funcName + " = " + rA.verdict + ", " +
        b.funcName + " = " + rB.verdict + " — same underlying oracle.entries() blind spot " +
        "(evidence-attack.md Attack 4) hits A independently of B, no shared amplification.",
      {},
      "A=" + rA.verdict + ", B=" + rB.verdict + " (no amplification)"
    );
  }

  return snaps;
};
