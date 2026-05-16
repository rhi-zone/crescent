// lib/js_realm_sandbox/sandbox.js
//
// Allow-list realm lockdown for pack browser realms. ESM module.
//
// The exported entry point is `installLockdown(opts)`. It is invoked
// inside the pack realm (sandboxed iframe today, ShadowRealm in the
// future) as the very first JS to run, before any pack-author code is
// loaded. It mutates the realm into the locked-down state described in
// docs/platform_isolation.md §3.
//
// What lockdown does, in spec order:
//
//   1. Capture references to the original intrinsics in a closure so
//      bounded-method and regex wrappers can delegate to the originals
//      even after we have neutered the public-facing slots.
//   2. Walk every kept intrinsic prototype:
//        - delete methods on the removed list,
//        - replace methods on the wrapped list with bounded versions,
//        - replace regex methods on String.prototype with patterns that
//          consult validatePattern from lib/js_safe_regex/safe_regex.js
//          before delegating to the captured originals,
//        - neutralise .constructor (set to undefined, non-configurable),
//        - strip Error.prototype.stack, RegExp legacy statics, etc.
//   3. Curate globalThis. The real realm globalThis cannot be replaced
//      with a fresh object (the language gives no mechanism to do so),
//      so we delete every own property not on the allow-list, install
//      opts.caps as a non-configurable, non-writable __cap__ namespace,
//      then Object.freeze the curated globalThis.
//   4. Remove the language-level dynamic-construction shadows: Function,
//      AsyncFunction, GeneratorFunction, AsyncGeneratorFunction. Each is
//      both deleted from globalThis (when present) and its prototype
//      .constructor slot is neutralised.
//   5. Object.freeze every kept intrinsic, every kept prototype, every
//      anonymous iterator prototype, and the opts.caps object itself.
//
// Strict mode requirement. Callers MUST load installLockdown from a
// strict-mode module (this file is ESM, strict by default) and MUST
// load pack code in strict mode (either as ESM, or with a `'use
// strict';` prelude). The realm bootstrap is responsible for
// guaranteeing strict-mode loading; this function cannot fully detect
// non-strict callers from the inside.
//
// Things this module deliberately does NOT do:
//   - Re-bind `globalThis` to a fresh object. Not possible in JS.
//   - Validate or rewrite pack source code. That is the daemon-side
//     acorn pass (separate library, to be built).
//   - Install host caps that perform I/O. Caps are passed in via
//     opts.caps; the host wires them up before invoking lockdown.
//
// Reference: docs/platform_isolation.md, especially §3
// "Allow-list specification (draft)", "Bootstrap script", "Bootstrap
// order", and "Escape-test corpus".

// =====================================================================
// Step 0: capture originals in a closure.
//
// Every wrapper we install delegates to one of these captured
// references, never reaches back through globalThis. The closure
// ensures wrappers continue to work after the public-facing slots are
// deleted or replaced.
// =====================================================================

const O_Object = Object;
const O_Array = Array;
const O_String = String;
const O_RegExp = RegExp;
const O_JSON_stringify = JSON.stringify;
const O_JSON_parse = JSON.parse;

const O_create = Object.create;
const O_defineProperty = Object.defineProperty;
const O_getOwnPropertyNames = Object.getOwnPropertyNames;
const O_getOwnPropertySymbols = Object.getOwnPropertySymbols;
const O_getPrototypeOf = Object.getPrototypeOf;
const O_freeze = Object.freeze;
const O_isFrozen = Object.isFrozen;

const O_String_prototype = String.prototype;
const O_Array_prototype = Array.prototype;
const O_Object_prototype = Object.prototype;
const O_Function_prototype = Function.prototype;
const O_RegExp_prototype = RegExp.prototype;
const O_Error_prototype = Error.prototype;

const O_padStart = String.prototype.padStart;
const O_padEnd = String.prototype.padEnd;
const O_repeat = String.prototype.repeat;
const O_join = Array.prototype.join;
const O_flat = Array.prototype.flat;
const O_flatMap = Array.prototype.flatMap;
const O_Array_from = Array.from;
const O_Array_of = Array.of;
const O_fromCharCode = String.fromCharCode;
const O_fromCodePoint = String.fromCodePoint;
const O_String_match = String.prototype.match;
const O_String_matchAll = String.prototype.matchAll;
const O_String_search = String.prototype.search;

const O_bind = Function.prototype.bind;
const O_call = Function.prototype.call;
const O_apply = Function.prototype.apply;

const O_TypeError = TypeError;
const O_RangeError = RangeError;

