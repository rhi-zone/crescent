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

--:: Text         = { type: "text", text: string, style: (TextStyle | nil), cite: (Cite  | nil)}
--:: Code         = { type: "code", text: string, lang: (CodeLang | nil), cite: (Cite  | nil)}
--:: Markdown     = { type: "markdown", text: string, cite: (Cite  | nil)}
--:: StatusBadge  = { type: "status_badge", label: string, state: BadgeState, cite: (Cite  | nil)}
--:: Link         = { type: "link", href: string, label: (string | nil), cite: (Cite  | nil)}
--:: Icon         = { type: "icon", name: string, tone: (string | nil), cite: (Cite  | nil)}
--:: Kbd          = { type: "kbd", keys: string[], cite: (Cite  | nil)}

-- ── Numeric / scalar primitives ─────────────────────────────────────────────

--:: SingleStat   = { type: "single_stat", value: unknown, unit: (string | nil), label: (string | nil), delta: (unknown | nil), state: (BadgeState | nil), cite: (Cite  | nil)}
--:: GaugeThresh  = { at: number, state: BadgeState }
--:: Gauge        = { type: "gauge", value: number, min: number, max: number, unit: (string | nil), thresholds: (GaugeThresh[] | nil), cite: (Cite  | nil)}
--:: ProgressBar  = { type: "progress_bar", value: number, max: number, label: (string | nil), indeterminate: (boolean | nil), cite: (Cite  | nil)}
--:: Sparkline    = { type: "sparkline", points: number[], unit: (string | nil), cite: (Cite  | nil)}

-- ── Tabular ─────────────────────────────────────────────────────────────────

--:: ColumnSpec   = { key: string, label: string, type: ColumnType, sortable: (boolean | nil), align: (string  | nil)}
--:: KVPair       = { key: string, value: Primitive }
--:: ListItem     = { title: string, subtitle: (string | nil), icon: (string | nil), trailing: (string | nil), action: (string  | nil)}
--:: Table        = { type: "table", columns: ColumnSpec[], rows: { [string]: unknown }[], default_sort: (string | nil), row_actions: (string[] | nil), cite: (Cite  | nil)}
--:: KeyValue     = { type: "key_value", pairs: KVPair[], cite: (Cite  | nil)}
--:: PList        = { type: "list", items: ListItem[], cite: (Cite  | nil)}

-- ── Time-series ─────────────────────────────────────────────────────────────

--:: SeriesPoint  = { t: number, v: number }
--:: Series       = { name: string, points: SeriesPoint[] }
--:: LineChart    = { type: "line_chart", series: Series[], unit: (string | nil), y_min: (number | nil), y_max: (number | nil), cite: (Cite  | nil)}
--:: BarChart     = { type: "bar_chart", series: Series[], unit: (string | nil), stacked: (boolean | nil), cite: (Cite  | nil)}
--:: AreaChart    = { type: "area_chart", series: Series[], unit: (string | nil), stacked: (boolean | nil), cite: (Cite  | nil)}
--:: Heatmap      = { type: "heatmap", x_bins: number, y_bins: number, values: number[][], cite: (Cite  | nil)}
--:: TopListItem  = { label: string, value: number, unit: (string  | nil)}
--:: TopList      = { type: "top_list", items: TopListItem[], max: (number | nil), cite: (Cite  | nil)}

-- ── Composite (recursive — body fields may be any primitive) ────────────────

--:: Card         = { type: "card", title: (string | nil), subtitle: (string | nil), body: Primitive, footer: (Primitive | nil), cite: (Cite  | nil)}
--:: Grid         = { type: "grid", cells: Primitive[], columns: (number | nil), cite: (Cite  | nil)}
--:: Panel        = { type: "panel", title: string, body: Primitive, actions: (string[] | nil), cite: (Cite  | nil)}
--:: TabSpec      = { label: string, body: Primitive }
--:: Tabs         = { type: "tabs", tabs: TabSpec[], cite: (Cite  | nil)}
--:: Split        = { type: "split", direction: SplitDir, parts: Primitive[], cite: (Cite  | nil)}

