// dom.js
//
// Sealed createElement-direct DOM constructors with strict allowlists.
//
// CONTRACT: every projection (built-in or future pack-shipped) MUST construct
// DOM through this module. Direct `document.createElement` from projection
// code is forbidden. The allowlist is the security boundary — pack-shipped
// projections cannot smuggle a `<script>`, `javascript:` URL, `style="..."`
// expression, or unknown event handler past these constructors.
//
// Class-name namespacing is the projection author's responsibility, not a
// dom.js concern. Built-in projections ARE the host CSS so class tokens pass
// through verbatim. Pack-shipped projections will be lua2ts-enforced at
// compile time to prefix their classes — dom.js does not rewrite tokens.
//
// `data-*` attributes are universally allowed (parallel to `aria-*`) and pass
// through via setAttribute.
//
// Usage:
//   import { dom, text, unmount } from "./dom.js";
//   const el = dom.div({ class: "card", style: { padding: "8px" } }, [
//     dom.span({ class: "muted" }, ["hello ", dom.strong({}, ["world"])]),
//   ]);
//
// Constructor behavior (per tag):
//   1. createElement(tag) — SVG tags use createElementNS.
//   2. Apply props per allowlist; throw on unknown prop / unknown attr value
//      pattern / unknown style property / unknown style value pattern.
//   3. Append children. HTMLElement / SVGElement -> appendChild.
//      string / number -> text node with String(child).
//      null / undefined / false -> skip. Anything else -> throw.

const SVG_NS = "http://www.w3.org/2000/svg";

const HTML_TAGS = [
  "div", "span", "p", "h1", "h2", "h3", "h4", "h5", "h6",
  "pre", "code", "ul", "ol", "li", "dl", "dt", "dd",
  "table", "thead", "tbody", "tr", "th", "td", "caption",
  "details", "summary", "a", "kbd", "time",
  "button", "input", "label", "select", "option", "form", "fieldset", "legend",
  "nav", "section", "article", "header", "footer", "main", "aside",
  "figure", "figcaption", "img", "hr", "br", "strong", "em",
];

const SVG_TAGS = [
  "svg", "g", "path", "rect", "circle", "line",
  "polyline", "polygon", "text", "title", "defs", "clipPath", "use",
];

const SVG_TAG_SET = new Set(SVG_TAGS);

