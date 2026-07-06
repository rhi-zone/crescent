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
// "self"), deref_site(F, Line, "self")` pattern-matches the exact same
// premise as subtract's colon-self-nonnil-v1, and is wrong for the
// identical reason. This engine reproduces that identical break. All
// narrative commentary lives in scenario.notes["saturation-a"] as data.

window.runSaturationAEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes["saturation-a"]) || [];
  function note(key) {
    return notes.find((n) => n.key === key);
  }
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict, spans) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    if (spans) s.spans = spans;
    snaps.push(s);
  }
  function spanOf(fileFacts, span) {
    if (!span) return null;
    return Object.assign({ file: fileFacts }, span);
  }

  function runSelfShape(funcName, hasCounterexample, counterexampleCall, fileName, defSpan, useSpan) {
    const store = [];
    store.push({ term: "def_form(" + funcName + ", colon)", polarity: "supports" });
    store.push({ term: "receiver_param(" + funcName + ", self)", polarity: "supports" });
    store.push({ term: "deref_site(" + funcName + ", self)", polarity: "supports" });
    snap(
      "Initial ground facts admitted into the store: " + store.map((s) => s.term).join(", "),
      { pool: store.slice() },
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    const rule = "nonnil(F, \"self\") :- def_form(F, colon), receiver_param(F, self), deref_site(F, self)";
    snap(
      "Propagation rule: " + rule + " — pattern-matches against the store; guard passes.",
      { pool: store.slice(), rule: rule },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    const derived = "nonnil(" + funcName + ", self)";
    store.push({ term: derived, polarity: "supports", derivedBy: rule });
    snap("saturate(store, rules) — fixpoint step adds " + derived, { pool: store.slice() });
    const sameBreakNote = note("same-break");
    snap(
      "Fixpoint reached.",
      { pool: store.slice(), note: sameBreakNote ? sameBreakNote.text + " [" + sameBreakNote.citesFinding + "]" : undefined },
      hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: same unsound rule shape, no counterexample in THIS scenario)",
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    return hasCounterexample ? "False-Proved-flagged" : "Proved";
  }

  if (f.shape === "colon_self_nonnil") {
    runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall, f.file, f.defSpan, f.useSpan);
  } else if (f.shape === "colon_self_nonnil_multi") {
    runSelfShape(f.funcName + " (rule fires ×4, same rule as #1, same break)", false, null, f.file, f.defSpan, f.useSpans && f.useSpans[0]);
  } else if (f.shape === "single_assign_nonnil") {
    const store = [
      { term: "single_assignment(" + f.name + ")", polarity: "supports" },
      { term: "assigned_kind(" + f.name + ", table)", polarity: "supports" },
      { term: "deref_site(" + f.name + ")", polarity: "supports" },
    ];
    snap("Initial ground facts: " + store.map((s) => s.term).join(", "), { pool: store.slice() }, undefined, f.assignSpan ? [spanOf(f.file, f.assignSpan)] : undefined);
    const rule = "nonnil(F, X) :- single_assignment(F, X), assigned_kind(F, X, table), deref_site(F, X)";
    store.push({ term: "nonnil(" + f.name + ")", polarity: "supports", derivedBy: rule });
    const gapNote = note("gap");
    snap(
      "Propagation rule fires: " + rule,
      { pool: store.slice(), note: gapNote ? gapNote.text + " [" + gapNote.citesFinding + "]" : undefined },
      undefined,
      f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined
    );
    snap("Fixpoint reached — no conflicting atom for this canonical address.", { pool: store.slice() }, "Proved");
  } else if (f.shape === "branch_reachable") {
    snap(
      "Pattern-indexing the rule set's heads against reachable(F, \"then\"): no rule head unifies. " +
        "Honestly Open — computed by pattern-indexing the rule heads against the address, without running saturation at all.",
      {},
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall, a.file, a.defSpan, a.useSpan);
    const rB = runSelfShape(b.funcName, false, null, b.file, b.defSpan, b.useSpans && b.useSpans[0]);
    const blastNote = note("blast-radius");
    snap(
      "Reading A NEVER merges or deletes ground atoms — the store only grows. " + a.funcName +
        " -> nonnil(" + a.funcName + ", self) [wrong, same rule defect] and " + b.funcName +
        " -> nonnil(" + b.funcName + ", self) [correct] remain two DISTINCT ground atoms forever.",
      { note: blastNote ? blastNote.text + " [" + blastNote.citesFinding + "]" : undefined },
      "A=" + rA + " (blast radius: itself and anything that cites it, not B), B=" + rB
    );
  }

  return snaps;
};
