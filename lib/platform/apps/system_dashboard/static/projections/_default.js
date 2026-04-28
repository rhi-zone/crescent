// projections/_default.js
//
// Fallback projection used when `shapeOf(value)` matches no registered
// projection. Renders the value as a JSON dump inside a <pre> and emits a
// console.warn so unknown shapes are visible during development.
//
// Self-registers via `setDefault` on import — `projections/index.js` brings
// this in for its side effect.

import { dom } from "../dom.js";
import { setDefault } from "./registry.js";

function projectDefault(value, _ctx) {
  console.warn("system_dashboard: no projection for shape", value);
  return dom.pre({ class: "default-fallback" }, [JSON.stringify(value, null, 2)]);
}

setDefault(projectDefault);
