// lib/js_safe_regex/safe_regex.js
//
// Validator for JS regex patterns against catastrophic backtracking.
// Companion to lib/safe_regex/init.lua (Lua); same algorithm.
//
// Used by the browser realm bootstrap's RegExp / String.prototype.match /
// matchAll / search wrappers to refuse to compile pathological patterns.
//
// Invariant enforced (the "hologram-shaped" rule):
//   No quantifier may be applied to an expression that itself contains
//   an UNBOUNDED quantifier.
//
// Quantifier classification:
//   *        unbounded
//   +        unbounded
//   {n,}     unbounded
//   {n,m}    unbounded when m > n
//   ?        bounded
//   {n}      bounded
//   {n,n}    bounded
//
// Anchors (^, $, \b, \B) are zero-width and cannot be quantified.
//
// API:
//   validatePattern(pattern)
//     -> { ok: true }                       when safe
//     -> { ok: false, error: <string> }     when unsafe or malformed
//
// Pure function; no I/O, no module-level mutable state.
//
// Known limitation (v1): alternation overlap is NOT detected (e.g.
// `(a|aa)+` is accepted). See lib/safe_regex/init.lua for the planned
// Thompson-NFA pass.

// AST nodes are created with a `{ __proto__: null }` literal so they
// have no prototype — defense-in-depth that matches harden-mode
// bootstrap style. The literal form is parse-time syntax; it does NOT
// go through `Object.prototype.__proto__` accessor or any `Object.*`
// method, so it survives sandbox lockdown (which removes
// `Object.create` and strips the `__proto__` accessor).

/**
 * @typedef {{ has_unbounded: boolean, is_anchor: boolean }} Node
 * @typedef {{ pattern: string, pos: number, len: number }} Parser
 */

/** @param {boolean} has_unbounded @param {boolean} is_anchor @returns {Node} */
function node(has_unbounded, is_anchor) {
  return { __proto__: null, has_unbounded: has_unbounded, is_anchor: is_anchor };
}

// Byte values
const B_LPAREN = "(".charCodeAt(0);
const B_RPAREN = ")".charCodeAt(0);
const B_LBRACKET = "[".charCodeAt(0);
const B_RBRACKET = "]".charCodeAt(0);
const B_LBRACE = "{".charCodeAt(0);
const B_RBRACE = "}".charCodeAt(0);
const B_BACKSLASH = "\\".charCodeAt(0);
const B_PIPE = "|".charCodeAt(0);
const B_STAR = "*".charCodeAt(0);
const B_PLUS = "+".charCodeAt(0);
const B_QUESTION = "?".charCodeAt(0);
const B_DOT = ".".charCodeAt(0);
const B_CARET = "^".charCodeAt(0);
const B_DOLLAR = "$".charCodeAt(0);
const B_COLON = ":".charCodeAt(0);
const B_EQUALS = "=".charCodeAt(0);
const B_BANG = "!".charCodeAt(0);
const B_LT = "<".charCodeAt(0);
const B_GT = ">".charCodeAt(0);
const B_COMMA = ",".charCodeAt(0);
const B_0 = "0".charCodeAt(0);
const B_9 = "9".charCodeAt(0);
const B_LOWER_B = "b".charCodeAt(0);
const B_UPPER_B = "B".charCodeAt(0);
const B_K = "k".charCodeAt(0);
const B_LOWER_A = "a".charCodeAt(0);
const B_LOWER_F = "f".charCodeAt(0);
const B_LOWER_U = "u".charCodeAt(0);
const B_LOWER_X = "x".charCodeAt(0);
const B_UPPER_A = "A".charCodeAt(0);
const B_UPPER_F = "F".charCodeAt(0);

/** @param {number} c @returns {boolean} */
function isHex(c) {
  if (c !== c) return false; // NaN
  if (c >= B_0 && c <= B_9) return true;
  if (c >= B_LOWER_A && c <= B_LOWER_F) return true;
  if (c >= B_UPPER_A && c <= B_UPPER_F) return true;
  return false;
}