const ID_RE = /^[A-Za-z][A-Za-z0-9_-]*$/;
const HREF_RE = /^(https?:\/\/|\/static\/|#|mailto:)/;
const IMG_SRC_RE = /^(https?:\/\/|\/static\/)/;
const INPUT_TYPES = new Set([
  "text", "password", "number", "email", "checkbox", "radio",
  "hidden", "search", "url", "tel", "date", "time",
]);
const BUTTON_TYPES = new Set(["button", "submit", "reset"]);

// Style-value patterns we always reject (CSS injection vectors).
const STYLE_VALUE_REJECT = [
  /url\s*\(/i,
  /javascript\s*:/i,
  /expression\s*\(/i,
  /behavior\s*:/i,
  /-moz-binding/i,
  /data:/i,
];

// Allowed style properties (camelCase only — matches el.style.* API).
const STYLE_PROPS = new Set([
  // Layout
  "display", "flexDirection", "flexWrap", "flexGrow", "flexShrink", "flexBasis", "flex",
  "justifyContent", "alignItems", "alignContent", "alignSelf",
  "gap", "rowGap", "columnGap",
  "gridTemplateColumns", "gridTemplateRows", "gridColumn", "gridRow", "gridGap",
  "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight",
  "padding", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
  "margin", "marginTop", "marginRight", "marginBottom", "marginLeft",
  "position", "top", "right", "bottom", "left",
  "overflow", "overflowX", "overflowY", "boxSizing", "zIndex",
  // Type
  "fontSize", "fontWeight", "fontFamily", "fontStyle",
  "textAlign", "textDecoration", "textTransform",
  "lineHeight", "letterSpacing",
  "whiteSpace", "wordBreak", "wordWrap", "overflowWrap", "tabSize",
  // Color
  "color", "backgroundColor", "borderColor", "fill", "stroke", "caretColor",
  // Border
  "border", "borderTop", "borderRight", "borderBottom", "borderLeft",
  "borderWidth", "borderStyle", "borderRadius",
  "outline", "outlineColor", "outlineWidth", "outlineStyle",
  // Misc
  "opacity", "cursor", "boxShadow", "transition", "transform",
  "pointerEvents", "userSelect", "visibility", "resize",
]);

// Per-tag attribute allowlists. Values are the set of allowed prop names beyond
// the universal ones. A value of `null` means the prop has tag-specific
// validation in `applyTagSpecific`.
const TAG_PROPS = {
  a:        new Set(["href", "target"]),
  img:      new Set(["src", "alt", "width", "height"]),
  input:    new Set(["type", "name", "placeholder", "value", "checked",
                     "disabled", "min", "max", "step", "pattern",
                     "required", "readonly", "autocomplete"]),
  button:   new Set(["type", "disabled", "name", "value"]),
  select:   new Set(["name", "disabled", "required", "multiple"]),
  option:   new Set(["value", "selected", "disabled"]),
  form:     new Set(["name"]),
  details:  new Set(["open"]),
  time:     new Set(["datetime"]),
  label:    new Set(["for"]),
  // SVG
  svg:      new Set(["viewBox", "width", "height", "xmlns"]),
  path:     new Set(["d", "fill", "stroke", "stroke-width", "stroke-dasharray",
                     "stroke-linecap", "stroke-linejoin", "transform"]),
  rect:     new Set(["x", "y", "width", "height", "rx", "ry",
                     "fill", "stroke", "stroke-width"]),
  circle:   new Set(["cx", "cy", "r", "fill", "stroke", "stroke-width"]),
  line:     new Set(["x1", "y1", "x2", "y2", "stroke", "stroke-width"]),
  polyline: new Set(["points", "fill", "stroke", "stroke-width"]),
  polygon:  new Set(["points", "fill", "stroke", "stroke-width"]),
  text:     new Set(["x", "y", "dx", "dy", "text-anchor", "dominant-baseline",
                     "font-size", "font-family", "font-weight",
                     "fill", "stroke", "transform"]),
  g:        new Set(["transform", "fill", "stroke", "opacity"]),
  clipPath: new Set(["id"]),
  use:      new Set(["href"]),
};

// Forms reject `action` and `method` outright — all submission is JS.
const FORM_REJECT = new Set(["action", "method"]);

// Universal props applicable to any tag.
const UNIVERSAL_PROPS = new Set([
  "class", "id", "title", "role", "tabindex",
  "style", "onClick", "onSubmit", "onInput", "onChange",
]);

// Tags where each event prop is permitted.
const EVENT_TAG_REQUIREMENTS = {
  onSubmit: new Set(["form"]),
  onInput:  new Set(["input", "textarea", "select"]),
  onChange: new Set(["input", "select", "textarea"]),
};

function isAllowedProp(tag, name) {
  if (UNIVERSAL_PROPS.has(name)) return true;
  if (name.startsWith("aria-")) return true;
  if (name.startsWith("data-")) return true;
  const tagSet = TAG_PROPS[tag];
  if (tagSet && tagSet.has(name)) return true;
  return false;
}

function setStyle(el, styleObj, tag) {
  if (typeof styleObj === "string") {
    throw new Error(`dom.${tag}: style must be an object, not a string`);
  }
  if (styleObj === null || typeof styleObj !== "object") {
    throw new Error(`dom.${tag}: style must be a plain object`);
  }
  for (const prop of Object.keys(styleObj)) {
    if (!STYLE_PROPS.has(prop)) {
      throw new Error(`dom.${tag}: style property '${prop}' not allowed`);
    }
    const value = styleObj[prop];
    if (value == null) continue;
    if (typeof value === "string") {
      for (const re of STYLE_VALUE_REJECT) {
        if (re.test(value)) {
          throw new Error(`dom.${tag}: style value for '${prop}' rejected by safety pattern`);
        }
      }
    }
    el.style[prop] = value;
  }
}

function setBoolAttr(el, name, value) {
  if (value) el.setAttribute(name, "");
  else el.removeAttribute(name);
}

function applyUniversal(el, tag, name, value) {
  if (name === "class") {
    if (typeof value !== "string") {
      throw new Error(`dom.${tag}: class must be a string`);
    }
    const tokens = value.split(/\s+/).filter(Boolean);
    el.className = tokens.join(" ");
    return true;
  }
  if (name === "id") {
    if (typeof value !== "string" || !ID_RE.test(value)) {
      throw new Error(`dom.${tag}: id must match ${ID_RE} (got ${JSON.stringify(value)})`);
    }
    el.setAttribute("id", value);
    return true;
  }
  if (name === "title") {
    if (typeof value !== "string") throw new Error(`dom.${tag}: title must be a string`);
    el.setAttribute("title", value);
    return true;
  }
  if (name === "role") {
    if (typeof value !== "string") throw new Error(`dom.${tag}: role must be a string`);
    el.setAttribute("role", value);
    return true;
  }
  if (name === "tabindex") {
    if (typeof value !== "number") throw new Error(`dom.${tag}: tabindex must be a number`);
    el.setAttribute("tabindex", String(value));
    return true;
  }
  if (name.startsWith("aria-")) {
    if (typeof value !== "string") throw new Error(`dom.${tag}: ${name} must be a string`);
    el.setAttribute(name, value);
    return true;
  }
  if (name.startsWith("data-")) {
    if (typeof value !== "string") throw new Error(`dom.${tag}: ${name} must be a string`);
    el.setAttribute(name, value);
    return true;
  }
  if (name === "style") {
    setStyle(el, value, tag);
    return true;
  }
  if (name === "onClick") {
    if (typeof value !== "function") throw new Error(`dom.${tag}: onClick must be a function`);
    el.addEventListener("click", value);
    return true;
  }
  if (name === "onSubmit" || name === "onInput" || name === "onChange") {
    if (typeof value !== "function") throw new Error(`dom.${tag}: ${name} must be a function`);
    const allowedTags = EVENT_TAG_REQUIREMENTS[name];
    if (!allowedTags.has(tag)) {
      throw new Error(`dom.${tag}: ${name} not allowed on this tag`);
    }
    const evtName = name.slice(2).toLowerCase();
    el.addEventListener(evtName, value);
    return true;
  }
  return false;
}

function applyTagSpecific(el, tag, name, value) {
  // Form rejection list.
  if (tag === "form" && FORM_REJECT.has(name)) {
    throw new Error(`dom.form: '${name}' is rejected — forms must not navigate`);
  }
  // a: href, target.
  if (tag === "a") {
    if (name === "href") {
      if (typeof value !== "string" || !HREF_RE.test(value)) {
        throw new Error(`dom.a: href must match ${HREF_RE}`);
      }
      el.setAttribute("href", value);
      return;
    }
    if (name === "target") {
      if (value !== "_blank") {
        throw new Error(`dom.a: target only supports '_blank'`);
      }
      el.setAttribute("target", "_blank");
      el.setAttribute("rel", "noopener noreferrer");
      return;
    }
  }
  // img: src/alt/width/height.
  if (tag === "img") {
    if (name === "src") {
      if (typeof value !== "string" || !IMG_SRC_RE.test(value)) {
        throw new Error(`dom.img: src must match ${IMG_SRC_RE}`);
      }
      el.setAttribute("src", value);
      return;
    }
    if (name === "alt") {
      el.setAttribute("alt", String(value));
      return;
    }
    if (name === "width" || name === "height") {
      el.setAttribute(name, String(value));
      return;
    }
  }
  // input.
  if (tag === "input") {
    if (name === "type") {
      if (typeof value !== "string" || !INPUT_TYPES.has(value)) {
        throw new Error(`dom.input: type must be one of ${[...INPUT_TYPES].join("|")}`);
      }
      el.setAttribute("type", value);
      return;
    }
    if (name === "checked" || name === "disabled" || name === "required" || name === "readonly") {
      setBoolAttr(el, name, !!value);
      return;
    }
    el.setAttribute(name, String(value));
    return;
  }
  // button.
  if (tag === "button") {
    if (name === "type") {
      if (typeof value !== "string" || !BUTTON_TYPES.has(value)) {
        throw new Error(`dom.button: type must be one of ${[...BUTTON_TYPES].join("|")}`);
      }
      el.setAttribute("type", value);
      return;
    }
    if (name === "disabled") {
      setBoolAttr(el, "disabled", !!value);
      return;
    }
    el.setAttribute(name, String(value));
    return;
  }
  // select.
  if (tag === "select") {
    if (name === "disabled" || name === "required" || name === "multiple") {
      setBoolAttr(el, name, !!value);
      return;
    }
    el.setAttribute(name, String(value));
    return;
  }
  // option.
  if (tag === "option") {
    if (name === "selected" || name === "disabled") {
      setBoolAttr(el, name, !!value);
      return;
    }
    el.setAttribute(name, String(value));
    return;
  }
  // details.
  if (tag === "details" && name === "open") {
    setBoolAttr(el, "open", !!value);
    return;
  }
  // label: for must match id pattern.
  if (tag === "label" && name === "for") {
    if (typeof value !== "string" || !ID_RE.test(value)) {
      throw new Error(`dom.label: for must match ${ID_RE}`);
    }
    el.setAttribute("for", value);
    return;
  }
  // SVG `use` href: must start with #.
  if (tag === "use" && name === "href") {
    if (typeof value !== "string" || value[0] !== "#") {
      throw new Error("dom.use: href must start with '#'");
    }
    el.setAttribute("href", value);
    return;
  }
  // Generic SVG/HTML attribute fallthrough — set via setAttribute.
  el.setAttribute(name, String(value));
}

// Default button type is "button" — never a default submit.
function applyDefaults(el, tag, props) {
  if (tag === "button" && (!props || props.type === undefined)) {
    el.setAttribute("type", "button");
  }
}

function appendChildren(el, children, tag) {
  if (children == null) return;
  if (!Array.isArray(children)) {
    throw new Error(`dom.${tag}: children must be an array`);
  }
  for (const child of children) {
    if (child == null || child === false) continue;
    if (typeof child === "string" || typeof child === "number") {
      el.appendChild(document.createTextNode(String(child)));
      continue;
    }
    if (child instanceof Element) {
      el.appendChild(child);
      continue;
    }
    throw new Error(`dom.${tag}: invalid child of type ${typeof child}`);
  }
}

function makeConstructor(tag) {
  const isSvg = SVG_TAG_SET.has(tag);
  return function (props, children) {
    const el = isSvg
      ? document.createElementNS(SVG_NS, tag)
      : document.createElement(tag);
    if (props != null) {
      if (typeof props !== "object") {
        throw new Error(`dom.${tag}: props must be an object`);
      }
      for (const name of Object.keys(props)) {
        if (!isAllowedProp(tag, name)) {
          throw new Error(`dom.${tag}: prop '${name}' not allowed`);
        }
        const value = props[name];
        if (applyUniversal(el, tag, name, value)) continue;
        applyTagSpecific(el, tag, name, value);
      }
    }
    applyDefaults(el, tag, props);
    appendChildren(el, children, tag);
    return el;
  };
}

const _dom = {};
for (const tag of HTML_TAGS) _dom[tag] = makeConstructor(tag);
for (const tag of SVG_TAGS)  _dom[tag] = makeConstructor(tag);

export const dom = Object.freeze(_dom);

export function text(s) {
  return document.createTextNode(String(s));
}

export function unmount(el) {
  el.replaceChildren();
}
