# Crescent as the entire computer: system & infrastructure

Exploration doc. Speculative throughout unless citing a file. Facet: terminal
emulators, shell, file management, window management, system settings,
monitoring, package management, backup/sync, clipboard, notifications,
theming, input, printing, screenshot/recording, disk, networking config,
process management, init, permissions.

## 1. What people actually do

- Open a terminal, `cd` into a project, run a build/test command, read the
  output, maybe pipe it into `grep`/`less`.
- Alt-tab between a browser, an editor, and a terminal; drag windows between
  monitors; snap two windows side by side to compare.
- Copy a URL in the browser, paste it into a chat app; copy a stack trace from
  a terminal, paste into an issue tracker. Clipboard is the one universal IPC
  channel between otherwise-unrelated apps.
- Check disk space before a big download (`df -h`), check what's eating RAM
  when the fans spin up (`htop`), tail a log file while reproducing a bug.
- Get a desktop notification when a long build finishes, or when a chat
  message arrives while the window isn't focused.
- Install a package (`apt`, `brew`, `nix profile install`), and later wonder
  what's installed and why.
- Back up a laptop before an OS reinstall; sync a dotfiles repo across
  machines; `rsync` a directory to a NAS.
- Take a screenshot of an error dialog to paste into a bug report; screen-record
  a repro for a teammate.
- Plug in a second keyboard, fix the layout, adjust key repeat rate.
- Print a boarding pass (rare now, but still a real workflow with a
  disproportionate amount of user rage attached to it).

The common thread: these are not "apps" in the sense of a single program with
a UI. They're glue — moving bytes, attention, and control between things that
don't know about each other. The OS's job here is arbitration and transport,
not computation.

## 2. Prior art worth stealing from

- **Plan 9**: everything is a file server; window system (`rio`), namespaces
  (per-process mount tables), and even the mouse are exposed as `/dev` files
  read/written over 9P. The insight that survives contact with 2026: *union
  namespaces per-process* is a permission model, not just a filesystem trick —
  a process only sees what's mounted into its namespace.
- **Unix philosophy**: small tools, text streams, `|`. Degrades badly for
  anything binary or structured (hence `jq`, `jc`, PowerShell objects).
- **Haiku/BeOS**: pervasive live-query filesystem (attributes + queries as
  first-class, "smart folders" fell out for free), single coherent API instead
  of ioctl soup.
