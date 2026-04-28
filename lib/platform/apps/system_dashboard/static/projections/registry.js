// projections/registry.js
//
// The projection registry maps a "shape tag" (the result of `shapeOf(value)`)
// to a stack of projection functions. The active projection is the last one
// pushed via `register` or moved to the end via `select`. This lets future
// pack-shipped projections layer on top of built-ins without mutating them
// — a pack registers its own renderer for a given tag, and `select` makes it
// active. Unwinding (e.g. on pack unload) just splices it out.
//
// Ctx shape (consumed by projection functions; documented but not exported):
//   Ctx = {
//     project: (value) => Element | StreamConsumer,  // recurse via registry
//     action:  (alias_id, args?, onResult?) => clickHandler, // bound elsewhere
//   }

const reg = new Map(); // tag -> Projection[]

export function register(tag, fn) {
  if (typeof tag !== "string") throw new TypeError("register: tag must be string");
  if (typeof fn !== "function") throw new TypeError("register: fn must be function");
  let arr = reg.get(tag);
  if (!arr) { arr = []; reg.set(tag, arr); }
  arr.push(fn);
}

export function select(tag, fn) {
  // Move fn to the end of the array (active position) — caller must have
  // register()ed it first.
  const arr = reg.get(tag);
  if (!arr) throw new Error("select: no projections for tag " + tag);
  const idx = arr.indexOf(fn);
  if (idx === -1) throw new Error("select: fn not registered for tag " + tag);
  arr.splice(idx, 1);
  arr.push(fn);
}

export function has(tag) { return reg.has(tag); }

export function shapeOf(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  const t = typeof v;
  if (t !== "object") return t;
  return typeof v.type === "string" ? v.type : "object";
}

export function project(v, ctx) {
  const tag = shapeOf(v);
  const arr = reg.get(tag);
  const fn = arr && arr.length > 0 ? arr[arr.length - 1] : null;
  if (!fn) {
    // Lazy default — `_default.js` registers itself via `setDefault`. Keeping
    // a plain function reference here breaks the circular import:
    //   registry.js -> _default.js -> registry.js
    return _defaultProjection(v, ctx);
  }
  return fn(v, ctx);
}

let _defaultProjection = (v) => {
  throw new Error("registry: no _default projection registered");
};

export function setDefault(fn) {
  if (typeof fn !== "function") throw new TypeError("setDefault: fn must be function");
  _defaultProjection = fn;
}
