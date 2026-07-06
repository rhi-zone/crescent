// engine-primitive.js
//
// Reproduces candidates/primitive.md: a claim is an executable checker
// `check(witness) -> "accept"|"reject"|"unknown"`; Kernel.find_disagreement
// searches for a witness two claims disagree on (Refuted); Kernel.exhaust
// runs a witness source to observed termination; find_corroboration (the
// second primitive, added in §2.4) treats "accept + unknown, nothing
// rejects" as provisionally closed.
//
// Faithfully reproduces the design's OWN flagship bug
// (judgments/primitive-attack.md "Attack 0 (the flagship demo does not run
// as claimed) — FATAL"): `mined_deref_nonnil.check`, exactly as pasted in
// primitive.md §2.3, has no branch that returns "unknown" for "no concrete
// value" -- `witness.value == nil` unconditionally hits the `"reject"`
// branch, because Lua cannot distinguish "field absent" from "field
// explicitly nil". This engine literally implements that pasted check
// function verbatim, so the bug reproduces itself rather than being asserted.

window.runPrimitiveEngine = function (scenario) {
  const f = scenario.facts;
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    snaps.push(s);
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

  function runSelfShape(funcName, useLine, calledOnlyViaColon, counterexampleCall) {
    // The witness source is single-shot (primitive.md §2.3
    // `mined.witness_source`): the harvester has no concrete runtime value
    // (static analysis only), so value = nil.
    const witness = { kind: "binding", site: funcName + "@" + useLine, via: "colon_call_self", value: null };
    snap(
      "witness_source(site, binding_info) emits ONE witness (single-shot, per primitive.md §2.3): " +
        JSON.stringify(witness),
      { pool: [{ id: "axiom", check: "axiomColonSelfCheck" }, { id: "mined-obligation", check: "minedDerefNonnilCheck" }], witnesses: [witness] }
    );

    const ra = axiomColonSelfCheck(witness);
    snap("axiom.check(w) = \"" + ra + "\"", { witnesses: [witness], calls: { axiom: ra } });

    const rb = minedDerefNonnilCheck(witness);
    snap(
      "mined_deref_nonnil.check(w) = \"" + rb + "\" — witness.value is `nil` (no concrete " +
        "runtime value collected), and the pasted check has no `\"unknown\"` branch for " +
        "that case; it falls straight to `if witness.value == nil then return \"reject\" end`.",
      { witnesses: [witness], calls: { axiom: ra, mined: rb } }
    );

    const disagreement = findDisagreement(axiomColonSelfCheck, minedDerefNonnilCheck, [witness]);
    if (disagreement) {
      const note =
        "FALSE REFUTED — see judgments/primitive-attack.md finding \"Attack 0 (the " +
        "flagship demo does not run as claimed) — FATAL\": \"Lua cannot distinguish " +
        "'field absent' from 'field explicitly nil'... Running the pasted code produces " +
        "a Refuted finding, not an empty `findings` table... self is genuinely " +
        "guaranteed non-nil; the tool would report a contradiction.\"" +
        (counterexampleCall
          ? " (In THIS scenario a real counterexample call, " + counterexampleCall +
            ", also exists — the design still never reaches that fact; it Refutes for " +
            "the wrong reason, via the nil/absent bug, not via detecting the counterexample.)"
          : "");
      snap(
        "Kernel.find_disagreement(axiom, mined_obligation, [w]) found a disagreement: " +
          "axiom=\"" + ra + "\", mined=\"" + rb + "\" -> Refuted",
        { witnesses: [witness], calls: { axiom: ra, mined: rb }, note: note },
        "False-Refuted-flagged"
      );
      return "False-Refuted-flagged";
    }
    return null;
  }

  if (f.shape === "colon_self_nonnil") {
    runSelfShape(f.funcName, f.useLine, f.calledOnlyViaColon, f.calledOnlyViaColon === false ? f.counterexampleCall : null);
  } else if (f.shape === "colon_self_nonnil_multi") {
    let last = null;
    for (const useLine of f.useLines) {
      last = runSelfShape(f.funcName, useLine, true, null);
    }
    snap(
      "Same nil/absent-conflation bug (primitive-attack.md Attack 0) fires identically at " +
        "all 4 sites — the design's per-producer reuse (\"zero new code\", §3.1 instance 4) " +
        "amplifies the bug exactly as it amplifies correctness would have.",
      {},
      last
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
    snap("dataflow producer's own check(w) = \"" + r + "\" (accept: single assignment, before use)", { witnesses: [witness], calls: { dataflow: r } });
    snap(
      "Kernel.exhaust(witness_source, ..., budget) observes termination after exactly ONE " +
        "witness — per judgments/primitive-attack.md \"Attack 1 (pressure point 1 — does " +
        "Proved ever fire on a claim that matters?)\": \"the kernel's honest claim... is " +
        "*technically* true, but the domain it exhausted has cardinality one, and that " +
        "one witness was constructed by the harvester... The producer relabeled the " +
        "universal claim as a singleton fact and then let the kernel 'exhaust' that " +
        "singleton.\"",
      { witnesses: [witness] },
      "Proved (flagged: degenerate singleton domain)"
    );
  } else if (f.shape === "branch_reachable") {
    snap(
      "No witness source and no claim registered for branch reachability in this scenario " +
        "— no producer sketched in primitive.md supplies one (§3.1 instance 5). Stays Open.",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, 0, a.calledOnlyViaColon, a.calledOnlyViaColon === false ? a.counterexampleCall : null);
    const rB = runSelfShape(b.funcName, 0, b.calledOnlyViaColon, null);
    snap(
      "primitive has no merge/rewrite mechanism either — pool entries are independent " +
        "claim closures, never unioned. " + a.funcName + " = " + rA + ", " + b.funcName +
        " = " + rB + ". Both happen to hit the SAME nil/absent-conflation bug " +
        "(primitive-attack.md Attack 0) independently, not via any shared amplification " +
        "path.",
      {},
      "A=" + rA + ", B=" + rB + " (no amplification, but same bug fires independently)"
    );
  }

  return snaps;
};
