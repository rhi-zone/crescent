-- Demonstrates pack-level cap declaration shorthand: every action below
-- uses the same `shell` cap, declared once at pack scope. Action-level caps
-- could still override per-name if needed.
return {
	name        = "git",
	description = "Common git commands for the current working directory",
	version     = "0.1.0",
	-- Pack-level caps: inherited by every action in this pack unless the
	-- action declares a cap of the same name (which fully overrides).
	caps = {
		shell = { type = "shell", reason = "Run git commands in the current working directory" },
	},
	aliases = {
		{
			id          = "git-status",
			title       = "Git status",
			description = "Show working tree status for the current repository.",
			tags        = { "git", "vcs", "status" },
			platform    = { "linux", "macos", "windows" },
			actions     = {
				{ label = "Show status", exec = { cap = "shell", args = "git status" } },
			},
		},
		{
			id          = "git-log-graph",
			title       = "Git log (graph)",
			description = "Show the most recent commits across all branches as a graph.",
			tags        = { "git", "vcs", "log", "history" },
			platform    = { "linux", "macos", "windows" },
			actions     = {
				{
					label = "Show log",
					exec  = { cap = "shell", args = "git log --oneline --graph --decorate --all -n 30" },
				},
			},
		},
		{
			id          = "git-diff",
			title       = "Git diff (unstaged)",
			description = "Show unstaged changes in the working tree.",
			tags        = { "git", "vcs", "diff" },
			platform    = { "linux", "macos", "windows" },
			actions     = {
				{ label = "Show diff", exec = { cap = "shell", args = "git diff" } },
			},
		},
		{
			id          = "git-fetch",
			title       = "Git fetch",
			description = "Fetch refs from the default remote without merging.",
			tags        = { "git", "vcs", "remote", "fetch" },
			platform    = { "linux", "macos", "windows" },
			actions     = {
				{ label = "Fetch", exec = { cap = "shell", args = "git fetch --all --prune" } },
			},
		},
	},
}
