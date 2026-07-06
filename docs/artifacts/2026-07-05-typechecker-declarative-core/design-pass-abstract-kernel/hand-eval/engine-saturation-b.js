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
// candidates/saturation.md §4 names: a wrong rewrite doesn't add a fact
// alongside the truth, it can merge two previously-distinct equivalence
// classes into one, silently identifying facts that are not actually the
// same runtime thing.
//
// The rewrite rule implemented below is deliberately plausible-but-wrong,
// in the same spirit as subtract's colon-self-nonnil-v1: it canonicalizes
// any two `nonnil_binding(self, _)` terms to ONE equivalence class keyed
// only on the receiver name ("self"), discarding which method they came
// from. All narrative commentary lives in scenario.notes["saturation-b"]
// as data.

window.runSaturationBEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes["saturation-b"]) || [];
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
    const term = { functor: "nonnil_binding", args: ["self", funcName] };
    snap(
      "Ground term admitted: " + JSON.stringify(term),
      { pool: [{ id: funcName, term: term }] },
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    const sameBreakNote = note("same-break");
    snap(
      "Rewrite rule applies: def-form(colon) -> nonnil_binding(self, F) canonicalized directly (no call-site check)." +
        (hasCounterexample ? (" Real counterexample: " + counterexampleCall + ".") : ""),
      { pool: [{ id: funcName, term: term }], note: sameBreakNote ? sameBreakNote.text + " [" + sameBreakNote.citesFinding + "]" : undefined },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    return { funcName: funcName, term: term, hasCounterexample: hasCounterexample, counterexampleCall: counterexampleCall };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall, f.file, f.defSpan, f.useSpan);
    snap(
      "normalize(store, rules) reaches a fixpoint: " + r.funcName + " canonicalizes to supports(nonnil_binding(self, " + r.funcName + ")) — no merge opportunity exists with only one fact in the store.",
      {},
      r.hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: same unsound rule shape)",
      f.useSpan ? [Object.assign({ file: f.file }, f.useSpan)] : undefined
    );
  } else if (f.shape === "colon_self_nonnil_multi") {
    runSelfShape(f.funcName, false, null, f.file, f.defSpan, f.useSpans && f.useSpans[0]);
    snap(
      "Applied to all 4 sites, same rewrite, no merge opportunity in isolation.",
      {},
      "Proved (flagged: same unsound rule shape)",
      f.useSpans ? f.useSpans.map((s) => Object.assign({ file: f.file }, s)) : undefined
    );
  } else if (f.shape === "single_assign_nonnil") {
    const term = { functor: "nonnil_binding", args: [f.name] };
    snap("Ground term: " + JSON.stringify(term), { pool: [{ id: f.name, term: term }] }, undefined, f.assignSpan ? [Object.assign({ file: f.file }, f.assignSpan)] : undefined);
    snap(
      "Rewrite rule for single-assignment non-nil normalizes this to supports(" + JSON.stringify(term) + ") — same disclosed ordering-check gap as Reading A, not exercised in this scenario.",
      { pool: [{ id: f.name, term: term }] },
      "Proved",
      f.useSpan ? [Object.assign({ file: f.file }, f.useSpan)] : undefined
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "No rewrite rule's left-hand side matches reachable(F, \"then\") — stays Open, same structural receipt as Reading A.",
      {},
      "Open",
      f.lineSpan ? [Object.assign({ file: f.file }, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    // THIS is the mandatory adversarial walk-through.
    const a = f.factA, b = f.factB;
    const termA = { functor: "nonnil_binding", args: ["self", a.funcName] };
    const termB = { functor: "nonnil_binding", args: ["self", b.funcName] };
    snap(
      "Two DISTINCT ground terms admitted: A = " + JSON.stringify(termA) + " (from " + a.funcName +
        ", has a real counterexample call " + a.counterexampleCall + ") and B = " + JSON.stringify(termB) +
        " (from " + b.funcName + ", genuinely true, no counterexample).",
      { pool: [{ id: "A", term: termA }, { id: "B", term: termB }] },
      undefined,
      [spanOf(a.file, a.defSpan), spanOf(b.file, b.defSpan)].filter(Boolean)
    );
    const mechanismNote = note("merge-mechanism");
    snap(
      "The plausible-but-wrong REWRITE rule: canonicalize any nonnil_binding(self, _) term to ONE shared equivalence class keyed only on the receiver name \"self\", discarding which method it came from.",
      { pool: [{ id: "A", term: termA }, { id: "B", term: termB }], note: mechanismNote ? mechanismNote.text + " [" + mechanismNote.citesFinding + "]" : undefined }
    );
    const mergedClass = { canonical: "nonnil_binding(self, *)", members: [a.funcName, b.funcName] };
    snap(
      "MERGE: A and B are unioned into one equivalence class: " + JSON.stringify(mergedClass),
      { pool: [{ id: "merged", term: mergedClass }], note: "A and B no longer independently addressable." }
    );
    const amplificationNote = note("amplification");
    snap(
      "B's derivation (genuinely true) supplies `supports` for the MERGED canonical representative.",
      { pool: [{ id: "merged", term: mergedClass, polarity: "supports (inherited from B, wrongly applied to A too)" }], note: amplificationNote ? amplificationNote.text + " [" + amplificationNote.citesFinding + "]" : undefined },
      "False-Proved-flagged (A amplified via B's merged identity)",
      [spanOf(a.file, a.useSpan), spanOf(b.file, b.useSpans && b.useSpans[0])].filter(Boolean)
    );
  }

  return snaps;
};