- **i3/sway/Hyprland (tiling WMs)**: window management as a *typed IPC
  protocol* (i3's JSON-over-socket `i3-msg`), not a mouse-driven GUI you can
  only script by faking clicks. Layout is declarative tree state you can query
  and mutate externally. This is the one most worth studying for crescent.
- **Alacritty/Kitty/WezTerm**: terminal-as-GPU-canvas, plus kitty's graphics
  protocol and remote-control socket (`kitty @`) — the terminal exposes itself
  as an API, not just a VT100 renderer.
- **fish/nushell/oil**: shell as structured-data pipeline (nushell tables) or
  as a real, typed-ish language (oil) instead of string soup. nushell in
  particular treats `ls`, `ps`, `df` output as structured records from the
  start — no `awk '{print $2}'` archaeology.
- **rofi/dmenu**: the "universal fuzzy-select launcher as a UNIX filter" — read
  lines on stdin, print the chosen line on stdout. Any script becomes a menu.
- **dunst / wl-clipboard / xdotool**: single-purpose daemons each owning one
  slice of desktop state (notifications, clipboard, input synthesis) reachable
  by CLI, so they compose into scripts instead of only GUIs.
- **Nix/Guix**: package management as pure function of a declared graph, not
  imperative install/uninstall — the profile *is* the state, reproducible from
  source.
- **Syncthing**: sync as a P2P protocol with no server, versus rsync's
  point-to-point push model — different topology, same "make two trees agree"
  problem.
- **Timeshift/restic/borg**: backup as content-addressed snapshots
  (deduplicated, incremental) vs. tarball-of-everything.

## 3. What crescent already covers

Directly reusable substrate, per `docs/inventory_summary.md` and
`lib/platform/`:

- `fs`, `path`, `process`, `exec`, `signal`, `env`, `dotenv`, `glob` — the
  Unix-process-and-filesystem layer.
- `cli`, `hex_dump`, `log_parser` — terminal/inspection tooling primitives.
- `lib/platform/` — the actual app runtime: manifest-declared caps
  (`lib/platform/caps/fs.lua` gives `{root, allow_write}`-scoped read/write/list,
  path-traversal-checked), `cap_dispatch.lua` with per-cap risk descriptions,
  `xdg.lua` for cross-platform state/config/cache/runtime dirs, an audit log,
  and a policy layer. This is already a Plan-9-flavored per-app namespace: an
  app doesn't get "the filesystem," it gets a cap scoped to a root.
- `tracing` (OTel), `metric` (Prometheus), `service_registry`,
  `circuit_breaker`, `connection_pool`, `rate_limit`/`ratelimit`,
  `retry`, `scheduler`, `cron`/`cron_parser`, `feature_flags`, `hot_reload` —
  the monitoring/reliability layer, already built for *services*, reusable
  wholesale for *system daemons* once system daemons exist as a concept.
- `lib/platform/apps/system_dashboard` — an existing app already doing
  "packs + projections" for system-dashboard-shaped data.

Not covered, as far as this pass found: terminal emulation (VT100/ANSI
parsing exists partially under `lib/web/` TUI/ANSI layer, but not a terminal
*emulator* — a PTY-driving grid-and-scrollback model), window management/
compositing, clipboard, notifications, package management *as an installer*
(`lib/pkg/` is "foundation only — no install algo" per inventory), disk usage
scanning, input method / keyboard layout handling, printing, screen capture.

## 4. What's missing, and the design question that actually matters

Most of the missing pieces above are "just write the library" — a clipboard
cap, a notification cap, a disk-usage scanner over `fs`. Unsurprising, low
tension with crescent's philosophy. The one genuinely hard question is:

**What does "window management" mean when apps run sandboxed in a browser
tab?**

A native WM manages *processes with their own top-level surfaces* — it can
kill one without touching another, it mediates input focus below the app
layer, it composites independently-rendered buffers. Crescent apps under
`lib/platform/` are not independent surfaces; they're cap-sandboxed code
running inside one host page (per `docs/overview.md` / the platform sandbox
model). "Windows" in that world can't be i3-style X11 clients — they're more
like panes in a single-process multiplexer (tmux, not i3). That's not a
downgrade so much as a different substrate: tmux already proves a
single-process multiplexer can have a full window model (splits, layouts,
detach/reattach, session state) *and* a scriptable control protocol
(`tmux list-panes`, `send-keys`) — it just never has to composite
independently-rendered GPU buffers because everything's already text/cells in
one process.

So the crescent-native framing is closer to **tmux/i3's control-plane idea
applied to DOM panes**: a window manager cap that owns a tree of DOM regions,
exposes it as queryable/mutable state (a typed IPC protocol like i3's, not a
GUI you can only drive by synthesizing clicks), and lets apps request a pane
the same way they request an `fs` cap — scoped, revocable, auditable. Two apps
sharing a screen is then a capability-grant question ("does app B get a pane
at all, and can it read app A's pane title/size") rather than an OS-level
process-isolation question, because the isolation is already handled one
layer down by the sandbox.

That reframing cascades into the rest of the facet:

- **Clipboard** is the sharpest instance of the same problem the browser
  itself hasn't solved well: an inter-app channel that must cross cap
  boundaries by design (that's its entire purpose) while everything else in
  the platform is built to *prevent* apps reaching each other. A `clipboard`
  cap needs its own grant semantics — probably "paste requires a user
  gesture," mirroring the Clipboard API's own security model, rather than
  crescent inventing something novel. Worth flagging as a place where
  copying the web platform's existing answer beats designing a new one.
- **Notifications** are an escalation path: a background app (one without
  focus, maybe without a visible pane at all) reaching the user. That's
  exactly the shape of capability crescent's cap model is built to gate —
  "can this app interrupt me" is a permission, not a given.
- **Package management** for crescent doesn't mean installing binaries — it
  means resolving and vendoring *library* dependency graphs, which is
  `lib/pkg/`'s actual scope per the inventory note ("foundation only — no
  install algo"). Nix's pure-function-of-a-declared-graph model is the
  directly relevant prior art here, more than apt/brew, because crescent's
  zero-dependency/vendored-binary discipline already rhymes with Nix's
  reproducibility goal — worth reading `docs/pkg-design.md` before designing
  further.
- **Process management / init**: crescent already has `process`/`exec`/
  `signal` for spawning and signaling real OS processes, and `scheduler`/
  `cron` for in-process scheduling. An "init system" concept only becomes
  interesting if crescent apps can themselves be long-running daemons
  supervised the same way — which is really just `lib/platform/daemon/`
  (exists) plus `circuit_breaker`/`retry`/`service_registry` composed
  together; no new substrate needed, just an app that wires the existing
  pieces into a supervisor UI.

## 5. Where this is genuinely open (not a guess to resolve here)

- Whether a crescent "window manager" cap is worth building before any app
  actually needs multi-pane layout — building substrate ahead of a real
  consumer risks guessing at the wrong protocol shape (the "substrate before
  consumers" rule cuts both ways: substrate needs a consumer in view to avoid
  being invented in a vacuum).
- Whether clipboard/notification caps belong in `lib/platform/caps/`
  alongside `fs.lua` now, or wait until an app in `lib/platform/apps/` needs
  one — same question as above, concretely scoped to two caps.
- Whether "terminal emulator" is in scope at all for a browser-hosted
  platform, or whether `cr`'s own CLI/`lib/cli` plus the existing ANSI/TUI
  layer under `lib/web/` already covers what crescent needs and a literal
  PTY-grid emulator would be building infrastructure crescent apps don't run
  on top of.

These three are flagged as open rather than answered — they're product/
sequencing calls, not facts this pass can establish by reading code.
