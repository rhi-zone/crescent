// lib/js_caps/compress.js
//
// Day-zero `compress` cap implementation. Uint8Array -> Promise<Uint8Array>
// via the host's CompressionStream.
//
// Spec: docs/browser_caps.md §4.14 / §5. Formats accepted are the three
// the Web Platform's CompressionStream supports: "gzip", "deflate" (zlib
// wrapper), "deflate-raw" (no header).
//
// The cap is async because CompressionStream is a streams-API primitive:
// we feed the input through a TransformStream and collect the chunks.
// The returned Promise<Uint8Array> is structured-clone-safe.

const ALLOWED_FORMATS = new Set(["gzip", "deflate", "deflate-raw"]);

export const compress = async (bytes, format) => {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError("compress: first arg must be Uint8Array");
  }
  if (typeof format !== "string" || !ALLOWED_FORMATS.has(format)) {
    throw new TypeError(
      "compress: format must be one of gzip, deflate, deflate-raw",
    );
  }
  const stream = new Response(bytes).body.pipeThrough(
    new CompressionStream(format),
  );
  const buffer = await new Response(stream).arrayBuffer();
  return new Uint8Array(buffer);
};
