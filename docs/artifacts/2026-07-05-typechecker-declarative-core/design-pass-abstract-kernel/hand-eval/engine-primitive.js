// engine-primitive.js
//
// Reproduces candidates/primitive.md: a claim is an executable checker
// `check(witness) -> "accept"|"reject"|"unknown"`; Kernel.find_disagreement
// searches for a witness two claims disagree on (Refuted); Kernel.exhaust
// runs a witness source to observed termination; find_corroboration (the
// second primitive, added in §2.4) treats "accept + unknown, nothing
// rejects" as provisionally closed.
//
// Faithfully reproduces the design's OWN flagship bug: `mined_deref_nonnil
// .check`, exactly as pasted in primitive.md §2.3, has no branch that
// returns "unknown" for "no concrete value" -- `witness.value == nil`
// unconditionally hits the `"reject"` branch, because Lua cannot
// distinguish "field absent" from "field explicitly nil". This engine
// literally implements that pasted check function verbatim, so the bug
// reproduces itself rather than being asserted. All narrative commentary
// about WHY that is a bug lives in scenario.notes.primitive as data.

window.runPrimitiveEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes.primitive) || [];
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

  // --- the axiom producer (primitive.md §2.2), verbatim in spirit -------
  function axiomColonSelfCheck(witness) {
    if (typeof witness !== "object" || witness === null || witness.kind !== "binding") return "unknown";
    if (witness.via === "colon_call_self") return "accept";
    return "unknown";
  }

  // --- the mined producer (primitive.md §2.3), VERBATIM, bug included ---
  // if witness.value ~= nil then return "accept" end
  // if witness.value == nil then return "reject" end   <-- the bug: no
  //   "unknown" branch for "I have no data" vs "I have data and it's nil"
  // return "unknown"
  function minedDerefNonnilCheck(witness) {
    if (typeof witness !== "object" || witness === null || witness.kind !== "binding") return "unknown";
    if (witness.site !== witness.site) return "unknown"; // no-op, mirrors site check structurally
    if (witness.value !== null && witness.value !== undefined) return "accept";
    if (witness.value === null || witness.value === undefined) return "reject";
    return "unknown";
  }

  function findDisagreement(a, b, witnesses) {
    for (const w of witnesses) {
      const ra = a(w), rb = b(w);
      if ((ra === "accept" && rb === "reject") || (ra === "reject" && rb === "accept")) {
        return { witness: w, ra: ra, rb: rb };
      }
    }
    return null;
  }

  function runSelfShape(funcName, useLine, useSpan) {
    // The witness source is single-shot (primitive.md §2.3
    // `mined.witness_source`): the harvester has no concrete runtime value
    // (static analysis only), so value = nil.
    const witness = { kind: "binding", site: funcName + "@" + useLine, via: "colon_call_self", value: null };
    snap(
      "witness_source(site, binding_info) emits ONE witness (single-shot): " + JSON.stringify(witness),
      { pool: [{ id: "axiom", check: "axiomColonSelfCheck" }, { id: "mined-obligation", check: "minedDerefNonnilCheck" }], witnesses: [witness] },
      undefined,
      useSpan ? [useSpan] : undefined
    );

    const ra = axiomColonSelfCheck(witness);
    snap("axiom.check(w) = \"" + ra + "\"", { witnesses: [witness], calls: { axiom: ra } });

    const rb = minedDerefNonnilCheck(witness);
    const bugNote = note("witness-bug");
    snap(
      "mined_deref_nonnil.check(w) = \"" + rb + "\"",
      { witnesses: [witness], calls: { axiom: ra, mined: rb }, note: bugNote ? bugNote.text + " [" + bugNote.citesFinding + "]" : undefined },
      undefined,
      useSpan ? [useSpan] : undefined
    );

    const disagreement = findDisagreement(axiomColonSelfCheck, minedDerefNonnilCheck, [witness]);
    if (disagreement) {
      const disagreementNote = note("disagreement");
      snap(
        "Kernel.find_disagreement(axiom, mined_obligation, [w]) found a disagreement: " +
          "axiom=\"" + ra + "\", mined=\"" + rb + "\" -> Refuted",
        { witnesses: [witness], calls: { axiom: ra, mined: rb }, note: disagreementNote ? disagreementNote.text + " [" + disagreementNote.citesFinding + "]" : undefined },
        "False-Refuted-flagged",
        useSpan ? [useSpan] : undefined
      );
      return "False-Refuted-flagged";
    }
    return null;
  }

  if (f.shape === "colon_self_nonnil") {
    runSelfShape(f.funcName, f.useLine, f.useSpan ? Object.assign({ file: f.file }, f.useSpan) : undefined);
  } else if (f.shape === "colon_self_nonnil_multi") {
    let last = null;
    f.useLines.forEach((useLine, idx) => {
      const useSpan = f.useSpans && f.useSpans[idx];
      last = runSelfShape(f.funcName, useLine, useSpan ? Object.assign({ file: f.file }, useSpan) : undefined);
    });
    const amplificationNote = note("amplification");
    snap(
      "Same bug fires identically at all 4 sites (one producer, reused, zero new code).",
      { note: amplificationNote ? amplificationNote.text + " [" + amplificationNote.citesFinding + "]" : undefined },
      last,
      f.useSpans ? f.useSpans.map((s) => Object.assign({ file: f.file }, s)) : undefined
    );
  } else if (f.shape === "single_assign_nonnil") {
    // Different producer family (no pasted code in primitive.md for this
    // shape) -- implemented honestly per the design's OWN prose (§3.1
    // instances #2/#3): a dataflow producer plays both witness-source and
    // corroborating-checker roles; its check reads its OWN witness type, so
    // the nil/absent bug specific to mined_deref_nonnil.check does not
    // apply here. No disagreement occurs.
    function dataflowCheck(witness) {
      if (typeof witness !== "object" || witness === null || witness.kind !== "assignment_trace") return "unknown";
      if (witness.assignments === 1 && witness.name === f.name) return "accept";
      return "unknown";
    }
    const witness = { kind: "assignment_trace", name: f.name, assignments: f.assignmentCount };
    snap("witness_source emits ONE witness (single-shot): " + JSON.stringify(witness), { witnesses: [witness] });
    const r = dataflowCheck(witness);
    snap("dataflow producer's own check(w) = \"" + r + "\"", { witnesses: [witness], calls: { dataflow: r } });
    const singletonNote = note("singleton-domain");
    snap(
      "Kernel.exhaust(witness_source, ..., budget) observes termination after exactly ONE witness.",
      { witnesses: [witness], note: singletonNote ? singletonNote.text + " [" + singletonNote.citesFinding + "]" : undefined },
      "Proved (flagged: degenerate singleton domain)"
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "No witness source and no claim registered for branch reachability in this scenario.",
      {},
      "Open",
      f.lineSpan ? [Object.assign({ file: f.file }, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.useLine, a.useSpan ? Object.assign({ file: a.file }, a.useSpan) : undefined);
    const rB = runSelfShape(b.funcName, b.useLines && b.useLines[0], b.useSpans && b.useSpans[0] ? Object.assign({ file: b.file }, b.useSpans[0]) : undefined);
    const independentNote = note("independent-bug");
    snap(
      "primitive has no merge/rewrite mechanism — pool entries are independent claim closures, never unioned. " +
        a.funcName + " = " + rA + ", " + b.funcName + " = " + rB,
      { note: independentNote ? independentNote.text + " [" + independentNote.citesFinding + "]" : undefined },
      "A=" + rA + ", B=" + rB + " (no amplification, but same bug fires independently)"
    );
  } else if (f.shape === "hand_claims") {
    // Generic claim-kind shape: a witness per claim carries whatever arms
    // the evidence structurally establishes. The arm-subset entailment
    // itself is producers.js content (PLACEMENT, see scenarios.js header);
    // this checker just maps producers.js's two-valued
    // "supports"/"no-match" onto primitive's own three-valued
    // "accept"/"reject"/"unknown" protocol -- "reject" is never reached by
    // this generic shape, since establishesArms is always a subset of
    // unionArms here, not a positive contradiction.
    const armsRule = (window.PRODUCER_RULES || []).filter((r) => r.id === "arm-subset-entailment-v1")[0];
    function armsCoverCheck(witness) {
      if (typeof witness !== "object" || witness === null || witness.kind !== "arms_witness") return "unknown";
      if (!armsRule) return "unknown";
      return armsRule.entails({ establishesArms: witness.establishesArms }, { claimedArms: witness.claimedArms }) === "supports" ? "accept" : "unknown";
    }
    const results = [];
    f.claims.forEach((claim) => {
      const witness = { kind: "arms_witness", claimedArms: claim.claimedArms, establishesArms: claim.evidence.establishesArms };
      const useSpan = claim.site ? Object.assign({ file: f.file }, claim.site) : undefined;
      snap(
        "witness_source(" + claim.subject + ") emits ONE witness: " + JSON.stringify(witness),
        { witnesses: [witness] },
        undefined,
        useSpan ? [useSpan] : undefined
      );
      const r = armsCoverCheck(witness);
      const v = r === "accept" ? "Proved" : r === "reject" ? "Disproved" : "Open";
      snap(
        "arms_cover_check(w) = \"" + r + "\" for " + claim.subject,
        { witnesses: [witness], calls: { arms_cover: r } },
        v,
        useSpan ? [useSpan] : undefined
      );
      results.push(claim.id + "=" + v);
    });
    snap("All claims evaluated: " + results.join(", "), {}, results.join(", "));
  }

  return snaps;
};
