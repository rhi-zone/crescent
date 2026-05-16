// lib/js_caps/kv.js
//
// Day-zero `kv_read` / `kv_write` / `kv_delete` / `kv_keys` cap impls.
// Per-pack persistent key-value store backed by IndexedDB in the host
// realm. Each pack gets its own IndexedDB database named `pack_<id>`
// with a single object store `kv` (string keys, structured-clone
// values).
//
// Spec: docs/browser_caps.md §4.2.1 / §5.
//
// Backend choice -- IndexedDB over localStorage:
//   - Quota: GB-scale vs the 5-10 MB localStorage cap.
//   - Async: no main-thread blocking on writes.
//   - Stores structured-clone values directly: Uint8Array / Map / Set /
//     Date round-trip with no JSON.stringify hop.
//
// Per-pack partitioning is the database name. Two packs with distinct
// `pack_id`s are storage-isolated by IndexedDB's per-database scoping
// (plus the surrounding origin scoping that the host realm already
// provides). The host realm holds every pack's DB; each factory
// instance only ever touches the DB whose name it was constructed
// with.
//
// Factory-shaped, like fetch_api: `makeKvCaps({ pack_id })` returns a
// record of the four caps bound to that pack's database. The host page
// constructs the record per pack manifest and merges into the cap-
// impls Map (kv_* are NOT in dayZeroCaps -- they are config-bound).

const DB_VERSION = 1;
const STORE_NAME = "kv";
const MAX_KEY_LENGTH = 1024;

/**
 * Convert an IDBRequest to a Promise. Resolves with `request.result`,
 * rejects with `request.error`.
 *
 * @template T
 * @param {IDBRequest<T>} request
 * @returns {Promise<T>}
 */
function requestToPromise(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

/**
 * Open (or upgrade) the per-pack IndexedDB database. Creates the `kv`
 * object store on first open. The returned database is reused across
 * cap invocations for the lifetime of the factory instance.
 *
 * @param {string} dbName
 * @returns {Promise<IDBDatabase>}
 */
function openDatabase(dbName) {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(dbName, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error(
      "makeKvCaps: indexedDB.open blocked for " + dbName,
    ));
  });
}

/**
 * Validate a key argument. Keys are non-empty strings up to
 * MAX_KEY_LENGTH chars.
 *
 * @param {unknown} key
 * @param {string} where
 * @returns {string}
 */
function validateKey(key, where) {
  if (typeof key !== "string") {
    throw new TypeError(where + ": key must be a string");
  }
  if (key.length === 0) {
    throw new TypeError(where + ": key must be non-empty");
  }
  if (key.length > MAX_KEY_LENGTH) {
    throw new TypeError(where + ": key too long (max " +
      MAX_KEY_LENGTH + " chars, got " + key.length + ")");
  }
  return key;
}

/**
 * Construct the four kv_* cap impls bound to a specific pack's
 * IndexedDB database.
 *
 * @param {{ pack_id: string }} config
 * @returns {{
 *   kv_read:   (key: string) => Promise<unknown>,
 *   kv_write:  (args: { key: string, value: unknown }) => Promise<void>,
 *   kv_delete: (key: string) => Promise<void>,
 *   kv_keys:   () => Promise<string[]>,
 * }}
 */
export function makeKvCaps(config) {
  if (config === null || typeof config !== "object") {
    throw new TypeError("makeKvCaps: config must be an object with pack_id");
  }
  const rawPackId = /** @type {Record<string, unknown>} */ (config).pack_id;
  if (typeof rawPackId !== "string") {
    throw new TypeError("makeKvCaps: config.pack_id must be a string");
  }
  if (rawPackId.length === 0) {
    throw new TypeError("makeKvCaps: config.pack_id must be non-empty");
  }
  const dbName = "pack_" + rawPackId;

  // Lazy DB handle: open on first use, then reuse. A failed open is
  // not cached -- the next call retries.
  /** @type {Promise<IDBDatabase> | null} */
  let dbPromise = null;
  function getDb() {
    if (dbPromise === null) {
      if (typeof indexedDB === "undefined") {
        return Promise.reject(new Error(
          "makeKvCaps: indexedDB is not available in this realm",
        ));
      }
      dbPromise = openDatabase(dbName).catch((err) => {
        dbPromise = null;
        throw err;
      });
    }
    return dbPromise;
  }

  // Each cap is a concise method (drops [[Construct]]; `new kv_read()`
  // throws). The object literal pattern matches fetch_api.js.
  return {
    async kv_read(/** @type {unknown} */ key) {
      const k = validateKey(key, "kv_read");
      const db = await getDb();
      const tx = db.transaction(STORE_NAME, "readonly");
      const store = tx.objectStore(STORE_NAME);
      const result = await requestToPromise(store.get(k));
      return result;
    },
    async kv_write(/** @type {unknown} */ args) {
      if (args === null || typeof args !== "object") {
        throw new TypeError("kv_write: args must be an object");
      }
      const a = /** @type {Record<string, unknown>} */ (args);
      const k = validateKey(a.key, "kv_write");
      // `value` may be any structured-cloneable value; IndexedDB will
      // reject unsupported values (functions, DOM nodes, ...) with a
      // DataCloneError. Let that propagate verbatim.
      const db = await getDb();
      const tx = db.transaction(STORE_NAME, "readwrite");
      const store = tx.objectStore(STORE_NAME);
      await requestToPromise(store.put(a.value, k));
    },
    async kv_delete(/** @type {unknown} */ key) {
      const k = validateKey(key, "kv_delete");
      const db = await getDb();
      const tx = db.transaction(STORE_NAME, "readwrite");
      const store = tx.objectStore(STORE_NAME);
      // `delete` is a no-op when the key is absent; IDB does not
      // signal "not found".
      await requestToPromise(store.delete(k));
    },
    async kv_keys() {
      const db = await getDb();
      const tx = db.transaction(STORE_NAME, "readonly");
      const store = tx.objectStore(STORE_NAME);
      const keys = await requestToPromise(store.getAllKeys());
      // IDBValidKey[] is structurally string[] here because every
      // write goes through validateKey -- but cast explicitly so the
      // return type is honest.
      /** @type {string[]} */
      const out = [];
      for (let i = 0; i < keys.length; i++) {
        const v = keys[i];
        if (typeof v === "string") out.push(v);
      }
      return out;
    },
  };
}
