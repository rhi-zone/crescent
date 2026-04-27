# system_dashboard

## Identity

The dashboard has no fixed identity — packs give it one. Install no packs: it's a blank command palette. Install the right packs: it becomes any of these simultaneously:

- **Raycast / Alfred** — command palette with read+act on the system. Fuzzy search over curated aliases, each mapping a description to a concrete action.
- **Home Assistant** — observe and control through pluggable integrations. Each pack is an integration; the surface is composable across all of them.
- **Control Panel / System Preferences** — expose configurable system state. Registry keys, config files, service toggles — all surfaced through named aliases.
- **Hammerspoon / AutoHotkey** — scriptable system automation. Packs declare `exec`/`shell` caps and wire descriptions to commands.
- **Rainmeter** — scriptable system widgets. Read-only aliases surface live system state (memory, ports, services).
- **Regedit editors** — curated registry modification surfaces. Packs declare `registry` caps scoped to specific key paths; actions cite the exact key being touched.
- **nushell** — system as structured queryable data. Search returns structured results; actions return structured output.
- **Local service dashboards** — Tailscale admin, Ollama, Grafana, anything with a local HTTP API. Pack declares `http_client` cap; dashboard becomes that service's admin console.

One surface. What it is depends entirely on what packs are installed. The quality and coverage match the installed packs — a blank dashboard is a blank slate. Parity with the prior art tools means fully bidirectional packs: not just reading Tailscale status but toggling exit nodes; not just listing registry values but writing them. Read-only is a floor, not a ceiling.

## Pack Format

A pack is a section of the app manifest — a list of named aliases, each with a human-readable description, cap declarations, and an action. The manifest ships inside the app's tarball alongside the Lua source. Packs are vendorable: install one, it's source you own and can modify.

Packs are currently declared inline in the app manifest; user-installable packs from external sources are an open thread.

### Pack-level cap declarations (shorthand)

A pack may declare caps once at pack scope; every action in that pack inherits those caps by default. Action-level caps still take precedence — if an action declares a cap with the same name, the action-level decl fully replaces the pack-level decl for that name (no field merging).

```lua
return {
  name = "git",
  caps = {
    -- inherited by every action below
    shell = { type = "shell", reason = "Run git commands" },
  },
  aliases = {
    {
      id = "git-status", title = "Git status",
      actions = {
        -- no caps field: uses pack-level shell cap
        { label = "Show", exec = { cap = "shell", args = "git status" } },
      },
    },
  },
}
```

Both styles coexist. Use action-level caps when actions need different scopes (e.g. registry cap with different `root` per action). Use pack-level caps when many actions share an identical cap declaration.

The merged caps are resolved at pack-load time and validated as a single set. `exec.cap` must reference a name present in the merged result; an action that references an undeclared cap is skipped with a warning.

## Pack Directions

### Regedit hacks

Decades of accumulated Windows system tweaks have no official UI. The canonical source is community knowledge: NTDev, tenforums, winaero, archived TweakUI documentation. Each alias maps a human-readable description to its exact registry key path and operation (read or write). This is high-value and has essentially zero legitimate competition — the knowledge exists but is scattered across blog posts, forum threads, and unmaintained tools. Packs can consolidate it.

Example territory: `HKCU\Control Panel\Desktop` for focus behavior, `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` for startup programs, `HKLM\SYSTEM\CurrentControlSet\Services` for driver settings. Each alias should cite its key path and ideally a source link in the description.

### Platform configuration (cross-platform)

Concepts that exist on every OS with completely different mechanisms are prime candidates for unified packs:

- **File associations**: `xdg-mime` / `~/.config/mimeapps.list` (Linux), Launch Services / `duti` (macOS), registry file associations (Windows). One "set default app for .pdf" action that does the right thing per platform.
- **Startup programs**: systemd user units (Linux), launchd plists in `~/Library/LaunchAgents` (macOS), `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (Windows).
- **Default browser / default apps**: corollary to file associations.
- **Network/DNS config**: resolv.conf / systemd-resolved (Linux), `/etc/hosts` equivalents, DNS-over-HTTPS settings.

The pack declares platform-specific cap implementations behind a unified alias description. The user sees "Set default PDF viewer" — the pack handles which OS it's running on. Packs that unify cross-platform concepts behind a single alias description are especially valuable: the user gets a stable description; the pack absorbs the OS-specific complexity.

### NixOS options as daemon catalogue

`services.X.enable = true` across the NixOS module system is the most comprehensive machine-readable catalogue of daemons worth supporting that exists. Use it as a research index — not as the delivery mechanism (NixOS is niche; the daemons themselves are not). If NixOS has a module for a service, that service has a local HTTP API, systemd unit, or config file worth wrapping in a pack.

### Local HTTP services

Tailscale local API (`http://localhost:41112`), Ollama (`http://localhost:11434`), Grafana, Prometheus, MinIO, Gitea — anything that exposes a local HTTP API. Pack declares an `http_client` cap scoped to the local host and port. The dashboard becomes that service's admin console without requiring the service to ship one.

These packs are pure data — a list of aliases mapping readable descriptions to API calls. The `http_client` cap handles the transport; the pack specifies endpoints, methods, and expected output shapes.

### Web services

GitHub, Notion, Linear, Spotify, etc. via `http_client` with remote scope. Same pattern as local HTTP services; the cap system already supports this. A pack wrapping the GitHub API surfaces repository, issue, and PR actions directly in the dashboard.

## Transparency

Pack actions cite their sources. Registry aliases include the key path and subkey in `exec`. HTTP aliases include the endpoint. This is not documentation — it is the literal operation being performed, visible to the user before they run it. Transparency is a feature: the user can verify exactly what will be touched.

The `cap_info` API (`GET /api/cap_info?alias=&action=`) surfaces cap declarations and risk level before execution. The frontend shows this in a confirmation modal before any action runs.

## Cap System Fit

The existing cap taxonomy maps cleanly to pack use cases:

| Cap | Use case |
|-----|----------|
| `exec` / `shell` | System commands, service control, build tools |
| `registry` | Windows registry read/write, scoped to key path prefix |
| `http_client` | Local HTTP services (Tailscale, Ollama), remote APIs (GitHub, Notion) |
| `fs` | Config file editing, dotfile management |
| `db` / `kv` | Local state, cached query results |

Each pack declares exactly what it touches. No ambient authority. A pack that reads a registry key cannot write it unless `allow_write = true` is declared. A pack that talks to Ollama cannot talk to GitHub unless it declares a separate `http_client` cap for that host. Granularity comes from declaring multiple named caps, not from a single broad permission.

Pack-level cap declarations (see Pack Format above) are a shorthand for the common case where many actions share an identical cap; they don't change the security model — every cap is still declared, scoped, and granted by the operator.

## Open Threads

- **User-installed packs**: currently only built-in packs ship with the app. The `packs.load_user(fs_cap)` API is implemented and ready — the missing piece is a UI for installing packs and a `fs` cap scoped to the user packs directory. `crescent run github:user/my-pack` is the intended install gesture.
- **RAG retrieval**: for queries that don't match any known alias, a local index of documentation and community knowledge would cover the long tail. Fuzzy search over curated aliases covers the known surface; RAG covers the unknown.
- **Read/write naming consistency**: `fs` uses `allow_write: boolean`; `db` uses `readonly: boolean` (inverted). Should normalize to `allow_write` across all caps.
