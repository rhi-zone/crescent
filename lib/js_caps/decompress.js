// lib/js_caps/decompress.js
//
// Day-zero `decompress` cap implementation. Inverse of compress.
//
// Spec: docs/browser_caps.md §4.14 / §5. Wraps DecompressionStream.

const ALLOWED_FORMATS = new Set(["gzip", "deflate", "deflate-raw"]);

export const decompress = async (bytes, format) => {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError("decompress: first arg must be Uint8Array");
  }
  if (typeof format !== "string" || !ALLOWED_FORMATS.has(format)) {
    throw new TypeError(
      "decompress: format must be one of gzip, deflate, deflate-raw",
    );
  }
  const stream = new Response(bytes).body.pipeThrough(
    new DecompressionStream(format),
  );
  const buffer = await new Response(stream).arrayBuffer();
  return new Uint8Array(buffer);
};
