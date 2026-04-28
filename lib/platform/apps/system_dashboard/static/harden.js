// harden.js
//
// Defense-in-depth against prototype pollution from pack-shipped projections
// (future). No-op for current built-in projections; importing it once at load
// is the contract.
//
// Freezes built-in prototypes and constructors so neither a malicious nor a
// buggy projection can mutate them (e.g. `Array.prototype.map = ...`,
// `Object.prototype.x = 1`). Self-executing on import — no exports.
//
// Pre-verified safe: `static/app.js` has no `.prototype.X = ...` mutations;
// the only `prototype` references are `Object.prototype.hasOwnProperty.call`
// reads, which remain valid against frozen prototypes.

[Object, Array, Function, String, Number, Boolean, Map, Set, Date, RegExp, Promise].forEach((C) => {
  Object.freeze(C.prototype);
  Object.freeze(C);
});
