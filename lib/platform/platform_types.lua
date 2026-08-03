-- lib/platform/platform_types.lua
-- Core platform type declarations: Manifest, CapDecl, EntryDef, AppRecord.
--
-- This file is declarations only (no runtime code). It consolidates the
-- duplicate declarations that previously appeared in both lib/platform/init.lua
-- and lib/platform/cli.lua.
--
-- Load via:  --:: require "lib.platform.platform_types"
-- Or add to opts.globals_files for files that need these types.

-- ── TarEntry ─────────────────────────────────────────────────────────────────

--:: TarEntry = { name: string, mode: number, size: number, mtime: number, data: string, typeflag: string }

-- ── CapDecl ───────────────────────────────────────────────────────────────────
-- A capability declaration as it appears in manifest.json.
-- Fields are optional — the platform reads only what it understands; unknown
-- fields are passed through to the cap factory.

--:: CapDecl = {
--::   type: string | nil,
--::   required: boolean | nil,
--::   host: string | nil,
--::   model: string | nil,
--::   path: string | nil,
--::   paths: unknown,
--::   methods: unknown,
--::   allow_write: boolean | nil,
--::   allow_read: boolean | nil,
--::   allow_list: boolean | nil,
--::   allow_list_recursive: boolean | nil,
--::   allow_stat: boolean | nil,
--::   allow_mkdir: boolean | nil,
--::   allow_delete: boolean | nil,
--::   allow_rename: boolean | nil,
--::   scope: unknown,
--::   tables: unknown,
--::   provider: string | nil,
--::   key_name: string | nil,
--::   base_url: string | nil,
--::   provider_default: string | nil,
--::   root: string | nil,
--::   binaries: unknown,
--::   stderr: string | nil,
--::   port: integer | nil,
--::   ...
--:: }

-- ── EntryDef ──────────────────────────────────────────────────────────────────
-- One entry in manifest.entry; may be a plain path string or a table.

--:: EntryDef = {
--::   main: string | nil,
--::   caps: { [string]: CapDecl | string } | nil,
--:: }

-- ── ManifestMeta ─────────────────────────────────────────────────────────────

--:: ManifestMeta = { tags: { [integer]: string } | nil, description: string | nil, ... }

-- ── Manifest ─────────────────────────────────────────────────────────────────

--:: Manifest = {
--::   name: string | nil,
--::   version: string | nil,
--::   entry: { [string]: EntryDef | string } | nil,
--::   caps: { [string]: CapDecl | string } | nil,
--::   default_entry: string | nil,
--::   meta: ManifestMeta | nil,
--::   ...
--:: }

-- ── AppRecord ─────────────────────────────────────────────────────────────────
-- The in-memory representation of a loaded app (returned by platform.load_app).

--:: AppRecord = {
--::   path: string,
--::   chunks: { [integer]: { type: string, data: string } } | nil,
--::   entries: { [number]: TarEntry },
--::   manifest: Manifest | nil,
--::   _dir_mode: boolean | nil,
--:: }

return {}