/** @param {string} s @param {number} i 0-based @returns {boolean} */
function isDigit(s, i) {
  if (i < 0 || i >= s.length) return false;
  const b = s.charCodeAt(i);
  return b >= B_0 && b <= B_9;
}

/**
 * Decide whether `{` at position `start` opens a valid quantifier.
 * Returns { end_pos, n, m } on success (m === -1 for {n,}), or null.
 * Positions are 0-based; end_pos is the index of `}`.
 * @param {string} pattern @param {number} start
 * @returns {{ end_pos: number, n: number, m: number } | null}
 */
function scanQuantBrace(pattern, start) {
  const len = pattern.length;
  let i = start + 1; // skip '{'
  if (!isDigit(pattern, i)) return null;
  const n_start = i;
  while (isDigit(pattern, i)) i += 1;
  const n_raw = Number(pattern.slice(n_start, i));
  if (!Number.isFinite(n_raw)) return null;
  const n = Math.floor(n_raw);
  if (i >= len) return null;
  let b = pattern.charCodeAt(i);
  if (b === B_RBRACE) return { end_pos: i, n: n, m: n };
  if (b !== B_COMMA) return null;
  i += 1;
  if (i >= len) return null;
  b = pattern.charCodeAt(i);
  if (b === B_RBRACE) return { end_pos: i, n: n, m: -1 };
  if (!isDigit(pattern, i)) return null;
  const m_start = i;
  while (isDigit(pattern, i)) i += 1;
  if (i >= len) return null;
  const m_raw = Number(pattern.slice(m_start, i));
  if (!Number.isFinite(m_raw)) return null;
  const m = Math.floor(m_raw);
  if (pattern.charCodeAt(i) !== B_RBRACE) return null;
  return { end_pos: i, n: n, m: m };
}

// Parse functions return either a Node or { error: string }. We use a
// tagged shape rather than tuple returns. A `null` return means "no atom
// here" (end of input or sequence delimiter) without an error.

/**
 * @param {Parser} state
 * @returns {Node | null | { error: string }}
 */
function parseEscape(state) {
  const pattern = state.pattern;
  const len = state.len;
  let pos = state.pos;
  if (pos >= len) return { error: "trailing backslash with nothing after it" };
  const b = pattern.charCodeAt(pos);

  // \b and \B are word-boundary anchors (zero-width)
  if (b === B_LOWER_B || b === B_UPPER_B) {
    state.pos = pos + 1;
    return node(false, true);
  }

  // numeric backref \1..\9
  if (b >= B_0 && b <= B_9) {
    while (pos < len && isDigit(pattern, pos)) pos += 1;
    state.pos = pos;
    return node(false, false);
  }

  // named backref \k<name>
  if (b === B_K && pattern.charCodeAt(pos + 1) === B_LT) {
    let i = pos + 2;
    while (i < len && pattern.charCodeAt(i) !== B_GT) i += 1;
    if (i >= len) return { error: "unterminated named backreference \\k<...>" };
    state.pos = i + 1;
    return node(false, false);
  }

  // \xHH
  if (b === B_LOWER_X) {
    state.pos = pos + 1;
    for (let k = 0; k < 2; k++) {
      if (state.pos >= len) break;
      if (!isHex(pattern.charCodeAt(state.pos))) break;
      state.pos += 1;
    }
    return node(false, false);
  }

  // \uHHHH or \u{HHHH..}
  if (b === B_LOWER_U) {
    state.pos = pos + 1;
    if (state.pos < len && pattern.charCodeAt(state.pos) === B_LBRACE) {
      state.pos += 1;
      while (state.pos < len && pattern.charCodeAt(state.pos) !== B_RBRACE) {
        state.pos += 1;
      }
      if (state.pos >= len) return { error: "unterminated \\u{...} escape" };
      state.pos += 1; // consume '}'
    } else {
      for (let k = 0; k < 4; k++) {
        if (state.pos >= len) break;
        if (!isHex(pattern.charCodeAt(state.pos))) break;
        state.pos += 1;
      }
    }
    return node(false, false);
  }

  // generic single-char escape
  state.pos = pos + 1;
  return node(false, false);
}

