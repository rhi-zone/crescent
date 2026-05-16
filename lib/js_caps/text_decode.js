// lib/js_caps/text_decode.js
//
// Day-zero `text_decode` cap implementation. Uint8Array -> string.
//
// Spec: docs/browser_caps.md §4.8 / §5. Wraps TextDecoder. Defaults to
// UTF-8 but accepts an `opts` object selecting encoding/fatal/ignoreBOM.
//
// Validation: input must be a Uint8Array (the binary path the bridge
// permits). `opts` is treated as opaque structured-clone data: the
// fields are read only after coarse typeof checks so foreign-thenable
// hazards are avoided (no property access that could trigger
// Symbol.toPrimitive on values the realm might have crafted).

export const text_decode = (bytes, opts) => {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError("text_decode: arg must be Uint8Array");
  }
  let encoding = "utf-8";
  let fatal = false;
  let ignoreBOM = false;
  if (opts !== undefined && opts !== null) {
    if (typeof opts !== "object") {
      throw new TypeError("text_decode: opts must be an object");
    }
    if (opts.encoding !== undefined) {
      if (typeof opts.encoding !== "string") {
        throw new TypeError("text_decode: opts.encoding must be string");
      }
      encoding = opts.encoding;
    }
    fatal = !!opts.fatal;
    ignoreBOM = !!opts.ignoreBOM;
  }
  const decoder = new TextDecoder(encoding, { fatal, ignoreBOM });
  return decoder.decode(bytes);
};
