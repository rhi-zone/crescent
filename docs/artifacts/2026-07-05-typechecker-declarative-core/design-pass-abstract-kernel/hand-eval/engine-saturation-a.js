// engine-saturation-a.js
//
// Reproduces candidates/saturation.md READING A: monotone fact
// accumulation (Datalog/CHR-propagation shape). Claims are ground atoms
// over a term algebra; propagation rules only ever ADD new ground atoms
// derived from atoms already present; nothing is ever deleted or merged.
// Conflict = the store contains both supports(A) and refutes(A) for the
// same canonical A.
//
// Per saturation.md §1.5, encoding the flagship rule as a Reading-A
// propagation rule and RE-DERIVING (not narrating success): the rule
// `nonnil(F, Line, "self") :- def_form(F, "colon"), receiver_param(F,
// "self"), deref_site(F, Line, "self")` "pattern-matches the exact same
// premise as subtract's colon-self-nonnil-v1, and is wrong for the
// identical reason judgments/subtract-attack.md Attack 1 found... Breaks,
// identically." This engine reproduces that identical break.

window.runSaturationAEngine = function (scenario) {
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
    const store = [];
    store.push({ term: "def_form(" + funcName + ", colon)", polarity: "supports" });
    store.push({ term: "receiver_param(" + funcName + ", self)", polarity: "supports" });
    store.push({ term: "deref_site(" + funcName + ", self)", polarity: "supports" });
    snap(
      "Initial ground facts admitted into the store: " + store.map((s) => s.term).join(", "),
      { pool: store.slice() }
    );
    const rule = "nonnil(F, \"self\") :- def_form(F, colon), receiver_param(F, self), deref_site(F, self)";
    snap(
      "Propagation rule (saturation.md §1.5 instance 1): " + rule + " — pattern-matches " +
        "against the store; guard passes.",
      { pool: store.slice(), rule: rule }
    );
    const derived = "nonnil(" + funcName + ", self)";
    store.push({ term: derived, polarity: "supports", derivedBy: rule });
    let note =
      "M.saturate fires the rule, adds " + derived + " to the store — this pattern-matches " +
      "the EXACT SAME PREMISE as subtract's colon-self-nonnil-v1 (a definition-site fact), " +
      "and is wrong for the identical reason judgments/subtract-attack.md Attack 1 found: " +
      "\"colon definition syntax... places zero obligation on callers.\" Rewriting this " +
      "into Datalog notation changes nothing about its logical content.";
    if (hasCounterexample) {
      note += " Real counterexample in this scenario: " + counterexampleCall + ".";
    }
    snap("saturate(store, rules) — fixpoint step adds " + derived, { pool: store.slice() }, undefined);
    snap(
      "Fixpoint reached. " + note,
      { pool: store.slice() },
      hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: same unsound rule shape, no counterexample in THIS scenario)"
    );
    return hasCounterexample ? "False-Proved-flagged" : "Proved";
  }

  if (f.shape === "colon_self_nonnil") {
    runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall);
  } else if (f.shape === "colon_self_nonnil_multi") {
    runSelfShape(f.funcName + " (rule fires ×4, saturation.md §1.5 instance 4: \"same rule as #1, same break, ×4\")", false, null);
  } else if (f.shape === "single_assign_nonnil") {
    const store = [
      { term: "single_assignment(" + f.name + ")", polarity: "supports" },
      { term: "assigned_kind(" + f.name + ", table)", polarity: "supports" },
      { term: "deref_site(" + f.name + ")", polarity: "supports" },
    ];
    snap("Initial ground facts: " + store.map((s) => s.term).join(", "), { pool: store.slice() });
    const rule = "nonnil(F, X) :- single_assignment(F, X), assigned_kind(F, X, table), deref_site(F, X)";
    store.push({ term: "nonnil(" + f.name + ")", polarity: "supports", derivedBy: rule });
    snap(
      "Propagation rule fires: " + rule + " — saturation.md §1.5 instance 2/3: \"same " +
        "partial weakness as subtract's version: no ordering/dominance check between the " +
        "assignment and the dereference\" (not exercised here since use is control-flow-" +
        "after assignment in this scenario).",
      { pool: store.slice() }
    );
    snap("Fixpoint reached — no conflicting atom for this canonical address.", { pool: store.slice() }, "Proved");
  } else if (f.shape === "branch_reachable") {
    snap(
      "Pattern-indexing the rule set's heads against reachable(F, \"then\"): no rule head " +
        "unifies. saturation.md §1.5 instance 5, verbatim: \"no rule's head matches " +
        "reachable(F, 'then') in this minimal rule set. Honestly Open... this is a " +
        "structural, checkable fact about the rule set... computed by pattern-indexing " +
        "the rule heads against the address, without running saturation at all.\"",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall);
    const rB = runSelfShape(b.funcName, false, null);
    snap(
      "Reading A NEVER merges or deletes ground atoms — the store only grows. " + a.funcName +
        " -> nonnil(" + a.funcName + ", self) [wrong, same rule defect] and " + b.funcName +
        " -> nonnil(" + b.funcName + ", self) [correct] remain two DISTINCT ground atoms " +
        "forever. saturation.md §4, \"Plausible-but-wrong rule earning false Proved\": " +
        "\"Under Reading A... a wrong rule adds one wrong fact to the store, exactly as a " +
        "wrong incumbent rule adds one wrong edge — the blast radius is the same... " +
        "subtract-attack.md Attack 2's 'one wrong mined fact poisons every claim reachable " +
        "from it' applies verbatim, unchanged.\" No amplification beyond that ordinary " +
        "blast radius.",
      {},
      "A=" + rA + " (blast radius: itself and anything that cites it, not B), B=" + rB
    );
  }

  return snaps;
};
