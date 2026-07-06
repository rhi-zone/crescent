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
    // Strip any top-level key on `state` whose value is JS `undefined`
    // (e.g. a conditional `note` that resolved to no note) -- an explicit
    // undefined value is the same disease as a missing `id` field: it
    // surfaces as the literal string "undefined" wherever a generic
    // renderer reads it. Source-level fix, not a display-time fallback.
    if (state && typeof state === "object") {
      for (const k in state) {
        if (Object.prototype.hasOwnProperty.call(state, k) && state[k] === undefined) delete state[k];
      }
    }
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    if (spans) s.spans = spans;
    snaps.push(s);
  }
  function spanOf(fileFacts, span) {
    if (!span) return null;
    return Object.assign({ file: fileFacts }, span);
  }

  // Each store entry's `id` is set to its own `term` string (the natural
  // ground-atom identity in this Datalog/CHR store -- every term string is
  // unique per atom in this engine's usage). Every push site below follows
  // the same construction: { id: term, term, polarity, ... }.
  function push(store, term, polarity, extra) {
    store.push(Object.assign({ id: term, term: term, polarity: polarity }, extra || {}));
  }

  function runSelfShape(funcName, hasCounterexample, counterexampleCall, fileName, defSpan, useSpan) {
    const store = [];
    push(store, "def_form(" + funcName + ", colon)", "supports");
    push(store, "receiver_param(" + funcName + ", self)", "supports");
    push(store, "deref_site(" + funcName + ", self)", "supports");
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
    push(store, derived, "supports", { derivedBy: rule });
    snap("saturate(store, rules) — fixpoint step adds " + derived, { pool: store.slice() });
    const sameBreakNote = note("same-break");
    const fixpointState = { pool: store.slice() };
    if (sameBreakNote) fixpointState.note = sameBreakNote.text + " [" + sameBreakNote.citesFinding + "]";
    snap(
      "Fixpoint reached.",
      fixpointState,
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
    const store = [];
    push(store, "single_assignment(" + f.name + ")", "supports");
    push(store, "assigned_kind(" + f.name + ", table)", "supports");
    push(store, "deref_site(" + f.name + ")", "supports");
    snap("Initial ground facts: " + store.map((s) => s.term).join(", "), { pool: store.slice() }, undefined, f.assignSpan ? [spanOf(f.file, f.assignSpan)] : undefined);
    const rule = "nonnil(F, X) :- single_assignment(F, X), assigned_kind(F, X, table), deref_site(F, X)";
    push(store, "nonnil(" + f.name + ")", "supports", { derivedBy: rule });
    const gapNote = note("gap");
    const gapState = { pool: store.slice() };
    if (gapNote) gapState.note = gapNote.text + " [" + gapNote.citesFinding + "]";
    snap(
      "Propagation rule fires: " + rule,
      gapState,
      undefined,
      f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined
    );
    snap("Fixpoint reached — no conflicting atom for this canonical address.", { pool: store.slice() }, "Proved");
  } else if (f.shape === "branch_reachable") {
    snap(
      "Pattern-indexing rule heads against reachable(F, \"then\"): no rule head unifies -> Open (no saturation run).",
      {},
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall, a.file, a.defSpan, a.useSpan);
    const rB = runSelfShape(b.funcName, false, null, b.file, b.defSpan, b.useSpans && b.useSpans[0]);
    const blastNote = note("blast-radius");
    const blastState = {};
    if (blastNote) blastState.note = blastNote.text + " [" + blastNote.citesFinding + "]";
    snap(
      "Reading A NEVER merges or deletes ground atoms — the store only grows. " + a.funcName +
        " -> nonnil(" + a.funcName + ", self) [wrong, same rule defect] and " + b.funcName +
        " -> nonnil(" + b.funcName + ", self) [correct] remain two DISTINCT ground atoms forever.",
      blastState,
      "A=" + rA + " (blast radius: itself and anything that cites it, not B), B=" + rB
    );
  } else if (f.shape === "hand_claims") {
    // Generic claim-kind shape: ground atoms establishes(EvId, Arm) per arm
    // the evidence structurally establishes, claimed(ClaimId, Arm) per
    // claimed arm; the propagation rule derives covered(ClaimId) only if
    // every claimed arm has a matching establishes atom. Pure set
    // inclusion restated in Datalog form -- generic over every claim kind.
    // PLACEMENT: the arm-subset entailment rule is PRODUCER content
    // (producers.js), not kernel content -- this engine's fixpoint loop
    // fires whatever producers.js's rule.entails returns, same as the
    // colon-self rule above is producer content re-fired by this kernel.
    const armsRule = (window.PRODUCER_RULES || []).filter((r) => r.id === "arm-subset-entailment-v1")[0];
    const results = [];
    f.claims.forEach((claim) => {
      const store = [];
      const evId = "ev:" + claim.id;
      push(store, "evidence_kind(" + evId + ", " + claim.evidence.kind + ")", "supports");
      const arms = claim.evidence.establishesArms || [];
      arms.forEach((arm) => push(store, "establishes(" + evId + ", " + arm + ")", "supports"));
      claim.claimedArms.forEach((arm) => push(store, "claimed(" + claim.id + ", " + arm + ")", "supports"));
      snap(
        "Ground facts admitted for " + claim.subject + ": " + store.map((s) => s.term).join(", "),
        { pool: store.slice() },
        undefined,
        claim.evidence.span ? [spanOf(f.file, claim.evidence.span)] : undefined
      );
      const entailed = armsRule ? armsRule.entails({ establishesArms: claim.evidence.establishesArms, subject: claim.subject }, { claimedArms: claim.claimedArms, unionArms: claim.unionArms, subject: claim.subject }) : "no-match";
      const covered = entailed === "supports";
      const rule = armsRule ? armsRule.datalog : "covered(C) :- claimed(C, A), establishes(EvId, A) for every A claimed by C";
      const v = covered ? "Proved" : "Open";
      if (covered) push(store, "covered(" + claim.id + ")", "supports", { derivedBy: rule });
      snap(
        "Propagation rule: " + rule + " — " + (covered ? "fires, all claimed arms covered." : "does not fire (evidence establishes nothing usable, or a claimed arm is uncovered)."),
        { pool: store.slice() },
        v,
        claim.site ? [spanOf(f.file, claim.site)] : undefined
      );
      results.push(claim.id + "=" + v);
    });
    snap("Fixpoint reached over all claims: " + results.join(", "), {}, results.join(", "));
  }

  return snaps;
};