// Async / generator constructor shadows reached via prototype.
let O_AsyncFunction = undefined;
let O_GeneratorFunction = undefined;
let O_AsyncGeneratorFunction = undefined;
try {
  // eslint-disable-next-line no-new-func
  O_AsyncFunction = O_getPrototypeOf(async function () {}).constructor;
} catch (_e) { /* not available, fine */ }
try {
  // eslint-disable-next-line no-new-func
  O_GeneratorFunction = O_getPrototypeOf(function* () {}).constructor;
} catch (_e) { /* not available, fine */ }
try {
  // eslint-disable-next-line no-new-func
  O_AsyncGeneratorFunction = O_getPrototypeOf(async function* () {}).constructor;
} catch (_e) { /* not available, fine */ }

// =====================================================================
// Helpers.
// =====================================================================

/**
 * Raise a RangeError naming the cap and the offending size.
 * @param {string} where
 * @param {number} requested
 * @param {number} cap
 * @returns {never}
 */
function rangeFail(where, requested, cap) {
  throw new O_RangeError(
    where + ": requested size " + String(requested) +
    " exceeds size cap " + String(cap)
  );
}

/**
 * Delete a property if present. Some intrinsic slots are
 * non-configurable; in that case we replace the value with undefined
 * (via defineProperty) when possible.
 * @param {object} obj
 * @param {string|symbol} key
 */
function tryDelete(obj, key) {
  try {
    delete obj[key];
  } catch (_e) { /* non-configurable, ignored */ }
}

/**
 * Force `obj[key]` to `undefined` with a non-configurable, non-writable
 * descriptor. Used to neutralise .constructor slots that should not
 * resolve to any usable value.
 * @param {object} obj
 * @param {string|symbol} key
 */