/** @param {Parser} state @returns {Node | { error: string }} */
function parseCharacterClass(state) {
  const pattern = state.pattern;
  const len = state.len;
  state.pos += 1; // consume '['
  if (state.pos < len && pattern.charCodeAt(state.pos) === B_CARET) {
    state.pos += 1;
  }
  // ']' as first char is a literal
  if (state.pos < len && pattern.charCodeAt(state.pos) === B_RBRACKET) {
    state.pos += 1;
  }
  while (state.pos < len) {
    const b = pattern.charCodeAt(state.pos);
    if (b === B_RBRACKET) {
      state.pos += 1;
      return node(false, false);
    }
    if (b === B_BACKSLASH) {
      state.pos += 1;
      if (state.pos >= len) return { error: "trailing backslash inside character class" };
      state.pos += 1;
    } else {
      state.pos += 1;
    }
  }
  return { error: "unterminated character class -- missing ']'" };
}

/** @param {Parser} state @returns {Node | { error: string }} */
function parseGroup(state) {
  const pattern = state.pattern;
  const len = state.len;
  state.pos += 1; // consume '('
  if (state.pos >= len) return { error: "unterminated group -- missing ')'" };
  if (pattern.charCodeAt(state.pos) === B_QUESTION) {
    state.pos += 1;
    if (state.pos >= len) return { error: "unterminated group -- missing ')'" };
    const b = pattern.charCodeAt(state.pos);
    if (b === B_COLON || b === B_EQUALS || b === B_BANG) {
      state.pos += 1;
    } else if (b === B_LT) {
      state.pos += 1;
      if (state.pos >= len) return { error: "unterminated group -- missing ')'" };
      const b2 = pattern.charCodeAt(state.pos);
      if (b2 === B_EQUALS || b2 === B_BANG) {
        state.pos += 1;
      } else {
        while (state.pos < len && pattern.charCodeAt(state.pos) !== B_GT) {
          state.pos += 1;
        }
        if (state.pos >= len) return { error: "unterminated named group -- missing '>'" };
        state.pos += 1; // consume '>'
      }
    } else {
      return { error: "unknown group type '(?" + String.fromCharCode(b) + "...)'" };
    }
  }
  const inner = parseAlternation(state);
  if (inner && typeof inner === "object" && "error" in inner) return inner;
  if (state.pos >= len || pattern.charCodeAt(state.pos) !== B_RPAREN) {
    return { error: "unterminated group -- missing ')'" };
  }
  state.pos += 1; // consume ')'
  return node(/** @type {Node} */(inner).has_unbounded, false);
}

/**
 * Parse one atom. Returns null to signal "no atom here"
 * (end of input or sequence delimiter), { error } for malformed,
 * Node for success.
 * @param {Parser} state
 * @returns {Node | null | { error: string }}
 */
function parseAtom(state) {
  if (state.pos >= state.len) return null;
  const pattern = state.pattern;
  const b = pattern.charCodeAt(state.pos);

  if (b === B_PIPE || b === B_RPAREN) return null;

  if (b === B_BACKSLASH) {
    state.pos += 1;
    return parseEscape(state);
  }
  if (b === B_LBRACKET) return parseCharacterClass(state);
  if (b === B_LPAREN) return parseGroup(state);
  if (b === B_DOT) {
    state.pos += 1;
    return node(false, false);
  }
  if (b === B_CARET || b === B_DOLLAR) {
    state.pos += 1;
    return node(false, true);
  }

  if (b === B_STAR || b === B_PLUS || b === B_QUESTION) {
    return { error: "quantifier '" + String.fromCharCode(b) + "' without preceding element" };
  }
  if (b === B_LBRACE) {
    const q = scanQuantBrace(pattern, state.pos);
    if (q) return { error: "quantifier '{...}' without preceding element" };
    state.pos += 1;
    return node(false, false);
  }
  if (b === B_RBRACE) {
    state.pos += 1;
    return node(false, false);
  }
  if (b === B_RBRACKET) {
    state.pos += 1;
    return node(false, false);
  }

  // ordinary literal char
  state.pos += 1;
  return node(false, false);
}

