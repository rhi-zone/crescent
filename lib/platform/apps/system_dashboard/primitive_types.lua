-- lib/platform/apps/system_dashboard/primitive_types.lua
-- Shared type declarations for the system_dashboard pack output schema.
--
-- This file is declarations only (no runtime code). It is loaded as a
-- typechecker globals file (`opts.globals_files`) by the projection prelude
-- and by anything else that needs to refer to the `Primitive` discriminated
-- union by name.
--
-- The runtime constructors / validators live in `output.lua`. The catalogue
-- of primitives is documented in `docs/system_dashboard_primitives.md`; this
-- file is the executable type-level form of that doc and must stay in sync.

-- ── Shared scalar / enum aliases ────────────────────────────────────────────

--:: TextStyle    = "muted" | "strong" | "error" | "success"
--:: BadgeState   = "ok" | "warn" | "error" | "unknown" | "info"
--:: CodeLang     = "json" | "xml" | "html" | "lua" | "yaml" | "toml" | "shell" | "sql" | "markdown" | string
--:: ColumnType   = "string" | "number" | "bytes" | "duration" | "timestamp" | "status" | "code" | "link"
--:: FieldType    = "text" | "password" | "number" | "bool" | "select" | "multiselect" | "path" | "host"
--:: ButtonStyle  = "primary" | "danger"
--:: SplitDir     = "row" | "col"
--:: FrameType    = "log" | "table" | "event"

-- ── Atomic primitives ───────────────────────────────────────────────────────

--:: Text         = { type: "text", text: string, style?: TextStyle, cite?: Cite }
--:: Code         = { type: "code", text: string, lang?: CodeLang, cite?: Cite }
--:: Markdown     = { type: "markdown", text: string, cite?: Cite }
--:: StatusBadge  = { type: "status_badge", label: string, state: BadgeState, cite?: Cite }
--:: Link         = { type: "link", href: string, label?: string, cite?: Cite }
--:: Icon         = { type: "icon", name: string, tone?: string, cite?: Cite }
--:: Kbd          = { type: "kbd", keys: string[], cite?: Cite }

-- ── Numeric / scalar primitives ─────────────────────────────────────────────

--:: SingleStat   = { type: "single_stat", value: unknown, unit?: string, label?: string, delta?: unknown, state?: BadgeState, cite?: Cite }
--:: GaugeThresh  = { at: number, state: BadgeState }
--:: Gauge        = { type: "gauge", value: number, min: number, max: number, unit?: string, thresholds?: GaugeThresh[], cite?: Cite }
--:: ProgressBar  = { type: "progress_bar", value: number, max: number, label?: string, indeterminate?: boolean, cite?: Cite }
--:: Sparkline    = { type: "sparkline", points: number[], unit?: string, cite?: Cite }

-- ── Tabular ─────────────────────────────────────────────────────────────────

--:: ColumnSpec   = { key: string, label: string, type: ColumnType, sortable?: boolean, align?: string }
--:: KVPair       = { key: string, value: Primitive }
--:: ListItem     = { title: string, subtitle?: string, icon?: string, trailing?: string, action?: string }
--:: Table        = { type: "table", columns: ColumnSpec[], rows: { [string]: unknown }[], default_sort?: string, row_actions?: string[], cite?: Cite }
--:: KeyValue     = { type: "key_value", pairs: KVPair[], cite?: Cite }
--:: PList        = { type: "list", items: ListItem[], cite?: Cite }

-- ── Time-series ─────────────────────────────────────────────────────────────

--:: SeriesPoint  = { t: number, v: number }
--:: Series       = { name: string, points: SeriesPoint[] }
--:: LineChart    = { type: "line_chart", series: Series[], unit?: string, y_min?: number, y_max?: number, cite?: Cite }
--:: BarChart     = { type: "bar_chart", series: Series[], unit?: string, stacked?: boolean, cite?: Cite }
--:: AreaChart    = { type: "area_chart", series: Series[], unit?: string, stacked?: boolean, cite?: Cite }
--:: Heatmap      = { type: "heatmap", x_bins: number, y_bins: number, values: number[][], cite?: Cite }
--:: TopListItem  = { label: string, value: number, unit?: string }
--:: TopList      = { type: "top_list", items: TopListItem[], max?: number, cite?: Cite }