function neutralise(obj, key) {
  try {
    O_defineProperty(obj, key, {
      value: undefined,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  } catch (_e) {
    // Slot is non-configurable with a different value; best we can do
    // is leave it. Document with a no-op rather than throwing — the
    // bootstrap must not abort mid-lockdown.
  }
}

/**
 * Replace a property with a fixed value, non-configurable,
 * non-writable. Used for bounded-method wrappers.
 * @param {object} obj
 * @param {string|symbol} key
 * @param {*} value
 */
function sealValue(obj, key, value) {
  try {
    O_defineProperty(obj, key, {
      value: value,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  } catch (_e) { /* non-configurable existing slot, leave as-is */ }
}

/**
 * Build a non-constructable replacement for `Function.prototype.bind`.
 *
 * Spec semantics preserved:
 *   - Call: `bound.call(_, ...later)` returns
 *     `target.call(thisArg, ...boundArgs, ...later)`.
 *   - `bound.length` = max(0, target.length - boundArgs.length).
 *   - `bound.name` = "bound " + (target.name || "").
 *
 * Spec semantics intentionally NOT preserved:
 *   - `[[Construct]]` is removed. `new bound()` and
 *     `class X extends bound {}` both throw `TypeError`.
 *
 * Technique: concise method syntax (`{ name(...) {} }.name`). Concise
 * methods are callable but have no `[[Construct]]` slot. We then
 * `defineProperty` `.length` and `.name` to match the spec values
 * (concise-method `.name` would otherwise be the literal property key,
 * and `.length` would be its declared arity).
 *
 * Reference: docs/platform_isolation.md §3 "Function.prototype" and
 * "Non-constructable wrapper pattern". Mirrors endo's
 * `makeEvalFunction` (`packages/ses/src/make-eval-function.js`), which
 * uses concise-method syntax for the same purpose.
 */
function makeNonConstructableBind() {
  return {
    bind(thisArg, ...boundArgs) {
      const target = this;
      if (typeof target !== "function") {
        throw new O_TypeError(
          "Function.prototype.bind called on non-function"
        );
      }
      // Capture target and boundArgs in closure; produce a
      // non-constructable concise-method wrapper that delegates.
      const bound = {
        ["bound " + (target.name || "")](...later) {
          return O_apply.call(
            target, thisArg,
            boundArgs.length === 0
              ? later
              : (later.length === 0
                ? boundArgs
                : boundArgs.concat(later))
          );
        },
      }["bound " + (target.name || "")];
      // Repair `.length` per spec: max(0, target.length - boundArgs).
      const targetLen = typeof target.length === "number" ? target.length : 0;
      const newLen = Math.max(0, targetLen - boundArgs.length);
      try {
        O_defineProperty(bound, "length", {
          value: newLen,
          writable: false,
          configurable: true,
          enumerable: false,
        });
      } catch (_e) { /* keep concise-method default */ }
      return bound;
    },
  }.bind;
}

/**
 * Wrap a host cap function in a non-constructable shell. The shell
 * preserves call semantics (`shell(...args)` -> `cap(...args)`), keeps
 * the original cap name, and removes `[[Construct]]` so pack code
 * cannot invoke `new __cap__.foo(...)`. See
 * docs/platform_isolation.md §3 "Non-constructable wrapper pattern".
 *
 * @param {string} name
 * @param {Function} cap
 */
function makeCapShell(name, cap) {
  return { [name](...args) { return cap(...args); } }[name];
}

/**
 * Replace a getter (e.g. Error.prototype.stack) with one that returns
 * a fixed safe value.
 * @param {object} obj
 * @param {string|symbol} key
 * @param {*} safe
 */
function sealGetter(obj, key, safe) {
  try {
    O_defineProperty(obj, key, {
      get: function () { return safe; },
      set: undefined,
      configurable: false,
      enumerable: false,
    });
  } catch (_e) { /* non-configurable, leave */ }
}

// =====================================================================
// Removed-method lists. Anything not listed in "kept" or "wrapped" is
// either deleted (configurable) or neutralised (non-configurable).
// Source of truth: docs/platform_isolation.md §3 "Allow-list
// specification (draft)".
// =====================================================================

const REMOVED_ON_OBJECT_CTOR = [
  "create", "defineProperty", "defineProperties",
  "getPrototypeOf", "setPrototypeOf",
  "getOwnPropertyDescriptor", "getOwnPropertyDescriptors",
  "getOwnPropertyNames", "getOwnPropertySymbols",
  "preventExtensions", "seal", "isSealed", "isExtensible",
  "fromEntries",
];

const REMOVED_ON_OBJECT_PROTO = [
  "__defineGetter__", "__defineSetter__",
  "__lookupGetter__", "__lookupSetter__",
  "propertyIsEnumerable", "isPrototypeOf",
];

const REMOVED_ON_FUNCTION_PROTO = [
  "toString",
];

const REMOVED_ON_REGEXP_PROTO = [
  "compile",
];

const REMOVED_ON_ERROR_CTOR = [
  "captureStackTrace", "stackTraceLimit", "prepareStackTrace",
];

const REMOVED_ON_SYMBOL_CTOR = [
  "for", "keyFor",
];

const REGEXP_LEGACY_STATICS = [
  "$1", "$2", "$3", "$4", "$5", "$6", "$7", "$8", "$9",
  "input", "$_",
  "lastMatch", "$&",
  "lastParen", "$+",
  "leftContext", "$`",
  "rightContext", "$'",
];

const ERROR_SUBCLASSES = [
  "Error", "TypeError", "SyntaxError", "RangeError",
  "ReferenceError", "URIError", "EvalError", "AggregateError",
];

const KEPT_TYPED_ARRAYS = [
  "Int8Array", "Uint8Array", "Uint8ClampedArray",
  "Int16Array", "Uint16Array",
  "Int32Array", "Uint32Array",
  "Float32Array", "Float64Array",
  "BigInt64Array", "BigUint64Array",
];

/**
 * Names that survive on globalThis. Anything else is deleted.
 * Source of truth: docs/platform_isolation.md §3 "Intrinsics".
 */
const GLOBAL_ALLOWLIST = [
  // Value globals.
  "undefined", "NaN", "Infinity",
  "globalThis",
  // Allowed constructors / namespaces.
  "Object", "Array", "String", "Number", "Boolean", "BigInt",
  "Symbol", "Math", "JSON",
  "Map", "Set", "WeakMap", "WeakSet",
  "Promise", "Date", "RegExp",
  "Error", "TypeError", "SyntaxError", "RangeError",
  "ReferenceError", "URIError", "EvalError", "AggregateError",
  "ArrayBuffer", "DataView",
  "Int8Array", "Uint8Array", "Uint8ClampedArray",
  "Int16Array", "Uint16Array",
  "Int32Array", "Uint32Array",
  "Float32Array", "Float64Array",
  "BigInt64Array", "BigUint64Array",
  // Coercion helpers we keep (parse* are real-use-case literals,
  // isNaN/isFinite are inert predicates).
  "parseInt", "parseFloat", "isNaN", "isFinite",
];

// =====================================================================
// Bounded-method wrappers.
//
// Each wrapper checks the cap before delegating to the captured
// original. Wrappers throw RangeError (via rangeFail) when the input
// or output would exceed the cap.
//
// SIZE_CAP applies to: argument counts for variadic constructors and
// fromCharCode/fromCodePoint/Array.of; element counts for Array(n) /
// Array.from / Array.of; output character counts for repeat/padStart/
// padEnd; output character counts for join/flat/flatMap; input AND
// output sizes for JSON.parse / JSON.stringify.
// =====================================================================

/**
 * Build the suite of bounded wrappers for a given cap.
 *
 * Authoring rule: every wrapper here MUST be authored as concise method
 * syntax (`{ name(...) {} }.name`) or arrow function — both produce
 * callables without `[[Construct]]`. Wrappers that need a dynamic `this`
 * (prototype methods like `repeat`, `padStart`, `join`) use concise
 * method syntax; pure delegators use arrows. A wrapper authored as
 * `function name() {}` would be constructable, which violates the
 * non-constructable-wrapper rule (see docs/platform_isolation.md §3
 * "Non-constructable wrapper pattern").
 *
 * Exception: `boundedArray` is intentionally a `function` declaration
 * because it replaces `globalThis.Array` and pack code legitimately
 * invokes `new Array(n)`. It is the only bootstrap-installed wrapper
 * that retains `[[Construct]]`.
 *
 * @param {number} cap
 */
function buildBoundedWrappers(cap) {
  // String.prototype.repeat — output length = this.length * count.
  const boundedRepeat = {
    repeat(count) {
      const n = +count;
      if (!Number.isFinite(n) || n < 0) {
        // Let the original handle the invalid-input error path.
        return O_call.call(O_repeat, this, count);
      }
      const out = O_String(this).length * Math.floor(n);
      if (out > cap) rangeFail("String.prototype.repeat", out, cap);
      return O_call.call(O_repeat, this, count);
    },
  }.repeat;

  // String.prototype.padStart / padEnd — output length is targetLength.
  const boundedPadStart = {
    padStart(targetLength, padString) {
      const t = +targetLength;
      if (Number.isFinite(t) && t > cap) {
        rangeFail("String.prototype.padStart", t, cap);
      }
      return O_call.call(O_padStart, this, targetLength, padString);
    },
  }.padStart;
  const boundedPadEnd = {
    padEnd(targetLength, padString) {
      const t = +targetLength;
      if (Number.isFinite(t) && t > cap) {
        rangeFail("String.prototype.padEnd", t, cap);
      }
      return O_call.call(O_padEnd, this, targetLength, padString);
    },
  }.padEnd;

  // Array constructor — Array(n). The wrapper replaces the global
  // Array binding; the original prototype is preserved by setting
  // boundedArray.prototype = O_Array_prototype.
  //
  // Authored as a `function` declaration on purpose: pack code uses
  // `new Array(n)`, so this wrapper must retain `[[Construct]]`. The
  // bounded Array constructor is the single documented exception to the
  // non-constructable-wrapper rule.
  function boundedArray(...args) {
    if (args.length === 1) {
      const n = args[0];
      if (typeof n === "number" && Number.isFinite(n) && n > cap) {
        rangeFail("Array", n, cap);
      }
    }
    if (args.length > cap) {
      rangeFail("Array", args.length, cap);
    }
    // Apply original with `new` semantics.
    return new O_Array(...args);
  }

  // Array.from — bound length first, then delegate.
  const boundedArrayFrom = (items, mapfn, thisArg) => {
    if (items != null && typeof items === "object") {
      const len = items.length;
      if (typeof len === "number" && Number.isFinite(len) && len > cap) {
        rangeFail("Array.from", len, cap);
      }
    }
    // For genuine iterables (no length), let the original handle it but
    // wrap mapfn to fail-fast if we exceed the cap during iteration.
    // We do this by counting through a wrapper iterator only when length
    // is not present.
    if (items != null && typeof items === "object" &&
        typeof items.length !== "number") {
      let count = 0;
      const wrappedMap = (v, i) => {
        count = i + 1;
        if (count > cap) rangeFail("Array.from", count, cap);
        return mapfn ? O_call.call(mapfn, thisArg, v, i) : v;
      };
      return O_call.call(O_Array_from, O_Array, items, wrappedMap, thisArg);
    }
    return O_call.call(O_Array_from, O_Array, items, mapfn, thisArg);
  };

  // Array.of — argument count.
  const boundedArrayOf = (...args) => {
    if (args.length > cap) rangeFail("Array.of", args.length, cap);
    return O_apply.call(O_Array_of, O_Array, args);
  };

  // String.fromCharCode / fromCodePoint — argument count.
  const boundedFromCharCode = (...args) => {
    if (args.length > cap) {
      rangeFail("String.fromCharCode", args.length, cap);
    }
    return O_apply.call(O_fromCharCode, O_String, args);
  };
  const boundedFromCodePoint = (...args) => {
    if (args.length > cap) {
      rangeFail("String.fromCodePoint", args.length, cap);
    }
    return O_apply.call(O_fromCodePoint, O_String, args);
  };

  // Array.prototype.join — output length bounded post-hoc by computing
  // a worst-case before joining. Cheap upper bound: sum of element
  // string lengths after String() coercion, plus separator length.
  // We compute this bound directly (which forces coercion, matching
  // join's own semantics) then call the original.
  const boundedJoin = {
    join(separator) {
      const sep = separator === undefined ? "," : O_String(separator);
      const arr = this;
      const len = arr != null ? arr.length : 0;
      let total = 0;
      if (typeof len === "number" && Number.isFinite(len) && len > 0) {
        total = sep.length * (len - 1);
        for (let i = 0; i < len; i++) {
          const v = arr[i];
          const s = v == null ? "" : O_String(v);
          total += s.length;
          if (total > cap) {
            rangeFail("Array.prototype.join", total, cap);
          }
        }
      }
      return O_call.call(O_join, this, separator);
    },
  }.join;

  // Array.prototype.flat — bound resulting element count.
  const boundedFlat = {
    flat(depth) {
      const result = O_call.call(O_flat, this, depth);
      if (result.length > cap) {
        rangeFail("Array.prototype.flat", result.length, cap);
      }
      return result;
    },
  }.flat;
  const boundedFlatMap = {
    flatMap(mapper, thisArg) {
      const result = O_call.call(O_flatMap, this, mapper, thisArg);
      if (result.length > cap) {
        rangeFail("Array.prototype.flatMap", result.length, cap);
      }
      return result;
    },
  }.flatMap;

  // JSON wrappers.
  const boundedJSONStringify = (value, replacer, space) => {
    const out = O_call.call(O_JSON_stringify, JSON, value, replacer, space);
    if (typeof out === "string" && out.length > cap) {
      rangeFail("JSON.stringify", out.length, cap);
    }
    return out;
  };
  const boundedJSONParse = (text, reviver) => {
    if (typeof text === "string" && text.length > cap) {
      rangeFail("JSON.parse", text.length, cap);
    }
    return O_call.call(O_JSON_parse, JSON, text, reviver);
  };

  return {
    boundedRepeat, boundedPadStart, boundedPadEnd,
    boundedArray, boundedArrayFrom, boundedArrayOf,
    boundedFromCharCode, boundedFromCodePoint,
    boundedJoin, boundedFlat, boundedFlatMap,
    boundedJSONStringify, boundedJSONParse,
  };
}

// =====================================================================
// Regex wrappers (consume lib/js_safe_regex/safe_regex.js).
//
// Import path is relative; the bootstrap loads both modules from
// the same lib/js_*/ tree. We re-export validatePattern at the
// bottom of the file for convenience to test code.
// =====================================================================

import { validatePattern } from "../js_safe_regex/safe_regex.js";

/**
 * Throw if the pattern is unsafe; otherwise return.
 * @param {*} pat
 */
function checkPattern(pat) {
  if (typeof pat !== "string") return; // RegExp objects already checked
  const v = validatePattern(pat);
  if (!v.ok) {
    throw new O_TypeError("regex pattern rejected: " + v.error);
  }
}

/**
 * Build a RegExp constructor wrapper that validates its first arg.
 *
 * Authored as a `function` declaration intentionally: pack code does
 * `new RegExp(...)`, so SafeRegExp must retain `[[Construct]]`. Along
 * with `boundedArray`, this is the only other bootstrap-installed
 * wrapper that intentionally keeps the construct slot.
 */
function buildRegExpWrapper() {
  function SafeRegExp(pattern, flags) {
    if (typeof pattern === "string") checkPattern(pattern);
    // When called as a function, the spec returns the same RegExp if the
    // first arg is already a RegExp and no flags are supplied; delegate.
    return new O_RegExp(pattern, flags);
  }
  // Preserve the prototype so `instanceof RegExp` and prototype lookups
  // continue to work.
  SafeRegExp.prototype = O_RegExp_prototype;
  return SafeRegExp;
}

// String.prototype.{match,matchAll,search} wrappers.
//
// Authored as concise methods: each is installed onto String.prototype
// and uses `this` (the string being matched against), so an arrow form
// would lose the receiver. Concise method form has no `[[Construct]]`,
// satisfying the non-constructable wrapper rule.
function buildStringMatchWrappers() {
  const safeMatch = {
    match(pat) {
      if (typeof pat === "string") checkPattern(pat);
      return O_call.call(O_String_match, this, pat);
    },
  }.match;
  const safeMatchAll = {
    matchAll(pat) {
      if (typeof pat === "string") checkPattern(pat);
      return O_call.call(O_String_matchAll, this, pat);
    },
  }.matchAll;
  const safeSearch = {
    search(pat) {
      if (typeof pat === "string") checkPattern(pat);
      return O_call.call(O_String_search, this, pat);
    },
  }.search;
  return { safeMatch, safeMatchAll, safeSearch };
}

// =====================================================================
// Iterator prototypes — reach via Symbol.iterator on instances and walk
// up to the anonymous shared iterator prototypes. We neutralise their
// .constructor slots.
// =====================================================================

/**
 * @param {object} instance
 * @returns {object[]}
 */
function reachableIteratorPrototypes(instance) {
  const out = [];
  try {
    const it = instance[Symbol.iterator]();
    let p = O_getPrototypeOf(it);
    while (p && p !== O_Object_prototype) {
      out.push(p);
      p = O_getPrototypeOf(p);
    }
  } catch (_e) { /* not iterable, skip */ }
  return out;
}

// =====================================================================
// The main entry point.
// =====================================================================

/**
 * Lock down the current realm. Must be called exactly once, from the
 * realm bootstrap, before any pack-author code runs. The caller MUST be
 * in strict mode (this module is ESM, which is strict by default).
 *
 * After this call returns:
 *   - globalThis contains only the allow-listed intrinsics plus
 *     opts.caps under the name `__cap__`.
 *   - globalThis is Object.freeze'd; pack code cannot add new globals.
 *   - Every kept intrinsic and its prototype is Object.freeze'd.
 *   - Function / AsyncFunction / GeneratorFunction /
 *     AsyncGeneratorFunction are removed and their prototype
 *     .constructor slots neutralised so the (a={}).__proto__
 *     .constructor.constructor escape returns undefined.
 *   - String / Array / JSON amplifier methods are bounded against
 *     opts.sizeCap (default 128 MiB).
 *   - RegExp constructor and String.prototype match / matchAll / search
 *     consult lib/js_safe_regex before delegating, rejecting unsafe
 *     patterns.
 *   - Error.prototype.stack returns "".
 *   - RegExp legacy statics ($1..$9 etc.) return undefined.
 *   - Symbol.for / Symbol.keyFor removed.
 *
 * The lockdown is positive (allow-list): anything not enumerated above
 * is deleted from globalThis by structural absence.
 *
 * @param {{
 *   caps?: { [name: string]: Function },
 *   sizeCap?: number,
 *   _skipGlobalFreeze?: boolean,
 * }} [opts]
 *
 * `_skipGlobalFreeze` (underscore-prefixed, not for production use): skip
 * the final `Object.freeze(globalThis)`. Provided so tests running under
 * bun's `node:vm` emulation can verify the rest of the lockdown — that
 * emulation does not implement realm-global freeze in a way consistent
 * with real browser realms (freezing the vm context global breaks
 * intrinsic resolution). Production callers MUST NOT pass this. Every
 * load-bearing barrier (`__cap__` non-writable / non-configurable, every
 * intrinsic property sealed) is installed via `defineProperty`
 * independent of the final freeze; freeze is the belt-and-braces "no
 * NEW globals" step on top.
 */
export function installLockdown(opts) {
  const o = opts || {};
  const caps = o.caps || {};
  const sizeCap = typeof o.sizeCap === "number" && o.sizeCap > 0
    ? Math.floor(o.sizeCap)
    : 134217728; // 128 MiB
  const skipGlobalFreeze = o._skipGlobalFreeze === true;

  const W = buildBoundedWrappers(sizeCap);
  const { safeMatch, safeMatchAll, safeSearch } = buildStringMatchWrappers();
  const SafeRegExp = buildRegExpWrapper();

  // --- Step 2: walk kept intrinsic prototypes. ---

  // Object constructor.
  for (let i = 0; i < REMOVED_ON_OBJECT_CTOR.length; i++) {
    tryDelete(O_Object, REMOVED_ON_OBJECT_CTOR[i]);
  }

  // Object.prototype.
  for (let i = 0; i < REMOVED_ON_OBJECT_PROTO.length; i++) {
    tryDelete(O_Object_prototype, REMOVED_ON_OBJECT_PROTO[i]);
  }
  // __proto__ accessor — has to go via defineProperty to remove the
  // getter/setter pair; the slot is configurable in V8.
  try {
    O_defineProperty(O_Object_prototype, "__proto__", {
      get: function () { return undefined; },
      set: function () {
        throw new O_TypeError("__proto__ assignment forbidden in pack realm");
      },
      configurable: false,
      enumerable: false,
    });
  } catch (_e) { /* fall through */ }
  neutralise(O_Object_prototype, "constructor");

  // Function.prototype: remove toString, neutralise .constructor,
  // replace bind with a non-constructable wrapper.
  for (let i = 0; i < REMOVED_ON_FUNCTION_PROTO.length; i++) {
    tryDelete(O_Function_prototype, REMOVED_ON_FUNCTION_PROTO[i]);
  }
  sealValue(O_Function_prototype, "bind", makeNonConstructableBind());
  neutralise(O_Function_prototype, "constructor");

  // Array constructor + prototype.
  // Replace Array.from / Array.of with bounded versions.
  sealValue(O_Array, "from", W.boundedArrayFrom);
  sealValue(O_Array, "of", W.boundedArrayOf);
  // Replace prototype amplifier methods.
  sealValue(O_Array_prototype, "join", W.boundedJoin);
  sealValue(O_Array_prototype, "flat", W.boundedFlat);
  sealValue(O_Array_prototype, "flatMap", W.boundedFlatMap);
  neutralise(O_Array_prototype, "constructor");

  // String constructor + prototype.
  sealValue(O_String, "fromCharCode", W.boundedFromCharCode);
  sealValue(O_String, "fromCodePoint", W.boundedFromCodePoint);
  sealValue(O_String_prototype, "repeat", W.boundedRepeat);
  sealValue(O_String_prototype, "padStart", W.boundedPadStart);
  sealValue(O_String_prototype, "padEnd", W.boundedPadEnd);
  sealValue(O_String_prototype, "match", safeMatch);
  sealValue(O_String_prototype, "matchAll", safeMatchAll);
  sealValue(O_String_prototype, "search", safeSearch);
  neutralise(O_String_prototype, "constructor");

  // RegExp: neutralise legacy statics, remove compile, neutralise
  // prototype.constructor.
  for (let i = 0; i < REGEXP_LEGACY_STATICS.length; i++) {
    const k = REGEXP_LEGACY_STATICS[i];
    // Some are accessor properties on the RegExp constructor itself.
    try {
      O_defineProperty(O_RegExp, k, {
        get: function () { return undefined; },
        set: undefined,
        configurable: false,
        enumerable: false,
      });
    } catch (_e) { tryDelete(O_RegExp, k); }
  }
  for (let i = 0; i < REMOVED_ON_REGEXP_PROTO.length; i++) {
    tryDelete(O_RegExp_prototype, REMOVED_ON_REGEXP_PROTO[i]);
  }
  neutralise(O_RegExp_prototype, "constructor");

  // Error subclasses: strip .stack on each prototype; neutralise
  // .constructor on each prototype.
  for (let i = 0; i < ERROR_SUBCLASSES.length; i++) {
    const name = ERROR_SUBCLASSES[i];
    const ctor = globalThis[name];
    if (typeof ctor === "function") {
      const proto = ctor.prototype;
      if (proto) {
        sealGetter(proto, "stack", "");
        neutralise(proto, "constructor");
      }
    }
  }
  // Error static fields (V8-specific).
  for (let i = 0; i < REMOVED_ON_ERROR_CTOR.length; i++) {
    tryDelete(Error, REMOVED_ON_ERROR_CTOR[i]);
  }
  // Also strip stack on the actual Error.prototype canonical reference.
  sealGetter(O_Error_prototype, "stack", "");

  // Symbol — remove cross-realm registry surface.
  if (typeof Symbol === "function") {
    for (let i = 0; i < REMOVED_ON_SYMBOL_CTOR.length; i++) {
      tryDelete(Symbol, REMOVED_ON_SYMBOL_CTOR[i]);
    }
  }

  // JSON wrappers.
  sealValue(JSON, "stringify", W.boundedJSONStringify);
  sealValue(JSON, "parse", W.boundedJSONParse);

  // Map / Set / WeakMap / WeakSet: neutralise prototype .constructor.
  for (const n of ["Map", "Set", "WeakMap", "WeakSet", "Promise", "Date",
                   "ArrayBuffer", "DataView"]) {
    const c = globalThis[n];
    if (c && c.prototype) neutralise(c.prototype, "constructor");
  }
  for (let i = 0; i < KEPT_TYPED_ARRAYS.length; i++) {
    const c = globalThis[KEPT_TYPED_ARRAYS[i]];
    if (c && c.prototype) neutralise(c.prototype, "constructor");
  }

  // Anonymous iterator prototypes — walk via instances of allowed
  // intrinsics, neutralise each .constructor we find.
  const iteratorSources = [];
  try { iteratorSources.push([]); } catch (_e) {}
  try { iteratorSources.push(""); } catch (_e) {}
  try { iteratorSources.push(new Map()); } catch (_e) {}
  try { iteratorSources.push(new Set()); } catch (_e) {}
  for (let i = 0; i < iteratorSources.length; i++) {
    const protos = reachableIteratorPrototypes(iteratorSources[i]);
    for (let j = 0; j < protos.length; j++) {
      neutralise(protos[j], "constructor");
    }
  }

  // --- Step 4: language-level dynamic-construction shadows. ---
  //
  // Function: replace globalThis.Function with the kept Function.prototype
  // accessor pattern is not needed because Function itself is removed.
  // The .constructor slots on the function prototypes were neutralised
  // above; here we delete the globals themselves and any reachable
  // shadow constructors.

  // The .constructor on AsyncFunction.prototype etc. is on a per-kind
  // prototype, not Function.prototype. Walk and neutralise.
  if (O_AsyncFunction && O_AsyncFunction.prototype) {
    neutralise(O_AsyncFunction.prototype, "constructor");
  }
  if (O_GeneratorFunction && O_GeneratorFunction.prototype) {
    neutralise(O_GeneratorFunction.prototype, "constructor");
  }
  if (O_AsyncGeneratorFunction && O_AsyncGeneratorFunction.prototype) {
    neutralise(O_AsyncGeneratorFunction.prototype, "constructor");
  }

  // --- Step 3: curate globalThis. ---
  //
  // Delete every own property of globalThis not on the allow-list. We
  // cannot replace globalThis with a fresh Object.create(null) — the
  // language gives no mechanism — so we prune in place. This is the
  // load-bearing point in the implementation that does not perfectly
  // match the spec's "fresh object via Object.create(null)"; see the
  // doc comment above.

  const allow = O_create.call(O_Object, null);
  for (let i = 0; i < GLOBAL_ALLOWLIST.length; i++) {
    allow[GLOBAL_ALLOWLIST[i]] = true;
  }
  // Replace the Array global with the bounded wrapper. SafeArray must
  // be on the allow-list, so we set it now (it's already named
  // "Array").
  // We also replace globalThis.RegExp with SafeRegExp.

  const ownNames = O_getOwnPropertyNames(globalThis);
  for (let i = 0; i < ownNames.length; i++) {
    const k = ownNames[i];
    if (!allow[k]) {
      tryDelete(globalThis, k);
    }
  }
  // Symbols on globalThis (Symbol.toStringTag etc. are typically not on
  // globalThis itself but on prototypes; skip — the symbol walk above
  // is enough for kept prototypes).

  // Now install the bounded Array constructor and the safe RegExp.
  // Both must replace the already-allow-listed globals.
  //
  // The bounded Array wrapper needs the same static surface as the
  // original (Array.from, Array.of, Array.isArray): we already replaced
  // Array.from / Array.of with bounded versions on the original
  // constructor; copy those forward (and Array.isArray) onto the
  // wrapper so pack code that calls `Array.from(...)` keeps working.
  // Array.prototype is shared (wrapper.prototype = original prototype).
  try {
    W.boundedArray.prototype = O_Array_prototype;
    sealValue(W.boundedArray, "from", O_Array.from);
    sealValue(W.boundedArray, "of", O_Array.of);
    if (typeof O_Array.isArray === "function") {
      sealValue(W.boundedArray, "isArray", O_Array.isArray);
    }
    O_defineProperty(globalThis, "Array", {
      value: W.boundedArray,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  } catch (_e) { /* if non-configurable, leave; prototype methods are
                     still bounded via sealValue above */ }
  try {
    O_defineProperty(globalThis, "RegExp", {
      value: SafeRegExp,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  } catch (_e) { /* leave */ }

  // --- Step 5: install caps. ---
  //
  // opts.caps is installed under globalThis.__cap__ as a frozen
  // namespace. Each cap function is sealed in place so pack code cannot
  // swap one out for another.

  const capNS = O_create.call(O_Object, null);
  const capNames = O_getOwnPropertyNames(caps);
  for (let i = 0; i < capNames.length; i++) {
    const name = capNames[i];
    const fn = caps[name];
    if (typeof fn !== "function") continue;
    // Wrap each cap in a non-constructable shell so pack code cannot
    // invoke `new __cap__.foo(...)` to trigger constructor semantics on
    // a host function. See docs/platform_isolation.md §3
    // "Non-constructable wrapper pattern".
    O_defineProperty(capNS, name, {
      value: makeCapShell(name, fn),
      writable: false,
      configurable: false,
      enumerable: true,
    });
  }
  O_freeze(capNS);
  O_defineProperty(globalThis, "__cap__", {
    value: capNS,
    writable: false,
    configurable: false,
    enumerable: false,
  });

  // --- Step 6: freeze everything kept. ---

  const toFreeze = [
    O_Object, O_Object_prototype,
    O_Array, O_Array_prototype,
    O_String, O_String_prototype,
    O_Function_prototype,
    O_RegExp, O_RegExp_prototype,
    JSON, Math,
    O_Error_prototype,
  ];
  for (let i = 0; i < ERROR_SUBCLASSES.length; i++) {
    const c = globalThis[ERROR_SUBCLASSES[i]];
    if (c) { toFreeze.push(c); if (c.prototype) toFreeze.push(c.prototype); }
  }
  for (const n of ["Map", "Set", "WeakMap", "WeakSet", "Promise", "Date",
                   "ArrayBuffer", "DataView", "Number", "Boolean", "BigInt",
                   "Symbol"]) {
    const c = globalThis[n];
    if (c) {
      toFreeze.push(c);
      if (c.prototype) toFreeze.push(c.prototype);
    }
  }
  for (let i = 0; i < KEPT_TYPED_ARRAYS.length; i++) {
    const c = globalThis[KEPT_TYPED_ARRAYS[i]];
    if (c) {
      toFreeze.push(c);
      if (c.prototype) toFreeze.push(c.prototype);
    }
  }
  for (let i = 0; i < toFreeze.length; i++) {
    try { O_freeze(toFreeze[i]); } catch (_e) { /* skip */ }
  }

  // Finally freeze globalThis itself. Pack code can still define local
  // variables; it cannot add or replace properties on the realm root.
  if (!skipGlobalFreeze) {
    try { O_freeze(globalThis); } catch (_e) { /* leave */ }
  }
}

// Re-export for tests / parity work.
export { validatePattern };
