// producers.js
//
// Producer-supplied rule definitions. This is the PRODUCER layer's term
// language -- the arm-set encoding lives here and in scenarios.js claim
// data, and NOWHERE in any engine's kernel loop. Every engine runs these
// rules through its own generic mechanism (subtract/synthesis: kernel
// re-executes check; saturation-A: propagation rule firing; invert:
// certificate construction; evidence: predicate decide; primitive:
// checker over witnesses) without inspecting arms itself. Placement test:
// a numeric-range entailment producer is a new entry in this array with
// zero engine edits.
//
// Rule shape: { id, datalog, describe(claim), entails(evidence, claim) ->
// "supports" | "no-match" }. `evidence` and `claim` are opaque payloads to
// every kernel; only producer code (this file) reads their fields.
// `datalog` is the display form saturation-family engines show.
//
// nil appears below only as an ordinary arm name inside producer rule
// content (the mined presupposing forms happen to be about the nil arm --
// see the harvest.lua scope comment in scenarios.js). No kernel and no
// engine privileges it.

(function () {
  function isSubset(sub, sup) {
    return Array.isArray(sub) && Array.isArray(sup) &&
      sub.every(function (x) { return sup.indexOf(x) !== -1; });
  }
  function setMinus(a, b) {
    return a.filter(function (x) { return b.indexOf(x) === -1; });
  }
  function setEq(a, b) {
    return isSubset(a, b) && isSubset(b, a);
  }

  window.PRODUCER_RULES = [
    {
      // Generic arm-subset entailment: evidence establishing a value in
      // some arm subset supports any claim whose claimed arms include that
      // subset. Used by the hand-derived scenarios' evidence records.
      id: "arm-subset-entailment-v1",
      datalog: "in_arms(S, A) :- evidence(S, E), subset(E, A)",
      describe: function (c) {
        return c.subject + " ∈ {" + (c.claimedArms || []).join(",") + "}";
      },
      entails: function (ev, c) {
        if (!c || !Array.isArray(c.claimedArms)) return "no-match";
        if (!ev || !Array.isArray(ev.establishesArms)) return "no-match";
        if (ev.subject !== undefined && c.subject !== undefined && ev.subject !== c.subject) return "no-match";
        return isSubset(ev.establishesArms, c.claimedArms) ? "supports" : "no-match";
      },
    },
    {
      // The flagship unsound rule (subtract.md §2.2's colon-self-nonnil-v1)
      // restated in the arm term language: a colon definition form whose
      // receiver matches the claim subject entails subject ∈ union minus
      // its nil arm. Definition-site-only -- never inspects call sites.
      // The unsoundness is the producer's own content, preserved on
      // purpose; see judgments/subtract-attack.md Attack 1.
      id: "colon-self-nonnil-v1",
      datalog: "in_arms(R, U∖{nil}) :- def_form(F, colon), receiver_param(F, R), deref_site(F, R)",
      describe: function (c) {
        return c.subject + " ∈ {" + (c.claimedArms || []).join(",") + "} (definition-site evidence only)";
      },
      entails: function (ev, c) {
        if (!ev || ev.form !== "colon" || !c) return "no-match";
        if (ev.receiver_param !== c.subject) return "no-match";
        if (!Array.isArray(c.unionArms) || !Array.isArray(c.claimedArms)) return "no-match";
        return setEq(c.claimedArms, setMinus(c.unionArms, ["nil"])) ? "supports" : "no-match";
      },
    },
    {
      // never-reassigned-nonnil restated: exactly one assignment, of a
      // table literal, to the claim subject entails subject ∈ union minus
      // its nil arm. Still no ordering/dominance check between assignment
      // and use -- the disclosed gap, preserved; see
      // judgments/subtract-attack.md Attack 4.
      id: "never-reassigned-nonnil",
      datalog: "in_arms(X, U∖{nil}) :- single_assignment(X), assigned_kind(X, table), deref_site(X)",
      describe: function (c) {
        return c.subject + " ∈ {" + (c.claimedArms || []).join(",") + "} (single table assignment)";
      },
      entails: function (ev, c) {
        if (!ev || ev.assignment_count !== 1 || ev.initial_value_kind !== "table") return "no-match";
        if (!c || ev.name !== c.subject) return "no-match";
        if (!Array.isArray(c.unionArms) || !Array.isArray(c.claimedArms)) return "no-match";
        return setEq(c.claimedArms, setMinus(c.unionArms, ["nil"])) ? "supports" : "no-match";
      },
    },
  ];
})();
