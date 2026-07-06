// engine-evidence.js
//
// Reproduces candidates/evidence.md: an Oracle (mechanized stepper exposing
// entries/step/replay/cfg_at), an Address term algebra + unify, a Predicate
// protocol (decide: Oracle,State -> true|false|unknown), check_box
// (universal claims via invariant entry/step-closure/implies checking) and
// check_witness (existential/refutation via concrete replay), plus a
// citation-graph acyclicity+groundedness law.
//
// Faithfully reproduces the design's OWN blind spot: the self-non-nil
// invariant is certified via `oracle.entries(method)`, described as a
// STATIC enumeration of colon-call sites, with no argument that this
// enumeration soundly over-approximates every actual invocation. When a
// scenario's ground truth includes a counterexample call, this engine's
// `entries()` still only enumerates the syntactic colon-call sites (exactly
// as evidence.md describes it), so `check_box` mechanically reports the
// invariant holds at every ENUMERATED entry -- and mints a false Proved,
// because the enumeration itself was never sound. All narrative commentary
// lives in scenario.notes.evidence as data.

window.runEvidenceEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes.evidence) || [];
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

  function runSelfShape(funcName, hasEscape, counterexampleCall, fileName, defSpan, useSpan) {
    const addr = { functor: "param_binding", args: [{ atom: "self" }, { atom: funcName }] };
    snap(
      "Address term built: " + JSON.stringify(addr),
      { pool: [{ id: "addr", term: addr }] },
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    snap(
      "oracle.entries(" + funcName + ") — static enumeration of colon-call sites." +
        (hasEscape ? " A first-class escape (" + counterexampleCall + ") exists but is invisible to this enumeration." : " No escapes exist; the enumeration is complete."),
      { pool: [{ id: "addr", term: addr }], entries: hasEscape ? ["colon-call sites only (escape invisible)"] : ["colon-call sites (complete)"] },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    snap(
      "check_box: entries_satisfy(invariant, oracle, claim) walks every ENUMERATED entry state; preserved_by_every_step holds trivially; implies(invariant, claim) is identity here.",
      { pool: [{ id: "addr", term: addr }] }
    );
    if (hasEscape) {
      const escapeNote = note("escape-blind");
      return {
        description: escapeNote ? escapeNote.text + " [" + escapeNote.citesFinding + "]" : "FALSE PROVED",
        verdict: "False-Proved-flagged",
      };
    }
    return { description: "check_box succeeds honestly — no escape exists in this scenario, so the (incomplete-in-general) static enumeration happens to be complete here.", verdict: "Proved" };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall, f.file, f.defSpan, f.useSpan);
    snap(r.description, {}, r.verdict, f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined);
  } else if (f.shape === "colon_self_nonnil_multi") {
    const r = runSelfShape(f.funcName, false, null, f.file, f.defSpan, f.useSpans && f.useSpans[0]);
    snap(r.description + " (applied uniformly across all 4 sites)", {}, r.verdict, f.useSpans ? f.useSpans.map((s) => spanOf(f.file, s)) : undefined);
  } else if (f.shape === "single_assign_nonnil") {
    const addr = { functor: "no_reassign", args: [{ atom: f.name }] };
    snap("Address term: " + JSON.stringify(addr), { pool: [{ id: "addr", term: addr }] }, undefined, f.assignSpan ? [spanOf(f.file, f.assignSpan)] : undefined);
    snap(
      "Invariant: \"no bind event to " + f.name + " has occurred since def_site\". A second producer mints non_nil_at_construction(" + f.name + ", def_site) grounded in table-constructor semantics.",
      { pool: [{ id: "addr", term: addr }] },
      undefined,
      f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined
    );
    snap(
      "check_box walks the (finite, syntactically local) CFG span and confirms step-closure — cites two independently-grounded claims, satisfying the one law without the kernel ever knowing what \"" + f.name + "\" or \"table\" mean.",
      { pool: [{ id: "addr", term: addr }] },
      "Proved"
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "Test-trace-harvesting producer feeds recorded event traces through oracle.replay. No harvested trace covers this branch in this scenario.",
      {},
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall, a.file, a.defSpan, a.useSpan);
    const rB = runSelfShape(b.funcName, false, null, b.file, b.defSpan, b.useSpans && b.useSpans[0]);
    const noAmpNote = note("no-shared-amplification");
    snap(
      a.funcName + " = " + rA.verdict + ", " + b.funcName + " = " + rB.verdict,
      { note: noAmpNote ? noAmpNote.text + " [" + noAmpNote.citesFinding + "]" : undefined },
      "A=" + rA.verdict + ", B=" + rB.verdict + " (no amplification)"
    );
  }

  return snaps;
};
