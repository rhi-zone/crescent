return {
	name        = "default",
	description = "Built-in cross-platform system configuration aliases",
	version     = "0.1.0",
	aliases = {
		-- ── Linux / macOS ──────────────────────────────────────────────────────

		{
			id          = "hosts-edit",
			title       = "Edit hosts file",
			description = "Open /etc/hosts for editing. Maps hostnames to IP addresses.",
			tags        = { "network", "hosts", "dns" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Open in editor", type = "shell", command = "sudoedit /etc/hosts" },
			},
		},

		{
			id          = "dns-flush-macos",
			title       = "Flush DNS cache (macOS)",
			description = "Clear the macOS DNS resolver cache. Run after editing /etc/hosts or changing DNS settings.",
			tags        = { "network", "dns", "cache" },
			platform    = { "macos" },
			actions     = {
				{ label = "Flush DNS", type = "shell", command = "sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder" },
			},
		},

		{
			id          = "dns-flush-linux",
			title       = "Flush DNS cache (Linux)",
			description = "Clear the systemd-resolved DNS cache. Run after editing /etc/hosts or changing DNS.",
			tags        = { "network", "dns", "cache" },
			platform    = { "linux" },
			actions     = {
				{ label = "Flush DNS", type = "shell", command = "sudo systemd-resolve --flush-caches" },
			},
		},

		{
			id          = "open-ports-linux",
			title       = "Show open listening ports (Linux)",
			description = "List all TCP ports currently listening for connections.",
			tags        = { "network", "ports", "security" },
			platform    = { "linux" },
			actions     = {
				{ label = "Show ports", type = "shell", command = "ss -tlnp" },
			},
		},

		{
			id          = "open-ports-macos",
			title       = "Show open listening ports (macOS)",
			description = "List all TCP/UDP ports currently listening for connections.",
			tags        = { "network", "ports", "security" },
			platform    = { "macos" },
			actions     = {
				{ label = "Show ports", type = "shell", command = 'lsof -i -P -n | grep LISTEN' },
			},
		},

		{
			id          = "disk-usage",
			title       = "Disk usage overview",
			description = "Show free and used disk space on all mounted filesystems.",
			tags        = { "disk", "storage", "system" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Show disk usage", type = "shell", command = "df -h" },
			},
		},

		{
			id          = "large-files",
			title       = "Find large files in current directory",
			description = "List subdirectories and files sorted by size, largest first.",
			tags        = { "disk", "storage", "files" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Find large files", type = "shell", command = "du -sh * | sort -rh | head -20" },
			},
		},

		{
			id          = "env-vars",
			title       = "Show environment variables",
			description = "Print all currently-set environment variables, sorted alphabetically.",
			tags        = { "environment", "shell", "system" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Show env vars", type = "shell", command = "printenv | sort | less" },
			},
		},

		{
			id          = "crontab-edit",
			title       = "Edit crontab",
			description = "Open the current user's crontab for editing scheduled jobs.",
			tags        = { "cron", "scheduler", "automation" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Edit crontab", type = "shell", command = "crontab -e" },
			},
		},

		{
			id          = "ssh-config-edit",
			title       = "Edit SSH config",
			description = "Open ~/.ssh/config in the default editor. Configure SSH host aliases, keys, and options.",
			tags        = { "ssh", "network", "config" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Edit SSH config", type = "shell", command = "${EDITOR:-nano} ~/.ssh/config" },
			},
		},

		{
			id          = "ssh-keygen",
			title       = "Generate SSH key (ed25519)",
			description = "Create a new SSH key pair using the ed25519 algorithm.",
			tags        = { "ssh", "security", "keys" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Generate key", type = "shell", command = "ssh-keygen -t ed25519" },
			},
		},

		{
			id          = "system-info-linux",
			title       = "Show system info (Linux)",
			description = "Print kernel version and Linux distribution details.",
			tags        = { "system", "info", "kernel" },
			platform    = { "linux" },
			actions     = {
				{ label = "Show system info", type = "shell", command = "uname -a && lsb_release -a" },
			},
		},

		{
			id          = "system-info-macos",
			title       = "Show system info (macOS)",
			description = "Print kernel version and macOS version details.",
			tags        = { "system", "info", "kernel" },
			platform    = { "macos" },
			actions     = {
				{ label = "Show system info", type = "shell", command = "uname -a && sw_vers" },
			},
		},

		{
			id          = "memory-linux",
			title       = "Show memory usage (Linux)",
			description = "Display RAM and swap usage in human-readable form.",
			tags        = { "memory", "system", "ram" },
			platform    = { "linux" },
			actions     = {
				{ label = "Show memory", type = "shell", command = "free -h" },
			},
		},

		{
			id          = "memory-macos",
			title       = "Show memory usage (macOS)",
			description = "Display virtual memory statistics including wired, active, and free memory.",
			tags        = { "memory", "system", "ram" },
			platform    = { "macos" },
			actions     = {
				{ label = "Show memory", type = "shell", command = "vm_stat" },
			},
		},

		{
			id          = "sudoers-edit",
			title       = "Edit sudoers",
			description = "Open /etc/sudoers safely with visudo. Controls which users can run commands as root.",
			tags        = { "sudo", "security", "permissions" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Edit sudoers", type = "shell", command = "sudo visudo" },
			},
		},

		{
			id          = "running-services-linux",
			title       = "Show running services (Linux)",
			description = "List all active systemd services currently running.",
			tags        = { "services", "systemd", "system" },
			platform    = { "linux" },
			actions     = {
				{ label = "List services", type = "shell", command = "systemctl list-units --type=service --state=running" },
			},
		},

		{
			id          = "running-services-macos",
			title       = "Show running services (macOS)",
			description = "List launchd agents and daemons that are running, excluding Apple system services.",
			tags        = { "services", "launchd", "system" },
			platform    = { "macos" },
			actions     = {
				{ label = "List services", type = "shell", command = 'launchctl list | grep -v "com.apple"' },
			},
		},

		{
			id          = "restart-network-linux",
			title       = "Restart networking (Linux)",
			description = "Restart the NetworkManager service to re-apply network configuration.",
			tags        = { "network", "networking", "restart" },
			platform    = { "linux" },
			actions     = {
				{ label = "Restart network", type = "shell", command = "sudo systemctl restart NetworkManager" },
			},
		},

		{
			id          = "restart-network-macos",
			title       = "Restart networking (macOS)",
			description = "Bring en0 (primary interface) down and back up to refresh network state.",
			tags        = { "network", "networking", "restart" },
			platform    = { "macos" },
			actions     = {
				{ label = "Restart network", type = "shell", command = "sudo ifconfig en0 down && sudo ifconfig en0 up" },
			},
		},

		{
			id          = "path-add-permanently",
			title       = "Add directory to PATH permanently",
			description = 'Add "export PATH=\\"$PATH:/your/path\\"" to ~/.bashrc (bash) or ~/.zshrc (zsh), then reload with "source ~/.bashrc" or "source ~/.zshrc".',
			tags        = { "environment", "path", "shell" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Edit .bashrc", type = "shell", command = "${EDITOR:-nano} ~/.bashrc" },
				{ label = "Edit .zshrc",  type = "shell", command = "${EDITOR:-nano} ~/.zshrc",  caps = { "shell" } },
			},
		},

		{
			id          = "shell-profile-edit",
			title       = "Edit shell profile",
			description = "Open ~/.bashrc in the default editor. For zsh users, edit ~/.zshrc instead.",
			tags        = { "shell", "profile", "config" },
			platform    = { "linux", "macos" },
			actions     = {
				{ label = "Edit .bashrc", type = "shell", command = "${EDITOR:-nano} ~/.bashrc" },
				{ label = "Edit .zshrc",  type = "shell", command = "${EDITOR:-nano} ~/.zshrc",  caps = { "shell" } },
			},
		},

		-- ── Windows ────────────────────────────────────────────────────────────

		{
			id          = "win-hosts-edit",
			title       = "Edit hosts file (Windows)",
			description = "Open C:\\Windows\\System32\\drivers\\etc\\hosts in Notepad. Requires running as Administrator.",
			tags        = { "network", "hosts", "dns" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open in Notepad", type = "shell", command = [[notepad C:\Windows\System32\drivers\etc\hosts]] },
			},
		},

		{
			id          = "win-dns-flush",
			title       = "Flush DNS cache (Windows)",
			description = "Clear the Windows DNS resolver cache. Run in Command Prompt or PowerShell as Administrator.",
			tags        = { "network", "dns", "cache" },
			platform    = { "windows" },
			actions     = {
				{ label = "Flush DNS", type = "shell", command = "ipconfig /flushdns" },
			},
		},

		{
			id          = "win-network-config",
			title       = "Show network configuration (Windows)",
			description = "Display full IP configuration including adapters, gateways, and DNS servers.",
			tags        = { "network", "ip", "config" },
			platform    = { "windows" },
			actions     = {
				{ label = "Show network config", type = "shell", command = "ipconfig /all" },
			},
		},

		{
			id          = "win-env-vars",
			title       = "Environment variables (Windows)",
			description = "Open the System Properties dialog to edit user and system environment variables.",
			tags        = { "environment", "path", "system" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open env vars dialog", type = "shell", command = "rundll32 sysdm.cpl,EditEnvironmentVariables" },
			},
		},

		{
			id          = "win-device-manager",
			title       = "Device Manager (Windows)",
			description = "View and manage hardware devices, drivers, and device status.",
			tags        = { "hardware", "drivers", "devices" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Device Manager", type = "shell", command = "devmgmt.msc" },
			},
		},

		{
			id          = "win-services",
			title       = "Services (Windows)",
			description = "View, start, stop, and configure Windows services.",
			tags        = { "services", "system", "startup" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Services", type = "shell", command = "services.msc" },
			},
		},

		{
			id          = "win-task-scheduler",
			title       = "Task Scheduler (Windows)",
			description = "Create and manage scheduled tasks that run programs or scripts automatically.",
			tags        = { "scheduler", "automation", "tasks" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Task Scheduler", type = "shell", command = "taskschd.msc" },
			},
		},

		{
			id          = "win-event-viewer",
			title       = "Event Viewer (Windows)",
			description = "Browse Windows system, security, and application event logs.",
			tags        = { "logs", "events", "diagnostics" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Event Viewer", type = "shell", command = "eventvwr.msc" },
			},
		},

		{
			id          = "win-startup-programs",
			title       = "Manage startup programs (Windows)",
			description = "Open Task Manager to the Startup tab to enable or disable programs that run at login. Alternatively, run msconfig for older-style startup management.",
			tags        = { "startup", "performance", "programs" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Task Manager (Startup tab)", type = "shell", command = "taskmgr",  caps = { "shell" } },
				{ label = "Open msconfig",                   type = "shell", command = "msconfig" },
			},
		},

		{
			id          = "win-focus-follows-mouse",
			title       = "Enable focus-follows-mouse (Windows)",
			description = 'Set registry key HKCU\\Control Panel\\Desktop → ActiveWndTrkTimeout=0 and enable window tracking via UserPreferencesMask. Requires relogin or explorer restart. Note: full X11-style focus-follows-mouse requires third-party tools like AutoHotkey.',
			tags        = { "window-management", "focus", "registry", "accessibility" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Registry Editor", type = "shell", command = "regedit" },
			},
		},

		{
			id          = "win-firewall",
			title       = "Windows Firewall with Advanced Security",
			description = "Configure inbound and outbound firewall rules, connection security rules, and monitoring.",
			tags        = { "firewall", "security", "network" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Firewall", type = "shell", command = "wf.msc" },
			},
		},

		{
			id          = "win-group-policy",
			title       = "Group Policy Editor (Windows Pro/Enterprise)",
			description = "Configure machine and user policy settings. Only available on Windows Pro and Enterprise editions.",
			tags        = { "policy", "security", "enterprise" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Group Policy Editor", type = "shell", command = "gpedit.msc" },
			},
		},

		{
			id          = "win-disk-management",
			title       = "Disk Management (Windows)",
			description = "View, partition, format, and assign drive letters to disks.",
			tags        = { "disk", "storage", "partitions" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Disk Management", type = "shell", command = "diskmgmt.msc" },
			},
		},

		{
			id          = "win-version",
			title       = "Check Windows version",
			description = "Show the Windows version, edition, and build number.",
			tags        = { "system", "info", "version" },
			platform    = { "windows" },
			actions     = {
				{ label = "Show Windows version", type = "shell", command = "winver" },
			},
		},

		{
			id          = "win-hyperv",
			title       = "Enable Hyper-V (Windows)",
			description = "Enable the Hyper-V hypervisor. Requires Windows Pro, Enterprise, or Education. Opens the Windows Features dialog or runs DISM.",
			tags        = { "virtualization", "hyper-v", "features" },
			platform    = { "windows" },
			actions     = {
				{ label = "Open Windows Features",   type = "shell", command = "optionalfeatures",                                                          caps = { "shell" } },
				{ label = "Enable via DISM (admin)", type = "shell", command = "dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /NoRestart" },
			},
		},
	},
}
