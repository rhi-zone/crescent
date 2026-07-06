// engine-saturation-b.js
//
// Reproduces candidates/saturation.md READING B: genuine term rewriting
// with replacement (Knuth-Bendix/egraph shape). A representation is
// REPLACED by a canonical one; two claims "meet" iff they reduce to, or get
// merged into, the same equivalence class -- a real, potentially
// irreversible operation on the term store's identity structure, not just
// an added fact.
//
// This engine's mandatory job (per the task) is to WALK the exact failure
// saturation.md §4 names: "Plausible-but-wrong rule earning false Proved —
// rewriting is MORE dangerous than checking, under Reading B specifically...
// a wrong rewrite doesn't add a fact alongside the truth, it can merge two
// previously-distinct equivalence classes into one, silently identifying
// facts that are not actually the same runtime thing... 'A wrong rewrite
// rewrites the world.'"
//
// The rewrite rule implemented below is deliberately plausible-but-wrong,
// in the same spirit as subtract's colon-self-nonnil-v1: it canonicalizes
// any two `nonnil_binding(self, _)` terms to ONE equivalence class keyed
// only on the receiver name ("self"), discarding which method they came
// from -- i.e. it identifies "self is non-nil in method X" with "self is
// non-nil in method Y" whenever both happen to be named "self". That is
// exactly the "silently identifying facts that are not actually the same
// runtime thing" mechanism named in the finding.

window.runSaturationBEngine = function (scenario) {
  const f = scenario.facts;
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    snaps.push(s);
  }

  function runSelfShape(funcName, hasCounterexample, counterexampleCall) {
    const term = { functor: "nonnil_binding", args: ["self", funcName] };
    snap(
      "Ground term admitted: " + JSON.stringify(term),
      { pool: [{ id: funcName, term: term }] }
    );
    const rewriteRule = "def-form(colon) -> nonnil_binding(self, F) canonicalized directly (no call-site check) — same content as subtract's colon-self-nonnil-v1, restated as a rewrite";
    snap(
      "Rewrite rule applies: " + rewriteRule + (hasCounterexample ? (" — real counterexample: " + counterexampleCall) : ""),
      { pool: [{ id: funcName, term: term }] }
    );
    return { funcName: funcName, term: term, hasCounterexample: hasCounterexample, counterexampleCall: counterexampleCall };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall);
    snap(
      "normalize(store, rules) reaches a fixpoint: " + r.funcName + " canonicalizes to " +
        "supports(nonnil_binding(self, " + r.funcName + ")) — same unsound rule content as " +
        "Reading A/subtract, no merge opportunity exists with only one fact in the store.",
      {},
      r.hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: same unsound rule shape)"
    );
  } else if (f.shape === "colon_self_nonnil_multi") {
    const r = runSelfShape(f.funcName, false, null);
    snap("Applied to all 4 sites, same rewrite, no merge opportunity in isolation.", {}, "Proved (flagged: same unsound rule shape)");
  } else if (f.shape === "single_assign_nonnil") {
    const term = { functor: "nonnil_binding", args: [f.name] };
    snap("Ground term: " + JSON.stringify(term), { pool: [{ id: f.name, term: term }] });
    snap(
      "Rewrite rule for single-assignment non-nil normalizes this to supports(" +
        JSON.stringify(term) + ") — same disclosed ordering-check gap as Reading A, not " +
        "exercised in this scenario.",
      { pool: [{ id: f.name, term: term }] },
      "Proved"
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "No rewrite rule's left-hand side matches reachable(F, \"then\") — stays Open, same " +
        "structural receipt as Reading A.",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    // THIS is the mandatory adversarial walk-through.
    const a = f.factA, b = f.factB;
    const termA = { functor: "nonnil_binding", args: ["self", a.funcName] };
    const termB = { functor: "nonnil_binding", args: ["self", b.funcName] };
    snap(
      "Two DISTINCT ground terms admitted: A = " + JSON.stringify(termA) + " (from " +
        a.funcName + ", has a real counterexample call " + a.counterexampleCall + " — " +
        "should NOT be provable) and B = " + JSON.stringify(termB) + " (from " + b.funcName +
        ", genuinely true, no counterexample).",
      { pool: [{ id: "A", term: termA }, { id: "B", term: termB }] }
    );
    snap(
      "The plausible-but-wrong REWRITE rule (Reading B, this engine): canonicalize any " +
        "nonnil_binding(self, _) term to ONE shared equivalence class keyed only on the " +
        "receiver name \"self\", discarding which method it came from — a real, " +
        "irreversible egraph-style merge, not an added fact.",
      { pool: [{ id: "A", term: termA }, { id: "B", term: termB }] }
    );
    const mergedClass = { canonical: "nonnil_binding(self, *)", members: [a.funcName, b.funcName] };
    snap(
      "MERGE: A and B are unioned into one equivalence class: " + JSON.stringify(mergedClass) +
        " — this is precisely candidates/saturation.md §4's finding, \"Plausible-but-wrong " +
        "rule earning false Proved — rewriting is MORE dangerous than checking, under " +
        "Reading B specifically\": \"a wrong rewrite doesn't add a fact alongside the " +
        "truth, it can merge two previously-distinct equivalence classes into one, " +
        "silently identifying facts that are not actually the same runtime thing. Every " +
        "subsequent rule that matches against the merged class's canonical representative " +
        "now applies indiscriminately to both original facts, with no record left in the " +
        "term store that they were ever distinct.\"",
      { pool: [{ id: "merged", term: mergedClass }], note: "A and B no longer independently addressable." }
    );
    snap(
      "B's derivation (genuinely true — no counterexample) supplies `supports` for the " +
        "MERGED canonical representative. Because A and B are now the same identity in the " +
        "term store, that `supports` verdict is read back for A too — even though A has a " +
        "real counterexample (" + a.counterexampleCall + ") that should have kept it at " +
        "Open or Refuted. \"A wrong rewrite rewrites the world.\"",
      { pool: [{ id: "merged", term: mergedClass, polarity: "supports (inherited from B, wrongly applied to A too)" }] },
      "False-Proved-flagged (A amplified via B's merged identity — the amplification failure mode saturation.md names as unique to Reading B)"
    );
  }

  return snaps;
};