-- ── Streaming ───────────────────────────────────────────────────────────────

--:: LogStream    = { type: "log_stream", frame_type: "log", columns: (ColumnSpec[] | nil), cite: (Cite  | nil)}
--:: LiveTable    = { type: "live_table", frame_type: "table", columns: ColumnSpec[], key: string, row_actions: (string[] | nil), cite: (Cite  | nil)}
--:: EventStream  = { type: "event_stream", frame_type: "event", cite: (Cite  | nil)}

-- ── Hierarchical ────────────────────────────────────────────────────────────

--:: TreeNode     = { label: string, children: (TreeNode[] | nil), value: (unknown | nil), icon: (string  | nil)}
--:: Tree         = { type: "tree", root: TreeNode, cite: (Cite  | nil)}
--:: JsonView     = { type: "json_view", value: unknown, expand_depth: (number | nil), cite: (Cite  | nil)}
--:: Diff         = { type: "diff", before: string, after: string, lang: (CodeLang | nil), cite: (Cite  | nil)}

-- ── Action ──────────────────────────────────────────────────────────────────

--:: FormField    = { name: string, label: string, type: FieldType, required: (boolean | nil), default: (unknown | nil), options: (unknown[]  | nil)}
--:: Button       = { type: "button", label: string, alias: string, args: ({ [string]: unknown } | nil), confirm: (boolean | nil), style: (ButtonStyle | nil), cite: (Cite  | nil)}
--:: Form         = { type: "form", fields: FormField[], submit_alias: string, submit_label: (string | nil), cite: (Cite  | nil)}
--:: Confirm      = { type: "confirm", prompt: string, alias: string, args: ({ [string]: unknown } | nil), danger: (boolean | nil), cite: (Cite  | nil)}
--:: ActionMenuItem = { label: string, alias: string, args: ({ [string]: unknown }  | nil)}
--:: ActionMenu   = { type: "action_menu", items: ActionMenuItem[], cite: (Cite  | nil)}

-- ── Top-level discriminated union ───────────────────────────────────────────

--:: Primitive = Text | Code | Markdown | StatusBadge | Link | Icon | Kbd | SingleStat | Gauge | ProgressBar | Sparkline | Table | KeyValue | PList | LineChart | BarChart | AreaChart | Heatmap | TopList | Card | Grid | Panel | Tabs | Split | LogStream | LiveTable | EventStream | Tree | JsonView | Diff | Button | Form | Confirm | ActionMenu

-- ── Cite channel (transparency: what was actually touched) ──────────────────

--:: CiteRegistry  = { kind: "registry", path: string, value: (string  | nil)}
--:: CiteRegKey    = { kind: "registry_key", path: string }
--:: CiteHttp      = { kind: "http", method: string, url: string }
--:: CiteUrl       = { kind: "url", href: string }
--:: CiteFile      = { kind: "file", path: string }
--:: CiteCommand   = { kind: "command", argv: string[] }
--:: CiteExec      = { kind: "exec", argv: string[] }
--:: CiteDb        = { kind: "db", query: string }
--:: CiteEnv       = { kind: "env", name: string }
--:: CiteText      = { kind: "text", text: string }
--:: CiteEntry     = CiteRegistry | CiteRegKey | CiteHttp | CiteUrl | CiteFile | CiteCommand | CiteExec | CiteDb | CiteEnv | CiteText
--:: Cite          = CiteEntry[]

-- ── Envelope ────────────────────────────────────────────────────────────────

--:: OkEnvelope   = { ok: true, body: Primitive, cite: (Cite | nil), stream: (unknown | nil), ttl_ms: (number  | nil)}
--:: ErrEnvelope  = { ok: false, error: string, body: (Primitive | nil), cite: (Cite  | nil)}
--:: Envelope     = OkEnvelope | ErrEnvelope