-- ── Composite (recursive — body fields may be any primitive) ────────────────

--:: Card         = { type: "card", title?: string, subtitle?: string, body: Primitive, footer?: Primitive, cite?: Cite }
--:: Grid         = { type: "grid", cells: Primitive[], columns?: number, cite?: Cite }
--:: Panel        = { type: "panel", title: string, body: Primitive, actions?: string[], cite?: Cite }
--:: TabSpec      = { label: string, body: Primitive }
--:: Tabs         = { type: "tabs", tabs: TabSpec[], cite?: Cite }
--:: Split        = { type: "split", direction: SplitDir, parts: Primitive[], cite?: Cite }

-- ── Streaming ───────────────────────────────────────────────────────────────

--:: LogStream    = { type: "log_stream", frame_type: "log", columns?: ColumnSpec[], cite?: Cite }
--:: LiveTable    = { type: "live_table", frame_type: "table", columns: ColumnSpec[], key: string, row_actions?: string[], cite?: Cite }
--:: EventStream  = { type: "event_stream", frame_type: "event", cite?: Cite }

-- ── Hierarchical ────────────────────────────────────────────────────────────

--:: TreeNode     = { label: string, children?: TreeNode[], value?: unknown, icon?: string }
--:: Tree         = { type: "tree", root: TreeNode, cite?: Cite }
--:: JsonView     = { type: "json_view", value: unknown, expand_depth?: number, cite?: Cite }
--:: Diff         = { type: "diff", before: string, after: string, lang?: CodeLang, cite?: Cite }

-- ── Action ──────────────────────────────────────────────────────────────────

--:: FormField    = { name: string, label: string, type: FieldType, required?: boolean, default?: unknown, options?: unknown[] }
--:: Button       = { type: "button", label: string, alias: string, args?: { [string]: unknown }, confirm?: boolean, style?: ButtonStyle, cite?: Cite }
--:: Form         = { type: "form", fields: FormField[], submit_alias: string, submit_label?: string, cite?: Cite }
--:: Confirm      = { type: "confirm", prompt: string, alias: string, args?: { [string]: unknown }, danger?: boolean, cite?: Cite }
--:: ActionMenuItem = { label: string, alias: string, args?: { [string]: unknown } }
--:: ActionMenu   = { type: "action_menu", items: ActionMenuItem[], cite?: Cite }

-- ── Top-level discriminated union ───────────────────────────────────────────

--:: Primitive = Text | Code | Markdown | StatusBadge | Link | Icon | Kbd
--::           | SingleStat | Gauge | ProgressBar | Sparkline
--::           | Table | KeyValue | PList
--::           | LineChart | BarChart | AreaChart | Heatmap | TopList
--::           | Card | Grid | Panel | Tabs | Split
--::           | LogStream | LiveTable | EventStream
--::           | Tree | JsonView | Diff
--::           | Button | Form | Confirm | ActionMenu

-- ── Cite channel (transparency: what was actually touched) ──────────────────

--:: CiteRegistry  = { kind: "registry", path: string, value?: string }
--:: CiteRegKey    = { kind: "registry_key", path: string }
--:: CiteHttp      = { kind: "http", method: string, url: string }
--:: CiteUrl       = { kind: "url", href: string }
--:: CiteFile      = { kind: "file", path: string }
--:: CiteCommand   = { kind: "command", argv: string[] }
--:: CiteExec      = { kind: "exec", argv: string[] }
--:: CiteDb        = { kind: "db", query: string }
--:: CiteEnv       = { kind: "env", name: string }
--:: CiteText      = { kind: "text", text: string }
--:: CiteEntry     = CiteRegistry | CiteRegKey | CiteHttp | CiteUrl | CiteFile
--::               | CiteCommand | CiteExec | CiteDb | CiteEnv | CiteText
--:: Cite          = CiteEntry[]

-- ── Envelope ────────────────────────────────────────────────────────────────

--:: OkEnvelope   = { ok: true, body: Primitive, cite?: Cite, stream?: unknown, ttl_ms?: number }
--:: ErrEnvelope  = { ok: false, error: string, body?: Primitive, cite?: Cite }
--:: Envelope     = OkEnvelope | ErrEnvelope
