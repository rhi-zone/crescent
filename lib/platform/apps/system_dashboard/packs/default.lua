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
				{
					label = "Open in editor",
					caps  = { shell = { type = "shell", reason = "Edit /etc/hosts as root using sudoedit" } },
					exec  = { cap = "shell", args = "sudoedit /etc/hosts" },
				},
			},
		},

		{
			id          = "dns-flush-macos",
			title       = "Flush DNS cache (macOS)",
			description = "Clear the macOS DNS resolver cache. Run after editing /etc/hosts or changing DNS settings.",
			tags        = { "network", "dns", "cache" },
			platform    = { "macos" },
			actions     = {
				{
					label = "Flush DNS",
					caps  = { shell = { type = "shell", reason = "Flush the macOS DNS resolver cache via dscacheutil and mDNSResponder" } },
					exec  = { cap = "shell", args = "sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder" },
				},
			},
		},

		{
			id          = "dns-flush-linux",
			title       = "Flush DNS cache (Linux)",
			description = "Clear the systemd-resolved DNS cache. Run after editing /etc/hosts or changing DNS.",
			tags        = { "network", "dns", "cache" },
			platform    = { "linux" },
			actions     = {
				{
					label = "Flush DNS",
					caps  = { shell = { type = "shell", reason = "Flush the systemd-resolved DNS cache" } },
					exec  = { cap = "shell", args = "sudo systemd-resolve --flush-caches" },
				},
			},
		},

		{
			id          = "open-ports-linux",
			title       = "Show open listening ports (Linux)",
			description = "List all TCP ports currently listening for connections.",
			tags        = { "network", "ports", "security" },
			platform    = { "linux" },
			actions     = {
				{
					label = "Show ports",
					caps  = { shell = { type = "shell", reason = "List TCP sockets currently in the LISTEN state" } },
					exec  = { cap = "shell", args = "ss -tlnp" },
				},
			},
		},

		{
			id          = "open-ports-macos",
			title       = "Show open listening ports (macOS)",
			description = "List all TCP/UDP ports currently listening for connections.",
			tags        = { "network", "ports", "security" },
			platform    = { "macos" },
			actions     = {
				{
					label = "Show ports",
					caps  = { shell = { type = "shell", reason = "List all network files in LISTEN state via lsof" } },
					exec  = { cap = "shell", args = 'lsof -i -P -n | grep LISTEN' },
				},
			},
		},

		{
			id          = "disk-usage",
			title       = "Disk usage overview",
			description = "Show free and used disk space on all mounted filesystems.",
			tags        = { "disk", "storage", "system" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Show disk usage",
					caps  = { shell = { type = "shell", reason = "Display free and used space on all mounted filesystems" } },
					exec  = { cap = "shell", args = "df -h" },
				},
			},
		},

		{
			id          = "large-files",
			title       = "Find large files in current directory",
			description = "List subdirectories and files sorted by size, largest first.",
			tags        = { "disk", "storage", "files" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Find large files",
					caps  = { shell = { type = "shell", reason = "List entries in current directory sorted by size, largest first" } },
					exec  = { cap = "shell", args = "du -sh * | sort -rh | head -20" },
				},
			},
		},

		{
			id          = "env-vars",
			title       = "Show environment variables",
			description = "Print all currently-set environment variables, sorted alphabetically.",
			tags        = { "environment", "shell", "system" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Show env vars",
					caps  = { shell = { type = "shell", reason = "Print all environment variables sorted alphabetically" } },
					exec  = { cap = "shell", args = "printenv | sort | less" },
				},
			},
		},

		{
			id          = "crontab-edit",
			title       = "Edit crontab",
			description = "Open the current user's crontab for editing scheduled jobs.",
			tags        = { "cron", "scheduler", "automation" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Edit crontab",
					caps  = { shell = { type = "shell", reason = "Open the current user's crontab in the default editor" } },
					exec  = { cap = "shell", args = "crontab -e" },
				},
			},
		},

		{
			id          = "ssh-config-edit",
			title       = "Edit SSH config",
			description = "Open ~/.ssh/config in the default editor. Configure SSH host aliases, keys, and options.",
			tags        = { "ssh", "network", "config" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Edit SSH config",
					caps  = { shell = { type = "shell", reason = "Open ~/.ssh/config in the default editor" } },
					exec  = { cap = "shell", args = "${EDITOR:-nano} ~/.ssh/config" },
				},
			},
		},

		{
			id          = "ssh-keygen",
			title       = "Generate SSH key (ed25519)",
			description = "Create a new SSH key pair using the ed25519 algorithm.",
			tags        = { "ssh", "security", "keys" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Generate key",
					caps  = { shell = { type = "shell", reason = "Generate a new ed25519 SSH key pair interactively" } },
					exec  = { cap = "shell", args = "ssh-keygen -t ed25519" },
				},
			},
		},

		{
			id          = "system-info-linux",
			title       = "Show system info (Linux)",
			description = "Print kernel version and Linux distribution details.",
			tags        = { "system", "info", "kernel" },
			platform    = { "linux" },
			actions     = {
				{
					label = "Show system info",
					caps  = { shell = { type = "shell", reason = "Print kernel version and Linux distribution release details" } },
					exec  = { cap = "shell", args = "uname -a && lsb_release -a" },
				},
			},
		},

		{
			id          = "system-info-macos",
			title       = "Show system info (macOS)",
			description = "Print kernel version and macOS version details.",
			tags        = { "system", "info", "kernel" },
			platform    = { "macos" },
			actions     = {
				{
					label = "Show system info",
					caps  = { shell = { type = "shell", reason = "Print kernel version and macOS release details" } },
					exec  = { cap = "shell", args = "uname -a && sw_vers" },
				},
			},
		},

		{
			id          = "memory-linux",
			title       = "Show memory usage (Linux)",
			description = "Display RAM and swap usage in human-readable form.",
			tags        = { "memory", "system", "ram" },
			platform    = { "linux" },
			actions     = {
				{
					label = "Show memory",
					caps  = { shell = { type = "shell", reason = "Display RAM and swap usage in human-readable form" } },
					exec  = { cap = "shell", args = "free -h" },
				},
			},
		},

		{
			id          = "memory-macos",
			title       = "Show memory usage (macOS)",
			description = "Display virtual memory statistics including wired, active, and free memory.",
			tags        = { "memory", "system", "ram" },
			platform    = { "macos" },
			actions     = {
				{
					label = "Show memory",
					caps  = { shell = { type = "shell", reason = "Display macOS virtual memory statistics" } },
					exec  = { cap = "shell", args = "vm_stat" },
				},
			},
		},

		{
			id          = "sudoers-edit",
			title       = "Edit sudoers",
			description = "Open /etc/sudoers safely with visudo. Controls which users can run commands as root.",
			tags        = { "sudo", "security", "permissions" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Edit sudoers",
					caps  = { shell = { type = "shell", reason = "Open /etc/sudoers safely via visudo with syntax validation" } },
					exec  = { cap = "shell", args = "sudo visudo" },
				},
			},
		},

		{
			id          = "running-services-linux",
			title       = "Show running services (Linux)",
			description = "List all active systemd services currently running.",
			tags        = { "services", "systemd", "system" },
			platform    = { "linux" },
			actions     = {
				{
					label = "List services",
					caps  = { shell = { type = "shell", reason = "List all active systemd services in the running state" } },
					exec  = { cap = "shell", args = "systemctl list-units --type=service --state=running" },
				},
			},
		},

		{
			id          = "running-services-macos",
			title       = "Show running services (macOS)",
			description = "List launchd agents and daemons that are running, excluding Apple system services.",
			tags        = { "services", "launchd", "system" },
			platform    = { "macos" },
			actions     = {
				{
					label = "List services",
					caps  = { shell = { type = "shell", reason = "List running launchd agents and daemons excluding Apple system entries" } },
					exec  = { cap = "shell", args = 'launchctl list | grep -v "com.apple"' },
				},
			},
		},

		{
			id          = "restart-network-linux",
			title       = "Restart networking (Linux)",
			description = "Restart the NetworkManager service to re-apply network configuration.",
			tags        = { "network", "networking", "restart" },
			platform    = { "linux" },
			actions     = {
				{
					label = "Restart network",
					caps  = { shell = { type = "shell", reason = "Restart NetworkManager to re-apply network configuration" } },
					exec  = { cap = "shell", args = "sudo systemctl restart NetworkManager" },
				},
			},
		},

		{
			id          = "restart-network-macos",
			title       = "Restart networking (macOS)",
			description = "Bring en0 (primary interface) down and back up to refresh network state.",
			tags        = { "network", "networking", "restart" },
			platform    = { "macos" },
			actions     = {
				{
					label = "Restart network",
					caps  = { shell = { type = "shell", reason = "Bring the en0 interface down and back up to refresh network state" } },
					exec  = { cap = "shell", args = "sudo ifconfig en0 down && sudo ifconfig en0 up" },
				},
			},
		},

		{
			id          = "path-add-permanently",
			title       = "Add directory to PATH permanently",
			description = 'Add "export PATH=\\"$PATH:/your/path\\"" to ~/.bashrc (bash) or ~/.zshrc (zsh), then reload with "source ~/.bashrc" or "source ~/.zshrc".',
			tags        = { "environment", "path", "shell" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Edit .bashrc",
					caps  = { shell = { type = "shell", reason = "Open ~/.bashrc in the default editor to add a PATH entry" } },
					exec  = { cap = "shell", args = "${EDITOR:-nano} ~/.bashrc" },
				},
				{
					label = "Edit .zshrc",
					caps  = { shell = { type = "shell", reason = "Open ~/.zshrc in the default editor to add a PATH entry" } },
					exec  = { cap = "shell", args = "${EDITOR:-nano} ~/.zshrc" },
				},
			},
		},

		{
			id          = "shell-profile-edit",
			title       = "Edit shell profile",
			description = "Open ~/.bashrc in the default editor. For zsh users, edit ~/.zshrc instead.",
			tags        = { "shell", "profile", "config" },
			platform    = { "linux", "macos" },
			actions     = {
				{
					label = "Edit .bashrc",
					caps  = { shell = { type = "shell", reason = "Open ~/.bashrc in the default editor" } },
					exec  = { cap = "shell", args = "${EDITOR:-nano} ~/.bashrc" },
				},
				{
					label = "Edit .zshrc",
					caps  = { shell = { type = "shell", reason = "Open ~/.zshrc in the default editor" } },
					exec  = { cap = "shell", args = "${EDITOR:-nano} ~/.zshrc" },
				},
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
				{
					label = "Open in Notepad",
					caps  = { shell = { type = "shell", reason = "Open the Windows hosts file in Notepad for editing" } },
					exec  = { cap = "shell", args = [[notepad C:\Windows\System32\drivers\etc\hosts]] },
				},
			},
		},

		{
			id          = "win-reg-product-name",
			title       = "Windows product name (registry)",
			description = "Read the Windows product name from HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion.",
			tags        = { "system", "info", "registry" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Read product name",
					caps  = {
						reg = {
							type        = "registry",
							reason      = "Read the Windows product edition name from the OS version registry key",
							root        = [[HKLM\Software\Microsoft\Windows NT\CurrentVersion]],
							allow_write = false,
						},
					},
					exec  = { cap = "reg", op = "get", name = "ProductName" },
				},
			},
		},

		{
			id          = "win-reg-list-startup",
			title       = "Startup programs (registry)",
			description = "List user-level startup programs registered under HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run.",
			tags        = { "startup", "autorun", "registry" },
			platform    = { "windows" },
			actions     = {
				{
					label = "List startup entries",
					caps  = {
						reg = {
							type        = "registry",
							reason      = "List the value names under the current-user Run key to show startup programs",
							root        = [[HKCU\Software\Microsoft\Windows\CurrentVersion\Run]],
							allow_write = false,
						},
					},
					exec  = { cap = "reg", op = "list_values" },
				},
			},
		},

		{
			id          = "win-dns-flush",
			title       = "Flush DNS cache (Windows)",
			description = "Clear the Windows DNS resolver cache. Run in Command Prompt or PowerShell as Administrator.",
			tags        = { "network", "dns", "cache" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Flush DNS",
					caps  = { shell = { type = "shell", reason = "Flush the Windows DNS resolver cache" } },
					exec  = { cap = "shell", args = "ipconfig /flushdns" },
				},
			},
		},

		{
			id          = "win-network-config",
			title       = "Show network configuration (Windows)",
			description = "Display full IP configuration including adapters, gateways, and DNS servers.",
			tags        = { "network", "ip", "config" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Show network config",
					caps  = { shell = { type = "shell", reason = "Display full Windows IP configuration for all adapters" } },
					exec  = { cap = "shell", args = "ipconfig /all" },
				},
			},
		},

		{
			id          = "win-env-vars",
			title       = "Environment variables (Windows)",
			description = "Open the System Properties dialog to edit user and system environment variables.",
			tags        = { "environment", "path", "system" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open env vars dialog",
					caps  = { shell = { type = "shell", reason = "Open the Windows environment variables dialog via System Properties" } },
					exec  = { cap = "shell", args = "rundll32 sysdm.cpl,EditEnvironmentVariables" },
				},
			},
		},

		{
			id          = "win-device-manager",
			title       = "Device Manager (Windows)",
			description = "View and manage hardware devices, drivers, and device status.",
			tags        = { "hardware", "drivers", "devices" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Device Manager",
					caps  = { shell = { type = "shell", reason = "Open the Windows Device Manager MMC snap-in" } },
					exec  = { cap = "shell", args = "devmgmt.msc" },
				},
			},
		},

		{
			id          = "win-services",
			title       = "Services (Windows)",
			description = "View, start, stop, and configure Windows services.",
			tags        = { "services", "system", "startup" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Services",
					caps  = { shell = { type = "shell", reason = "Open the Windows Services MMC snap-in" } },
					exec  = { cap = "shell", args = "services.msc" },
				},
			},
		},

		{
			id          = "win-task-scheduler",
			title       = "Task Scheduler (Windows)",
			description = "Create and manage scheduled tasks that run programs or scripts automatically.",
			tags        = { "scheduler", "automation", "tasks" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Task Scheduler",
					caps  = { shell = { type = "shell", reason = "Open the Windows Task Scheduler MMC snap-in" } },
					exec  = { cap = "shell", args = "taskschd.msc" },
				},
			},
		},

		{
			id          = "win-event-viewer",
			title       = "Event Viewer (Windows)",
			description = "Browse Windows system, security, and application event logs.",
			tags        = { "logs", "events", "diagnostics" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Event Viewer",
					caps  = { shell = { type = "shell", reason = "Open the Windows Event Viewer MMC snap-in" } },
					exec  = { cap = "shell", args = "eventvwr.msc" },
				},
			},
		},

		{
			id          = "win-startup-programs",
			title       = "Manage startup programs (Windows)",
			description = "Open Task Manager to the Startup tab to enable or disable programs that run at login. Alternatively, run msconfig for older-style startup management.",
			tags        = { "startup", "performance", "programs" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Task Manager (Startup tab)",
					caps  = { shell = { type = "shell", reason = "Open Task Manager to review and toggle startup programs" } },
					exec  = { cap = "shell", args = "taskmgr" },
				},
				{
					label = "Open msconfig",
					caps  = { shell = { type = "shell", reason = "Open System Configuration (msconfig) for startup management" } },
					exec  = { cap = "shell", args = "msconfig" },
				},
			},
		},

		{
			id          = "win-focus-follows-mouse",
			title       = "Enable focus-follows-mouse (Windows)",
			description = 'Set registry key HKCU\\Control Panel\\Desktop → ActiveWndTrkTimeout=0 and enable window tracking via UserPreferencesMask. Requires relogin or explorer restart. Note: full X11-style focus-follows-mouse requires third-party tools like AutoHotkey.',
			tags        = { "window-management", "focus", "registry", "accessibility" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Registry Editor",
					caps  = { shell = { type = "shell", reason = "Open the Windows Registry Editor to configure focus-follows-mouse keys" } },
					exec  = { cap = "shell", args = "regedit" },
				},
			},
		},

		{
			id          = "win-firewall",
			title       = "Windows Firewall with Advanced Security",
			description = "Configure inbound and outbound firewall rules, connection security rules, and monitoring.",
			tags        = { "firewall", "security", "network" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Firewall",
					caps  = { shell = { type = "shell", reason = "Open Windows Firewall with Advanced Security MMC snap-in" } },
					exec  = { cap = "shell", args = "wf.msc" },
				},
			},
		},

		{
			id          = "win-group-policy",
			title       = "Group Policy Editor (Windows Pro/Enterprise)",
			description = "Configure machine and user policy settings. Only available on Windows Pro and Enterprise editions.",
			tags        = { "policy", "security", "enterprise" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Group Policy Editor",
					caps  = { shell = { type = "shell", reason = "Open the Local Group Policy Editor MMC snap-in" } },
					exec  = { cap = "shell", args = "gpedit.msc" },
				},
			},
		},

		{
			id          = "win-disk-management",
			title       = "Disk Management (Windows)",
			description = "View, partition, format, and assign drive letters to disks.",
			tags        = { "disk", "storage", "partitions" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Disk Management",
					caps  = { shell = { type = "shell", reason = "Open the Windows Disk Management MMC snap-in" } },
					exec  = { cap = "shell", args = "diskmgmt.msc" },
				},
			},
		},

		{
			id          = "win-version",
			title       = "Check Windows version",
			description = "Show the Windows version, edition, and build number.",
			tags        = { "system", "info", "version" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Show Windows version",
					caps  = { shell = { type = "shell", reason = "Display the Windows version, edition, and build number dialog" } },
					exec  = { cap = "shell", args = "winver" },
				},
			},
		},

		{
			id          = "win-hyperv",
			title       = "Enable Hyper-V (Windows)",
			description = "Enable the Hyper-V hypervisor. Requires Windows Pro, Enterprise, or Education. Opens the Windows Features dialog or runs DISM.",
			tags        = { "virtualization", "hyper-v", "features" },
			platform    = { "windows" },
			actions     = {
				{
					label = "Open Windows Features",
					caps  = { shell = { type = "shell", reason = "Open the Windows Optional Features dialog to enable Hyper-V" } },
					exec  = { cap = "shell", args = "optionalfeatures" },
				},
				{
					label = "Enable via DISM (admin)",
					caps  = { shell = { type = "shell", reason = "Enable Hyper-V and all sub-features via DISM without restarting" } },
					exec  = { cap = "shell", args = "dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /NoRestart" },
				},
			},
		},
	},
}