/** @param {Parser} state @returns {Node | null | { error: string }} */
function parseQuantified(state) {
  const atom = parseAtom(state);
  if (atom === null) return null;
  if (atom && typeof atom === "object" && "error" in atom) return atom;
  /** @type {Node} */
  const a = /** @type {Node} */(atom);
  if (state.pos >= state.len) return a;
  const pattern = state.pattern;
  const b = pattern.charCodeAt(state.pos);

  let quant_str = "";
  let is_unbounded = false;
  /** @type {number | null} */
  let end_pos = null;

  if (b === B_STAR) {
    quant_str = "*"; is_unbounded = true;
  } else if (b === B_PLUS) {
    quant_str = "+"; is_unbounded = true;
  } else if (b === B_QUESTION) {
    quant_str = "?"; is_unbounded = false;
  } else if (b === B_LBRACE) {
    const q = scanQuantBrace(pattern, state.pos);
    if (!q) return a;
    end_pos = q.end_pos;
    quant_str = pattern.slice(state.pos, end_pos + 1);
    if (q.m === -1) {
      is_unbounded = true;
    } else {
      is_unbounded = q.m > q.n;
    }
  } else {
    return a;
  }

  if (a.is_anchor) {
    return { error: "quantifier '" + quant_str + "' applied to a zero-width anchor (^ $ \\b \\B)" };
  }

  if (a.has_unbounded) {
    return { error: "nested quantifier '" + quant_str +
      "' on a subexpression that already contains an unbounded " +
      "quantifier -- this can cause catastrophic backtracking" };
  }

  if (end_pos !== null) {
    state.pos = end_pos + 1;
  } else {
    state.pos += 1;
  }
  // optional lazy / possessive modifier
  if (state.pos < state.len) {
    const nb = pattern.charCodeAt(state.pos);
    if (nb === B_QUESTION || nb === B_PLUS) state.pos += 1;
  }
  return node(is_unbounded, false);
}

/** @param {Parser} state @returns {Node | { error: string }} */
function parseSequence(state) {
  let has_unbounded = false;
  while (state.pos < state.len) {
    const b = state.pattern.charCodeAt(state.pos);
    if (b === B_PIPE || b === B_RPAREN) break;
    const n = parseQuantified(state);
    if (n === null) break;
    if (n && typeof n === "object" && "error" in n) return n;
    if (/** @type {Node} */(n).has_unbounded) has_unbounded = true;
  }
  return node(has_unbounded, false);
}

/** @param {Parser} state @returns {Node | { error: string }} */
function parseAlternation(state) {
  let left = parseSequence(state);
  if (left && typeof left === "object" && "error" in left) return left;
  while (state.pos < state.len && state.pattern.charCodeAt(state.pos) === B_PIPE) {
    state.pos += 1;
    const right = parseSequence(state);
    if (right && typeof right === "object" && "error" in right) return right;
    if (/** @type {Node} */(right).has_unbounded) {
      left = node(true, false);
    }
  }
  return /** @type {Node} */(left);
}

/**
 * Validate a JS regex pattern for catastrophic-backtracking shape.
 * @param {string} pattern
 * @returns {{ ok: true } | { ok: false, error: string }}
 */
export function validatePattern(pattern) {
  if (typeof pattern !== "string") {
    return { ok: false, error: "pattern must be a string" };
  }
  /** @type {Parser} */
  const state = { pattern: pattern, pos: 0, len: pattern.length };
  const root = parseAlternation(state);
  if (root && typeof root === "object" && "error" in root) {
    return { ok: false, error: "malformed pattern: " + root.error };
  }
  if (state.pos < state.len) {
    const b = pattern.charCodeAt(state.pos);
    if (b === B_RPAREN) {
      return { ok: false, error: "malformed pattern: unexpected ')' without matching '('" };
    }
    return { ok: false, error: "malformed pattern: unexpected character '" +
      String.fromCharCode(b) + "' at position " + (state.pos + 1) };
  }
  return { ok: true };
}
