// engine-invert.js
//
// Reproduces candidates/invert.md: Claim = { id, holds: Trace* -> boolean },
// a trusted evaluator (mechanized Lua stepper), a small fixed structural
// proof calculus (seq_compose / induct_trace / const_fold), Certificate =
// Witness | Proof, and a dependency-graph acyclicity check as the one law.
//
// Faithfully reproduces the design's OWN certificate-construction gap: for
// the self-non-nil shape, the certificate the design narrates cannot
// actually be built from the two Certificate shapes it defines (this
// engine reports UNDERSPECIFIED rather than inventing a third certificate
// kind that isn't in the doc). For the HEX/FIFO shape, the certificate IS
// constructible but only establishes the fact for one witnessed run, not
// universally -- this engine builds it, the (real) check() accepts it, and
// mints Proved, flagged as unsound. All narrative commentary about WHY
// lives in scenario.notes.invert as data.

window.runInvertEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes.invert) || [];
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

  function runSelfShape(funcName, fileName, defSpan, useSpan) {
    snap(
      "Claim.holds closure built: function(tr) return tr:binding_at_entry(\"self\") ~= nil end for " + funcName,
      { pool: [{ id: "claim:self-nonnil", kind: "Claim.holds closure" }] },
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    snap(
      "Attempting a Proof certificate via seq_compose, premises = [static-parse-fact: is " + funcName + " defined with `:` syntax?, err-absence-axiom]",
      { pool: [{ id: "claim:self-nonnil" }], attemptedCertificate: { rule: "seq_compose", premises: ["static-parse-fact: colon-vs-dot", "err-absence-axiom"] } },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    const underspecNote = note("underspecified");
    return {
      description:
        underspecNote ? underspecNote.text + " [" + underspecNote.citesFinding + "]" : "UNDERSPECIFIED",
      state: { pool: [{ id: "claim:self-nonnil" }], attemptedCertificate: { rule: "seq_compose", premises: ["static-parse-fact: colon-vs-dot (UNCONSTRUCTIBLE)", "err-absence-axiom"] } },
      verdict: "Underspecified-stopped",
    };
  }

  function runSingleAssignShape(name, useLine, assignSpan, useSpan, fileName) {
    snap(
      "Claim.holds closure: function(tr) return tr:binding_at(\"" + name + "\", " + useLine + ") ~= nil end",
      { pool: [{ id: "claim:" + name + "-nonnil" }] },
      undefined,
      assignSpan ? [spanOf(fileName, assignSpan)] : undefined
    );
    snap(
      "Witness certificate via induct_trace: base case = table-constructor witness replay, inductive step = syntactic no-rebind scan over ONE trace.",
      { pool: [{ id: "claim:" + name + "-nonnil" }], attemptedCertificate: { rule: "induct_trace", premises: ["table-constructor-witness", "no-rebind-scan-over-ONE-trace"] } },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    snap(
      "kernel/check.lua's check() recursively verifies both premises against the ONE replayed trace and accepts the induct_trace rule's structural precondition.",
      { pool: [{ id: "claim:" + name + "-nonnil" }] }
    );
    const unsoundNote = note("unsound-induct");
    return {
      description: "Proved via induct_trace" + (unsoundNote ? " — " + unsoundNote.text + " [" + unsoundNote.citesFinding + "]" : ""),
      state: { pool: [{ id: "claim:" + name + "-nonnil" }] },
      verdict: "False-Proved-flagged",
    };
  }

  let result;
  if (f.shape === "colon_self_nonnil") {
    result = runSelfShape(f.funcName, f.file, f.defSpan, f.useSpan);
    snap(result.description, result.state, result.verdict, f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined);
  } else if (f.shape === "colon_self_nonnil_multi") {
    result = runSelfShape(f.funcName + " (amortized: one universal certificate, 4 site-specific projections)", f.file, f.defSpan, f.useSpans && f.useSpans[0]);
    snap(result.description, result.state, result.verdict, f.useSpans ? f.useSpans.map((s) => spanOf(f.file, s)) : undefined);
  } else if (f.shape === "single_assign_nonnil") {
    result = runSingleAssignShape(f.name, f.useLine, f.assignSpan, f.useSpan, f.file);
    snap(result.description, result.state, result.verdict, f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined);
  } else if (f.shape === "branch_reachable") {
    snap(
      "Cheapest move: look for a Witness certificate (a concrete input reaching the site) or its dual (a full unreachability proof). Neither is available in this scenario.",
      {},
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.file, a.defSpan, a.useSpan);
    const rB = runSelfShape(b.funcName, b.file, b.defSpan, b.useSpans && b.useSpans[0]);
    const independentNote = note("independent-underspec");
    const independentState = {};
    if (independentNote) independentState.note = independentNote.text + " [" + independentNote.citesFinding + "]";
    snap(
      "invert's pool is a dependency graph over certificate ids, never a rewrite/merge system — no equivalence classes exist to collapse. " +
        a.funcName + " and " + b.funcName + " independently hit the same unconstructible-certificate problem.",
      independentState,
      "A=Underspecified-stopped, B=Underspecified-stopped (no amplification possible)"
    );
  } else if (f.shape === "hand_claims") {
    // Generic claim-kind shape: a Proof certificate is constructible via
    // const_fold (the claimed arms are read directly off evidence's own
    // establishesArms set, no induction over traces needed) iff
    // establishesArms is non-null and covers claimedArms; otherwise no
    // certificate shape in this design carries "evidence establishes
    // nothing usable" -- honestly Underspecified, same spirit as the
    // colon-self shape's own gap. The arm-subset entailment itself is
    // producers.js content (PLACEMENT, see scenarios.js header) -- this
    // engine only decides which certificate SHAPE (Proof vs Underspecified)
    // the entailment result can be carried in.
    const armsRule = (window.PRODUCER_RULES || []).filter((r) => r.id === "arm-subset-entailment-v1")[0];
    const results = [];
    f.claims.forEach((claim) => {
      const useSpan = claim.site ? spanOf(f.file, claim.site) : undefined;
      snap(
        "Claim.holds closure built: function(tr) return arm_of(tr, \"" + claim.subject + "\") in " + JSON.stringify(claim.claimedArms) + " end",
        { pool: [{ id: "claim:" + claim.id }] },
        undefined,
        useSpan ? [useSpan] : undefined
      );
      const arms = claim.evidence.establishesArms;
      const covered = armsRule && armsRule.entails({ establishesArms: arms, subject: claim.subject }, { claimedArms: claim.claimedArms, unionArms: claim.unionArms, subject: claim.subject }) === "supports";
      let v, desc;
      if (covered) {
        desc = "const_fold certificate: evidence.establishesArms=" + JSON.stringify(arms) + " covers claimedArms=" + JSON.stringify(claim.claimedArms) + " directly -- Proof accepted.";
        v = "Proved";
      } else {
        desc = "UNDERSPECIFIED: evidence establishes nothing usable for this claim (establishesArms=" + JSON.stringify(arms) + ") -- no certificate shape carries a bare non-coverage fact.";
        v = "Underspecified-stopped";
      }
      snap(desc, { pool: [{ id: "claim:" + claim.id }], attemptedCertificate: { rule: "const_fold", premises: ["evidence.establishesArms"] } }, v, useSpan ? [useSpan] : undefined);
      results.push(claim.id + "=" + v);
    });
    snap("All claims evaluated: " + results.join(", "), {}, results.join(", "));
  }

  return snaps;
};
